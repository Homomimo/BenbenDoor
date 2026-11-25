import Foundation
import Security
import CryptoKit

struct DoorKey: Codable, Sendable {
    var schemaVersion: Int
    var displayName: String
    var deviceID: String
    var advertisedName: String
    var agentID: String
    var sysID: String
    var region: UInt8
    var subregion: UInt16
    var devID: UInt16
    var seqNo: UInt32
    var validFrom: String
    var validUntil: String
    var timezone: String
    var config: String

    var start: Date? { Self.parseDate(validFrom) }
    var end: Date? { Self.parseDate(validUntil) }
    var connectionIdentity: String { "\(deviceID)|\(region)|\(subregion)|\(devID)" }
    var authorizationIdentity: String {
        // Bind rollback tracking to this authorization without copying its
        // credential fields into plaintext preferences or diagnostic logs.
        let scope = [connectionIdentity, agentID, sysID, String(seqNo), validFrom, validUntil, timezone, config]
        let encoder = JSONEncoder()
        let data = (try? encoder.encode(scope)) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    var timeZone: TimeZone? {
        let bytes = Array(timezone.utf8)
        guard bytes.count == 6, bytes[0] == 43 || bytes[0] == 45, bytes[3] == 58,
              [1, 2, 4, 5].allSatisfy({ (48...57).contains(bytes[$0]) }) else { return nil }
        let hours = Int(bytes[1] - 48) * 10 + Int(bytes[2] - 48)
        let minutes = Int(bytes[4] - 48) * 10 + Int(bytes[5] - 48)
        guard hours <= 14, minutes < 60, hours != 14 || minutes == 0 else { return nil }
        return TimeZone(secondsFromGMT: (hours * 3600 + minutes * 60) * (bytes[0] == 45 ? -1 : 1))
    }

    static func parseDate(_ text: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = f.date(from: text) { return date }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: text)
    }

    func validate(at now: Date = Date()) throws {
        try validity().check(now)
    }

    func validity() throws -> DoorValidity {
        guard schemaVersion == 1, !deviceID.isEmpty,
              advertisedName == "KD-\(deviceID)", !agentID.isEmpty, !sysID.isEmpty,
              agentID.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }),
              sysID.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }),
              let begin = start, let finish = end, begin < finish,
              timeZone != nil, UInt64(config) != nil else {
            throw DoorError.message("配置格式不正确，请重新导入。")
        }
        return DoorValidity(begin: begin, finish: finish)
    }
}

struct DoorValidity {
    let begin: Date
    let finish: Date
    func check(_ now: Date) throws {
        guard now >= begin else { throw DoorError.message("钥匙尚未生效。") }
        guard now <= finish else { throw DoorError.message("钥匙已过期，请更新配置。") }
    }
}

// Only retained during one request. The key is still loaded from Keychain for every request.
struct DoorRequestKey {
    let key: DoorKey
    let validity: DoorValidity
    let authorization: String
    let priorSubmission: DoorClockRecord?

    init(_ key: DoorKey, priorSubmission: DoorClockRecord?) throws {
        self.key = key
        self.validity = try key.validity()
        self.authorization = key.authorizationIdentity
        self.priorSubmission = priorSubmission
    }

    func clockBlocks(at now: Date) -> Bool {
        priorSubmission?.blocks(authorization: authorization, at: now) == true
    }
}

// A scanned success only rehabilitates a different peripheral; retry the same
// failed direct route after its short cooldown. The saved date is a routing hint.
struct DoorDirectFailure: Codable {
    let identity: String
    let peripheral: UUID
    let failedAt: Date
    static let cooldown: TimeInterval = 60

    func remaining(at now: Date) -> TimeInterval {
        let age = now.timeIntervalSince(failedAt)
        return (0..<Self.cooldown).contains(age) ? Self.cooldown - age : 0
    }
    func matches(_ identity: String, _ peripheral: UUID) -> Bool {
        self.identity == identity && self.peripheral == peripheral
    }

    struct Active {
        let failure: DoorDirectFailure
        let until: ContinuousClock.Instant
        func prefersScan(_ identity: String, _ peripheral: UUID, at instant: ContinuousClock.Instant = ContinuousClock().now) -> Bool {
            instant < until && failure.matches(identity, peripheral)
        }
        func retainAfterSuccess(direct: Bool, identity: String, peripheral: UUID,
                                at instant: ContinuousClock.Instant = ContinuousClock().now) -> Bool {
            !direct && prefersScan(identity, peripheral, at: instant)
        }
    }
}

enum DoorError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self { case .message(let text): return text }
    }
}

enum DoorUnlockPolicy {
    static func validate(background: Bool, enabled: Bool, foreground: Bool,
                         deadline: ContinuousClock.Instant, now: ContinuousClock.Instant = ContinuousClock().now) throws {
        guard now < deadline else { throw DoorError.message("本次请求已过期，已停止发送。") }
        if background {
            guard enabled else { throw DoorError.message("请先在 App 设置开启“允许锁屏快捷开门”。") }
        } else {
            guard foreground else { throw DoorError.message("请保持 App 在前台。") }
        }
    }
}

