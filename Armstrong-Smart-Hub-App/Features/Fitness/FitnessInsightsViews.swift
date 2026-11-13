import SwiftUI

/// The hub's Whoop, Oura, Garmin and Apple style scores
/// (lib/fitness/insights.ts and insight-metrics.ts in the hub): strain,
/// recovery, sleep need, resilience, training effect, load focus, threshold,
/// race times, ages and vitals. Every score that needs a baseline says how
/// many nights or days it still needs instead of guessing.
struct FitnessInsights: Decodable {
    var strain: Strain?
    var recovery: Recovery?
    var sleep: Sleep
    var stress: Stress
    var training: Training
    var age: Age?
    var vitals: Vitals?
    /// A readiness score laid out by contributor, and the health monitor (lib/fitness/scores.ts). Missing from older hubs.
    var readiness: ContributorReadiness?
    var health: Health?

    /// A score that is still learning a baseline carries `have` and `need`; once `ready`, its own fields.
    struct ContributorReadiness: Decodable {
        var score: Int?
        var level: String?
        var contributors: [Contributor]
        struct Contributor: Decodable, Identifiable {
            var key: String
            var label: String
            var score: Int?
            var weight: Double
            var detail: String
            var id: String { key }
        }
    }

    struct Health: Decodable {
        var monitor: Monitor?
        var hrvStability: Stability?

        struct Monitor: Decodable {
            var status: String
            var have: Int?
            var need: Int?
            var level: String?
            var points: Int?
            var signs: [Sign]?
            struct Sign: Decodable, Identifiable {
                var key: String
                var label: String
                var value: Double
                var usual: Double
                /// Standard deviations toward strain: positive is worse.
                var z: Double
                var flagged: Bool
                var id: String { key }
            }
        }
        struct Stability: Decodable { var status: String; var have: Int?; var need: Int?; var cv: Double?; var level: String?; var nights: Int? }
    }

    struct Strain: Decodable {
        var today: Double?
        var level: String?
        var week: [Day]
        /// How much strain today can take, from this morning's recovery. Missing from older hubs.
        var target: Target?
        struct Day: Decodable { var day: String; var strain: Double? }
        struct Target: Decodable { var low: Double; var high: Double; var state: String?; var advice: String }
    }

    /// Either `ready` with a score and zone, or `calibrating` with how many nights it has.
    struct Recovery: Decodable {
        var status: String
        var have: Int?
        var need: Int?
        var score: Int?
        var zone: String?
        /// What moved it: each input as standard deviations from your baseline (positive helps).
        var parts: [Part]?
        struct Part: Decodable, Identifiable { var key: String; var weight: Double; var z: Double; var id: String { key } }
    }

    struct Sleep: Decodable {
        var need: Need
        var lastNight: LastNight?
        var bedtimeSpread: Int?
        /// Missing from older hubs.
        var debt: Debt?
        var chronotype: Chronotype?
        var regularity: Regularity?
        var naps: [Nap]?

        struct Debt: Decodable { var status: String; var have: Int?; var need: Int?; var hours: Double?; var level: String?; var nights: Int?; var averageHours: Double? }
        struct Chronotype: Decodable {
            var status: String
            var have: Int?
            var need: Int?
            var type: String?
            /// Minutes after local midnight (negative before it).
            var midpoint: Int?
            var bedtime: Int?
            var wake: Int?
            var socialJetlagMinutes: Int?
        }
        struct Regularity: Decodable { var status: String; var have: Int?; var need: Int?; var score: Int?; var level: String?; var days: Int? }
        struct Nap: Decodable, Identifiable {
            var start: String
            var end: String
            var minutes: Int
            var id: String { start }
        }
        struct StageShare: Decodable, Identifiable {
            var key: String
            var minutes: Int
            var share: Int
            var low: Int
            var high: Int
            var status: String
            var id: String { key }
        }
        struct Breathing: Decodable {
            /// Falls in blood oxygen an hour.
            var index: Double
            var events: Int
            var hours: Double
            var level: String
            var average: Double
            var lowest: Double
            var minutesBelow90: Int
        }

        struct Need: Decodable { var hours: Double; var baseline: Double; var debt: Double; var strain: Double; var naps: Double }
        struct LastNight: Decodable {
            var asleepHours: Double
            var needed: Double?
            var performance: Int?
            var score: Int?
            var interruptions: Int
            var recoveryIndex: RecoveryIndex?
            var apple: AppleScore
            /// Share of the night asleep, percent; each stage against its healthy range; overnight breathing. Missing from older hubs.
            var efficiency: Int?
            var stages: [StageShare]?
            var breathing: Breathing?
        }
        struct RecoveryIndex: Decodable { var score: Int; var lowestHr: Int; var lowestAt: Double; var share: Double }
        struct AppleScore: Decodable { var score: Int; var duration: Int; var consistency: Int; var interruptions: Int }
    }

