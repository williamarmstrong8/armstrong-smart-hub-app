import Foundation
import Observation

/// Writes hub-only numbers (sleep score and stages, overnight HRV, load,
/// readiness, VO2max) into the Last Night and Training glances' (and the
/// Armstrong Minimal face's) Connect IQ app settings, the way Garmin Connect saves an app's settings: a PROTOBUF_REQUEST
/// carrying Smart.app_config_service.appConfigSet, with the values in Garmin's
/// binary JSON. The glance reads them with Application.Properties. Ported from
/// Gadgetbridge's AppConfigHandler and GarminJson (AGPL-3.0-or-later); the
/// format is written up in watch/README.md.
///
/// Experimental: ported, not yet run against a real Forerunner 965.
@MainActor
@Observable
final class WatchSettings {
    /// One line per glance from the last push, for the diagnostics list.
    private(set) var lastResult: String?
    private(set) var isPushing = false

    weak var link: WatchLink?

    /// The glance apps and the Minimal face, by manifest id (watch/<App>/manifest.xml), and which part of the hub's answer each gets.
    static let targets: [(name: String, appID: UUID, part: KeyPath<HubValues, [String: HubValue]>)] = [
        ("Last Night", UUID(uuidString: "41a12dd5-ae16-476d-8d0e-d07e00c36c49")!, \.night),
        ("Training", UUID(uuidString: "5b8fa0a1-f73d-4582-88cc-7b70c5f3149d")!, \.training),
        // The Armstrong Minimal face shows training readiness in its top circle.
        ("Armstrong Minimal", UUID(uuidString: "99122c2f-4a24-4fa5-9291-b0eabcf1764c")!, \.training),
    ]

    private var nextRequestID: UInt16 = 0xB000
    /// Request id -> app, while waiting for the watch's answer.
    private var waiting: [UInt16: UUID] = [:]
    /// App -> status from AppConfigSetStatus (1 = saved).
    private var statuses: [UUID: UInt64] = [:]

    /// Fetches the hub's values and writes them to each glance. Quietly does nothing while disconnected.
    func push(api: APIClient) async {
        guard !isPushing, let link, link.state == .connected else { return }
        isPushing = true
        defer {
            isPushing = false
            waiting = [:]
        }
        let values: HubValues
        do {
            values = try await api.get("/api/mobile/fitness/watch")
        } catch {
            lastResult = "Couldn't get glance values from the hub: \(error.localizedDescription)"
            link.note("Glance settings: hub fetch failed")
            return
        }
        var lines: [String] = []
        for target in Self.targets {
            let fields = values[keyPath: target.part].sorted { $0.key < $1.key }.map { ($0.key, $0.value.garmin) }
            guard let config = try? GarminJSON.encode(fields) else {
                lines.append("\(target.name): couldn't encode")
                continue
            }
            nextRequestID = 0xB000 + (nextRequestID &+ 1) % 0x1000
            let id = nextRequestID
            waiting[id] = target.appID
            statuses[target.appID] = nil
            link.send(GarminFiles.protobufRequest(.protobufRequest, requestID: id, body: GarminAppConfig.set(appID: target.appID, config: config)))
            link.note("→ \(target.name) settings (\(config.count) bytes)")
            let outcome = switch await waitForStatus(target.appID) {
            case 1: "saved"
            case 2: "not installed, or the installed build has no settings"
            case nil: "no answer from the watch"
            case let other?: "refused (status \(other))"
            }
            lines.append("\(target.name): \(outcome)")
        }
        lastResult = lines.joined(separator: "\n")
        link.note("Glance settings: \(lines.joined(separator: "; "))")
    }

    private func waitForStatus(_ app: UUID) async -> UInt64? {
        let deadline = Date.now.addingTimeInterval(8)
        while statuses[app] == nil, Date.now < deadline, link?.state == .connected {
            try? await Task.sleep(for: .milliseconds(100))
        }
        return statuses[app]
    }

    /// True when the message is the watch's answer to a settings write.
    func handle(_ message: GFDIMessage) -> Bool {
        guard let link else { return false }
        switch Garmin.Message(rawValue: message.type) {
        case .response:
            // The watch's receipt for our PROTOBUF_REQUEST: original type, status, request id, ...
            guard message.payload.readLE(UInt16.self, at: 0) == Garmin.Message.protobufRequest.rawValue,
                  let id = message.payload.readLE(UInt16.self, at: 3), waiting[id] != nil else { return false }
            if message.payload.count >= 11, message.payload[2] != 0 || message.payload[9] != 0 || message.payload[10] != 0 {
                link.note("Watch rejected the settings request (\(message.payload.map { String(format: "%02x", $0) }.joined()))")
            }
            return true
        case .protobufRequest, .protobufResponse:
            guard let chunk = GarminFiles.ProtobufChunk(message.payload), chunk.offset == 0, Int(chunk.total) == chunk.data.count,
                  let result = GarminAppConfig.setStatus(chunk.data) else { return false }
            link.send(GFDIMessage.protobufAck(message.type, requestID: chunk.requestID, offset: 0))
            statuses[result.appID] = result.status
            return true
        default:
            return false
        }
    }
}

