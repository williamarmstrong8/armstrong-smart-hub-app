import Foundation

// Garmin's watch protocol, as pure functions over bytes: nothing here touches
// Bluetooth. Ported from garmin-ble (github.com/gwerneckp/garmin-ble @ b662032,
// AGPL-3.0) and Gadgetbridge's Garmin support (codeberg.org/Freeyourgadget/
// Gadgetbridge, AGPL-3.0-or-later). See README "Fitness" for what that means
// for redistributing this app.
//
// The layers, outermost first:
//   MLR      one routing byte per BLE packet: 0 is the control channel, where
//            the watch hands out a handle per service; any other value is a
//            handle.
//   COBS     GFDI messages are COBS-encoded and split across packets.
//   GFDI     size (LE16) | type (LE16) | payload | CRC16 (LE16).

enum Garmin {
    static func uuid(_ short: UInt16) -> String { String(format: "6A4E%04X-667B-11E3-949A-0800200C9A66", short) }

    /// The watch advertises this service.
    static let advertisedService = uuid(0x2800)
    /// The receive characteristic is one of 0x2810...0x2814; the one to write
    /// is always 0x10 above it.
    static let receiveRange: ClosedRange<UInt16> = 0x2810...0x2814
    static let transmitOffset: UInt16 = 0x10

    /// Identifies this app to the watch's multi-link layer (Gadgetbridge uses 2 too).
    static let clientID: UInt64 = 2

    /// Seconds between the Unix epoch and Garmin's (1989-12-31 00:00 UTC).
    static let epochOffset: TimeInterval = 631_065_600

    enum Service: UInt16 {
        case gfdi = 1
        case realtimeHeartRate = 6
        case realtimeSteps = 7
        case realtimeStress = 13
        case realtimeBodyBattery = 20

        /// The live streams the link turns on, in this order.
        static let live: [Service] = [.realtimeHeartRate, .realtimeSteps, .realtimeStress, .realtimeBodyBattery]
    }

    /// GFDI SYSTEM_EVENT types (Gadgetbridge's GarminSystemEventType, in order).
    enum SystemEvent: UInt8 {
        case syncComplete = 0
        case pairComplete = 4
        case syncReady = 8
        case setupWizardComplete = 14
        case timeUpdated = 16
    }

    enum Control: UInt8 {
        case registerRequest = 0
        case registerResponse = 1
        case closeHandleRequest = 2
        case closeHandleResponse = 3
        case closeAllRequest = 5
        case closeAllResponse = 6
    }

    enum Message: UInt16 {
        case response = 5000
        case downloadRequest = 5002
        case uploadRequest = 5003
        case fileTransferData = 5004
        case createFile = 5005
        case deviceInformation = 5024
        case deviceSettings = 5026
        case systemEvent = 5030
        case supportedFileTypesRequest = 5031
        case notificationSubscription = 5036
        case synchronization = 5037
        case protobufRequest = 5043
        case protobufResponse = 5044
        case configuration = 5050
        case currentTimeRequest = 5052
        case authNegotiation = 5101

        static func name(_ type: UInt16) -> String {
            Message(rawValue: type).map { "\($0)" } ?? "type \(type)"
        }
    }
}

// MARK: CRC

enum GarminCRC {
    private static let table: [UInt16] = [
        0x0000, 0xCC01, 0xD801, 0x1400, 0xF001, 0x3C00, 0x2800, 0xE401,
        0xA001, 0x6C00, 0x7800, 0xB401, 0x5000, 0x9C01, 0x8801, 0x4400,
    ]

    static func compute<C: Collection<UInt8>>(_ data: C, initial: UInt16 = 0) -> UInt16 {
        var crc = initial
        for byte in data {
            crc = ((crc >> 4) & 0x0FFF) ^ table[Int(crc & 0xF)] ^ table[Int(byte & 0xF)]
            crc = ((crc >> 4) & 0x0FFF) ^ table[Int(crc & 0xF)] ^ table[Int(byte >> 4)]
        }
        return crc
    }
}

// MARK: COBS

