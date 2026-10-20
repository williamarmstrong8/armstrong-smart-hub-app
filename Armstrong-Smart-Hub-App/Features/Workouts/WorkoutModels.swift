import Foundation

// MARK: Hub (lib/workouts on the hub)

/// GET /api/mobile/workouts
struct WorkoutsHome: Decodable {
    var exercises: [Exercise]
    var routines: [Routine]
    var workouts: [WorkoutSummary]
    /// The sets from the last time each exercise was done, by exercise id.
    var previous: [String: [PreviousSet]]
    /// Best estimated one-rep max per exercise.
    var bests: [String: Best]

    struct PreviousSet: Decodable {
        var kind: String
        var weightKg: Double?
        var reps: Int?
        var durationSeconds: Double?
    }

    struct Best: Decodable {
        var e1rmKg: Double?
        var weightKg: Double?
        var reps: Int?
    }
}

struct Exercise: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    var muscle: String
    var equipment: String
    /// weight_reps, reps or duration.
    var kind: String
    var custom: Bool

    var isDuration: Bool { kind == "duration" }
    var muscleName: String { WorkoutFormat.label(muscle) }
}

struct Routine: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    var position: Int
    var exercises: [Item]

    struct Item: Codable, Hashable {
        var exerciseId: String
        var name: String
        var restSeconds: Int?
        var superset: Int?
        var sets: [Target]
    }

    struct Target: Codable, Hashable {
        var kind: String
        var weightKg: Double?
        var reps: Int?
    }
}

struct WorkoutSummary: Decodable, Identifiable, Hashable {
    var id: String
    var name: String
    var startedAt: String
    var endedAt: String
    var exercises: [String]
    var sets: Int
    var volumeKg: Double
    var avgHr: Int?
    var maxHr: Int?

    var start: Date? { ISO.parse(startedAt) }
    var duration: TimeInterval? {
        guard let a = ISO.parse(startedAt), let b = ISO.parse(endedAt) else { return nil }
        return b.timeIntervalSince(a)
    }
}

/// GET /api/mobile/workouts/detail: a workout with heart rate mapped onto every set.
struct WorkoutDetail: Decodable, Identifiable {
    var id: String
    var name: String
    var routineId: String?
    var startedAt: String
    var endedAt: String
    var notes: String?
    var volumeKg: Double
    var avgHr: Int?
    var maxHr: Int?
    /// "activity" when it came from the watch's own recording, "live" from the phone's stream.
    var hrSource: String?
    var activityId: String?
    /// [seconds from start, bpm]
    var heartRate: [[Double]]
    var exercises: [Group]

    struct Group: Decodable, Identifiable {
        var exerciseId: String
        var name: String
        var superset: Int?
        var sets: [LoggedSet]
        var id: String { exerciseId + name }
    }

    struct LoggedSet: Decodable {
        var kind: String
        var weightKg: Double?
        var reps: Int?
        var durationSeconds: Double?
        var rpe: Double?
        var completedAt: String?
        var startedAt: String?
        var liveHr: Int?
        var avgHr: Int?
        var peakHr: Int?
        var endHr: Int?
        /// How far heart rate fell from the peak a minute after the set.
        var recoveryBpm: Int?
        var restSeconds: Int?
        var e1rmKg: Double?
        var pr: Bool

        var completed: Date? { completedAt.flatMap { ISO.parse($0) } }
    }

    var start: Date? { ISO.parse(startedAt) }
    var end: Date? { ISO.parse(endedAt) }
    var points: [(Double, Double)] { heartRate.compactMap { $0.count == 2 ? ($0[0], $0[1]) : nil } }
}

// MARK: The workout being logged (kept on the phone until it's uploaded)

enum SetKind: String, Codable, CaseIterable, Identifiable {
    case warmup, normal, drop, failure
    var id: String { rawValue }
    var name: String {
        switch self {
        case .warmup: "Warm-up"
        case .normal: "Working"
        case .drop: "Drop set"
        case .failure: "To failure"
        }
    }
    /// What the set column shows instead of a number.
    var badge: String? {
        switch self {
        case .warmup: "W"
        case .drop: "D"
        case .failure: "F"
        case .normal: nil
        }
    }
}

struct ActiveWorkout: Codable, Identifiable {
    var id = UUID()
    var name: String
    var routineId: String?
    var startedAt = Date.now
    var notes = ""
    /// The unit weights were typed in; they're sent to the hub in kilograms.
    var unit: WeightUnit
    var exercises: [DraftExercise] = []
    /// Live readings from the watch: [seconds from start, bpm].
    var heartRate: [[Double]] = []
    /// When Finish was tapped, for uploads that wait until the hub is reachable.
    var endedAt: Date?

    var completedSets: [DraftSet] { exercises.flatMap { $0.sets.filter { $0.completedAt != nil } } }
    var volumeKg: Double {
        exercises.reduce(0) { sum, exercise in
            sum + exercise.sets.reduce(0) { s, set in
                guard set.completedAt != nil, set.kind != .warmup else { return s }
                return s + (set.weight(unit) ?? 0) * Double(set.repCount ?? 0)
            }
        }
    }
}

