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

    // Filled directly from the original we/Se constants by the packaging script.
    static let highTable: [UInt8] = [0, 193, 129, 64, 1, 192, 128, 65, 1, 192, 128, 65, 0, 193, 129, 64, 1, 192, 128, 65, 0, 193, 129, 64, 0, 193, 129, 64, 1, 192, 128, 65, 1, 192, 128, 65, 0, 193, 129, 64, 0, 193, 129, 64, 1, 192, 128, 65, 0, 193, 129, 64, 1, 192, 128, 65, 1, 192, 128, 65, 0, 193, 129, 64, 1, 192, 128, 65, 0, 193, 129, 64, 0, 193, 129, 64, 1, 192, 128, 65, 0, 193, 129, 64, 1, 192, 128, 65, 1, 192, 128, 65, 0, 193, 129, 64, 0, 193, 129, 64, 1, 192, 128, 65, 1, 192, 128, 65, 0, 193, 129, 64, 1, 192, 128, 65, 0, 193, 129, 64, 0, 193, 129, 64, 1, 192, 128, 65, 1, 192, 128, 65, 0, 193, 129, 64, 0, 193, 129, 64, 1, 192, 128, 65, 0, 193, 129, 64, 1, 192, 128, 65, 1, 192, 128, 65, 0, 193, 129, 64, 0, 193, 129, 64, 1, 192, 128, 65, 1, 192, 128, 65, 0, 193, 129, 64, 1, 192, 128, 65, 0, 193, 129, 64, 0, 193, 129, 64, 1, 192, 128, 65, 0, 193, 129, 64, 1, 192, 128, 65, 1, 192, 128, 65, 0, 193, 129, 64, 1, 192, 128, 65, 0, 193, 129, 64, 0, 193, 129, 64, 1, 192, 128, 65, 1, 192, 128, 65, 0, 193, 129, 64, 0, 193, 129, 64, 1, 192, 128, 65, 0, 193, 129, 64, 1, 192, 128, 65, 1, 192, 128, 65, 0, 193, 129, 64]
    static let lowTable: [UInt8] = [0, 192, 193, 1, 195, 3, 2, 194, 198, 6, 7, 199, 5, 197, 196, 4, 204, 12, 13, 205, 15, 207, 206, 14, 10, 202, 203, 11, 201, 9, 8, 200, 216, 24, 25, 217, 27, 219, 218, 26, 30, 222, 223, 31, 221, 29, 28, 220, 20, 212, 213, 21, 215, 23, 22, 214, 210, 18, 19, 211, 17, 209, 208, 16, 240, 48, 49, 241, 51, 243, 242, 50, 54, 246, 247, 55, 245, 53, 52, 244, 60, 252, 253, 61, 255, 63, 62, 254, 250, 58, 59, 251, 57, 249, 248, 56, 40, 232, 233, 41, 235, 43, 42, 234, 238, 46, 47, 239, 45, 237, 236, 44, 228, 36, 37, 229, 39, 231, 230, 38, 34, 226, 227, 35, 225, 33, 32, 224, 160, 96, 97, 161, 99, 163, 162, 98, 102, 166, 167, 103, 165, 101, 100, 164, 108, 172, 173, 109, 175, 111, 110, 174, 170, 106, 107, 171, 105, 169, 168, 104, 120, 184, 185, 121, 187, 123, 122, 186, 190, 126, 127, 191, 125, 189, 188, 124, 180, 116, 117, 181, 119, 183, 182, 118, 114, 178, 179, 115, 177, 113, 112, 176, 80, 144, 145, 81, 147, 83, 82, 146, 150, 86, 87, 151, 85, 149, 148, 84, 156, 92, 93, 157, 95, 159, 158, 94, 90, 154, 155, 91, 153, 89, 88, 152, 136, 72, 73, 137, 75, 139, 138, 74, 78, 142, 143, 79, 141, 77, 76, 140, 68, 132, 133, 69, 135, 71, 70, 134, 130, 66, 67, 131, 65, 129, 128, 64]
}