/// `GET /api/mobile/fitness/watch` (lib/fitness/watch-settings.ts in the hub): flat integers and short strings per glance.
struct HubValues: Decodable {
    var v: Int
    var night: [String: HubValue]
    var training: [String: HubValue]
}

enum HubValue: Decodable {
    case int(Int32)
    case string(String)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let number = try? container.decode(Int32.self) {
            self = .int(number)
        } else {
            self = .string(try container.decode(String.self))
        }
    }

    var garmin: GarminJSON.Value {
        switch self {
        case let .int(value): .int(value)
        case let .string(value): .string(value)
        }
    }
}

// MARK: AppConfigService

/// Smart field 4 (app_config_service), Gadgetbridge's gdi_app_config_service.proto:
///   1 appConfigGet, 2 appConfigGetStatus, 3 appConfigSet, 4 appConfigSetStatus, 5 appConfigRet
///   AppConfig { 1 appId (16 bytes, big-endian UUID), 2 appConfig (Garmin JSON) }
///   appConfigStatus { 1 appId, 2 status: 1 ok, 2 not installed / no settings }
@MainActor
enum GarminAppConfig {
    static let smartField: UInt64 = 4

    static func set(appID: UUID, config: [UInt8]) -> [UInt8] {
        let appConfig = Protobuf.encode([(1, .bytes(uuidBytes(appID))), (2, .bytes(config))])
        return Protobuf.encode([(smartField, .bytes(Protobuf.encode([(3, .bytes(appConfig))])))])
    }

    static func setStatus(_ smart: [UInt8]) -> (appID: UUID, status: UInt64)? {
        guard let service = Protobuf.decode(smart)?.bytes(smartField).flatMap(Protobuf.decode),
              let status = service.bytes(4).flatMap(Protobuf.decode),
              let id = status.bytes(1), id.count == 16 else { return nil }
        let uuid = UUID(uuid: (id[0], id[1], id[2], id[3], id[4], id[5], id[6], id[7],
                               id[8], id[9], id[10], id[11], id[12], id[13], id[14], id[15]))
        return (uuid, status.int(2) ?? 0)
    }

    static func uuidBytes(_ uuid: UUID) -> [UInt8] {
        withUnsafeBytes(of: uuid.uuid) { Array($0) }
    }
}

// MARK: Garmin JSON

/// Monkey C's serialized-object format, big-endian: an optional string section
/// (magic ABCDABCD, length, then length-prefixed NUL-terminated UTF-8 strings),
/// then a data section (magic DA7ADA7A, length, values). A value is a type
/// byte and its payload; strings are offsets into the string section, and a
/// map's keys and values follow it breadth-first.
enum GarminJSON {
    enum Value: Equatable {
        case int(Int32)
        case string(String)
        case bool(Bool)
    }

    enum Failure: Error { case tooLong }

    private static let stringMagic: [UInt8] = [0xAB, 0xCD, 0xAB, 0xCD]
    private static let dataMagic: [UInt8] = [0xDA, 0x7A, 0xDA, 0x7A]

    /// One flat map, keys in the given order.
    static func encode(_ map: [(String, Value)]) throws -> [UInt8] {
        var offsets: [String: UInt32] = [:]
        var strings: [UInt8] = []
        func intern(_ string: String) throws {
            guard offsets[string] == nil else { return }
            let utf8 = Array(string.utf8)
            guard utf8.count < 0xFFFF else { throw Failure.tooLong }
            offsets[string] = UInt32(strings.count)
            strings.appendBE(UInt16(utf8.count + 1))
            strings += utf8 + [0]
        }
        for (key, value) in map {
            try intern(key)
            if case let .string(s) = value { try intern(s) }
        }

        var data: [UInt8] = [0x0B]
        data.appendBE(UInt32(map.count))
        for (key, value) in map {
            data.append(0x03)
            data.appendBE(offsets[key]!)
            switch value {
            case let .int(n):
                data.append(0x01)
                data.appendBE(UInt32(bitPattern: n))
            case let .string(s):
                data.append(0x03)
                data.appendBE(offsets[s]!)
            case let .bool(b):
                data += [0x09, b ? 1 : 0]
            }
        }

        var out: [UInt8] = []
        if !strings.isEmpty {
            out += stringMagic
            out.appendBE(UInt32(strings.count))
            out += strings
        }
        out += dataMagic
        out.appendBE(UInt32(data.count))
        return out + data
    }
}

extension Array where Element == UInt8 {
    mutating func appendBE<T: FixedWidthInteger>(_ value: T) {
        Swift.withUnsafeBytes(of: value.bigEndian) { append(contentsOf: $0) }
    }
}
