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

// MARK: Weather (lib/weather.ts)

struct WeatherHour: Decodable, Identifiable, Equatable, Sendable {
    /// Hub-local "2026-10-28T16:00".
    let time: String
    let temp: Int
    let code: Int
    let isDay: Bool
    let precipChance: Int?
    var id: String { time }
}

struct WeatherDay: Decodable, Identifiable, Equatable, Sendable {
    let day: String
    let high: Int
    let low: Int
    let code: Int
    let precipChance: Int?
    var id: String { day }
}

struct WeatherData: Decodable, Equatable, Sendable {
    struct Current: Decodable, Equatable, Sendable {
        let temp: Int
        let feelsLike: Int
        let code: Int
        let isDay: Bool
        let humidity: Int?
        let windMph: Int?
        let label: String
    }
    let place: String
    let current: Current
    let hours: [WeatherHour]
    let days: [WeatherDay]
    let sunrise: String?
    let sunset: String?
}

// MARK: Fitness and the Pi

struct FitnessCardData: Decodable, Equatable, Sendable {
    struct DaySteps: Decodable, Identifiable, Equatable, Sendable {
        let day: String
        let steps: Int?
        var id: String { day }
    }
    struct Workout: Decodable, Equatable, Sendable {
        let sport: String
        let startTime: String
        let minutes: Int?
        let distanceMeters: Double?
    }
    /// readiness, sleep, bodyBattery, steps, heart or workout: what the card shows big.
    let focus: String?
    let readiness: Int?
    let readinessLevel: String?
    let sleepScore: Int?
    let sleepSeconds: Int?
    let bodyBattery: Int?
    let stepsDay: String?
    let steps: Int?
    let stepGoal: Int?
    let restingHr: Int?
    let hrv: Int?
    let week: [DaySteps]
    let lastWorkout: Workout?
}

struct PiContainer: Decodable, Identifiable, Equatable, Sendable {
    let name: String
    let state: String
    let status: String
    let health: String?
    let image: String
    var id: String { name }
    var running: Bool { state == "running" }
    var troubled: Bool { !running || health == "unhealthy" }
}

/// /api/mobile/pi: how the Pi is doing, or why the hub can't see it.
struct PiStatus: Decodable, Equatable, Sendable {
    struct Usage: Decodable, Equatable, Sendable {
        let used: Double
        let total: Double
        var fraction: Double { total > 0 ? used / total : 0 }
    }
    let available: Bool
    let reason: String?
    let host: String?
    let temperature: Double?
    let load: [Double]?
    let cores: Int?
    let memory: Usage?
    let swap: Usage?
    let disk: Usage?
    let uptimeSeconds: Int?
    let hubUptimeSeconds: Int?
    let containers: [PiContainer]?
    let dockerError: String?

    private enum Keys: String, CodingKey {
        case available, reason, host, temperature, load, cores, memory, swap, disk, uptimeSeconds, hubUptimeSeconds, containers, dockerError
    }
    private struct MB: Decodable { let usedMB: Double; let totalMB: Double }
    private struct GB: Decodable { let usedGB: Double; let totalGB: Double }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        available = try c.decode(Bool.self, forKey: .available)
        reason = try c.decodeIfPresent(String.self, forKey: .reason)
        host = try c.decodeIfPresent(String.self, forKey: .host)
        temperature = try c.decodeIfPresent(Double.self, forKey: .temperature)
        load = try c.decodeIfPresent([Double].self, forKey: .load)
        cores = try c.decodeIfPresent(Int.self, forKey: .cores)
        memory = try c.decodeIfPresent(MB.self, forKey: .memory).map { Usage(used: $0.usedMB, total: $0.totalMB) }
        swap = try c.decodeIfPresent(MB.self, forKey: .swap).map { Usage(used: $0.usedMB, total: $0.totalMB) }
        disk = try c.decodeIfPresent(GB.self, forKey: .disk).map { Usage(used: $0.usedGB, total: $0.totalGB) }
        uptimeSeconds = try c.decodeIfPresent(Int.self, forKey: .uptimeSeconds)
        hubUptimeSeconds = try c.decodeIfPresent(Int.self, forKey: .hubUptimeSeconds)
        containers = try c.decodeIfPresent([PiContainer].self, forKey: .containers)
        dockerError = try c.decodeIfPresent(String.self, forKey: .dockerError)
    }

    var running: Int { containers?.filter(\.running).count ?? 0 }
    var troubled: [PiContainer] { containers?.filter(\.troubled) ?? [] }
}

/// The wake-up alarm Jarvis just set (or turned off, when `time` is nil). Made on the iPad,
/// which owns the alarm; the hub never sends it.
struct AlarmCardData: Equatable, Sendable {
    let time: Date?
    let secondAlarm: Bool
}

/// What the overlay shows after the orb: one card per kind of request.
enum VoiceView: Decodable, Sendable {
    case lights([LightTile], changed: [String])
    case movie(MovieCardData, MovieStage)
    case finance(FinanceCardData)
    case calendar(CalendarCardData)
    case habits(HabitsCardData)
    case weather(WeatherData)
    case fitness(FitnessCardData)
    case pi(PiStatus, changed: String?, action: String?)
    case alarm(AlarmCardData)

    enum Kind: String, Decodable, Sendable { case lights, movie, finance, calendar, habits, weather, fitness, pi, alarm }

    var kind: Kind {
        switch self {
        case .lights: .lights
        case .movie: .movie
        case .finance: .finance
        case .calendar: .calendar
        case .habits: .habits
        case .weather: .weather
        case .fitness: .fitness
        case .pi: .pi
        case .alarm: .alarm
        }
    }

    private enum Keys: String, CodingKey { case kind, lights, changed, movie, stage, weather, fitness, pi, action }

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
        case .weather:
            self = .weather(try c.decode(WeatherData.self, forKey: .weather))
        case .fitness:
            self = .fitness(try c.decode(FitnessCardData.self, forKey: .fitness))
        case .pi:
            self = .pi(try c.decode(PiStatus.self, forKey: .pi),
                       changed: try c.decodeIfPresent(String.self, forKey: .changed),
                       action: try c.decodeIfPresent(String.self, forKey: .action))
        case .alarm:
            throw DecodingError.dataCorruptedError(forKey: .kind, in: c, debugDescription: "Alarm cards are made on the iPad")
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

/// A view this app version can't draw (a newer hub) is dropped rather than failing the reply.
struct VoiceToolReply: Decodable, Sendable {
    let output: JSONObject
    let view: VoiceView?

    private enum Keys: String, CodingKey { case output, view }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        output = try c.decode(JSONObject.self, forKey: .output)
        view = try? c.decodeIfPresent(VoiceView.self, forKey: .view)
    }
}

struct VoiceIntentReply: Decodable, Sendable {
    let screen: String
    let probability: Double
    let view: VoiceView?

    private enum Keys: String, CodingKey { case screen, probability, view }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        screen = try c.decode(String.self, forKey: .screen)
        probability = try c.decode(Double.self, forKey: .probability)
        view = try? c.decodeIfPresent(VoiceView.self, forKey: .view)
    }
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
