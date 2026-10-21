import AppIntents
import Foundation
#if canImport(ActivityKit)
import ActivityKit
#endif

// Shared by the app and the WorkoutWidgets extension: what the Live Activity
// and the home screen widget show, and the buttons on them. The buttons run in
// the app (LiveActivityIntent), which owns the workout.

/// The workout in progress as the lock screen, Dynamic Island and widget show it.
nonisolated struct WorkoutActivityState: Codable, Hashable, Sendable {
    /// The next set to do, or nil once every set is checked off.
    var exerciseName: String?
    /// "Set 2 of 4", "Warm-up set".
    var setLabel: String
    /// "135 lb × 8", "1:00", or "" with nothing to go on.
    var target: String
    var isTimed: Bool
    var restEndsAt: Date?
    var restTotal: TimeInterval
    var repsDone: Int
    var repsTotal: Int
    /// "4,250 lb".
    var volume: String
    var setsDone: Int
    var bpm: Int?

    var isResting: Bool { (restEndsAt ?? .distantPast) > .now }
    var repFraction: Double { repsTotal > 0 ? min(1, Double(repsDone) / Double(repsTotal)) : 0 }
}

#if canImport(ActivityKit) && os(iOS)
nonisolated struct WorkoutActivityAttributes: ActivityAttributes {
    typealias ContentState = WorkoutActivityState
    var name: String
    var startedAt: Date
}
#endif

/// The latest state, written by the app for the home screen widget to read.
nonisolated struct WorkoutSnapshot: Codable, Sendable {
    var name: String
    var startedAt: Date
    var state: WorkoutActivityState

    static let appGroup = "group.com.paularmstrong.ArmstrongSmartHubApp"
    static let widgetKind = "WorkoutWidget"
    private static let key = "workout.snapshot"

    private static var defaults: UserDefaults? { UserDefaults(suiteName: appGroup) }

    static func read() -> WorkoutSnapshot? {
        guard let data = defaults?.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(WorkoutSnapshot.self, from: data)
    }

    static func write(_ snapshot: WorkoutSnapshot?) {
        if let snapshot, let data = try? JSONEncoder().encode(snapshot) {
            defaults?.set(data, forKey: key)
        } else {
            defaults?.removeObject(forKey: key)
        }
    }
}

// MARK: Buttons

/// What a button on the lock screen or widget asks the app to do.
nonisolated enum WorkoutAction: Sendable {
    case completeSet
    case adjustRest(seconds: Int)
    case skipRest
}

/// The app sets `handler` at launch; the intents call it. In the extension it
/// stays nil, which is fine: LiveActivityIntent runs in the app's process.
@MainActor
enum WorkoutActions {
    static var handler: ((WorkoutAction) -> Void)?

    static func run(_ action: WorkoutAction) {
        handler?(action)
    }
}

#if os(iOS)
nonisolated struct CompleteSetIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Complete set"
    static let isDiscoverable = false

    init() {}

    func perform() async throws -> some IntentResult {
        await WorkoutActions.run(.completeSet)
        return .result()
    }
}

nonisolated struct AdjustRestIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Change rest"
    static let isDiscoverable = false

    @Parameter(title: "Seconds") var seconds: Int

    init() {}
    init(seconds: Int) { self.seconds = seconds }

    func perform() async throws -> some IntentResult {
        await WorkoutActions.run(.adjustRest(seconds: seconds))
        return .result()
    }
}

nonisolated struct SkipRestIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Skip rest"
    static let isDiscoverable = false

    init() {}

    func perform() async throws -> some IntentResult {
        await WorkoutActions.run(.skipRest)
        return .result()
    }
}
#endif
