import Foundation
import Combine
@preconcurrency import CoreBluetooth
import UIKit

@MainActor
final class BluetoothDoor: NSObject, ObservableObject, @preconcurrency CBCentralManagerDelegate, @preconcurrency CBPeripheralDelegate {
    static let shared = BluetoothDoor()
    @Published private(set) var doorName = "尚未配置门锁"
    @Published private(set) var status = "导入配置后即可测试"
    @Published private(set) var isBusy = false
    @Published private(set) var isImporting = false
    @Published private(set) var needsClockConfirmation = false
    @Published private(set) var hasKey = false
    @Published private(set) var lastSucceeded = false
    @Published private(set) var log: [String] = []
    @Published var includePacketBytes = false

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var writeCharacteristic: CBCharacteristic?
    private var notifyCharacteristic: CBCharacteristic?
    private var timeout: DispatchWorkItem?
    private var fragmentWatchdog: DispatchWorkItem?
    private var key: DoorKey?
    private var stage = Stage.idle
    private var responses = DoorResponseSession()
    private enum Command: Equatable { case select, unlock }
    private var pendingWrite: Command?
    private var backgroundOperation = false
    private var requestDeadline: ContinuousClock.Instant?
    private var requestStarted: ContinuousClock.Instant?
    private var timingMark: ContinuousClock.Instant?
    private var completion: ((Result<String, Error>) -> Void)?
    private var requestID: UUID?
    private var requestTag: String?
    private var overallTimeout: DispatchWorkItem?
    private var usingRememberedPeripheral = false
    private var retiringPeripheral: CBPeripheral?
    private var failedDirectConnection: (identity: String, until: ContinuousClock.Instant)?
    private var connectionRoute = "尚未连接"
    private var persistedLog: [String] = []
    private var logFlush: DispatchWorkItem?
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private static let logFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()
    private enum DoorTimeout {
        static let overall: TimeInterval = 25
        static let bluetoothReady: TimeInterval = 12
        static let scan: TimeInterval = 10
        static let rememberedConnect: TimeInterval = 5
        static let connect: TimeInterval = 10
        static let disconnect: TimeInterval = 2
        static let discovery: TimeInterval = 8
        static let select: TimeInterval = 6
        static let unlock: TimeInterval = 8
    }
    private enum Stage { case idle, waitingBluetooth, scanning, connecting, disconnectingForScan, discovering, selecting, unlocking }

    private func bluetoothDescription(_ state: CBManagerState) -> String {
        switch state {
        case .unknown: return "正在检查蓝牙"
        case .resetting: return "蓝牙正在重新初始化，请稍候"
        case .unsupported: return "此设备不支持所需蓝牙功能"
        case .unauthorized: return "尚未允许 App 使用蓝牙，请检查系统设置"
        case .poweredOff: return "蓝牙已关闭，请打开蓝牙"
        case .poweredOn: return "蓝牙已开启，可以寻找门锁"
        @unknown default: return "暂时无法识别蓝牙状态（诊断编号 \(state.rawValue)）"
        }
    }

    private var appStateDescription: String {
        switch UIApplication.shared.applicationState {
        case .active: return "App 正在前台使用"
        case .inactive: return "App 正在切换状态"
        case .background: return "App 正在后台运行"
        @unknown default: return "App 运行状态暂时未知"
        }
    }

    override init() {
        super.init()
        log = UserDefaults.standard.stringArray(forKey: "recentDoorDiagnostics") ?? []
        persistedLog = log
        for error in DoorKeyImportCopy.cleanupAbandonedCopies() { reportImportCleanupFailure(error) }
        reloadKey()
        central = CBCentralManager(delegate: self, queue: .main)
    }

    func reloadKey() {
        do {
            key = try KeyStore.load()
            hasKey = key != nil
            doorName = key?.displayName ?? "尚未配置门锁"
            needsClockConfirmation = key.map { clockRecord()?.blocks($0, at: Date()) == true } ?? false
            status = hasKey ? "准备就绪" : "导入配置后即可测试"
        } catch {
            key = nil; hasKey = false; doorName = "钥匙暂时不可读取"
            status = error.localizedDescription
        }
    }