enum DoorCompletionText {
    static func message(_ reason: String, submitted: Bool, confirmed: Bool) -> String {
        submitted && !confirmed ? reason + " 开门指令已提交，未收到门锁最终结果，请先确认现场状态。" : reason
    }
}

enum AppVersion {
    static var display: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "未知"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "未知"
        return "\(version) · Build \(build)"
    }
}

struct DoorClockRecord: Codable {
    let authorization: String
    let submittedAt: Date
    static func load(from defaults: UserDefaults = .standard) throws -> Self? {
        guard let value = defaults.object(forKey: "doorClockRecord") else { return nil }
        guard let data = value as? Data, let record = try? JSONDecoder().decode(Self.self, from: data),
              record.authorization.utf8.count == 64,
              record.authorization.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw DoorError.message("上次操作时间记录无法读取，请在 App 设置中核对并确认手机时间。")
        }
        return record
    }
    func blocks(authorization current: String, at now: Date) -> Bool {
        authorization == current && now < submittedAt
    }
}

struct DoorKeyImportCopy: Sendable {
    let url: URL
    private let directory: URL

    struct Outcome<Value> {
        let result: Result<Value, Error>
        let cleanupError: Error?
    }

    private static var pickerCopyRoots: [URL] {
        [FileManager.default.temporaryDirectory] + FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
            .map { $0.appendingPathComponent("Inbox", isDirectory: true) }
    }

    // Call synchronously once at process startup, before any import can claim
    // a copy. A crash can leave our own staging directory across launches.
    static func cleanupAbandonedCopies(in root: URL = FileManager.default.temporaryDirectory) -> [Error] {
        let manager = FileManager.default
        let candidates: [URL]
        do { candidates = try manager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) }
        catch { return [error] }
        var failures: [Error] = []
        let prefix = "BenbenDoorImport-"
        let rootComponents = root.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        for candidate in candidates {
            let name = candidate.lastPathComponent
            guard name.hasPrefix(prefix) else { continue }
            let suffix = String(name.dropFirst(prefix.count))
            guard suffix.count == 36, UUID(uuidString: suffix) != nil else { continue }
            do {
                let attributes = try manager.attributesOfItem(atPath: candidate.path)
                guard attributes[.type] as? FileAttributeType == .typeDirectory else { continue }
                let components = candidate.standardizedFileURL.resolvingSymlinksInPath().pathComponents
                guard components.count == rootComponents.count + 1, components.starts(with: rootComponents) else { continue }
                try removeIfPresent(candidate)
            } catch { failures.append(error) }
        }
        return failures
    }

    // Only the asCopy document-picker delegate may transfer ownership here.
    // General URL reads never acquire deletion rights over the selected file.
    static func claimPickerCopy(_ url: URL, allowedRoots: [URL]? = nil) throws -> DoorKeyImportCopy {
        let manager = FileManager.default
        guard url.isFileURL else { throw DoorError.message("无法接管配置临时副本，请改用粘贴导入。") }
        let file = url.standardizedFileURL
        let resolved = file.resolvingSymlinksInPath().pathComponents
        let owned = (allowedRoots ?? pickerCopyRoots).contains { root in
            let components = root.standardizedFileURL.resolvingSymlinksInPath().pathComponents
            return root.isFileURL && resolved.count > components.count && resolved.starts(with: components)
        }
        guard owned else { throw DoorError.message("无法确认配置临时副本的位置，请改用粘贴导入。") }
        let attributes = try manager.attributesOfItem(atPath: file.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular else {
            throw DoorError.message("请选择普通配置文件，不要选择文件夹或文件链接。")
        }
        let directory = manager.temporaryDirectory.appendingPathComponent("BenbenDoorImport-\(UUID().uuidString)", isDirectory: true)
        let destination = directory.appendingPathComponent("configuration.json")
        do {
            try manager.createDirectory(at: directory, withIntermediateDirectories: false)
            // Claim once before starting an async read. A duplicate delegate
            // callback cannot remove a file already being read by another task.
            try manager.moveItem(at: file, to: destination)
        } catch {
            let preparationError = error as NSError
            var cleanupError: NSError?
            for candidate in [directory, file] {
                do { try removeIfPresent(candidate) }
                catch { cleanupError = error as NSError }
            }
            if let cleanupError {
                throw DoorError.message("无法准备配置副本（诊断编号 \(preparationError.code)）；临时副本清理失败（\(cleanupError.domain)/\(cleanupError.code)），请完全退出 App 后重试。")
            }
            throw error
        }
        return DoorKeyImportCopy(url: destination, directory: directory)
    }

    @MainActor
    func consume<Value>(removeItem: ((URL) throws -> Void)? = nil,
                        operation: () async throws -> Value) async -> Outcome<Value> {
        let result: Result<Value, Error>
        do {
            try Task.checkCancellation()
            result = .success(try await operation())
        } catch { result = .failure(error) }
        // Await the real read even when its caller was cancelled. Removing the
        // copy in a cancellation handler could race FileHandle/coordination.
        do {
            if let removeItem { try removeItem(directory) }
            else { try Self.removeIfPresent(directory) }
            return Outcome(result: result, cleanupError: nil)
        } catch { return Outcome(result: result, cleanupError: error) }
    }

    private static func removeIfPresent(_ url: URL) throws {
        do { try FileManager.default.removeItem(at: url) }
        catch {
            let failure = error as NSError
            guard failure.domain == NSCocoaErrorDomain && failure.code == NSFileNoSuchFileError else { throw error }
        }
    }
}

