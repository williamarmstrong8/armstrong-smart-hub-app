import SwiftUI

/// GET /api/mobile/fitness: what the hub has parsed from the watch's files.
struct FitnessSnapshot: Decodable {
    var days: [FitnessDay]
    var activities: [FitnessActivity]
    var sleep: [SleepNight]
    var heartRate: [HeartRatePoint]
    var files: [FileCount]
    /// Overnight HRV, newest first. Absent until the hub has the HRV update.
    var hrv: [FitnessHrv]?
    /// Missing from older hubs.
    var metrics: FitnessMetrics?
    /// Strain, recovery, sleep need, resilience, training analysis and vitals. Missing from older hubs.
    var insights: FitnessInsights?
    /// The watch's own readiness, Endurance Score, race predictions and more. Missing from older hubs.
    var watch: FitnessWatch?
    /// When the newest all-day reading is from: the day-long charts end here. Missing from older hubs.
    var allDayThrough: String?
    /// The newest once-a-day plain-English read of the data, and whether a newer one is being written. Missing from older hubs.
    var summary: FitnessSummary?
    var summaryWriting: Bool?

    struct FileCount: Decodable { var kind: String; var count: Int }

    /// Blocks that didn't decode, with why (shown in the watch sheet's diagnostics).
    var problems: [String] = []

    enum CodingKeys: String, CodingKey { case days, activities, sleep, heartRate, files, hrv, metrics, insights, watch, allDayThrough, summary, summaryWriting }

    /// The hub's models change more often than the app is rebuilt. One value
    /// of an unexpected shape used to fail the whole snapshot, which left the
    /// page on its old copy after a sync that had worked; now only the block
    /// it is in goes missing, and the rest of the page updates.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        var problems: [String] = []
        func block<T: Decodable>(_ key: CodingKeys, _ type: T.Type) -> T? {
            do { return try c.decodeIfPresent(T.self, forKey: key) } catch {
                problems.append("\(key.stringValue): \(Self.describe(error))")
                return nil
            }
        }
        days = block(.days, [FitnessDay].self) ?? []
        activities = block(.activities, [FitnessActivity].self) ?? []
        sleep = block(.sleep, [SleepNight].self) ?? []
        heartRate = block(.heartRate, [HeartRatePoint].self) ?? []
        files = block(.files, [FileCount].self) ?? []
        hrv = block(.hrv, [FitnessHrv].self)
        metrics = block(.metrics, FitnessMetrics.self)
        insights = block(.insights, FitnessInsights.self)
        watch = block(.watch, FitnessWatch.self)
        allDayThrough = block(.allDayThrough, String.self)
        summary = block(.summary, FitnessSummary.self)
        summaryWriting = block(.summaryWriting, Bool.self)
        self.problems = problems
        #if DEBUG
        for problem in problems { print("FITNESS snapshot block dropped:", problem) }
        #endif
    }

    private static func describe(_ error: Error) -> String {
        func path(_ context: DecodingError.Context) -> String { context.codingPath.map(\.stringValue).joined(separator: ".") }
        switch error as? DecodingError {
        case let .keyNotFound(key, context): return "no \(key.stringValue) at \(path(context))"
        case let .valueNotFound(_, context): return "null at \(path(context))"
        case let .typeMismatch(_, context): return "wrong type at \(path(context))"
        case let .dataCorrupted(context): return "unreadable at \(path(context))"
        default: return error.localizedDescription
        }
    }
}

/// One paragraph on how the person is doing, written by a model on the hub after the morning sync (lib/fitness/daily-summary.ts).
struct FitnessSummary: Decodable {
    /// The sleep file it was written after.
    var night: String
    var nightEnd: String
    var text: String
    var model: String
    var createdAt: String
}

