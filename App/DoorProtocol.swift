import Foundation

enum DoorProtocol {
    static let serviceUUID = "FFF0"
    static let writeUUID = "FFF2"
    static let notifyUUID = "FFF1"

    // Ie in the original mini program, applied to the ASCII decimal ID.
    static func identifier(_ value: String) -> UInt16 {
        var a: UInt8 = 255
        var o: UInt8 = 255
        for byte in value.utf8 {
            let n = Int(a ^ byte)
            a = o ^ highTable[n]
            o = lowTable[n]
        }
        return UInt16(a) | (UInt16(o) << 8)
    }

    // Be/_e from app-service.js. Not a cryptographic signature.
    static func checksum(_ bytes: [UInt8]) -> UInt16 {
        var crc: UInt32 = 25443
        for byte in bytes {
            var e = UInt32(byte) ^ (crc & 255)
            e ^= (e << 4) & 255
            crc = ((crc >> 8) ^ (e << 8) ^ (e << 3) ^ (e >> 4)) & 65535
        }
        return UInt16(crc)
    }

    static func be16(_ value: UInt16) -> [UInt8] {
        [UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value)]
    }
    static func be32(_ value: UInt32) -> [UInt8] {
        [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: value >> $0) }
    }

    static func select(_ key: DoorKey) -> Data {
        let body: [UInt8] = [0x2A, 7, 1, key.region] + be16(key.subregion) + be16(key.devID) + [0]
        return Data(body + be16(checksum(body + [0xA1])))
    }

    static func packedTime(_ date: Date, zone: TimeZone) throws -> UInt32 {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        guard let year = c.year, (2000...2127).contains(year),
              let month = c.month, let day = c.day, let hour = c.hour, let minute = c.minute else {
            throw DoorError.message("无法编码门锁时间。")
        }
        return UInt32(year - 2000) << 25 | UInt32(month) << 21 | UInt32(day) << 16
            | UInt32(hour) << 11 | UInt32(minute) << 5
    }

    static func unlock(_ key: DoorKey, session: UInt16, minorVersion: UInt8, now: Date) throws -> Data {
        guard session != 0, let zone = key.timeZone else {
            throw DoorError.message("选锁尚未完成。")
        }
        let begin = Date(timeIntervalSince1970: floor(now.timeIntervalSince1970 / 60) * 60)
        let end = begin.addingTimeInterval(300)
        var option: UInt8 = 0
        if minorVersion >= 32, let config = UInt64(key.config), (config % 4294967295) & 8 != 0 {
            option |= 64
        }
        var body: [UInt8] = [0x2A, 16, 6] + be16(session) + [option]
        body += be32(try packedTime(begin, zone: zone))
        body += be32(try packedTime(end, zone: zone))
        body += be32(key.seqNo)
        let virtualTail = be16(identifier(key.agentID)) + be16(identifier(key.sysID)) + [0xA1]
        return Data(body + be16(checksum(body + virtualTail)))
    }

    static func validResponse(_ frame: [UInt8]) -> Bool {
        guard frame.count >= 7, frame[0] == 0x3B, frame.count == Int(frame[1]) + 4 else { return false }
        let length = frame.count - 2
        let expected = UInt16(frame[length]) << 8 | UInt16(frame[length + 1])
        return checksum(Array(frame.prefix(length)) + [0xA1]) == expected
    }

    static func supportedResponseLength(opcode: UInt8, payloadLength: Int) -> Bool {
        switch opcode {
        case 1: return payloadLength == 4 || payloadLength == 12
        // 4 includes opcode + two session bytes + result, excluding CRC.
        // Keep room for firmware-specific trailing fields (standard: 8).
        case 6: return (4...32).contains(payloadLength)
        default: return false
        }
    }

    // Filled directly from the original we/Se constants by the packaging script.
    static let highTable: [UInt8] = [0, 193, 129, 64, 1, 192, 128, 65, 1, 192, 128, 65, 0, 193, 129, 64, 1, 192, 128, 65, 0, 193, 129, 64, 0, 193, 129, 64, 1, 192, 128, 65, 1, 192, 128, 65, 0, 193, 129, 64, 0, 193, 129, 64, 1, 192, 128, 65, 0, 193, 129, 64, 1, 192, 128, 65, 1, 192, 128, 65, 0, 193, 129, 64, 1, 192, 128, 65, 0, 193, 129, 64, 0, 193, 129, 64, 1, 192, 128, 65, 0, 193, 129, 64, 1, 192, 128, 65, 1, 192, 128, 65, 0, 193, 129, 64, 0, 193, 129, 64, 1, 192, 128, 65, 1, 192, 128, 65, 0, 193, 129, 64, 1, 192, 128, 65, 0, 193, 129, 64, 0, 193, 129, 64, 1, 192, 128, 65, 1, 192, 128, 65, 0, 193, 129, 64, 0, 193, 129, 64, 1, 192, 128, 65, 0, 193, 129, 64, 1, 192, 128, 65, 1, 192, 128, 65, 0, 193, 129, 64, 0, 193, 129, 64, 1, 192, 128, 65, 1, 192, 128, 65, 0, 193, 129, 64, 1, 192, 128, 65, 0, 193, 129, 64, 0, 193, 129, 64, 1, 192, 128, 65, 0, 193, 129, 64, 1, 192, 128, 65, 1, 192, 128, 65, 0, 193, 129, 64, 1, 192, 128, 65, 0, 193, 129, 64, 0, 193, 129, 64, 1, 192, 128, 65, 1, 192, 128, 65, 0, 193, 129, 64, 0, 193, 129, 64, 1, 192, 128, 65, 0, 193, 129, 64, 1, 192, 128, 65, 1, 192, 128, 65, 0, 193, 129, 64]
    static let lowTable: [UInt8] = [0, 192, 193, 1, 195, 3, 2, 194, 198, 6, 7, 199, 5, 197, 196, 4, 204, 12, 13, 205, 15, 207, 206, 14, 10, 202, 203, 11, 201, 9, 8, 200, 216, 24, 25, 217, 27, 219, 218, 26, 30, 222, 223, 31, 221, 29, 28, 220, 20, 212, 213, 21, 215, 23, 22, 214, 210, 18, 19, 211, 17, 209, 208, 16, 240, 48, 49, 241, 51, 243, 242, 50, 54, 246, 247, 55, 245, 53, 52, 244, 60, 252, 253, 61, 255, 63, 62, 254, 250, 58, 59, 251, 57, 249, 248, 56, 40, 232, 233, 41, 235, 43, 42, 234, 238, 46, 47, 239, 45, 237, 236, 44, 228, 36, 37, 229, 39, 231, 230, 38, 34, 226, 227, 35, 225, 33, 32, 224, 160, 96, 97, 161, 99, 163, 162, 98, 102, 166, 167, 103, 165, 101, 100, 164, 108, 172, 173, 109, 175, 111, 110, 174, 170, 106, 107, 171, 105, 169, 168, 104, 120, 184, 185, 121, 187, 123, 122, 186, 190, 126, 127, 191, 125, 189, 188, 124, 180, 116, 117, 181, 119, 183, 182, 118, 114, 178, 179, 115, 177, 113, 112, 176, 80, 144, 145, 81, 147, 83, 82, 146, 150, 86, 87, 151, 85, 149, 148, 84, 156, 92, 93, 157, 95, 159, 158, 94, 90, 154, 155, 91, 153, 89, 88, 152, 136, 72, 73, 137, 75, 139, 138, 74, 78, 142, 143, 79, 141, 77, 76, 140, 68, 132, 133, 69, 135, 71, 70, 134, 130, 66, 67, 131, 65, 129, 128, 64]
}

