import SwiftUI

/// The hub's own physiology numbers (lib/fitness/physiology.ts in the hub):
/// Training Readiness, Body Battery, stress, VO2max, load and HRV status,
/// worked out from the watch's raw data rather than Garmin's firmware.
struct FitnessMetrics: Decodable {
    /// Max and resting heart rate the models used. Missing from older hubs.
    var profile: Profile?
    var readiness: Readiness
    var bodyBattery: BodyBattery?
    var stress: Stress?
    var vo2max: Vo2max?
    var load: Load
    var hrv: Hrv
    var vitals: Vitals
    /// "watch" or "hub" for readiness, recovery, vo2max, bodyBattery and stress. Missing from older hubs.
    var sources: [String: String]?

    func fromWatch(_ key: String) -> Bool { sources?[key] == "watch" }

    struct Profile: Decodable { var maxHr: Int; var restingHr: Int }

    struct Readiness: Decodable {
        var score: Int?
        var level: String?
        /// The hub's own score, when the watch's replaced it.
        var hubScore: Int?
        var factors: [Factor]

        struct Factor: Decodable, Identifiable {
            var key: String
            var label: String
            var score: Int?
            var weight: Double
            var detail: String
            var id: String { key }
        }
    }

    struct BodyBattery: Decodable {
        var current: Int
        var charged: Int
        var drained: Int
        var series: [Point]
        struct Point: Decodable { var at: String; var value: Int }
    }

    struct Stress: Decodable {
        var average: Int?
        var restMinutes: Int
        var series: [Point]
        struct Point: Decodable { var at: String; var value: Int?; var kind: String }
    }

    struct Vo2max: Decodable {
        var value: Double
        var asOf: String
        var watch: Double?
        var hub: Double?
        var runs: [Run]
        struct Run: Decodable { var at: String; var value: Double; var watch: Double? }
    }

    struct Load: Decodable {
        var acute: Int
        var chronic: Int
        var ratio: Double?
        var recoveryHours: Int
        var status: String?
    }

    struct Hrv: Decodable {
        var lastNight: Double?
        var weekly: Double?
        var baseline: Range?
        var status: String
        struct Range: Decodable { var low: Double; var high: Double }
    }

    struct Vitals: Decodable {
        var spo2: Double?
        var respiration: Double?
        var skinTemp: Double?
        var isEmpty: Bool { spo2 == nil && respiration == nil && skinTemp == nil }
    }
}

enum MetricColor {
    /// Garmin's readiness bands: prime 95+, high 75-94, moderate 50-74, low 25-49, poor.
    static func readiness(_ score: Int?) -> Color {
        guard let score else { return .secondary }
        return score >= 75 ? .green : score >= 50 ? .yellow : score >= 25 ? .orange : .red
    }

    /// Stress bands: 0-25 rest, 26-50 low, 51-75 medium, 76-100 high.
    static func stress(_ value: Int) -> Color {
        value <= 25 ? .blue : value <= 50 ? .yellow : value <= 75 ? .orange : .red
    }
}