struct FitnessHrv: Decodable, Identifiable {
    var id: String
    var day: String
    var weeklyAverage: Double?
    var lastNightAverage: Double?
    var lastNight5MinHigh: Double?
    var baselineLowUpper: Double?
    var baselineBalancedLower: Double?
    var baselineBalancedUpper: Double?
    var status: String?
    var date: Date? {
        let parts = day.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return Calendar.current.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }
}

struct FitnessDay: Decodable, Identifiable {
    var day: String
    var steps: Int?
    var stepGoal: Int?
    var restingHr: Int?
    /// The watch's own day totals, from that day's all-day file (so nil for today until midnight, and on older hubs).
    var distanceMeters: Double?
    var activeKcal: Int?
    var restingKcal: Int?
    var activeSeconds: Double?
    var floorsUp: Double?
    var floorsDown: Double?
    var moderateMinutes: Int?
    var vigorousMinutes: Int?
    var id: String { day }
    /// Garmin's intensity minutes: vigorous count double.
    var intensityMinutes: Int? {
        guard moderateMinutes != nil || vigorousMinutes != nil else { return nil }
        return (moderateMinutes ?? 0) + 2 * (vigorousMinutes ?? 0)
    }
    /// Local midnight of the day, for charts.
    var date: Date? {
        let parts = day.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return Calendar.current.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }
}

struct HeartRatePoint: Decodable, Identifiable {
    var at: String
    var bpm: Int
    var id: String { at }
    var date: Date? { ISO.parse(at) }
}

struct FitnessActivity: Decodable, Identifiable, Hashable {
    var id: String
    var sport: String
    var subSport: String?
    var startTime: String
    var utcOffset: Int?
    var elapsedSeconds: Double?
    var movingSeconds: Double?
    var distanceMeters: Double?
    var calories: Int?
    var avgHr: Int?
    var maxHr: Int?
    var ascentMeters: Double?
    var avgSpeed: Double?
    var trainingEffect: Double?
    /// The watch's own load and anaerobic Training Effect, and what it says the session trained.
    var watchLoad: Double?
    var anaerobicEffect: Double?
    var primaryBenefit: String?

    var start: Date? { ISO.parse(startTime) }
    var duration: Double? { movingSeconds ?? elapsedSeconds }
    var end: Date? { start.flatMap { s in elapsedSeconds.map { s.addingTimeInterval($0) } } }

    /// "Strength Training" over "Training" when the watch says which.
    var title: String { FitnessFormat.name(subSport ?? sport) }
    var symbol: String { FitnessFormat.symbol(sport: sport, subSport: subSport) }
    var color: Color { FitnessFormat.color(sport: sport) }
    var hasDistance: Bool { (distanceMeters ?? 0) > 50 }
}

/// GET /api/mobile/fitness/activity: one activity with its heart rate curve,
/// laps, strength sets and the watch's verdicts.
struct FitnessActivityDetail: Decodable {
    var heartRate: [[Double]]
    var activity: FitnessActivity
    var extras: ActivityExtras?
    /// The watch's recovery time after the session.
    var recoveryHours: Double?

    init(from decoder: Decoder) throws {
        activity = try FitnessActivity(from: decoder)
        struct Rest: Decodable { var heartRate: [[Double]]; var extras: ActivityExtras?; var recoveryHours: Double? }
        let rest = try Rest(from: decoder)
        heartRate = rest.heartRate
        extras = rest.extras
        recoveryHours = rest.recoveryHours
    }

    /// (seconds from start, bpm)
    var points: [(Double, Double)] { heartRate.compactMap { $0.count == 2 ? ($0[0], $0[1]) : nil } }
}

struct SleepNight: Decodable, Identifiable {
    var id: String
    var start: String
    var end: String
    var deepSeconds: Int?
    var lightSeconds: Int?
    var remSeconds: Int?
    var awakeSeconds: Int?
    /// The watch's sleep score when it gave one, else the hub's.
    var score: Int?
    /// The watch's own, alone. Missing from older hubs.
    var watchScore: Int?
    var levels: [[Double]]