    struct Stress: Decodable {
        var now: Int?
        var today: Day
        var resilience: Resilience
        var bodyBattery: Battery?

        struct Day: Decodable { var stressedMinutes: Int; var restoredMinutes: Int; var summary: String? }
        struct Resilience: Decodable { var status: String; var have: Int?; var need: Int?; var level: String?; var daytime: Int?; var overnight: Int? }
        struct Battery: Decodable {
            var current: Int
            var high: Int
            var low: Int
            var series: [Point]
            struct Point: Decodable { var at: String; var value: Int }
        }
    }

    struct Training: Decodable {
        var lastWorkout: Workout?
        var focus: Focus
        var lactateThreshold: Threshold?
        var races: Races?
        var endurance: Endurance?
        var hill: Hill?
        var performanceCondition: Condition?
        var effortLoad: EffortLoad
        /// Fitness / fatigue / form, monotony, training status, zones and cardio recovery. Missing from older hubs.
        var form: Form?
        var monotony: Monotony?
        var status: Status?
        var zones: Zones?
        var zoneMinutes: ZoneMinutes?
        var cardioRecovery: CardioRecovery?

        struct Form: Decodable {
            var fitness: Double
            var fatigue: Double
            var form: Double
            var label: String
            /// Fitness gained over the last week.
            var ramp: Double?
            var series: [Day]
            struct Day: Decodable { var day: String; var fitness: Double; var fatigue: Double; var form: Double }
        }
        struct Monotony: Decodable { var monotony: Double; var strain: Int; var weekLoad: Int; var level: String }
        struct Status: Decodable { var key: String; var label: String; var detail: String; var vo2maxTrend: Double? }
        struct Zones: Decodable {
            var week: Distribution
            var month: Distribution
            struct Distribution: Decodable { var minutes: [Int]; var low: Int?; var moderate: Int?; var high: Int?; var pattern: String? }
        }
        struct ZoneMinutes: Decodable {
            var today: Int
            var week: Int
            var goal: Int
            var days: [Day]
            struct Day: Decodable { var day: String; var minutes: Int; var fatBurn: Int; var cardio: Int; var peak: Int }
        }
        struct CardioRecovery: Decodable { var latest: Double; var at: String; var average: Int; var sessions: Int; var level: String }

        struct Workout: Decodable {
            var sport: String
            var at: String
            var minutes: Int
            var aerobic: Double?
            var aerobicLabel: String?
            var watchAerobic: Double?
            var anaerobic: Double?
            var anaerobicLabel: String?
            var watchAnaerobic: Double?
            var effort: Int?
            var strain: Double?
            var strainLevel: String?
        }
        struct Focus: Decodable { var low: Int; var high: Int; var anaerobic: Int; var status: String? }
        struct Threshold: Decodable { var heartRate: Int; var measured: Bool; var speed: Double?; var percentOfMax: Int }
        struct Races: Decodable {
            var fiveK: Int
            var tenK: Int
            var half: Int
            var marathon: Int
            enum CodingKeys: String, CodingKey { case fiveK = "5k", tenK = "10k", half, marathon }
        }
        struct Endurance: Decodable { var score: Int; var tier: String; var longLoad: Int }
        struct Hill: Decodable { var score: Int; var strength: Int; var endurance: Int; var climbed: Int }
        struct Condition: Decodable { var value: Int?; var at: String }
        struct EffortLoad: Decodable { var week: Int; var month: Int; var trend: String? }
    }

    struct Age: Decodable {
        var age: Int
        var cardioFitness: CardioFitness?
        var hubAge: HubAge?
        var paceOfAging: Double?

        struct CardioFitness: Decodable { var percentile: Int; var level: String; var lowFitness: Bool }
        struct HubAge: Decodable {
            var age: Double
            var fitnessAge: Int
            var difference: Double
            var parts: [Part]
            struct Part: Decodable, Identifiable { var key: String; var label: String; var years: Double; var id: String { key } }
        }
    }

    struct Vitals: Decodable {
        var readings: [Reading]
        var outliers: Int
        var calibrating: Bool
        struct Reading: Decodable, Identifiable {
            var key: String
            var value: Double?
            var low: Double?
            var high: Double?
            var outlier: Bool
            var have: Int
            var id: String { key }
        }
    }
}

/// "YYYY-MM-DD" as local midnight.
enum DateOnly {
    static func parse(_ day: String) -> Date? {
        let parts = day.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return Calendar.current.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }
}