enum DoorKeyImporter {
    static let sizeLimit = 64 * 1024
    static func decodePasted(_ text: String) throws -> DoorKey {
        guard text.utf8.prefix(sizeLimit + 1).count <= sizeLimit else {
            throw DoorError.message("配置内容过大（最多 64 KB）。")
        }
        return try decode(Data(text.trimmingCharacters(in: .whitespacesAndNewlines).utf8))
    }
    static func decode(_ input: Data) throws -> DoorKey {
        guard input.count <= sizeLimit else { throw DoorError.message("配置文件过大。") }
        var data = input
        if data.starts(with: [0xEF, 0xBB, 0xBF]) { data.removeFirst(3) }
        let key: DoorKey
        do { key = try JSONDecoder().decode(DoorKey.self, from: data) }
        catch { throw DoorError.message("内容不是有效的门锁配置 JSON，请导入完整配置。") }
        try key.validate()
        return key
    }

    static func read(_ url: URL) throws -> DoorKey {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        var result: Result<DoorKey, Error>?
        var coordinationError: NSError?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { readableURL in
            result = Result {
                let values = try readableURL.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey])
                guard values.isDirectory != true else { throw DoorError.message("请选择配置文件，不要选择文件夹。") }
                guard (values.fileSize ?? 0) <= sizeLimit else { throw DoorError.message("配置文件过大。") }
                let file = try FileHandle(forReadingFrom: readableURL)
                defer { try? file.close() }
                // Bound reads even if the provider cannot report a size, and
                // continue short reads until EOF instead of decoding a prefix.
                var data = Data()
                while data.count <= sizeLimit {
                    guard let chunk = try file.read(upToCount: sizeLimit + 1 - data.count), !chunk.isEmpty else { break }
                    data.append(chunk)
                }
                return try decode(data)
            }
        }
        if let error = coordinationError { throw error }
        guard let result else { throw DoorError.message("无法读取配置，请先在“文件”App 中下载到本机后重试。") }
        return try result.get()
    }
}

enum KeyStore {
    static let backgroundUnlockPreference = "backgroundUnlockEnabled"
    static var backgroundUnlockEnabled: Bool { UserDefaults.standard.bool(forKey: backgroundUnlockPreference) }
    static func setBackgroundUnlockEnabled(_ enabled: Bool) throws {
        guard let key = try load() else { throw DoorError.message("请先导入门锁配置。") }
        try save(key, background: enabled)
        UserDefaults.standard.set(enabled, forKey: backgroundUnlockPreference)
    }
    private static let service = "BenbenDoor.local-key"
    private static let account = "active-door"
    static func load() throws -> DoorKey? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: account,
            kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        let code = SecItemCopyMatching(query as CFDictionary, &result)
        if code == errSecItemNotFound { return nil }
        guard code == errSecSuccess, let data = result as? Data else {
            throw DoorError.message("读取钥匙失败（\(code)）。")
        }
        return try JSONDecoder().decode(DoorKey.self, from: data)
    }
    static func save(_ key: DoorKey, background: Bool? = nil) throws {
        let data = try JSONEncoder().encode(key)
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: account]
        let attributes: [String: Any] = [kSecValueData as String: data,
            kSecAttrAccessible as String: (background ?? backgroundUnlockEnabled)
                ? kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly : kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            let create = query.merging(attributes) { _, new in new }
            let result = SecItemAdd(create as CFDictionary, nil)
            guard result == errSecSuccess else { throw DoorError.message("保存失败（\(result)）。") }
        } else if status != errSecSuccess {
            throw DoorError.message("保存失败（\(status)）。")
        }
    }
    static func delete() throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: account]
        let code = SecItemDelete(query as CFDictionary)
        guard code == errSecSuccess || code == errSecItemNotFound else {
            throw DoorError.message("删除失败（\(code)）。")
        }
        UserDefaults.standard.removeObject(forKey: backgroundUnlockPreference)
    }
}
