import SwiftUI

/// The numbers the watch's firmware works out itself (Garmin's Firstbeat
/// models), as the hub decodes them from the metrics, sleep and activity files
/// (lib/fitness/watch-snapshot.ts in the hub). Every field is optional: older
/// hubs don't send the block, and the watch only writes what it has measured.
struct FitnessWatch: Decodable {
    var readiness: Readiness?
    var recovery: Recovery?
    var endurance: Endurance?
    var hill: Hill?
    var races: Races?
    var focus: Focus?
    var sleepNeed: SleepNeed?
    var sleep: Sleep?
    var vo2max: Vo2?
    var lactateThreshold: Threshold?

    struct Point: Decodable, Identifiable {
        var at: String
        var value: Double
        var id: String { at }
        var date: Date? { ISO.parse(at) }
    }

    struct Readiness: Decodable {
        var at: String
        var score: Int
        var level: String?
        var sleepScore: Int?
        var weeklyHrv: Double?
        var history: [Point]
    }

    struct Recovery: Decodable { var at: String; var totalHours: Double; var remainingHours: Double }

    struct Endurance: Decodable {
        var at: String
        var score: Int
        var level: String
        var nextLevel: Next?
        var gauge: Gauge?
        var bounds: [String: Double?]
        var history: [Point]
        struct Next: Decodable { var name: String; var at: Double }
        struct Gauge: Decodable { var low: Double; var high: Double }
    }

    struct Hill: Decodable { var at: String; var score: Int; var strength: Int?; var endurance: Int? }

    struct Races: Decodable {
        var at: String
        var fiveK: Int?
        var tenK: Int?
        var half: Int?
        var marathon: Int?
        var history: [Point]
    }

    struct Focus: Decodable {
        var at: String
        var low: Double
        var high: Double
        var anaerobic: Double
        var targets: Targets
        struct Targets: Decodable { var low: Band?; var high: Band?; var anaerobic: Band? }
        struct Band: Decodable { var min: Double; var max: Double }
    }

    struct SleepNeed: Decodable { var at: String; var hours: Double; var usualHours: Double? }

    struct Sleep: Decodable {
        var at: String
        var overall: Int?
        var parts: Parts
        var awakenings: Int?
        var avgStress: Double?
        var lowestHr: Int?
        var batteryGained: Int?
        var history: [Point]
        /// The watch's own averages over the night. Missing from older hubs.
        var overnight: Overnight?
        struct Overnight: Decodable { var hrv: Double?; var heartRate: Double?; var respiration: Double?; var spo2: Double? }

        struct Parts: Decodable {
            var duration: Int?
            var quality: Int?
            var deep: Int?
            var light: Int?
            var rem: Int?
            var recovery: Int?
            var restlessness: Int?
            var interruptions: Int?

            /// In the order Garmin Connect lists them.
            var rows: [(String, Int)] {
                [("Duration", duration), ("Quality", quality), ("Recovery", recovery), ("Deep", deep), ("Light", light),
                 ("REM", rem), ("Restlessness", restlessness), ("Interruptions", interruptions)]
                    .compactMap { row in row.1.map { (row.0, $0) } }
            }
        }
    }

    struct Vo2: Decodable { var at: String; var value: Double; var history: [Point] }

    struct Threshold: Decodable {
        var at: String
        var hr: Double
        /// m/s
        var speed: Double?
    }
}

/// What an activity's file says beyond the summary: laps, strength sets, best
/// efforts and the watch's own verdicts (lib/fitness/watch-metrics.ts).
struct ActivityExtras: Decodable {
    var primaryBenefit: String?
    var performanceCondition: Int?
    var endingBodyBattery: Int?
    var lactateThresholdHr: Int?
    var lactateThresholdSpeed: Double?
    var sets: [StrengthSet]
    var laps: [Lap]
    var bestEfforts: [BestEffort]

    struct StrengthSet: Decodable, Identifiable {
        var at: String
        var seconds: Double?
        var reps: Int?
        var weightKg: Double?
        var exercise: String?
        var id: String { at }
    }

    struct Lap: Decodable, Identifiable {
        var start: String
        var seconds: Double?
        var meters: Double?
        var avgSpeed: Double?
        var avgHr: Int?
        var maxHr: Int?
        var ascent: Double?
        var id: String { start }
    }

    struct BestEffort: Decodable, Identifiable {
        var meters: Double
        var seconds: Double
        var personalRecord: Bool
        var id: Double { meters }
    }
}

enum WatchFormat {
    /// 23:08, or 1:54:14 past an hour.
    static func raceTime(_ seconds: Int) -> String {
        seconds >= 3600 ? String(format: "%d:%02d:%02d", seconds / 3600, seconds % 3600 / 60, seconds % 60)
            : String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    static func hours(_ value: Double) -> String {
        let minutes = Int((value * 60).rounded())
        return minutes % 60 == 0 ? "\(minutes / 60)h" : "\(minutes / 60)h \(minutes % 60)m"
    }

    /// "Bench press" from "bench_press".
    static func name(_ raw: String) -> String {
        let text = raw.replacingOccurrences(of: "_", with: " ")
        return text.prefix(1).uppercased() + text.dropFirst()
    }

    static func weight(_ kg: Double) -> String {
        let metric = Locale.current.measurementSystem == .metric
        return metric ? (kg >= 1000 ? "\(Int(kg.rounded()).formatted()) kg" : String(format: "%.1f kg", kg)) : "\(Int((kg * 2.20462).rounded()).formatted()) lb"
    }

    /// Garmin's readiness colors.
    static func readinessColor(_ level: String?) -> Color {
        switch level {
        case "prime": .purple
        case "high": .green
        case "moderate": .yellow
        case "low": .orange
        case "poor": .red
        default: .gray
        }
    }

    static func benefitColor(_ benefit: String?) -> Color {
        switch benefit {
        case "recovery": .gray
        case "base": .green
        case "tempo": .orange
        case "threshold": .orange
        case "vo2max": .red
        case "anaerobic", "sprint": .purple
        default: .secondary
        }
    }
}

/// A small chip saying where a number came from.
struct SourceBadge: View {
    var watch: Bool

    var body: some View {
        HStack(spacing: 4) {
            TablerIcon(name: watch ? "device-watch" : "activity", size: 11)
            Text(watch ? "From your watch" : "Hub estimate").font(.caption2.weight(.semibold))
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Capsule().fill(Color.primary.opacity(0.06)))
    }
}
