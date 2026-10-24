import Foundation
import WidgetKit

/// Hands the widgets the app's latest copy of each thing they show, and reloads
/// only the ones whose snapshot actually changed.
@MainActor
enum WidgetSync {
    // MARK: Lights

    static func lights(_ state: HomeState) {
        guard let entities = state.entities else { return }
        let all = entities.filter { $0.control == .light }
            .map { LightItem(id: $0.id, name: $0.name, room: $0.room, state: $0.state, brightness: $0.brightness) }
        let next = LightsSnapshot(lights: all, shown: LightsSnapshot.shownIDs(all, visible: state.visible))
        let previous = LightsSnapshot.read()
        // A widget button was just pressed: its copy is newer than this poll.
        if previous?.recentlyTouched == true { return }
        guard previous?.lights != next.lights || previous?.shown != next.shown else { return }
        next.write()
        WidgetCenter.shared.reloadTimelines(ofKind: WidgetKind.lights)
        ControlCenter.shared.reloadControls(ofKind: WidgetKind.lightControl)
    }

    // MARK: Habits

    static func habits(_ store: HabitsStore) {
        let next = HabitsSnapshot.build(
            habits: store.habits.sorted { $0.position < $1.position }.map { ($0.id, $0.name, $0.color, $0.icon) },
            done: Set(store.doneKeys), historyDays: store.historyDays)
        guard HabitsSnapshot.read().map({ $0.day != next.day || $0.habits != next.habits }) ?? true else { return }
        next.write()
        WidgetCenter.shared.reloadTimelines(ofKind: WidgetKind.habits)
    }

    // MARK: Fitness

    /// Today from the Fitness page's data, with the watch's live readings on top.
    static func fitness(_ store: FitnessStore) {
        let today = store.today
        let live = store.live
        let heart = live.latest(.heartRate, maxAge: 1800)
        let glance = FitnessGlance(
            day: localDay(),
            steps: today?.steps,
            stepGoal: today?.stepGoal,
            bodyBattery: store.currentBodyBattery ?? store.series(.bodyBattery).last?.value,
            stress: store.currentStress,
            restingHr: store.restingHr,
            heartRate: heart?.value,
            heartRateAt: heart?.at,
            sleepSeconds: store.lastNight.map(\.asleepSeconds),
            sleepScore: store.lastNight.flatMap { $0.watchScore ?? $0.score },
            readiness: store.snapshot?.metrics?.readiness.score,
            readinessLevel: store.snapshot?.metrics?.readiness.level,
            intensityMinutes: today?.intensityMinutes,
            updatedAt: .now)
        write(glance)
    }

    /// A live reading from the watch. Body Battery and stress move slowly, so these reload the
    /// widgets at most every few minutes (the system budgets reloads anyway).
    static func live(_ kind: LiveStore.Kind, _ value: Int, at date: Date) {
        guard var glance = FitnessGlance.read() else { return }
        switch kind {
        case .bodyBattery: glance.bodyBattery = value
        case .stress: glance.stress = value
        case .heartRate:
            glance.heartRate = value
            glance.heartRateAt = date
        }
        glance.updatedAt = .now
        glance.write()
        if Date.now.timeIntervalSince(lastFitnessReload) > 5 * 60 { reloadFitness() }
    }

    private static var lastFitnessReload = Date.distantPast

    private static func write(_ glance: FitnessGlance) {
        glance.write()
        reloadFitness()
    }

    private static func reloadFitness() {
        lastFitnessReload = .now
        for kind in [WidgetKind.fitness, WidgetKind.fitness + ".bodyBattery", WidgetKind.fitness + ".steps"] {
            WidgetCenter.shared.reloadTimelines(ofKind: kind)
        }
    }

    // MARK: Brick

    #if os(iOS)
    static func brick(_ store: BrickStore) {
        let now = Date()
        let startOfDay = Calendar.current.startOfDay(for: now)
        let finished = store.sessions.reduce(0.0) { total, s in
            guard let end = s.end, end > startOfDay else { return total }
            return total + end.timeIntervalSince(max(s.start, startOfDay))
        }
        let next = BrickGlance(
            isBlocking: store.isBlocking,
            profileName: store.blockingProfile?.name,
            startedAt: store.current?.start,
            endsAt: store.endsAt,
            strict: store.blockingProfile?.strict ?? true,
            // Whole minutes, so the 15-second check doesn't rewrite it every time.
            finishedTodaySeconds: (finished / 60).rounded(.down) * 60,
            day: localDay(now),
            hasTag: store.hasTag)
        guard BrickGlance.read() != next else { return }
        next.write()
        WidgetCenter.shared.reloadTimelines(ofKind: WidgetKind.brick)
    }
    #endif

    // MARK: Sign in and out

    static func reloadAll() {
        WidgetCenter.shared.reloadAllTimelines()
        ControlCenter.shared.reloadAllControls()
    }

    /// Nothing from this account stays on the home screen.
    static func signedOut() {
        SharedStore.write(LightsSnapshot?.none, LightsSnapshot.key)
        SharedStore.write(HabitsSnapshot?.none, HabitsSnapshot.key)
        SharedStore.write(FitnessGlance?.none, FitnessGlance.key)
        reloadAll()
        Task { await TVActivityController.shared.endAll() }
    }
}