enum COBS {
    /// Encodes one message, wrapped in the leading and trailing zero Garmin expects.
    static func encode(_ data: [UInt8]) -> [UInt8] {
        var out: [UInt8] = [0]
        var start = 0
        var lastWasZero = false
        while start < data.count {
            var zero = start
            while zero < data.count, data[zero] != 0 { zero += 1 }
            lastWasZero = zero < data.count
            var size = zero - start
            while size >= 0xFE {
                out.append(0xFF)
                out.append(contentsOf: data[start..<start + 0xFE])
                size -= 0xFE
                start += 0xFE
            }
            out.append(UInt8(size + 1))
            out.append(contentsOf: data[start..<start + size])
            start = zero + 1
        }
        if lastWasZero { out.append(1) }
        out.append(0)
        return out
    }

    /// Decodes the bytes between the delimiting zeros.
    static func decode<C: Collection<UInt8>>(_ frame: C) -> [UInt8] where C.Index == Int {
        var out: [UInt8] = []
        var i = frame.startIndex
        while i < frame.endIndex {
            let code = Int(frame[i])
            i += 1
            if code == 0 { break }
            let end = min(i + code - 1, frame.endIndex)
            out.append(contentsOf: frame[i..<end])
            i = end
            if code != 0xFF, i < frame.endIndex { out.append(0) }
        }
        return out
    }
}

/// Reassembles COBS messages that arrive split across BLE packets. A message
/// is `00 <encoded> 00`; a stale partial message is dropped after 1.5 s, as in
/// garmin-ble and Gadgetbridge.
struct COBSAssembler {
    private var buffer: [UInt8] = []
    private var lastUpdate = Date.distantPast

    mutating func append(_ bytes: some Sequence<UInt8>, now: Date = .now) -> [[UInt8]] {
        if now.timeIntervalSince(lastUpdate) > 1.5 { buffer.removeAll() }
        lastUpdate = now
        buffer.append(contentsOf: bytes)

        var messages: [[UInt8]] = []
        while true {
            guard let start = buffer.firstIndex(where: { $0 != 0 }) else {
                // Only delimiters so far: keep one so a message can start.
                if !buffer.isEmpty { buffer = [0] }
                break
            }
            guard let end = buffer[start...].firstIndex(of: 0) else {
                if start > 0 { buffer.removeFirst(start - 1) }
                break
            }
            messages.append(COBS.decode(Array(buffer[start..<end])))
            buffer.removeFirst(end)
        }
        return messages
    }

    mutating func reset() { buffer.removeAll() }
}

// MARK: Little-endian helpers

extension Array where Element == UInt8 {
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }
}

extension Collection where Element == UInt8, Index == Int {
    func readLE<T: FixedWidthInteger>(_: T.Type, at offset: Int) -> T? {
        let size = MemoryLayout<T>.size
        guard offset >= 0, startIndex + offset + size <= endIndex else { return nil }
        var value: T = 0
        for i in 0..<size { value |= T(self[startIndex + offset + i]) << (8 * i) }
        return value
    }
}

// MARK: GFDI

struct GFDIMessage {
    let type: UInt16
    /// The payload between the type and the CRC.
    let payload: [UInt8]

    var name: String { Garmin.Message.name(type) }

    /// Wraps a payload: size (header + payload + CRC), type, payload, CRC.
    static func frame(_ type: UInt16, _ payload: [UInt8] = []) -> [UInt8] {
        var out: [UInt8] = []
        out.appendLE(UInt16(payload.count + 6))
        out.appendLE(type)
        out.append(contentsOf: payload)
        out.appendLE(GarminCRC.compute(out))
        return out
    }

    /// Parses a COBS-decoded frame, or nil when it's short or its CRC is wrong.
    init?(frame: [UInt8]) {
        guard frame.count >= 6,
              let size = frame.readLE(UInt16.self, at: 0), Int(size) == frame.count,
              var type = frame.readLE(UInt16.self, at: 2),
              let crc = frame.readLE(UInt16.self, at: frame.count - 2),
              crc == GarminCRC.compute(frame[0..<(frame.count - 2)])
        else { return nil }
        // Compact form: the high byte carries a sequence number (Gadgetbridge GFDIMessage).
        if type & 0x8000 != 0 { type = (type & 0xFF) + 5000 }
        self.type = type
        self.payload = Array(frame[4..<(frame.count - 2)])
    }

    /// A generic ACK for any message but a response.
    static func ack(_ type: UInt16) -> [UInt8] {
        var payload: [UInt8] = []
        payload.appendLE(type)
        payload.append(0)
        return frame(Garmin.Message.response.rawValue, payload)
    }