    func importKey(from url: URL) async -> Bool {
        guard !isBusy, !isImporting else { return false }
        isImporting = true; status = "正在读取并校验配置…"
        defer { isImporting = false }
        do {
            let imported = try await Task.detached(priority: .userInitiated) { try DoorKeyImporter.read(url) }.value
            try Task.checkCancellation()
            try saveImportedKey(imported)
            return true
        } catch { reportImportFailure(error); return false }
    }

    func importKey(text: String) async -> Bool {
        guard !isBusy, !isImporting else { return false }
        isImporting = true; status = "正在校验配置…"
        defer { isImporting = false }
        do {
            let imported = try await Task.detached(priority: .userInitiated) {
                try DoorKeyImporter.decode(Data(text.trimmingCharacters(in: .whitespacesAndNewlines).utf8))
            }.value
            try Task.checkCancellation()
            try saveImportedKey(imported)
            return true
        } catch { reportImportFailure(error); return false }
    }

    private func saveImportedKey(_ imported: DoorKey) throws {
        try imported.validate()
        let previous = key
        try KeyStore.save(imported)
        // Commit dependent state only after Keychain succeeds. A renewal for
        // the same physical door retains its known peripheral UUID.
        if previous?.connectionIdentity != imported.connectionIdentity { clearConnectionCache() }
        key = imported; hasKey = true; doorName = imported.displayName; lastSucceeded = false
        needsClockConfirmation = clockRecord()?.blocks(imported, at: Date()) == true
        status = "已导入配置：\(imported.displayName)"
        append(status)
        flushLog()
    }

    func reportImportFailure(_ error: Error) {
        let failure = error as NSError
        if failure.domain == NSCocoaErrorDomain && failure.code == NSUserCancelledError { return }
        status = "导入失败：\(error.localizedDescription)"
        append(status)
    }

    func reportImportCleanupFailure(_ error: Error) {
        let failure = error as NSError
        append("临时配置副本清理未完成；诊断类型 \(failure.domain)，编号 \(failure.code)。钥匙保存结果未改变。")
        flushLog()
    }

    func removeKey() {
        guard !isBusy, !isImporting else { return }
        do {
            try KeyStore.delete()
            clearConnectionCache()
            UserDefaults.standard.removeObject(forKey: "doorClockRecord")
            UserDefaults.standard.removeObject(forKey: "lastUnlockRequest")
            needsClockConfirmation = false
            reloadKey(); append("已移除本机钥匙")
            flushLog()
        }
        catch { status = error.localizedDescription }
    }

    func start() { begin(background: false, completion: nil) }

    func recordShortcutEvent(_ message: String) { append("快捷指令：\(message)") }

