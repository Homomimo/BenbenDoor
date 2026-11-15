import Foundation
import Security

struct DoorKey: Codable {
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
    var timeZone: TimeZone? {
        let parts = timezone.split(separator: ":")
        guard parts.count == 2, let hours = Int(parts[0]), let minutes = Int(parts[1]),
              minutes >= 0, minutes < 60 else { return nil }
        let negative = timezone.hasPrefix("-")
        return TimeZone(secondsFromGMT: hours * 3600 + (negative ? -minutes : minutes) * 60)
    }

    static func parseDate(_ text: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = f.date(from: text) { return date }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: text)
    }

    func validate(at now: Date = Date()) throws {
        guard schemaVersion == 1, !deviceID.isEmpty,
              advertisedName == "KD-\(deviceID)", !agentID.isEmpty, !sysID.isEmpty,
              agentID.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }),
              sysID.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }),
              let begin = start, let finish = end, begin < finish,
              timeZone != nil, UInt64(config) != nil else {
            throw DoorError.message("配置格式不正确，请重新导入。")
        }
        guard now >= begin else { throw DoorError.message("钥匙尚未生效。") }
        guard now <= finish else { throw DoorError.message("钥匙已过期，请更新配置。") }
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
                         deadline: Date, now: Date = Date()) throws {
        guard now <= deadline else { throw DoorError.message("本次请求已过期，已停止发送。") }
        if background {
            guard enabled else { throw DoorError.message("请先在 App 设置开启“允许锁屏快捷开门”。") }
        } else {
            guard foreground else { throw DoorError.message("请保持 App 在前台。") }
        }
    }
}

enum KeyStore {
    static var backgroundUnlockEnabled: Bool { UserDefaults.standard.bool(forKey: "backgroundUnlockEnabled") }
    static func setBackgroundUnlockEnabled(_ enabled: Bool) throws {
        guard let key = try load() else { throw DoorError.message("请先导入门锁配置。") }
        try save(key, background: enabled)
        UserDefaults.standard.set(enabled, forKey: "backgroundUnlockEnabled")
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
        UserDefaults.standard.removeObject(forKey: "backgroundUnlockEnabled")
    }
}