struct DraftExercise: Codable, Identifiable {
    var id = UUID()
    var exerciseId: String
    var name: String
    var isDuration = false
    var superset: Int?
    var restSeconds: Int?
    var sets: [DraftSet] = []
}

struct DraftSet: Codable, Identifiable {
    var id = UUID()
    var kind: SetKind = .normal
    /// As typed, in the workout's unit, so a half-typed "62." survives redraws.
    var weightText = ""
    var repsText = ""
    /// What the fields show greyed out: the routine's target or last time's numbers.
    var weightHint = ""
    var repsHint = ""
    var completedAt: Date?
    /// The watch's live reading when the set was checked off.
    var liveHr: Int?
    var isPR = false

    /// Weight in kilograms.
    func weight(_ unit: WeightUnit) -> Double? {
        WorkoutFormat.number(weightText).map { unit.toKg($0) }
    }
    var repCount: Int? { WorkoutFormat.number(repsText).map { Int($0.rounded()) } }
}

enum WeightUnit: String, Codable, CaseIterable, Identifiable {
    case kg, lb
    var id: String { rawValue }
    static let poundsPerKg = 2.2046226218

    static var localDefault: WeightUnit { Locale.current.measurementSystem == .metric ? .kg : .lb }

    func toKg(_ value: Double) -> Double { self == .kg ? value : value / Self.poundsPerKg }
    func fromKg(_ kg: Double) -> Double { self == .kg ? kg : kg * Self.poundsPerKg }

    /// "135" or "62.5": rounded to the nearest 0.5 so pounds stored as kilograms come back whole.
    func text(_ kg: Double?) -> String {
        guard let kg else { return "" }
        let value = (fromKg(kg) * 2).rounded() / 2
        return value == value.rounded() ? String(Int(value)) : String(format: "%.1f", value)
    }
}

/// POST /api/mobile/workouts
struct WorkoutUpload: Encodable {
    var id: String
    var name: String
    var routineId: String?
    var startedAt: String
    var endedAt: String
    var notes: String?
    var heartRate: [[Double]]
    var exercises: [Item]

    struct Item: Encodable {
        var exerciseId: String
        var name: String
        var superset: Int?
        var sets: [Entry]
    }

    struct Entry: Encodable {
        var kind: String
        var weightKg: Double?
        var reps: Int?
        var durationSeconds: Double?
        var completedAt: String?
        var liveHr: Int?
    }

    init(_ workout: ActiveWorkout) {
        let iso = ISO8601DateFormatter()
        id = workout.id.uuidString.lowercased()
        name = workout.name
        routineId = workout.routineId
        startedAt = iso.string(from: workout.startedAt)
        endedAt = iso.string(from: max(workout.endedAt ?? .now, workout.startedAt))
        notes = workout.notes.isEmpty ? nil : workout.notes
        heartRate = workout.heartRate
        exercises = workout.exercises.compactMap { exercise in
            let sets = exercise.sets.filter { $0.completedAt != nil }
            guard !sets.isEmpty else { return nil }
            return Item(exerciseId: exercise.exerciseId, name: exercise.name, superset: exercise.superset, sets: sets.map { set in
                // For timed exercises the reps field holds seconds.
                Entry(kind: set.kind.rawValue,
                      weightKg: exercise.isDuration ? nil : set.weight(workout.unit).map { ($0 * 1000).rounded() / 1000 },
                      reps: exercise.isDuration ? nil : set.repCount,
                      durationSeconds: exercise.isDuration ? WorkoutFormat.number(set.repsText) : nil,
                      completedAt: set.completedAt.map { iso.string(from: $0) },
                      liveHr: set.liveHr)
            })
        }
    }
}

/// POST /api/mobile/workouts/routines
struct RoutineUpload: Encodable {
    var id: String
    var name: String
    var position: Int
    var exercises: [Routine.Item]
}

enum WorkoutFormat {
    static func label(_ raw: String) -> String { raw.replacingOccurrences(of: "_", with: " ").capitalized }

    /// Accepts "62.5" and "62,5".
    static func number(_ text: String) -> Double? {
        let cleaned = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        guard let value = Double(cleaned), value >= 0, value.isFinite else { return nil }
        return value
    }

    static func volume(_ kg: Double, unit: WeightUnit) -> String {
        let value = unit.fromKg(kg)
        return "\(value.formatted(.number.precision(.fractionLength(0)))) \(unit.rawValue)"
    }

    static func clock(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }

    static func estimatedOneRepMax(kg: Double?, reps: Int?) -> Double? {
        guard let kg, kg > 0, let reps, (1...12).contains(reps) else { return nil }
        return reps == 1 ? kg : kg * (1 + Double(reps) / 30)
    }
}