    @MainActor func unlockFromShortcut() async throws -> String {
        let id = UUID()
        return try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
                begin(background: true, id: id) { continuation.resume(with: $0) }
            }
        }, onCancel: {
            Task { @MainActor in
                if self.requestID == id { self.cancel() }
            }
        })
    }

    func appEnteredBackground() {
        if !backgroundOperation { cancel() }
        flushLog()
    }

    func appBecameActive() {
        if isBusy { _ = requestIsCurrent() }
        else if !isImporting && !hasKey { reloadKey() }
    }

    private func requestIsCurrent() -> Bool {
        guard isBusy, let deadline = requestDeadline else { return false }
        guard ContinuousClock().now < deadline else {
            finish("本次开门请求已过期，已停止后续操作；如已发送指令，请确认门锁现场状态。", success: false)
            return false
        }
        return true
    }

    private func begin(background: Bool, id: UUID = UUID(), completion callback: ((Result<String, Error>) -> Void)?) {
        guard !isBusy else {
            callback?(.failure(DoorError.message("已有开门操作正在进行，请等待结果。"))); return
        }
        guard !isImporting else {
            callback?(.failure(DoorError.message("正在导入钥匙，请完成后重试。"))); return
        }
        guard retiringPeripheral == nil else {
            status = "蓝牙正在结束上次连接，请稍候后重试。"
            callback?(.failure(DoorError.message(status))); return
        }
        guard background || UIApplication.shared.applicationState == .active else { return }
        if background && !KeyStore.backgroundUnlockEnabled {
            callback?(.failure(DoorError.message("请先在 App 设置开启“允许锁屏快捷开门”。"))); return
        }
        backgroundOperation = background
        completion = callback; requestID = id; requestTag = String(id.uuidString.prefix(4))
        responses.reset()
        requestStarted = ContinuousClock().now; timingMark = requestStarted
        connectionRoute = "尚未连接"
        append("收到开门请求，来自\(background ? "快捷指令" : "App 按钮或小组件")；\(appStateDescription)；\(bluetoothDescription(central.state))")
        do {
            guard let stored = try KeyStore.load() else {
                throw DoorError.message("请先导入门锁配置。")
            }
            try stored.validate()
            try validateClock(stored)
            key = stored
            hasKey = true
            doorName = stored.displayName
            lastSucceeded = false
            isBusy = true
            stage = .waitingBluetooth
            // A stale connection must never issue an unlock after the request window.
            requestDeadline = ContinuousClock().now.advanced(by: .seconds(DoorTimeout.overall))
            let watchdog = DispatchWorkItem { [weak self] in
                guard let self, self.requestID == id else { return }
                self.finish("本次开门已超时；如已发送指令，请确认门锁现场状态。", success: false)
            }
            overallTimeout = watchdog
            DispatchQueue.main.asyncAfter(deadline: .now() + DoorTimeout.overall, execute: watchdog)
            if background {
                backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "BenbenDoorUnlock") { [weak self] in
                    Task { @MainActor in
                        guard let self, self.requestID == id else { return }
                        self.finish("系统结束了后台执行时间，请在 App 内确认并重试。", success: false)
                    }
                }
                append(backgroundTask == .invalid ? "系统未提供额外后台时间，将在本次快捷指令运行期间尝试开门" : "已向系统申请后台运行时间，等待门锁连接")
            }
            append("开始开门：\(stored.displayName)")
            if central.state == .poweredOn { scan() }
            else { status = "等待蓝牙就绪…"; armTimeout(DoorTimeout.bluetoothReady, message: "蓝牙未就绪，请检查蓝牙权限和开关。") }
        } catch { finish(error.localizedDescription, success: false) }
    }

    func cancel() {
        if isBusy { finish(responses.unlockSubmitted ? "开门指令已交给蓝牙，门锁结果尚未确认，请检查现场状态。" : "已取消，尚未提交开门指令。", success: false) }
    }

    func clearLog() {
        logFlush?.cancel(); logFlush = nil
        log.removeAll(); persistedLog.removeAll()
        UserDefaults.standard.removeObject(forKey: "recentDoorDiagnostics")
    }
    var exportedLog: String { (["奔奔开门 \(AppVersion.display) · \(doorName)", "状态：\(status)"] + log).joined(separator: "\n") }

    private func append(_ message: String, persist: Bool = true) {
        let tag = requestTag.map { " [\($0)]" } ?? ""
        let line = "\(Self.logFormatter.string(from: Date()))\(tag)  \(message)"
        log.append(line)
        if log.count > 200 { log.removeFirst(log.count - 200) }
        guard persist else { return }
        persistedLog.append(line)
        if persistedLog.count > 100 { persistedLog.removeFirst(persistedLog.count - 100) }
        guard logFlush == nil else { return }
        let work = DispatchWorkItem { [weak self] in self?.flushLog() }
        logFlush = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    private func flushLog() {
        logFlush?.cancel(); logFlush = nil
        UserDefaults.standard.set(persistedLog, forKey: "recentDoorDiagnostics")
    }

    private func markTiming(_ label: String) {
        let now = ContinuousClock().now
        guard let started = requestStarted, let previous = timingMark else { return }
        func milliseconds(_ duration: Duration) -> Double {
            let parts = duration.components
            return Double(parts.seconds) * 1000 + Double(parts.attoseconds) / 1_000_000_000_000_000
        }
        append(String(format: "耗时：%@ %.0f 毫秒；累计 %.0f 毫秒；%@", label,
                      milliseconds(previous.duration(to: now)), milliseconds(started.duration(to: now)), connectionRoute))
        timingMark = now
    }

    private func clearConnectionCache() {
        for name in ["rememberedDoorName", "rememberedDoorPeripheral", "rememberedDoorIdentity"] {
            UserDefaults.standard.removeObject(forKey: name)
        }
        failedDirectConnection = nil
    }

    private func clockRecord() -> DoorClockRecord? {
        guard let data = UserDefaults.standard.data(forKey: "doorClockRecord") else { return nil }
        return try? JSONDecoder().decode(DoorClockRecord.self, from: data)
    }

    private func validateClock(_ key: DoorKey) throws {
        needsClockConfirmation = clockRecord()?.blocks(key, at: Date()) == true
        if needsClockConfirmation {
            throw DoorError.message("手机时间早于这把钥匙的上次操作。请检查自动日期与时间，再在 App 设置中确认时间已校正。")
        }
    }

    func confirmCorrectedClock() {
        guard !isBusy, !isImporting, UIApplication.shared.applicationState == .active else { return }
        do {
            guard let key = try KeyStore.load() else { throw DoorError.message("请先导入门锁配置。") }
            try key.validate()
            UserDefaults.standard.removeObject(forKey: "doorClockRecord")
            UserDefaults.standard.removeObject(forKey: "lastUnlockRequest")
            needsClockConfirmation = false
            status = "已确认手机时间，下次开门会重新记录；本次未发送开门指令。"
            append(status); flushLog()
        } catch { status = error.localizedDescription }
    }

    private func armTimeout(_ seconds: TimeInterval, message: String) {
        timeout?.cancel()
        let id = requestID
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.isBusy, self.requestID == id else { return }
            self.finish(message, success: false)
        }
        timeout = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    private func finish(_ message: String, success: Bool) {
        overallTimeout?.cancel(); overallTimeout = nil
        timeout?.cancel(); timeout = nil
        fragmentWatchdog?.cancel(); fragmentWatchdog = nil
        markTiming(success ? "门锁确认结果" : "本次操作结束")
        central.stopScan()
        if let peripheral {
            peripheral.delegate = nil
            if peripheral.state != .disconnected { retiringPeripheral = peripheral }
            central.cancelPeripheralConnection(peripheral)
        }
        peripheral = nil; writeCharacteristic = nil; notifyCharacteristic = nil
        pendingWrite = nil; stage = .idle; usingRememberedPeripheral = false
        isBusy = false; lastSucceeded = success; status = message; append(message)
        let callback = completion
        flushLog()
        completion = nil; requestID = nil; requestTag = nil; requestDeadline = nil; requestStarted = nil; timingMark = nil
        backgroundOperation = false; responses.reset()
        if backgroundTask != .invalid {
            let task = backgroundTask; backgroundTask = .invalid
            UIApplication.shared.endBackgroundTask(task)
        }
        callback?(success ? .success(message) : .failure(DoorError.message(message)))
    }

    private func scan() {
        guard requestIsCurrent(), stage == .waitingBluetooth, let key else { return }
        markTiming("蓝牙就绪")
        let coolingDown = failedDirectConnection.map { $0.identity == key.connectionIdentity && ContinuousClock().now < $0.until } ?? false
        let storedIdentity = UserDefaults.standard.string(forKey: "rememberedDoorIdentity")
        if !coolingDown, (storedIdentity == nil || storedIdentity == key.connectionIdentity),
           UserDefaults.standard.string(forKey: "rememberedDoorName") == key.advertisedName,
           let text = UserDefaults.standard.string(forKey: "rememberedDoorPeripheral"),
           let id = UUID(uuidString: text),
           let known = central.retrievePeripherals(withIdentifiers: [id]).first {
            append("已找到上次成功连接的门锁，尝试直接连接")
            connectionRoute = "缓存直连"
            connect(known, remembered: true)
            return
        }
        connectionRoute = "扫描"
        append(coolingDown ? "上次直接连接未成功，本次先搜索门锁，避免重复等待" : "暂无可用的门锁连接记录，开始搜索附近门锁")
        scanForDoor()
    }

    private func scanForDoor() {
        guard requestIsCurrent(), let key else { return }
        stage = .scanning; status = "正在寻找门锁…"; append("正在搜索附近的目标门锁（设备名：\(key.advertisedName)）")
        central.scanForPeripherals(withServices: [CBUUID(string: DoorProtocol.serviceUUID)],
                                   options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        armTimeout(DoorTimeout.scan, message: "未找到目标门锁，请靠近门锁并确认设备已唤醒。")
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        append(bluetoothDescription(central.state))
        if central.state != .poweredOn && central.state != .unknown { retiringPeripheral = nil }
        guard requestIsCurrent() else { return }
        switch central.state {
        case .poweredOn: if stage == .waitingBluetooth { scan() }
        case .poweredOff: finish("请打开蓝牙后重试。", success: false)
        case .unauthorized: finish("请在系统设置中允许此 App 使用蓝牙。", success: false)
        case .unsupported: finish("此设备不支持所需蓝牙功能。", success: false)
        default: break
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover found: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard requestIsCurrent(), stage == .scanning, let key else { return }
        let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? found.name ?? ""
        guard name == key.advertisedName else { return }
        append("已找到目标门锁，准备连接（信号读数：\(RSSI) dBm）")
        markTiming("搜索门锁")
        connect(found, remembered: false)
    }

    private func connect(_ found: CBPeripheral, remembered: Bool) {
        guard requestIsCurrent() else { return }
        central.stopScan(); stage = .connecting; peripheral = found; found.delegate = self
        usingRememberedPeripheral = remembered
        status = "正在连接门锁…"
        append(status)
        central.connect(found, options: nil)
        if remembered {
            timeout?.cancel()
            let id = requestID
            let fallback = DispatchWorkItem { [weak self] in
                guard let self, self.isBusy, self.requestID == id, self.stage == .connecting,
                      self.usingRememberedPeripheral else { return }
                self.fallbackToScan()
            }
            timeout = fallback
            DispatchQueue.main.asyncAfter(deadline: .now() + DoorTimeout.rememberedConnect, execute: fallback)
        } else { armTimeout(DoorTimeout.connect, message: "蓝牙连接超时。") }
    }

    private func fallbackToScan() {
        guard requestIsCurrent(), stage == .connecting else { return }
        append("直接连接未成功，改为搜索附近的门锁")
        connectionRoute = "直连未成功后扫描"
        markTiming("缓存连接尝试")
        if let key { failedDirectConnection = (key.connectionIdentity, ContinuousClock().now.advanced(by: .seconds(60))) }
        timeout?.cancel(); timeout = nil
        usingRememberedPeripheral = false
        // Wait for cancellation before scanning, so an old disconnect callback
        // cannot fail a new connection to the same CBPeripheral instance.
        if let previous = peripheral, previous.state != .disconnected {
            stage = .disconnectingForScan
            central.cancelPeripheralConnection(previous)
            armTimeout(DoorTimeout.disconnect, message: "取消旧蓝牙连接超时，请重新运行快捷指令。")
            return
        }
        continueScanningAfterDisconnect()
    }

    private func continueScanningAfterDisconnect() {
        timeout?.cancel(); timeout = nil
        peripheral?.delegate = nil; peripheral = nil
        markTiming("结束旧连接")
        scanForDoor()
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        if retiringPeripheral === peripheral { central.cancelPeripheralConnection(peripheral); return }
        guard requestIsCurrent(), stage == .connecting, self.peripheral === peripheral else { return }
        markTiming("蓝牙连接")
        stage = .discovering; status = "已连接，正在准备通信…"; append("已连接门锁，正在准备发送指令和接收回复")
        peripheral.discoverServices([CBUUID(string: DoorProtocol.serviceUUID)])
        armTimeout(DoorTimeout.discovery, message: "已连接，但通信准备超时，请靠近门锁后重试。")
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        if retiringPeripheral === peripheral { retiringPeripheral = nil; return }
        guard requestIsCurrent(), self.peripheral === peripheral else { return }
        if stage == .disconnectingForScan { continueScanningAfterDisconnect(); return }
        guard stage == .connecting else { return }
        if usingRememberedPeripheral { fallbackToScan(); return }
        if let error {
            let nsError = error as NSError
            append("连接失败的诊断信息：错误类型 \(nsError.domain)，错误编号 \(nsError.code)")
        }
        finish("连接失败：\(error?.localizedDescription ?? "未知原因")", success: false)
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        if retiringPeripheral === peripheral { retiringPeripheral = nil; return }
        guard requestIsCurrent(), self.peripheral === peripheral else { return }
        if stage == .disconnectingForScan { continueScanningAfterDisconnect(); return }
        finish("门锁连接中断；若已发送开门指令，请确认现场状态。", success: false)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard requestIsCurrent(), self.peripheral === peripheral, stage == .discovering else { return }
        if let error { finish(error.localizedDescription, success: false); return }
        guard let service = peripheral.services?.first(where: { $0.uuid == CBUUID(string: DoorProtocol.serviceUUID) }) else {
            finish("门锁未提供所需通信服务，无法继续开门（诊断：FFF0）。", success: false); return
        }
        peripheral.discoverCharacteristics([CBUUID(string: DoorProtocol.writeUUID), CBUUID(string: DoorProtocol.notifyUUID)], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard requestIsCurrent(), self.peripheral === peripheral, stage == .discovering else { return }
        if let error { finish(error.localizedDescription, success: false); return }
        writeCharacteristic = service.characteristics?.first { $0.uuid == CBUUID(string: DoorProtocol.writeUUID) }
        notifyCharacteristic = service.characteristics?.first { $0.uuid == CBUUID(string: DoorProtocol.notifyUUID) }
        guard let writeCharacteristic, let notifyCharacteristic,
              writeCharacteristic.properties.contains(.write) || writeCharacteristic.properties.contains(.writeWithoutResponse),
              notifyCharacteristic.properties.contains(.notify) || notifyCharacteristic.properties.contains(.indicate) else {
            finish("门锁的指令发送或回复通道不可用（诊断：FFF1/FFF2）。", success: false); return
        }
        append("已找到指令发送和门锁回复通道，正在开启回复接收")
        peripheral.setNotifyValue(true, for: notifyCharacteristic)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard requestIsCurrent(), self.peripheral === peripheral, stage == .discovering, characteristic.uuid == CBUUID(string: DoorProtocol.notifyUUID) else { return }
        guard error == nil, characteristic.isNotifying, key != nil else {
            finish("无法接收门锁回复：\(error?.localizedDescription ?? "门锁未开启回复通道")", success: false); return
        }
        markTiming("准备通信通道")
        stage = .selecting; status = "正在确认门锁通信…"; append("已开启回复接收，正在向门锁发起通信确认")
        armTimeout(DoorTimeout.select, message: "门锁未回复通信确认，请靠近门锁后重试。")
        write(.select)
    }

    private func write(_ command: Command) {
        guard requestIsCurrent(), let deadline = requestDeadline, let key else { return }
        do {
            try DoorUnlockPolicy.validate(background: backgroundOperation, enabled: KeyStore.backgroundUnlockEnabled,
                                          foreground: UIApplication.shared.applicationState == .active, deadline: deadline)
            try key.validate()
            if command == .unlock { try validateClock(key) }
        } catch { finish(error.localizedDescription, success: false); return }
        guard let peripheral, let characteristic = writeCharacteristic else {
            finish("蓝牙通道不可用。", success: false); return
        }
        let type: CBCharacteristicWriteType = characteristic.properties.contains(.write) ? .withResponse : .withoutResponse
        if type == .withoutResponse && !peripheral.canSendWriteWithoutResponse {
            pendingWrite = command
            append("蓝牙发送通道忙，正在等待；尚未提交\(command == .unlock ? "开门" : "通信确认")指令")
            return
        }
        let value: Data
        let opcode: UInt8
        do {
            switch command {
            case .select:
                guard stage == .selecting else { return }
                opcode = 1; value = DoorProtocol.select(key)
            case .unlock:
                guard stage == .unlocking, let selection = responses.selection else { return }
                opcode = 6
                // Build a fresh time window after flow control is ready.
                value = try DoorProtocol.unlock(key, session: selection.session,
                                                minorVersion: selection.minorVersion, now: Date())
            }
        } catch { finish(error.localizedDescription, success: false); return }
        guard value.count <= peripheral.maximumWriteValueLength(for: type) else {
            finish("蓝牙单次写入长度不足。", success: false); return
        }
        guard requestIsCurrent() else { return }
        do {
            try key.validate()
            if command == .unlock { try validateClock(key) }
        } catch { finish(error.localizedDescription, success: false); return }
        guard responses.markSubmitted(opcode: opcode) else {
            finish("已阻止重复提交指令，请确认门锁现场状态。", success: false); return
        }
        fragmentWatchdog?.cancel(); fragmentWatchdog = nil
        pendingWrite = nil
        peripheral.writeValue(value, for: characteristic, type: type)
        if command == .unlock {
            let record = DoorClockRecord(authorization: key.authorizationIdentity, submittedAt: Date())
            if let data = try? JSONEncoder().encode(record) { UserDefaults.standard.set(data, forKey: "doorClockRecord") }
            markTiming("提交开门指令")
        }
        append("已向蓝牙提交\(command == .unlock ? "开门指令" : "通信确认指令")，\(value.count) 字节；正在等待回复")
        if includePacketBytes { append("发送原始字节：\(value.map { String(format: "%02X", $0) }.joined(separator: " "))", persist: false) }
    }

    func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        guard requestIsCurrent(), self.peripheral === peripheral, let command = pendingWrite else { return }
        pendingWrite = nil; write(command)
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard requestIsCurrent(), self.peripheral === peripheral, characteristic.uuid == CBUUID(string: DoorProtocol.writeUUID) else { return }
        if let error { finish("蓝牙写入失败：\(error.localizedDescription)", success: false) }
        else { append("蓝牙已确认指令写入，正在等待门锁处理结果；此时尚不能确认开门成功") }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard requestIsCurrent(), self.peripheral === peripheral, characteristic.uuid == CBUUID(string: DoorProtocol.notifyUUID) else { return }
        if let error { finish("接收失败：\(error.localizedDescription)", success: false); return }
        guard let value = characteristic.value else { return }
        append("收到门锁回复，\(value.count) 字节")
        if includePacketBytes { append("接收原始字节：\(value.map { String(format: "%02X", $0) }.joined(separator: " "))", persist: false) }
        do {
            let before = responses.discardedBytes
            let events = try responses.append(value)
            if responses.discardedBytes > before { append("已跳过无效或不支持的回复数据，继续等待完整回复") }
            processResponses(events)
            armFragmentWatchdog()
        } catch { finish(error.localizedDescription, success: false) }
    }

    private func processResponses(_ events: [DoorResponseSession.Event]) {
        let id = requestID
        for event in events {
            guard requestID == id, requestIsCurrent() else { break }
            handle(event)
        }
    }

    private func armFragmentWatchdog() {
        fragmentWatchdog?.cancel(); fragmentWatchdog = nil
        guard isBusy, !responses.buffered.isEmpty else { return }
        let id = requestID
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.requestID == id, self.requestIsCurrent() else { return }
            do {
                self.append("回复分包等待过久，正在跳过损坏的片段并寻找完整回复")
                let events = try self.responses.recoverStalledFragment()
                self.processResponses(events)
                self.armFragmentWatchdog()
            } catch { self.finish(error.localizedDescription, success: false) }
        }
        fragmentWatchdog = work
        // Match the original client's 1.5-second incomplete-frame recovery.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
    }

    private func handle(_ event: DoorResponseSession.Event) {
        switch event {
        case .selected(let selection):
            guard stage == .selecting else { return }
            markTiming("门锁通信确认")
            if let voltage = selection.voltage {
                append("门锁通信确认完成，准备开门（电压 \(voltage)V；诊断版本编号 \(selection.minorVersion)）")
            } else { append("门锁通信确认完成，准备开门（简短回复）") }
            stage = .unlocking; status = "正在开门…"
            armTimeout(DoorTimeout.unlock, message: "开门步骤超时；若已提交开门指令，请检查门锁现场状态。")
            write(.unlock)
        case .unlockResult(let result):
            guard stage == .unlocking else { return }
            if result == 0 {
                if let key, let peripheral {
                    UserDefaults.standard.set(key.advertisedName, forKey: "rememberedDoorName")
                    UserDefaults.standard.set(peripheral.identifier.uuidString, forKey: "rememberedDoorPeripheral")
                    UserDefaults.standard.set(key.connectionIdentity, forKey: "rememberedDoorIdentity")
                    failedDirectConnection = nil
                    append("已记住这把门锁，下次可尝试直接连接")
                }
                finish("门锁返回开门成功", success: true)
            }
            else if result == 4 { finish("开门失败：门锁已反锁（结果码 4）。", success: false) }
            else { finish("门锁拒绝开门，结果码 \(result)。", success: false) }
        case .ignored(let opcode):
            append("已忽略与当前步骤不符、重复或在指令提交前收到的回复（诊断指令编号 \(opcode)）")
        }
    }
}
