import Foundation

/// What the lock screen and widget show, built from the workout in progress,
/// and what their buttons do.
extension WorkoutStore {
    /// The next set to do: the first one not checked off, in order.
    var nextSet: (exercise: DraftExercise, set: DraftSet)? {
        for exercise in active?.exercises ?? [] {
            if let set = exercise.sets.first(where: { $0.completedAt == nil }) { return (exercise, set) }
        }
        return nil
    }

    /// The watch's last reading in this workout, if it's from the last 15 seconds.
    var recentBpm: Int? {
        guard let workout = active, let last = workout.heartRate.last, last.count == 2,
              Date.now.timeIntervalSince(workout.startedAt.addingTimeInterval(last[0])) < 15 else { return nil }
        return Int(last[1])
    }

    var activityState: WorkoutActivityState? {
        guard let workout = active else { return nil }
        let unit = workout.unit
        var state = WorkoutActivityState(exerciseName: nil, setLabel: "", target: "", isTimed: false,
                                         restEndsAt: nil, restTotal: restTotal,
                                         repsDone: workout.repProgress.done, repsTotal: workout.repProgress.total,
                                         volume: WorkoutFormat.volume(workout.volumeKg, unit: unit),
                                         setsDone: workout.completedSets.count, bpm: recentBpm)
        if let end = restEndsAt, end > .now { state.restEndsAt = end }
        guard let (exercise, set) = nextSet else { return state }
        state.exerciseName = exercise.name
        state.isTimed = exercise.isDuration
        if set.kind == .warmup {
            state.setLabel = "Warm-up set"
        } else {
            let working = exercise.sets.filter { $0.kind != .warmup }
            let index = (working.firstIndex { $0.id == set.id } ?? 0) + 1
            state.setLabel = "Set \(index) of \(working.count)"
        }
        let reps = set.repsText.isEmpty ? set.repsHint : set.repsText
        if exercise.isDuration {
            state.target = WorkoutFormat.timer(reps)
        } else {
            let weight = set.weightText.isEmpty ? set.weightHint : set.weightText
            switch (WorkoutFormat.number(weight), reps.isEmpty) {
            case let (w?, false) where w > 0: state.target = "\(weight) \(unit.rawValue) × \(reps)"
            case (_, false): state.target = "\(reps) reps"
            case let (w?, true) where w > 0: state.target = "\(weight) \(unit.rawValue)"
            default: state.target = ""
            }
        }
        return state
    }

    /// A button on the lock screen, Dynamic Island or widget.
    func handle(_ action: WorkoutAction) {
        switch action {
        case .completeSet:
            guard let (exercise, set) = nextSet else { return }
            toggle(exercise.id, set.id, liveHr: recentBpm)
        case .adjustRest(let seconds):
            adjustRest(by: TimeInterval(seconds))
        case .skipRest:
            skipRest()
        }
    }
}

#if os(iOS)
import ActivityKit
import WidgetKit

/// Starts, updates and ends the workout's Live Activity, and hands the same
/// state to the home screen widget.
@MainActor
final class WorkoutActivityController {
    static let shared = WorkoutActivityController()

    private var activity: Activity<WorkoutActivityAttributes>?
    private var lastState: WorkoutActivityState?
    private var lastPush = Date.distantPast

    private init() {
        // Picks the activity back up after the app was closed.
        activity = Activity<WorkoutActivityAttributes>.activities.first
    }

    func sync(_ store: WorkoutStore) {
        guard let workout = store.active, workout.endedAt == nil, let state = store.activityState else {
            end()
            return
        }
        guard state != lastState else { return }
        // Heart rate alone changes every few seconds: send it at most every 10 s.
        let heartOnly = lastState.map { var last = $0; last.bpm = state.bpm; return last == state } ?? false
        if heartOnly, Date.now.timeIntervalSince(lastPush) < 10 { return }
        lastState = state
        lastPush = .now

        WorkoutSnapshot.write(WorkoutSnapshot(name: workout.name, startedAt: workout.startedAt, state: state))
        if !heartOnly { WidgetCenter.shared.reloadTimelines(ofKind: WorkoutSnapshot.widgetKind) }

        // Stale when the rest runs out, so the lock screen flips back to the next set by itself.
        let content = ActivityContent(state: state, staleDate: state.restEndsAt)
        if let activity, activity.activityState == .active {
            Task { await activity.update(content) }
        } else if ActivityAuthorizationInfo().areActivitiesEnabled {
            activity = try? Activity.request(
                attributes: WorkoutActivityAttributes(name: workout.name, startedAt: workout.startedAt),
                content: content)
        }
    }

    private func end() {
        guard lastState != nil || activity != nil || !Activity<WorkoutActivityAttributes>.activities.isEmpty else { return }
        lastState = nil
        activity = nil
        WorkoutSnapshot.write(nil)
        WidgetCenter.shared.reloadTimelines(ofKind: WorkoutSnapshot.widgetKind)
        for running in Activity<WorkoutActivityAttributes>.activities {
            Task { await running.end(nil, dismissalPolicy: .immediate) }
        }
    }
}
#endif
