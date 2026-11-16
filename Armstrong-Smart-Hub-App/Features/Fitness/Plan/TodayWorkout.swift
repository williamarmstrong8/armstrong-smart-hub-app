import Foundation
import Observation
import UserNotifications

/// Today's session, picked each morning from how recovered you are against
/// your own history, and put on the watch over Bluetooth as a structured
/// workout with heart-rate targets (Training › Workouts). No Garmin Connect.
///
/// The pick scores the morning: readiness, HRV and sleep against your last
/// 60 days, last night's drinks, the check-in model's guess, and how much
/// you've trained lately. Low scores get a recovery walk or easy aerobic work;
/// high ones get tempo or intervals; a good weekend morning gets a long easy
/// one. Sick (by check-in or the model) means rest: nothing goes to the watch.
@MainActor
@Observable
final class TodayWorkout {
    static let shared = TodayWorkout()

    struct Plan: Equatable {
        var workout: FitWorkout?
        /// "Zone 2 run, 45 min"
        var title: String
        /// Why, from your numbers.
        var why: String
    }

    /// Put the morning's workout on the watch by itself.
    var autoSend: Bool { didSet { UserDefaults.standard.set(autoSend, forKey: "todayWorkout.auto") } }
    /// What went to the watch today, for the Fitness card.
    private(set) var sent: (day: String, title: String, why: String)?
    private(set) var sending = false

    init() {
        let d = UserDefaults.standard
        autoSend = d.object(forKey: "todayWorkout.auto") as? Bool ?? true
        if let day = d.string(forKey: "todayWorkout.day"), let title = d.string(forKey: "todayWorkout.title") {
            sent = (day, title, d.string(forKey: "todayWorkout.why") ?? "")
        }
    }

    var sentToday: Bool { sent?.day == localDay() }

    // MARK: Picking

    func plan(fitness: FitnessStore, now: Date = .now) -> Plan {
        let stats = Signals(fitness: fitness)
        let profile = fitness.snapshot?.metrics?.profile
        let maxHr = profile?.maxHr ?? WorkoutStore.shared.maxHr ?? 190
        func bpm(_ fraction: Double) -> Int { Int((Double(maxHr) * fraction).rounded()) }
        let z1 = (bpm(0.50), bpm(0.60)), z2 = (bpm(0.60), bpm(0.70)), z3 = (bpm(0.70), bpm(0.80)), z4 = (bpm(0.80), bpm(0.90))

        if stats.sick {
            return Plan(workout: nil, title: "Rest day", why: stats.reasons.prefix(2).joined(separator: " ") + " Training on that slows recovery, so nothing went to your watch.")
        }

        let sport = stats.sport
        let weekend = Calendar.current.isDateInWeekend(now)
        let score = stats.score
        var steps: [FitWorkout.Step]
        let title: String
        func t(_ name: String, _ minutes: Int, _ zone: (Int, Int), _ intensity: FitWorkout.Intensity) -> FitWorkout.Step {
            .timed(name: name, seconds: minutes * 60, low: zone.0, high: zone.1, intensity: intensity)
        }

        switch score {
        case ..<(-2):
            steps = [t("Easy", 30, z1, .active)]
            title = "Recovery walk, 30 min"
            return Plan(workout: FitWorkout(name: "Today: recovery walk", sport: .walking, steps: steps), title: title, why: stats.why(score))
        case -2 ... -1:
            steps = [t("Warm up", 5, z1, .warmup), t("Zone 2", 30, z2, .active), t("Cool down", 5, z1, .cooldown)]
            title = "Easy Zone 2 \(sport.title), 40 min"
        case 0 where weekend, 1 where weekend:
            steps = [t("Warm up", 10, z1, .warmup), t("Long Zone 2", 55, z2, .active), t("Cool down", 5, z1, .cooldown)]
            title = "Long Zone 2 \(sport.title), 70 min"
        case 0:
            steps = [t("Warm up", 10, z1, .warmup), t("Zone 2", 35, z2, .active), t("Cool down", 5, z1, .cooldown)]
            title = "Zone 2 \(sport.title), 50 min"
        case 1:
            steps = [t("Warm up", 10, z2, .warmup), t("Tempo", 20, z3, .active), t("Cool down", 10, z1, .cooldown)]
            title = "Tempo \(sport.title), 40 min"
        default:
            steps = [t("Warm up", 12, z2, .warmup), t("Hard", 3, z4, .active), t("Easy", 2, z1, .recovery),
                     .repeatFrom(fromStep: 1, times: 5), t("Cool down", 10, z1, .cooldown)]
            title = "Intervals \(sport.title): 5 × 3 min, 47 min"
        }
        return Plan(workout: FitWorkout(name: "Today: " + title.components(separatedBy: ",")[0].lowercased(), sport: sport, steps: steps),
                    title: title, why: stats.why(score))
    }

