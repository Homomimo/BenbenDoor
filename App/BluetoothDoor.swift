import Foundation
import Combine
import CoreBluetooth
import UIKit

final class BluetoothDoor: NSObject, ObservableObject, CBCentralManagerDelegate, CBPeripheralDelegate {
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
    private var timeout: Timer?
    private var key: DoorKey?
    private var stage = Stage.idle
    private var receiveBuffer: [UInt8] = []
    private var pendingWrite: Data?
    private enum Stage { case idle, waitingBluetooth, scanning, connecting, discovering, selecting, unlocking }

    override init() {
        super.init()
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
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= 64 * 1024 else { throw DoorError.message("配置文件过大。") }
            let imported = try JSONDecoder().decode(DoorKey.self, from: Data(contentsOf: url))
            try imported.validate()
            try KeyStore.save(imported)
            reloadKey()
            append("已导入门锁配置：\(imported.displayName)")
        } catch { status = "导入失败：\(error.localizedDescription)"; append(status) }
    }

    func removeKey() {
        guard !isBusy else { return }
        do { try KeyStore.delete(); reloadKey(); append("已移除本机钥匙") }
        catch { status = error.localizedDescription }
    }

    func start() {
        guard !isBusy else { return }
        guard UIApplication.shared.applicationState == .active else { return }
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
            append("开始开门：\(stored.displayName)")
            if central.state == .poweredOn { scan() }
            else { status = "等待蓝牙就绪…"; armTimeout(15, message: "蓝牙未就绪，请检查蓝牙权限和开关。") }
        } catch { status = error.localizedDescription; append(status) }
    }

    func cancel() {
        if isBusy { finish("已取消；如指令已经发出，请以门锁实际状态为准。", success: false) }
    }

    func clearLog() { log.removeAll() }
    var exportedLog: String { (["奔奔开门测试 · \(doorName)", "状态：\(status)"] + log).joined(separator: "\n") }

    private func append(_ message: String) {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss.SSS"
        log.append("\(f.string(from: Date()))  \(message)")
        if log.count > 200 { log.removeFirst(log.count - 200) }
    }

    private func armTimeout(_ seconds: TimeInterval, message: String) {
        timeout?.invalidate()
        timeout = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            self?.finish(message, success: false)
        }
    }

    private func finish(_ message: String, success: Bool) {
        timeout?.invalidate(); timeout = nil
        central.stopScan()
        if let peripheral {
            peripheral.delegate = nil
            central.cancelPeripheralConnection(peripheral)
        }
        peripheral = nil; writeCharacteristic = nil; notifyCharacteristic = nil
        pendingWrite = nil; receiveBuffer = []; stage = .idle
        isBusy = false; lastSucceeded = success; status = message; append(message)
        if success { UINotificationFeedbackGenerator().notificationOccurred(.success) }
    }

    private func scan() {
        guard isBusy, stage == .waitingBluetooth, let key else { return }
        stage = .scanning; status = "正在寻找 \(key.advertisedName)…"; append("开始扫描 FFF0 服务")
        central.scanForPeripherals(withServices: [CBUUID(string: DoorProtocol.serviceUUID)],
                                   options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        armTimeout(12, message: "未找到目标门锁，请靠近门锁并确认设备已唤醒。")
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard isBusy else { return }
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
        guard stage == .scanning, let key else { return }
        let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? found.name ?? ""
        guard name == key.advertisedName else { return }
        central.stopScan(); stage = .connecting; peripheral = found; found.delegate = self
        status = "正在连接门锁…"; append("发现目标，RSSI \(RSSI)")
        central.connect(found, options: nil)
        armTimeout(12, message: "蓝牙连接超时。")
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard isBusy, self.peripheral?.identifier == peripheral.identifier else { return }
        stage = .discovering; status = "正在准备蓝牙通道…"; append("已连接，发现服务")
        peripheral.discoverServices([CBUUID(string: DoorProtocol.serviceUUID)])
        armTimeout(10, message: "服务或通知初始化超时。")
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        guard self.peripheral?.identifier == peripheral.identifier, isBusy else { return }
        finish("连接失败：\(error?.localizedDescription ?? "未知原因")", success: false)
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        guard self.peripheral?.identifier == peripheral.identifier, isBusy else { return }
        finish("门锁连接中断；若已发送开门指令，请确认现场状态。", success: false)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard stage == .discovering else { return }
        if let error { finish(error.localizedDescription, success: false); return }
        guard let service = peripheral.services?.first(where: { $0.uuid == CBUUID(string: DoorProtocol.serviceUUID) }) else {
            finish("未找到 FFF0 服务。", success: false); return
        }
        peripheral.discoverCharacteristics([CBUUID(string: DoorProtocol.writeUUID), CBUUID(string: DoorProtocol.notifyUUID)], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard stage == .discovering else { return }
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
        guard stage == .discovering, characteristic.uuid == CBUUID(string: DoorProtocol.notifyUUID) else { return }
        guard error == nil, characteristic.isNotifying, let key else {
            finish("开启通知失败：\(error?.localizedDescription ?? "未生效")", success: false); return
        }
        stage = .selecting; status = "正在与门锁握手…"; append("通知已开启，发送选锁")
        armTimeout(8, message: "选锁未收到有效响应。")
        write(DoorProtocol.select(key))
    }

    private func write(_ value: Data) {
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
        guard isBusy, let value = pendingWrite else { return }
        pendingWrite = nil; write(value)
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard isBusy else { return }
        if let error { finish("蓝牙写入失败：\(error.localizedDescription)", success: false) }
        else { append("控制器已确认写入，等待门锁业务响应") }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard isBusy, characteristic.uuid == CBUUID(string: DoorProtocol.notifyUUID) else { return }
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
                guard UIApplication.shared.applicationState == .active else { throw DoorError.message("请保持 App 在前台。") }
                try key.validate()
                let data = try DoorProtocol.unlock(key, session: session, minorVersion: minor, now: Date())
                stage = .unlocking; status = "正在开门…"
                UserDefaults.standard.set(Date(), forKey: "lastUnlockRequest")
                armTimeout(10, message: "开门响应超时，未确认执行结果，请检查门锁现场状态。")
                write(data)
            } catch { finish(error.localizedDescription, success: false) }
        } else if stage == .unlocking && opcode == 6 {
            let result = frame[5]
            if result == 0 { finish("门锁返回开门成功", success: true) }
            else if result == 4 { finish("开门失败：门锁已反锁（结果码 4）。", success: false) }
            else { finish("门锁拒绝开门，结果码 \(result)。", success: false) }
        } else { append("忽略当前阶段以外的业务响应：\(opcode)") }
    }
}
