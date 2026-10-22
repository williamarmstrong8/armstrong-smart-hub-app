import AppIntents
import Foundation
#if canImport(ActivityKit)
import ActivityKit
#endif

// Shared by the app and the WorkoutWidgets extension: what's playing on the TV
// as the lock screen and Dynamic Island show it, and the buttons under it. The
// buttons run in the app (LiveActivityIntent), which talks to the hub.

/// What's playing, as of `asOf`. While playing, the progress and times tick on
/// their own from `startedAt`, so the activity needs no updates to keep time.
nonisolated struct TVActivityState: Codable, Hashable, Sendable {
    var title: String
    /// "S2 E5 · The Name" for an episode.
    var episodeLabel: String?
    var isPaused: Bool
    var position: TimeInterval
    var runtime: TimeInterval?
    var asOf: Date
    /// The poster's file name in the app group's container.
    var posterFile: String?

    /// When the title would have started had it played straight through to here.
    var startedAt: Date { asOf.addingTimeInterval(-position) }
    var endsAt: Date? { runtime.map { startedAt.addingTimeInterval($0) } }

    func position(at date: Date) -> TimeInterval {
        let p = isPaused ? position : position + date.timeIntervalSince(asOf)
        return min(max(0, p), runtime ?? .greatestFiniteMagnitude)
    }

    var fraction: Double {
        guard let runtime, runtime > 0 else { return 0 }
        return min(1, position(at: .now) / runtime)
    }
}

#if canImport(ActivityKit) && os(iOS)
nonisolated struct TVActivityAttributes: ActivityAttributes {
    typealias ContentState = TVActivityState
    /// "Living room TV".
    var tvName: String
}
#endif

// MARK: Buttons

nonisolated enum TVCommand: String, Sendable, CaseIterable {
    case back, playPause, forward, volumeDown, volumeUp, mute, stop

    /// How far the skip buttons jump.
    static let backSeconds: TimeInterval = 10
    static let forwardSeconds: TimeInterval = 30
}

/// The app sets `handler` at launch; the intent awaits it, so the app stays
/// awake until the hub has answered. In the extension it stays nil, which is
/// fine: LiveActivityIntent runs in the app's process.
@MainActor
enum TVActions {
    static var handler: ((TVCommand) async -> Void)?

    static func run(_ command: TVCommand) async {
        await handler?(command)
    }
}

#if os(iOS)
nonisolated struct TVControlIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Control the TV"
    static let isDiscoverable = false

    @Parameter(title: "Command") var command: String

    init() {}
    init(_ command: TVCommand) { self.command = command.rawValue }

    func perform() async throws -> some IntentResult {
        if let c = TVCommand(rawValue: command) { await TVActions.run(c) }
        return .result()
    }
}
#endif
