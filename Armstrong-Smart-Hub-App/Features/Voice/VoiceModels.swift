import Foundation

// MARK: Cards (VoiceView in lib/agent/voice.ts)

struct LightTile: Decodable, Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let on: Bool
    let brightnessPct: Int?
    let rgb: [Int]?
    let kelvin: Int?
}

struct MovieCardData: Decodable, Equatable, Sendable {
    let id: Int
    let mediaType: String
    let title: String
    let year: String?
    let posterURL: String?
    let backdropURL: String?
    let overview: String?
    let runtimeMinutes: Int?
    let genres: [String]
}

enum MovieStage: String, Decodable, Sendable {
    case confirm, requested, alreadyRequested, available, playing
}

struct FinanceStat: Decodable, Identifiable, Equatable, Sendable {
    enum Format: String, Decodable, Sendable { case currency, count, percent }
    enum Tone: String, Decodable, Sendable { case positive, negative }
    let label: String
    let value: Double
    let format: Format
    let detail: String?
    let tone: Tone?
    var id: String { label }
}

struct FinanceChart: Decodable, Equatable, Sendable {
    enum Style: String, Decodable, Sendable { case bar, hbar, line }
    struct Point: Decodable, Identifiable, Equatable, Sendable {
        let label: String
        let value: Double
        var id: String { label }
    }
    let style: Style
    let points: [Point]
}

struct FinanceRow: Decodable, Identifiable, Equatable, Sendable {
    let title: String
    let subtitle: String?
    let amount: Double
    var id: String { "\(title)|\(subtitle ?? "")|\(amount)" }
}

struct FinanceCardData: Decodable, Equatable, Sendable {
    let title: String
    let subtitle: String
    let currency: String
    let stats: [FinanceStat]
    let chart: FinanceChart?
    let rows: [FinanceRow]
}

struct VoiceCalendarDay: Decodable, Identifiable, Sendable {
    let day: String
    let events: [CalendarEvent]
    var id: String { day }
}

struct CalendarCardData: Decodable, Sendable {
    let title: String
    let timeZone: String
    let days: [VoiceCalendarDay]
    let addedId: String?
    /// Just deleted: shown at first, then slides out.
    let removedId: String?
}

struct HabitDot: Decodable, Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let color: String
    let icon: String?
    let done: Bool
    let streak: Int
}

struct HabitsCardData: Decodable, Sendable {
    let date: String
    let habits: [HabitDot]
    let changedId: String?
}

/// What the overlay shows after the orb: one card per kind of request.
enum VoiceView: Decodable, Sendable {
    case lights([LightTile], changed: [String])
    case movie(MovieCardData, MovieStage)
    case finance(FinanceCardData)
    case calendar(CalendarCardData)
    case habits(HabitsCardData)

    enum Kind: String, Decodable, Sendable { case lights, movie, finance, calendar, habits }

    var kind: Kind {
        switch self {
        case .lights: .lights
        case .movie: .movie
        case .finance: .finance
        case .calendar: .calendar
        case .habits: .habits
        }
    }

    private enum Keys: String, CodingKey { case kind, lights, changed, movie, stage }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        switch try c.decode(Kind.self, forKey: .kind) {
        case .lights:
            self = .lights(try c.decode([LightTile].self, forKey: .lights), changed: (try? c.decode([String].self, forKey: .changed)) ?? [])
        case .movie:
            self = .movie(try c.decode(MovieCardData.self, forKey: .movie), try c.decode(MovieStage.self, forKey: .stage))
        case .finance:
            self = .finance(try FinanceCardData(from: decoder))
        case .calendar:
            self = .calendar(try CalendarCardData(from: decoder))
        case .habits:
            self = .habits(try HabitsCardData(from: decoder))
        }
    }
}

// MARK: Wire types (/api/mobile/voice/*)

/// /api/mobile/voice/session: a single-use Gateway secret and the session config to send first.
struct VoiceSession: Decodable, Sendable {
    let url: String
    let token: String
    let expiresAt: Double
    let model: String
    /// Passed through to the socket untouched, so the server owns the prompt and tools.
    let config: JSONObject

    var isFresh: Bool { Date().timeIntervalSince1970 < expiresAt - 60 }
}

struct VoiceToolReply: Decodable, Sendable {
    let output: JSONObject
    let view: VoiceView?
}

struct VoiceIntentReply: Decodable, Sendable {
    let screen: String
    let probability: Double
    let view: VoiceView?
}

/// Any JSON object, kept as raw bytes so it can be forwarded without a schema.
nonisolated struct JSONObject: Decodable, @unchecked Sendable {
    let value: [String: Any]

    init(_ value: [String: Any]) { self.value = value }

    init(from decoder: Decoder) throws {
        let any = try AnyJSON(from: decoder)
        guard let dict = any.value as? [String: Any] else {
            throw DecodingError.typeMismatch([String: Any].self, .init(codingPath: decoder.codingPath, debugDescription: "Expected an object"))
        }
        value = dict
    }

    var jsonString: String {
        guard let data = try? JSONSerialization.data(withJSONObject: value), let s = String(data: data, encoding: .utf8) else { return "{}" }
        return s
    }
}

nonisolated private struct AnyJSON: Decodable {
    let value: Any

    private struct Key: CodingKey {
        var stringValue: String
        init?(stringValue: String) { self.stringValue = stringValue }
        var intValue: Int? { nil }
        init?(intValue: Int) { nil }
    }

    init(from decoder: Decoder) throws {
        if let keyed = try? decoder.container(keyedBy: Key.self) {
            var dict: [String: Any] = [:]
            for key in keyed.allKeys { dict[key.stringValue] = try keyed.decode(AnyJSON.self, forKey: key).value }
            value = dict
        } else if var list = try? decoder.unkeyedContainer() {
            var items: [Any] = []
            while !list.isAtEnd { items.append(try list.decode(AnyJSON.self).value) }
            value = items
        } else {
            let single = try decoder.singleValueContainer()
            if single.decodeNil() { value = NSNull() }
            else if let b = try? single.decode(Bool.self) { value = b }
            else if let i = try? single.decode(Int.self) { value = i }
            else if let d = try? single.decode(Double.self) { value = d }
            else { value = try single.decode(String.self) }
        }
    }
}