    /// Acknowledges a protobuf request or response chunk.
    static func protobufAck(_ type: UInt16, requestID: UInt16, offset: UInt32) -> [UInt8] {
        var payload: [UInt8] = []
        payload.appendLE(type)
        payload.append(0)
        payload.appendLE(requestID)
        payload.appendLE(offset)
        payload.append(contentsOf: [0, 0]) // chunk kept, no error
        return frame(Garmin.Message.response.rawValue, payload)
    }

    /// Answers CURRENT_TIME_REQUEST with the phone's time and UTC offset.
    static func timeResponse(now: Date = .now, timeZone: TimeZone = .current) -> [UInt8] {
        var payload: [UInt8] = []
        payload.appendLE(Garmin.Message.currentTimeRequest.rawValue)
        payload.append(0)
        payload.appendLE(UInt32(0)) // reference id
        payload.appendLE(UInt32(max(0, now.timeIntervalSince1970 - Garmin.epochOffset)))
        payload.appendLE(Int32(timeZone.secondsFromGMT(for: now)))
        payload.appendLE(Int32(0)) // DST end
        payload.appendLE(Int32(0)) // DST start
        return frame(Garmin.Message.response.rawValue, payload)
    }

    /// SUPPORTED_FILE_TYPES_REQUEST: asks which file types the watch serves. Read-only;
    /// Gadgetbridge and the official app send it on every connect.
    static func supportedFileTypesRequest() -> [UInt8] {
        frame(Garmin.Message.supportedFileTypesRequest.rawValue)
    }

    /// The answer to SUPPORTED_FILE_TYPES_REQUEST as "data/sub name" strings, or nil if the
    /// RESPONSE is about something else: status, count, then data type, sub-type and a
    /// length-prefixed name per type (Gadgetbridge's SupportedFileTypesStatusMessage).
    static func supportedFileTypes(_ payload: [UInt8]) -> [String]? {
        guard payload.readLE(UInt16.self, at: 0) == Garmin.Message.supportedFileTypesRequest.rawValue,
              payload.count >= 4, payload[2] == 0 else { return nil }
        var types: [String] = []
        var i = 4
        for _ in 0..<Int(payload[3]) {
            guard i + 3 <= payload.count else { break }
            let size = Int(payload[i + 2])
            guard i + 3 + size <= payload.count else { break }
            let name = String(decoding: payload[(i + 3)..<(i + 3 + size)], as: UTF8.self)
            types.append("\(payload[i])/\(payload[i + 1]) \(name)")
            i += 3 + size
        }
        return types
    }

    /// Answers NOTIFICATION_SUBSCRIPTION (payload: enable, unknown) with notifications
    /// disabled, since this app forwards none. A plain ACK leaves the watch asking again
    /// about once a second for as long as the link is up.
    static func notificationSubscriptionReply(_ request: [UInt8]) -> [UInt8] {
        var payload: [UInt8] = []
        payload.appendLE(Garmin.Message.notificationSubscription.rawValue)
        payload += [0, 1, request.first == 1 ? 1 : 0, 0] // ACK, DISABLED, enable echoed, unknown
        return frame(Garmin.Message.response.rawValue, payload)
    }

    /// Tells the watch something happened on the phone, such as setup finishing.
    static func systemEvent(_ event: Garmin.SystemEvent, value: UInt8 = 0) -> [UInt8] {
        frame(Garmin.Message.systemEvent.rawValue, [event.rawValue, value])
    }

    /// The protobuf header's request id and offset, for acknowledging it.
    var protobufHeader: (requestID: UInt16, offset: UInt32)? {
        guard let id = payload.readLE(UInt16.self, at: 0), let offset = payload.readLE(UInt32.self, at: 2) else { return nil }
        return (id, offset)
    }
}

/// What the watch says about itself once the GFDI channel opens.
struct WatchIdentity: Equatable, Codable {
    var productNumber: UInt16
    var unitNumber: UInt32
    var softwareVersion: UInt16
    var maxPacketSize: UInt16
    var bluetoothName: String
    var deviceName: String
    var model: String

    var firmware: String { String(format: "%d.%02d", softwareVersion / 100, softwareVersion % 100) }