    // MARK: Sending

    /// Mornings 5 to 11, once the night is in and the watch is connected: picks and sends today's.
    func runIfDue(fitness: FitnessStore) async {
        guard autoSend, !Demo.isOn, !sentToday else { return }
        let hour = Calendar.current.component(.hour, from: .now)
        guard (5..<11).contains(hour) else { return }
        guard let end = fitness.lastNight?.endDate, Calendar.current.isDateInToday(end) else { return }
        _ = await send(fitness: fitness)
    }

    /// Picks today's and sends it now. Returns what happened, for Test features.
    func send(fitness: FitnessStore) async -> String {
        guard !sending else { return "Already sending." }
        sending = true
        defer { sending = false }
        let plan = plan(fitness: fitness)
        guard let workout = plan.workout else {
            remember(plan)
            await notify(title: plan.title, body: plan.why)
            return "\(plan.title). \(plan.why)"
        }
        guard let watch = WatchLink.current, watch.state == .connected else { return "The watch isn't connected; it goes when it next syncs. Plan: \(plan.title)." }
        let ok = await watch.installer.install(workout.encode(), name: workout.name, busy: watch.files.isSyncing, kind: .workout)
        guard ok else { return watch.installer.lastResult ?? "The watch didn't take it." }
        remember(plan)
        await notify(title: "On your watch: \(plan.title)", body: plan.why)
        return "Sent \(plan.title). \(plan.why)"
    }

    private func remember(_ plan: Plan) {
        let day = localDay()
        sent = (day, plan.title, plan.why)
        let d = UserDefaults.standard
        d.set(day, forKey: "todayWorkout.day")
        d.set(plan.title, forKey: "todayWorkout.title")
        d.set(plan.why, forKey: "todayWorkout.why")
    }

    private func notify(title: String, body: String) async {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = HealthBriefing.undash(body)
        content.sound = .default
        content.categoryIdentifier = HealthBriefing.category
        try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "todayWorkout", content: content, trigger: nil))
    }
}

/// The morning's signals, each against your own last 60 days.
@MainActor
private struct Signals {
    var score = 0
    var reasons: [String] = []
    var sick = false
    var sport: FitWorkout.Sport = .running