struct DoorResponseDecoder {
    private(set) var buffered: [UInt8] = []
    private(set) var discardedBytes = 0

    mutating func reset() { buffered.removeAll(keepingCapacity: true); discardedBytes = 0 }

    mutating func discardBufferedFragment() {
        discardedBytes += buffered.count
        buffered.removeAll(keepingCapacity: true)
    }

    mutating func recoverStalledFragment() throws -> [[UInt8]] {
        guard !buffered.isEmpty else { return [] }
        discardedBytes += 1; buffered.removeFirst()
        return try append(Data())
    }

    mutating func append(_ value: Data) throws -> [[UInt8]] {
        guard buffered.count + value.count <= 1024 else {
            reset()
            throw DoorError.message("门锁回复数据过多，已停止本次操作，请重试。")
        }
        buffered += value
        var frames: [[UInt8]] = []
        while !buffered.isEmpty {
            guard let head = buffered.firstIndex(of: 0x3B) else {
                discardedBytes += buffered.count; buffered.removeAll(keepingCapacity: true); break
            }
            if head > 0 { discardedBytes += head; buffered.removeFirst(head) }
            guard buffered.count >= 3 else { break }
            let payload = Int(buffered[1])
            guard DoorProtocol.supportedResponseLength(opcode: buffered[2], payloadLength: payload) else {
                discardedBytes += 1; buffered.removeFirst(); continue
            }
            let length = payload + 4
            // Never scan inside an otherwise plausible partial frame: 0x3B
            // is also a valid payload/CRC byte and notifications may be split.
            guard buffered.count >= length else { break }
            let frame = Array(buffered.prefix(length))
            guard DoorProtocol.validResponse(frame) else {
                discardedBytes += 1; buffered.removeFirst(); continue
            }
            frames.append(frame); buffered.removeFirst(length)
        }
        return frames
    }
}

