import Foundation
import Combine
import CoreBluetooth
import UIKit

final class BluetoothDoor: NSObject, ObservableObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    static let shared = BluetoothDoor()
    @Published private(set) var doorName = "尚未配置门锁"
    @Published private(set) var status = "导入配置后即可测试"
    @Published private(set) var isBusy = false
    @Published private(set) var hasKey = false
    @Published private(set) var lastSucceeded = false
    @Published private(set) var log: [String] = []
    @Published var includePacketBytes = false

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var writeCharacteristic: CBCharacteristic?
    private var notifyCharacteristic: CBCharacteristic?
    private var timeout: DispatchWorkItem?
    private var key: DoorKey?
    private var stage = Stage.idle
    private var receiveBuffer: [UInt8] = []
    private var pendingWrite: Data?
    private var backgroundOperation = false
    private var requestDeadline: Date?
    private var requestDeadlineUptime: UInt64?
    private var completion: ((Result<String, Error>) -> Void)?
    private var requestID: UUID?
    private var requestTag: String?
    private var unlockWriteStarted = false
    private var overallTimeout: DispatchWorkItem?
    private var usingRememberedPeripheral = false
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

    override init() {
        super.init()
        log = UserDefaults.standard.stringArray(forKey: "recentDoorDiagnostics") ?? []
        reloadKey()
        central = CBCentralManager(delegate: self, queue: .main)
    }

    func reloadKey() {
        do {
            key = try KeyStore.load()
            hasKey = key != nil
            doorName = key?.displayName ?? "尚未配置门锁"
            status = hasKey ? "准备就绪" : "导入配置后即可测试"
        } catch { status = error.localizedDescription }
    }

    func importKey(from url: URL) {
        guard !isBusy else { return }
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        do {
            var readResult: Result<Data, Error>?
            var coordinationError: NSError?
            NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { readableURL in
                readResult = Result {
                    let values = try readableURL.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey])
                    guard values.isDirectory != true else { throw DoorError.message("请选择配置文件，不要选择文件夹。") }
                    guard (values.fileSize ?? 0) <= 64 * 1024 else { throw DoorError.message("配置文件过大。") }
                    var data = try Data(contentsOf: readableURL)
                    guard data.count <= 64 * 1024 else { throw DoorError.message("配置文件过大。") }
                    // Accept UTF-8 JSON exported by Windows tools with a BOM.
                    if data.starts(with: [0xEF, 0xBB, 0xBF]) { data.removeFirst(3) }
                    return data
                }
            }
            if let error = coordinationError { throw error }
            guard let result = readResult else { throw DoorError.message("无法读取配置，请先在“文件”App 中下载到本机后重试。") }
            try saveImportedKey(result.get())
        } catch { reportImportFailure(error) }
    }

    @discardableResult func importKey(text: String) -> Bool {
        guard !isBusy else { return false }
        do {
            try saveImportedKey(Data(text.trimmingCharacters(in: .whitespacesAndNewlines).utf8))
            return true
        } catch { reportImportFailure(error); return false }
    }

    private func saveImportedKey(_ input: Data) throws {
        guard input.count <= 64 * 1024 else { throw DoorError.message("配置文件过大。") }
        var data = input
        if data.starts(with: [0xEF, 0xBB, 0xBF]) { data.removeFirst(3) }
        let imported: DoorKey
        do { imported = try JSONDecoder().decode(DoorKey.self, from: data) }
        catch { throw DoorError.message("内容不是有效的门锁配置 JSON，请导入完整配置。") }
        try imported.validate()
        UserDefaults.standard.removeObject(forKey: "rememberedDoorName")
        UserDefaults.standard.removeObject(forKey: "rememberedDoorPeripheral")
        try KeyStore.save(imported)
        reloadKey()
        status = "已导入配置：\(imported.displayName)"
        append(status)
    }

    func reportImportFailure(_ error: Error) {
        let failure = error as NSError
        if failure.domain == NSCocoaErrorDomain && failure.code == NSUserCancelledError { return }
        status = "导入失败：\(error.localizedDescription)"
        append(status)
    }

    func removeKey() {
        guard !isBusy else { return }
        do {
            try KeyStore.delete()
            UserDefaults.standard.removeObject(forKey: "rememberedDoorName")
            UserDefaults.standard.removeObject(forKey: "rememberedDoorPeripheral")
            reloadKey(); append("已移除本机钥匙")
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
    }

    func appBecameActive() {
        if isBusy { _ = requestIsCurrent() }
    }

    private func requestIsCurrent() -> Bool {
        guard isBusy, let deadline = requestDeadline, let uptimeDeadline = requestDeadlineUptime else { return false }
        guard DispatchTime.now().uptimeNanoseconds < uptimeDeadline else {
            finish("本次开门请求已过期，已停止后续操作；如已发送指令，请确认门锁现场状态。", success: false)
            return false
        }
        return true
    }

    private func begin(background: Bool, id: UUID = UUID(), completion callback: ((Result<String, Error>) -> Void)?) {
        guard !isBusy else {
            callback?(.failure(DoorError.message("已有开门操作正在进行，请等待结果。"))); return
        }
        guard background || UIApplication.shared.applicationState == .active else { return }
        if background && !KeyStore.backgroundUnlockEnabled {
            callback?(.failure(DoorError.message("请先在 App 设置开启“允许锁屏快捷开门”。"))); return
        }
        backgroundOperation = background
        completion = callback; requestID = id; requestTag = String(id.uuidString.prefix(4)); unlockWriteStarted = false
        append("开始请求，来源=\(background ? "快捷指令" : "App")，应用状态=\(UIApplication.shared.applicationState.rawValue)，蓝牙状态=\(central.state.rawValue)")
        do {
            guard let stored = try KeyStore.load() else {
                throw DoorError.message("请先导入门锁配置。")
            }
            try stored.validate()
            if let last = UserDefaults.standard.object(forKey: "lastUnlockRequest") as? Date, Date() < last {
                throw DoorError.message("手机时间早于上次操作，请检查系统时间。")
            }
            key = stored
            doorName = stored.displayName
            lastSucceeded = false
            isBusy = true
            stage = .waitingBluetooth
            receiveBuffer = []
            // A stale connection must never issue an unlock after the request window.
            requestDeadline = Date().addingTimeInterval(DoorTimeout.overall)
            requestDeadlineUptime = DispatchTime.now().uptimeNanoseconds + UInt64(DoorTimeout.overall * 1_000_000_000)
            let watchdog = DispatchWorkItem { [weak self] in
                guard let self, self.requestID == id else { return }
                self.finish("本次开门已超时；如已发送指令，请确认门锁现场状态。", success: false)
            }
            overallTimeout = watchdog
            DispatchQueue.main.asyncAfter(deadline: .now() + DoorTimeout.overall, execute: watchdog)
            if background {
                backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "BenbenDoorUnlock") { [weak self] in
                    self?.finish("系统结束了后台执行时间，请在 App 内确认并重试。", success: false)
                }
                append(backgroundTask == .invalid ? "系统未分配附加后台任务时间；继续依赖当前 Intent 执行时段" : "已申请有限后台任务时间")
            }
            append("开始开门：\(stored.displayName)")
            if central.state == .poweredOn { scan() }
            else { status = "等待蓝牙就绪…"; armTimeout(DoorTimeout.bluetoothReady, message: "蓝牙未就绪，请检查蓝牙权限和开关。") }
        } catch { finish(error.localizedDescription, success: false) }
    }

    func cancel() {
        if isBusy { finish(unlockWriteStarted ? "开门指令已发送，结果未知，请确认门锁现场状态。" : "已取消，尚未发送开门指令。", success: false) }
    }

    func clearLog() { log.removeAll(); UserDefaults.standard.removeObject(forKey: "recentDoorDiagnostics") }
    var exportedLog: String { (["奔奔开门测试 · \(doorName)", "状态：\(status)"] + log).joined(separator: "\n") }

    private func append(_ message: String) {
        let tag = requestTag.map { " [\($0)]" } ?? ""
        log.append("\(Self.logFormatter.string(from: Date()))\(tag)  \(message)")
        if log.count > 200 { log.removeFirst(log.count - 200) }
        // Persist stage diagnostics across background process exits, excluding raw packets.
        let stages = log.filter { !$0.contains("字节：") }
        UserDefaults.standard.set(Array(stages.suffix(100)), forKey: "recentDoorDiagnostics")
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
        central.stopScan()
        if let peripheral {
            peripheral.delegate = nil
            central.cancelPeripheralConnection(peripheral)
        }
        peripheral = nil; writeCharacteristic = nil; notifyCharacteristic = nil
        pendingWrite = nil; receiveBuffer = []; stage = .idle; usingRememberedPeripheral = false
        isBusy = false; lastSucceeded = success; status = message; append(message)
        let callback = completion
        completion = nil; requestID = nil; requestTag = nil; requestDeadline = nil; requestDeadlineUptime = nil; backgroundOperation = false; unlockWriteStarted = false
        if backgroundTask != .invalid {
            let task = backgroundTask; backgroundTask = .invalid
            UIApplication.shared.endBackgroundTask(task)
        }
        callback?(success ? .success(message) : .failure(DoorError.message(message)))
        if success && UIApplication.shared.applicationState == .active { UINotificationFeedbackGenerator().notificationOccurred(.success) }
    }

    private func scan() {
        guard requestIsCurrent(), stage == .waitingBluetooth, let key else { return }
        if backgroundOperation,
           UserDefaults.standard.string(forKey: "rememberedDoorName") == key.advertisedName,
           let text = UserDefaults.standard.string(forKey: "rememberedDoorPeripheral"),
           let id = UUID(uuidString: text),
           let known = central.retrievePeripherals(withIdentifiers: [id]).first {
            append("找到前台成功开门记录，优先直接重连")
            connect(known, remembered: true)
            return
        }
        if backgroundOperation { append("没有可恢复设备，回退到 FFF0 扫描；请先用新版 App 成功开门一次") }
        scanForDoor()
    }

    private func scanForDoor() {
        guard requestIsCurrent(), let key else { return }
        stage = .scanning; status = "正在寻找 \(key.advertisedName)…"; append("开始扫描 FFF0 服务")
        central.scanForPeripherals(withServices: [CBUUID(string: DoorProtocol.serviceUUID)],
                                   options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        armTimeout(DoorTimeout.scan, message: "未找到目标门锁，请靠近门锁并确认设备已唤醒。")
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        append("蓝牙状态更新：\(central.state.rawValue)")
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
        append("发现目标，RSSI \(RSSI)")
        connect(found, remembered: false)
    }

    private func connect(_ found: CBPeripheral, remembered: Bool) {
        guard requestIsCurrent() else { return }
        central.stopScan(); stage = .connecting; peripheral = found; found.delegate = self
        usingRememberedPeripheral = remembered
        status = "正在连接门锁…"
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
        append("已记录设备重连未完成，回退扫描")
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
        scanForDoor()
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard requestIsCurrent(), stage == .connecting, self.peripheral === peripheral else { return }
        stage = .discovering; status = "正在准备蓝牙通道…"; append("已连接，发现服务")
        peripheral.discoverServices([CBUUID(string: DoorProtocol.serviceUUID)])
        armTimeout(DoorTimeout.discovery, message: "服务或通知初始化超时。")
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        guard requestIsCurrent(), self.peripheral === peripheral else { return }
        if stage == .disconnectingForScan { continueScanningAfterDisconnect(); return }
        guard stage == .connecting else { return }
        if usingRememberedPeripheral { fallbackToScan(); return }
        if let error {
            let nsError = error as NSError
            append("连接失败诊断：domain=\(nsError.domain), code=\(nsError.code)")
        }
        finish("连接失败：\(error?.localizedDescription ?? "未知原因")", success: false)
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        guard requestIsCurrent(), self.peripheral === peripheral else { return }
        if stage == .disconnectingForScan { continueScanningAfterDisconnect(); return }
        finish("门锁连接中断；若已发送开门指令，请确认现场状态。", success: false)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard requestIsCurrent(), self.peripheral === peripheral, stage == .discovering else { return }
        if let error { finish(error.localizedDescription, success: false); return }
        guard let service = peripheral.services?.first(where: { $0.uuid == CBUUID(string: DoorProtocol.serviceUUID) }) else {
            finish("未找到 FFF0 服务。", success: false); return
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
            finish("FFF1/FFF2 特征缺失或属性不兼容。", success: false); return
        }
        append("已发现写入与通知特征")
        peripheral.setNotifyValue(true, for: notifyCharacteristic)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard requestIsCurrent(), self.peripheral === peripheral, stage == .discovering, characteristic.uuid == CBUUID(string: DoorProtocol.notifyUUID) else { return }
        guard error == nil, characteristic.isNotifying, let key else {
            finish("开启通知失败：\(error?.localizedDescription ?? "未生效")", success: false); return
        }
        stage = .selecting; status = "正在与门锁握手…"; append("通知已开启，发送选锁")
        armTimeout(DoorTimeout.select, message: "选锁未收到有效响应。")
        write(DoorProtocol.select(key))
    }

    private func write(_ value: Data) {
        guard isBusy, let deadline = requestDeadline else {
            finish("本次请求已过期，已停止发送。", success: false); return
        }
        do {
            try DoorUnlockPolicy.validate(background: backgroundOperation, enabled: KeyStore.backgroundUnlockEnabled,
                                          foreground: UIApplication.shared.applicationState == .active, deadline: deadline)
        } catch { finish(error.localizedDescription, success: false); return }
        guard let peripheral, let characteristic = writeCharacteristic else {
            finish("蓝牙通道不可用。", success: false); return
        }
        let type: CBCharacteristicWriteType = characteristic.properties.contains(.write) ? .withResponse : .withoutResponse
        guard value.count <= peripheral.maximumWriteValueLength(for: type) else {
            finish("蓝牙单次写入长度不足。", success: false); return
        }
        if type == .withoutResponse && !peripheral.canSendWriteWithoutResponse {
            pendingWrite = value; return
        }
        append("TX \(value.count) 字节" + (includePacketBytes ? "：\(value.map { String(format: "%02X", $0) }.joined(separator: " "))" : ""))
        peripheral.writeValue(value, for: characteristic, type: type)
    }

    func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        guard requestIsCurrent(), self.peripheral === peripheral, let value = pendingWrite else { return }
        pendingWrite = nil; write(value)
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard requestIsCurrent(), self.peripheral === peripheral else { return }
        if let error { finish("蓝牙写入失败：\(error.localizedDescription)", success: false) }
        else { append("控制器已确认写入，等待门锁业务响应") }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard requestIsCurrent(), self.peripheral === peripheral, characteristic.uuid == CBUUID(string: DoorProtocol.notifyUUID) else { return }
        if let error { finish("接收失败：\(error.localizedDescription)", success: false); return }
        guard let value = characteristic.value else { return }
        append("RX \(value.count) 字节" + (includePacketBytes ? "：\(value.map { String(format: "%02X", $0) }.joined(separator: " "))" : ""))
        receiveBuffer += value
        if receiveBuffer.count > 1024 { finish("响应缓冲区超限。", success: false); return }
        while receiveBuffer.count >= 2 && isBusy {
            guard let head = receiveBuffer.firstIndex(of: 0x3B) else { receiveBuffer.removeAll(); return }
            if head > 0 { receiveBuffer.removeFirst(head) }
            guard receiveBuffer.count >= 2 else { return }
            let length = Int(receiveBuffer[1]) + 4
            if length < 7 { receiveBuffer.removeFirst(); continue }
            guard receiveBuffer.count >= length else { return }
            let frame = Array(receiveBuffer.prefix(length))
            guard DoorProtocol.validResponse(frame) else {
                append("忽略校验不通过的响应")
                receiveBuffer.removeFirst(); continue
            }
            receiveBuffer.removeFirst(length)
            handle(frame)
        }
    }

    private func handle(_ frame: [UInt8]) {
        let opcode = frame[2]
        if stage == .selecting && opcode == 1 {
            let session = UInt16(frame[3]) << 8 | UInt16(frame[4])
            guard session != 0, frame[1] == 12 || frame[1] == 4, let key else {
                finish("选锁响应不支持或会话参数无效。", success: false); return
            }
            let minor: UInt8 = frame[1] == 12 ? frame[7] : 0
            if frame[1] == 12 {
                let voltage = Double(UInt16(frame[8]) << 8 | UInt16(frame[9])) / 100
                append("选锁成功，固件 minor=\(minor)，电压 \(voltage)V")
            } else { append("选锁完成（简短响应）") }
            do {
                guard backgroundOperation || UIApplication.shared.applicationState == .active else { throw DoorError.message("请保持 App 在前台。") }
                if backgroundOperation && !KeyStore.backgroundUnlockEnabled { throw DoorError.message("锁屏快捷开门已关闭。") }
                try key.validate()
                let data = try DoorProtocol.unlock(key, session: session, minorVersion: minor, now: Date())
                stage = .unlocking; status = "正在开门…"
                UserDefaults.standard.set(Date(), forKey: "lastUnlockRequest")
                armTimeout(DoorTimeout.unlock, message: "开门响应超时，未确认执行结果，请检查门锁现场状态。")
                unlockWriteStarted = true
                write(data)
            } catch { finish(error.localizedDescription, success: false) }
        } else if stage == .unlocking && opcode == 6 {
            let result = frame[5]
            if result == 0 {
                if let key, let peripheral {
                    UserDefaults.standard.set(key.advertisedName, forKey: "rememberedDoorName")
                    UserDefaults.standard.set(peripheral.identifier.uuidString, forKey: "rememberedDoorPeripheral")
                    append("已记录成功开门设备，可用于下次直接重连")
                }
                finish("门锁返回开门成功", success: true)
            }
            else if result == 4 { finish("开门失败：门锁已反锁（结果码 4）。", success: false) }
            else { finish("门锁拒绝开门，结果码 \(result)。", success: false) }
        } else { append("忽略当前阶段以外的业务响应：\(opcode)") }
    }
}