    init(fitness: FitnessStore) {
        let today = localDay()
        let nights = fitness.nights.filter { ($0.endDate.map(localDay) ?? "") <= today }
        // Sleep against your nights.
        if let last = nights.first, let end = last.endDate, localDay(end) == today,
           let b = HealthStats.Baseline(nights.dropFirst().prefix(60).map { Double($0.asleepSeconds) / 3600 }.filter { $0 > 0.5 }) {
            let z = b.z(Double(last.asleepSeconds) / 3600)
            if z <= -1 { score -= 1; reasons.append(String(format: "Sleep was %.1f standard deviations below your average.", -z)) }
            if z >= 1 { score += 1; reasons.append("You slept well above your usual.") }
        }
        // HRV against your mornings.
        let hrv = (fitness.snapshot?.hrv ?? []).compactMap { h in h.lastNightAverage.map { (h.day, $0) } }
        if let first = hrv.first, first.0 == today, let b = HealthStats.Baseline(hrv.dropFirst().prefix(60).map { $0.1 }) {
            let z = b.z(first.1)
            if z <= -1 { score -= 1; reasons.append(String(format: "HRV is %.1f standard deviations below your baseline.", -z)) }
            if z >= 0.8 { score += 1; reasons.append(String(format: "HRV is %.1f standard deviations above your baseline, so you've absorbed recent training.", z)) }
        }
        // The watch's readiness.
        if let r = fitness.snapshot?.metrics?.readiness.score {
            if r < 40 { score -= 2; reasons.append("Readiness is \(r).") }
            else if r < 60 { score -= 1; reasons.append("Readiness is a middling \(r).") }
            else if r >= 75 { score += 1; reasons.append("Readiness is \(r).") }
        }
        // Last night's drinks.
        let night = AlcoholStore.night(of: Date.now.addingTimeInterval(-12 * 3600))
        let drinks = AlcoholStore.shared.drinks(on: night)
        if drinks > 0 || AlcoholStore.shared.amountUnknown(night) {
            score -= drinks >= 4 ? 2 : 1
            reasons.append(drinks > 0 ? "You had \(drinks) drink\(drinks == 1 ? "" : "s") last night." : "You drank last night.")
        }
        // The check-in model.
        let likely = CheckinStore.shared.likely
        let answered = CheckinStore.shared.entry(for: CheckinStore.shared.day)
        if answered?.tags.contains("sick") == true || likely.contains(where: { $0.state == "sick" && $0.probability >= 0.6 }) {
            sick = true
            reasons.insert(answered?.tags.contains("sick") == true ? "You checked in sick." : "The check-in model thinks you're getting sick.", at: 0)
        }
        if answered?.tags.contains("hungover") == true || likely.contains(where: { $0.state == "hungover" && $0.probability >= 0.5 }) {
            score -= 1
        }
        if answered?.tags.contains("run_down") == true || likely.contains(where: { $0.state == "run_down" && $0.probability >= 0.5 }) {
            score -= 1; reasons.append("You're likely run down.")
        }
        // Recent load: three days running, or two easy days in a row.
        let calendar = Calendar.current
        let trained = Set(fitness.activities.compactMap { a -> String? in
            guard let s = a.start, (a.duration ?? 0) >= 15 * 60 else { return nil }
            return localDay(s)
        })
        let lastThree = (1...3).compactMap { calendar.date(byAdding: .day, value: -$0, to: .now).map(localDay) }
        let streak = lastThree.filter { trained.contains($0) }.count
        if streak == 3 { score -= 1; reasons.append("You've trained three days straight.") }
        if streak == 0, !lastThree.isEmpty { score += 1; reasons.append("You've had three days off.") }
        // The cardio you actually do.
        let recent = fitness.activities.filter { ($0.start ?? .distantPast) > Date.now.addingTimeInterval(-60 * 86400) }
        let counts = Dictionary(grouping: recent.map(\.sport).filter { ["running", "cycling", "walking"].contains($0) }, by: { $0 }).mapValues(\.count)
        switch counts.max(by: { $0.value < $1.value })?.key {
        case "cycling": sport = .cycling
        case "walking": sport = .walking
        default: sport = .running
        }
    }

    func why(_ score: Int) -> String {
        let lead = reasons.prefix(3).joined(separator: " ")
        let verdict = switch score {
        case ..<(-2): "You're well short of recovered, so it's an easy walk to keep moving."
        case -2 ... -1: "You're a little under recovered, so it's easy aerobic work only."
        case 0: "You're about at your normal, so it's steady aerobic work."
        case 1: "You're recovered, so there's a tempo block."
        default: "You're well recovered, so today can take intervals."
        }
        return lead.isEmpty ? verdict : lead + " " + verdict
    }
}