struct DoorExchange {
    struct Selection: Equatable {
        let session: UInt16
        let minorVersion: UInt8
        let voltage: Double?
    }
    private(set) var selectSubmitted = false
    private(set) var unlockSubmitted = false
    private(set) var selection: Selection?

    mutating func reset() { self = DoorExchange() }
    mutating func markSubmitted(opcode: UInt8) -> Bool {
        if opcode == 1, !selectSubmitted, selection == nil {
            selectSubmitted = true; return true
        }
        if opcode == 6, selection != nil, !unlockSubmitted {
            unlockSubmitted = true; return true
        }
        return false
    }
    mutating func acceptSelection(_ frame: [UInt8]) -> Selection? {
        guard selectSubmitted, selection == nil, DoorProtocol.validResponse(frame), frame[2] == 1,
              DoorProtocol.supportedResponseLength(opcode: 1, payloadLength: Int(frame[1])) else { return nil }
        let session = UInt16(frame[3]) << 8 | UInt16(frame[4])
        guard session != 0 else { return nil }
        let extended = frame[1] == 12
        let value = Selection(session: session, minorVersion: extended ? frame[7] : 0,
                              voltage: extended ? Double(UInt16(frame[8]) << 8 | UInt16(frame[9])) / 100 : nil)
        selection = value
        return value
    }
    func unlockResult(_ frame: [UInt8]) -> UInt8? {
        guard unlockSubmitted, selection != nil, DoorProtocol.validResponse(frame), frame[2] == 6,
              DoorProtocol.supportedResponseLength(opcode: 6, payloadLength: Int(frame[1])) else { return nil }
        // The original client refreshes secKey on every response. It does not
        // establish that response session bytes must echo the submitted key.
        return frame[5]
    }
}

// Classify a complete receive batch before the controller handles any event.
// Handling a selection can submit the next command, but that must never make
// bytes already received in this batch eligible as its reply.
struct DoorResponseSession {
    enum Event: Equatable {
        case selected(DoorExchange.Selection)
        case unlockResult(UInt8)
        case ignored(opcode: UInt8)
    }

    private var decoder = DoorResponseDecoder()
    private var exchange = DoorExchange()

    var buffered: [UInt8] { decoder.buffered }
    var discardedBytes: Int { decoder.discardedBytes }
    var selection: DoorExchange.Selection? { exchange.selection }
    var unlockSubmitted: Bool { exchange.unlockSubmitted }

    mutating func reset() {
        decoder.reset()
        exchange.reset()
    }

    mutating func markSubmitted(opcode: UInt8) -> Bool {
        guard exchange.markSubmitted(opcode: opcode) else { return false }
        // A partial reply that began before this submission cannot belong to
        // the new command. This runs at writeValue, not while flow-controlled.
        decoder.discardBufferedFragment()
        return true
    }

    mutating func append(_ value: Data) throws -> [Event] {
        let frames = try decoder.append(value)
        return classify(frames)
    }

    mutating func recoverStalledFragment() throws -> [Event] {
        let frames = try decoder.recoverStalledFragment()
        return classify(frames)
    }

    private mutating func classify(_ frames: [[UInt8]]) -> [Event] {
        var events: [Event] = []
        for frame in frames {
            let opcode = frame[2]
            if opcode == 1, let selection = exchange.acceptSelection(frame) {
                events.append(.selected(selection))
            } else if opcode == 6, let result = exchange.unlockResult(frame) {
                events.append(.unlockResult(result))
            } else {
                events.append(.ignored(opcode: opcode))
            }
        }
        return events
    }
}