    init?(_ message: GFDIMessage) {
        let p = message.payload
        guard let product = p.readLE(UInt16.self, at: 2), let unit = p.readLE(UInt32.self, at: 4),
              let software = p.readLE(UInt16.self, at: 8), let maxPacket = p.readLE(UInt16.self, at: 10)
        else { return nil }
        var offset = 12
        func string() -> String {
            guard offset < p.count else { return "" }
            let size = Int(p[offset])
            let end = min(offset + 1 + size, p.count)
            defer { offset = end }
            return String(decoding: p[(offset + 1)..<end], as: UTF8.self)
        }
        productNumber = product
        unitNumber = unit
        softwareVersion = software
        maxPacketSize = maxPacket
        bluetoothName = string()
        deviceName = string()
        model = string()
    }
}

// MARK: MLR

enum MLRPacket: Equatable {
    case data(handle: UInt8, payload: [UInt8])
    case closeAllResponse
    /// The watch closed a service's handle, as it does after a file stream.
    case closedHandle(service: UInt16)
    case registered(service: UInt16, status: UInt8, handle: UInt8)
    case control(UInt8)

    /// Routes one notification. The watch flags handles 0-7 with the high bit
    /// (`1hhh....`) or sends a bare handle byte.
    init?(_ data: [UInt8]) {
        guard let first = data.first else { return nil }
        if first & 0x80 != 0 {
            self = .data(handle: (first & 0x70) >> 4, payload: Array(data.dropFirst()))
        } else if first != 0 {
            guard data.count >= 2 else { return nil }
            self = .data(handle: first, payload: Array(data.dropFirst()))
        } else {
            guard data.count >= 2 else { return nil }
            switch Garmin.Control(rawValue: data[1]) {
            case .closeAllResponse:
                self = .closeAllResponse
            case .closeHandleResponse:
                guard data.count >= 12, let service = data.readLE(UInt16.self, at: 10) else { return nil }
                self = .closedHandle(service: service)
            case .registerResponse:
                guard data.count >= 14, let service = data.readLE(UInt16.self, at: 10) else { return nil }
                self = .registered(service: service, status: data[12], handle: data[13])
            default:
                self = .control(data[1])
            }
        }
    }

    /// Drops every handle the watch had assigned, including another host's.
    /// Same bytes as garmin-ble, which this watch answers.
    static func closeAll() -> [UInt8] {
        var out: [UInt8] = [0, Garmin.Control.closeAllRequest.rawValue]
        out.appendLE(UInt16(0))
        out.appendLE(Garmin.clientID)
        out.append(0)
        return out
    }

    /// Asks for a handle for a service, without the reliable (MLR) layer.
    static func register(_ service: UInt16) -> [UInt8] {
        var out: [UInt8] = [0, Garmin.Control.registerRequest.rawValue]
        out.appendLE(Garmin.clientID)
        out.appendLE(service)
        out.append(0)
        return out
    }

    /// Splits an encoded GFDI message into writes of at most `maxWrite` bytes,
    /// each starting with the handle.
    static func packets(_ encoded: [UInt8], handle: UInt8, maxWrite: Int) -> [[UInt8]] {
        let body = max(maxWrite - 1, 1)
        return stride(from: 0, to: encoded.count, by: body).map {
            [handle] + encoded[$0..<min($0 + body, encoded.count)]
        }
    }
}

// MARK: Realtime readings

struct HeartRateReading: Equatable {
    var bpm: Int
    var restingBPM: Int?

    /// `[padding, bpm, resting]`; resting is 0 until the watch knows it.
    init?(_ payload: [UInt8]) {
        guard payload.count >= 3 else { return nil }
        bpm = Int(payload[1])
        restingBPM = payload[2] > 0 ? Int(payload[2]) : nil
    }
}

/// A 0-100 level from the live stress or Body Battery stream. The first byte
/// is the level; Body Battery sends 0x7F while it doesn't know (Gadgetbridge's
/// RealtimeBodyBatteryCallback). Gadgetbridge doesn't decode stress, so its
/// layout is assumed to match: anything outside 0-100 (the FIT file's -1 off
/// wrist, -2 too active) counts as no reading.
struct LevelReading: Equatable {
    var value: Int

    init?(_ payload: [UInt8]) {
        guard let first = payload.first else { return nil }
        let raw = Int(Int8(bitPattern: first))
        guard (0...100).contains(raw) else { return nil }
        value = raw
    }
}

struct StepsReading: Equatable {
    var count: Int
    var goal: Int

    /// `[steps LE32, goal LE32]`
    init?(_ payload: [UInt8]) {
        guard let count = payload.readLE(UInt32.self, at: 0), let goal = payload.readLE(UInt32.self, at: 4) else { return nil }
        self.count = Int(count)
        self.goal = Int(goal)
    }
}