    var startDate: Date? { ISO.parse(start) }
    var endDate: Date? { ISO.parse(end) }
    var asleepSeconds: Int { (deepSeconds ?? 0) + (lightSeconds ?? 0) + (remSeconds ?? 0) }

    enum Stage: Int, CaseIterable, Identifiable {
        case awake = 1, rem = 4, light = 2, deep = 3
        var id: Int { rawValue }
        var name: String {
            switch self {
            case .awake: "Awake"
            case .rem: "REM"
            case .light: "Light"
            case .deep: "Deep"
            }
        }
        var color: Color {
            switch self {
            case .awake: .pink
            case .rem: .cyan
            case .light: .blue
            case .deep: .indigo
            }
        }
    }

    func seconds(_ stage: Stage) -> Int {
        switch stage {
        case .awake: awakeSeconds ?? 0
        case .rem: remSeconds ?? 0
        case .light: lightSeconds ?? 0
        case .deep: deepSeconds ?? 0
        }
    }

    /// Stage intervals for the hypnogram.
    var segments: [(stage: Stage, start: Date, end: Date)] {
        guard let start = startDate, let end = endDate else { return [] }
        return levels.indices.compactMap { i in
            guard levels[i].count == 2, let stage = Stage(rawValue: Int(levels[i][1])) else { return nil }
            let from = start.addingTimeInterval(levels[i][0])
            let to = i + 1 < levels.count ? start.addingTimeInterval(levels[i + 1][0]) : end
            return to > from ? (stage, from, to) : nil
        }
    }
}

enum FitnessFormat {
    static func duration(_ seconds: Double?) -> String {
        guard let seconds else { return "–" }
        guard seconds >= 60 else { return "0m" }
        let minutes = Int(seconds / 60)
        return minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(minutes)m"
    }

    static func distance(_ meters: Double?) -> String {
        guard let meters, meters > 0 else { return "–" }
        return Measurement(value: meters, unit: UnitLength.meters).formatted(.measurement(width: .abbreviated, usage: .road))
    }

    /// Minutes per mile or km, for runs and walks.
    static func pace(_ speed: Double?) -> String? {
        guard let speed, speed > 0.3 else { return nil }
        let metric = Locale.current.measurementSystem == .metric
        let secondsPerUnit = (metric ? 1000 : 1609.344) / speed
        return String(format: "%d:%02d /%@", Int(secondsPerUnit) / 60, Int(secondsPerUnit) % 60, metric ? "km" : "mi")
    }

    static func name(_ raw: String) -> String {
        raw == "generic" ? "Activity" : raw.replacingOccurrences(of: "_", with: " ").capitalized
    }

    /// Tabler icon names (see TablerIcon); Tabler has run, walk, bike and swim glyphs.
    static func symbol(sport: String, subSport: String?) -> String {
        switch subSport {
        case "strength_training": return "barbell"
        case "yoga", "pilates": return "yoga"
        case "hiit": return "bolt"
        case "indoor_rowing": return "ship"
        default: break
        }
        switch sport {
        case "running": return "run"
        case "cycling", "e_biking": return "bike"
        case "swimming": return "swimming"
        case "walking": return "walk"
        case "hiking", "mountaineering": return "mountain"
        case "training", "fitness_equipment": return "barbell"
        case "rowing", "paddling", "kayaking": return "ship"
        case "tennis", "racket", "soccer", "basketball", "golf", "boxing", "mixed_martial_arts": return "target"
        case "alpine_skiing", "snowboarding", "cross_country_skiing": return "ski-jumping"
        default: return "activity"
        }
    }

    static func color(sport: String) -> Color {
        switch sport {
        case "running": .orange
        case "cycling", "e_biking": .green
        case "swimming": .cyan
        case "walking", "hiking": .mint
        case "training", "fitness_equipment": .purple
        default: .blue
        }
    }
}
