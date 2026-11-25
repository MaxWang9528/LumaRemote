// DayBetter BLE protocol, as reverse-engineered by github.com/grimsteel/daybetter-led-strip (MIT).
//
// Every frame written to characteristic 0xA031:
//     A0 | cmd | len | payload… | CRC16-Modbus (little-endian)
// where len = 3 + payload.count and the CRC covers every byte before it.
// The light replies on 0xF031 with A1 | cmd | 04 | 01 | CRC for an accepted command.
//
// Newer lights (P09C bulbs; decoded from a capture of the DayBetter app with bletrace) use the same
// framing but ignore every command until a "CCHIP" login (see `Login`), and use a 4-byte color.

public enum DayBetter {
    /// 16-bit UUIDs (expand with the Bluetooth base UUID).
    public enum UUIDs {
        public static let discoveryService = "C031"
        public static let controlService = "E031"
        public static let writeCharacteristic = "A031"
        public static let notifyCharacteristic = "F031"
    }

    /// GATT UUIDs are per model: model P0xx uses service E0xx, write A0xx, notify F0xx and advertises
    /// C0xx. (Strips are P031 → E031/A031/F031; P09C bulbs → E09C/A09C/F09C, verified on-device.)
    public struct ModelUUIDs: Equatable, Sendable {
        public let model: String
        public let service: String
        public let write: String
        public let notify: String
    }

    /// Recognizes a control service UUID like "E09C" (or its 128-bit base-UUID form).
    public static func modelUUIDs(forService uuid: String) -> ModelUUIDs? {
        var s = uuid.uppercased()
        if s.count == 36, s.hasPrefix("0000"), s.hasSuffix("-0000-1000-8000-00805F9B34FB") {
            s = String(s.dropFirst(4).prefix(4))
        }
        guard s.count == 4, s.hasPrefix("E0"), UInt16(s, radix: 16) != nil else { return nil }
        let suffix = s.suffix(2)
        return ModelUUIDs(model: "P0" + suffix, service: s, write: "A0" + suffix, notify: "F0" + suffix)
    }

    public enum Command: UInt8, Sendable {
        case status = 0x10
        case power = 0x11
        case effect = 0x12
        case brightness = 0x13
        case color = 0x15
    }

    public static let requestHeader: UInt8 = 0xA0
    public static let responseHeader: UInt8 = 0xA1

    /// Builds a complete frame, checksum included.
    public static func frame(_ command: Command, payload: [UInt8]) -> [UInt8] {
        frame(rawCommand: command.rawValue, payload: payload)
    }

    public static func frame(rawCommand: UInt8, payload: [UInt8]) -> [UInt8] {
        var bytes: [UInt8] = [requestHeader, rawCommand, UInt8(truncatingIfNeeded: 3 + payload.count)]
        bytes += payload
        let crc = crc16Modbus(bytes)
        bytes.append(UInt8(crc & 0xFF))
        bytes.append(UInt8(crc >> 8))
        return bytes
    }

    public static func power(_ on: Bool) -> [UInt8] {
        frame(.power, payload: [on ? 0x01 : 0x00])
    }

    /// Brightness in percent; clamped to 0...100. Note: 0 still leaves the LEDs faintly lit.
    public static func brightness(_ percent: Int) -> [UInt8] {
        frame(.brightness, payload: [UInt8(min(max(percent, 0), 100))])
    }

    public static func color(_ color: RGB, corrected: Bool = true) -> [UInt8] {
        let c = corrected ? color.corrected() : color
        return frame(.color, payload: [c.r, c.g, c.b])
    }

    public static func effect(_ effect: Effect) -> [UInt8] {
        frame(.effect, payload: [effect.rawValue])
    }

    public static func requestStatus(_ variant: Variant = .strip) -> [UInt8] {
        frame(.status, payload: [variant == .cchip ? 0x01 : 0x00])
    }

    /// Which command set a light speaks. Detected at connect time: a light that answers the
    /// CCHIP login is `.cchip`; one that stays silent is an older `.strip`.
    public enum Variant: String, Codable, Sendable {
        case strip
        case cchip
    }

    /// CCHIP login. Captured from the DayBetter app (5 sessions, 2 bulbs, all consistent):
    ///   → A0 00 08 "CCHIP"                 ← A1 00 0A "CCHIP" c0 c1      (challenge)
    ///   → A0 01 0A "CCHIP" c0^24 c1^4C     ← A1 01 09 "CCHIP" 00         (00 = accepted)
    public enum Login {
        static let magic: [UInt8] = Array("CCHIP".utf8)
        static let key: [UInt8] = [0x24, 0x4C]

        public static func hello() -> [UInt8] {
            frame(rawCommand: 0x00, payload: magic)
        }

        public static func answer(challenge: [UInt8]) -> [UInt8] {
            frame(rawCommand: 0x01, payload: magic + zip(challenge.prefix(2), key).map { $0 ^ $1 })
        }
    }

    public static func crc16Modbus(_ bytes: [UInt8]) -> UInt16 {
        var crc: UInt16 = 0xFFFF
        for byte in bytes {
            crc ^= UInt16(byte)
            for _ in 0..<8 {
                crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xA001 : crc >> 1
            }
        }
        return crc
    }

    /// Parses a notification from the notify characteristic (F0xx).
    public static func parse(_ bytes: [UInt8]) -> Response {
        guard bytes.count >= 4, bytes[0] == responseHeader else { return .unknown(bytes) }
        let isLogin = bytes.count >= 9 && Array(bytes[3..<8]) == Login.magic
        if bytes[1] == 0x00, isLogin, bytes.count >= 10 {
            return .challenge([bytes[8], bytes[9]])
        }
        if bytes[1] == 0x01, isLogin {
            return .login(accepted: bytes[8] == 0x00)
        }
        // Status: A1 10 <len> <power> … Strips send 0x11 bytes; CCHIP lights send 0x2D bytes with
        // brightness at index 6 (e.g. A1 10 2D 01 00 41 64 …).
        if bytes[1] == Command.status.rawValue, bytes[2] > 0x04 {
            let brightness = bytes[2] == 0x2D && bytes.count > 6 ? Int(bytes[6]) : nil
            return .status(isOn: bytes[3] == 0x01, brightness: brightness)
        }
        if bytes[2] == 0x04 {
            return .ack(command: bytes[1], accepted: bytes[3] == 0x01)
        }
        return .unknown(bytes)
    }

    public enum Response: Equatable, Sendable {
        case ack(command: UInt8, accepted: Bool)
        case status(isOn: Bool, brightness: Int?)
        case challenge([UInt8])
        case login(accepted: Bool)
        case unknown([UInt8])
    }
}

public extension Array where Element == UInt8 {
    var hexString: String {
        map { byte in
            let s = String(byte, radix: 16, uppercase: true)
            return s.count == 1 ? "0" + s : s
        }.joined(separator: " ")
    }

    /// Parses "A0 11 04 01", "a0110401" or "A0:11:04:01". Returns nil on any invalid input.
    init?(hexString: String) {
        let cleaned = hexString.filter { !" :,-\n\t".contains($0) }
        guard !cleaned.isEmpty, cleaned.count % 2 == 0 else { return nil }
        var result: [UInt8] = []
        var index = cleaned.startIndex
        while index < cleaned.endIndex {
            let next = cleaned.index(index, offsetBy: 2)
            guard let byte = UInt8(cleaned[index..<next], radix: 16) else { return nil }
            result.append(byte)
            index = next
        }
        self = result
    }
}
