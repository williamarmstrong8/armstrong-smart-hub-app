import Foundation
import Observation
import UserNotifications

/// The diet log: what he ate, and how he felt after. It lives in the phone's
/// database (LocalSchema step 7: diet_meals, diet_meal_foods, diet_checks,
/// diet_symptoms, diet_foods), where Jarvis can query it too. Each food keeps the
/// FODMAP rating it had when logged, so old meals mean the same thing later.
///
/// Two hours after a meal logged as it happened, a notification asks how he
/// feels, with the common answers as buttons. Until he answers, the Diet card
/// on Fitness asks too.
@MainActor
@Observable
final class DietStore {
    static let shared = DietStore()

    /// Newest first.
    private(set) var meals: [Meal] = []
    /// Newest first.
    private(set) var checks: [GutCheck] = []
    /// Foods he typed that aren't in the guide.
    private(set) var customFoods: [DietFood] = []
    private(set) var plan: DietPlan = .lowFodmap
    private(set) var phase: DietPhase = .elimination
    /// The local day the current phase started, once he's logged anything.
    private(set) var phaseSince: String?
    /// Meals he chose not to answer about, so the card stops asking.
    private var skipped: Set<String>
    /// A meal a notification asked to answer about in the app; the Diet card opens it.
    var askAbout: String?

    private var db: LocalDB? { Demo.isOn ? nil : LocalDB.shared }

    init() {
        skipped = Set(UserDefaults.standard.stringArray(forKey: Self.skippedKey) ?? [])
        load()
    }

    // MARK: Reading

    func load() {
        guard let db else { return }
        let foodRows = db.query("select meal_id, food_id, name, fodmap, groups from diet_meal_foods order by meal_id, position")
        var foods: [String: [MealFood]] = [:]
        for r in foodRows {
            guard let meal = r["meal_id"] as? String, let name = r["name"] as? String else { continue }
            foods[meal, default: []].append(MealFood(foodID: r["food_id"] as? String, name: name,
                                                     level: FodmapLevel(rawValue: r["fodmap"] as? String ?? "") ?? .unknown,
                                                     groups: Self.groups(r["groups"])))
        }
        meals = db.query("select id, at, slot, note from diet_meals order by at desc").compactMap { r in
            guard let id = r["id"] as? String, let at = LocalDB.date(r["at"] as? String) else { return nil }
            return Meal(id: id, at: at, slot: MealSlot(rawValue: r["slot"] as? String ?? "") ?? .snack,
                        foods: foods[id] ?? [], note: r["note"] as? String)
        }

        var symptoms: [String: [Symptom: Severity]] = [:]
        for r in db.query("select check_id, symptom, severity from diet_symptoms") {
            guard let id = r["check_id"] as? String, let s = Symptom(rawValue: r["symptom"] as? String ?? ""),
                  let level = Severity(rawValue: r["severity"] as? Int ?? 0) else { continue }
            symptoms[id, default: [:]][s] = level
        }
        checks = db.query("select id, at, meal_id, note from diet_checks order by at desc").compactMap { r in
            guard let id = r["id"] as? String, let at = LocalDB.date(r["at"] as? String) else { return nil }
            return GutCheck(id: id, at: at, mealID: r["meal_id"] as? String, symptoms: symptoms[id] ?? [:], note: r["note"] as? String)
        }

        customFoods = db.query("select id, name, fodmap, groups from diet_foods order by name collate nocase").compactMap { r in
            guard let id = r["id"] as? String, let name = r["name"] as? String else { return nil }
            return DietFood(id: id, name: name, category: nil, level: FodmapLevel(rawValue: r["fodmap"] as? String ?? "") ?? .unknown,
                            groups: Self.groups(r["groups"]))
        }

        let settings = Dictionary(db.query("select key, value from settings where key like 'diet.%'").compactMap { r -> (String, String)? in
            guard let k = r["key"] as? String, let v = r["value"] as? String else { return nil }
            return (k, v)
        }, uniquingKeysWith: { a, _ in a })
        plan = settings["diet.plan"].flatMap(DietPlan.init(rawValue:)) ?? .lowFodmap
        phase = settings["diet.phase"].flatMap(DietPhase.init(rawValue:)) ?? .elimination
        phaseSince = settings["diet.phase_since"]
    }

    private static func groups(_ value: Any?) -> [FodmapGroup] {
        (value as? String)?.split(separator: ",").compactMap { FodmapGroup(rawValue: String($0)) } ?? []
    }

    func meal(_ id: String?) -> Meal? { id.flatMap { id in meals.first { $0.id == id } } }

    /// How he felt after a meal, when he said.
    func check(for mealID: String) -> GutCheck? { checks.first { $0.mealID == mealID } }

    func meals(on day: String) -> [Meal] { meals.filter { localDay($0.at) == day }.sorted { $0.at < $1.at } }
    func checks(on day: String) -> [GutCheck] { checks.filter { localDay($0.at) == day }.sorted { $0.at < $1.at } }

    /// Days with anything logged, newest first.
    var loggedDays: [String] {
        Set(meals.map { localDay($0.at) } + checks.map { localDay($0.at) }).sorted(by: >)
    }

    /// The newest meal, from an hour to 14 hours ago, that he hasn't said how he felt after.
    func awaitingCheck(now: Date = .now) -> Meal? {
        meals.first { meal in
            let age = now.timeIntervalSince(meal.at)
            return age >= 3600 && age <= 14 * 3600 && check(for: meal.id) == nil && !skipped.contains(meal.id)
        }
    }

    /// Meals a check could be about: the last 14 hours, newest first.
    func recentMeals(before date: Date = .now) -> [Meal] {
        meals.filter { date.timeIntervalSince($0.at) >= -600 && date.timeIntervalSince($0.at) <= 14 * 3600 }
    }

    /// Days into the current phase, counting the first as day 1.
    var phaseDay: Int? {
        guard let since = phaseSince, let start = DayFormat.parse(since), let today = DayFormat.parse(localDay()) else { return nil }
        return max(1, Int((today.timeIntervalSince(start) / 86400).rounded()) + 1)
    }

    // MARK: Foods

    /// Every food he can pick: the guide's, then his own.
    var allFoods: [DietFood] { plan.foods + customFoods }

    func food(_ id: String) -> DietFood? { LowFodmap.byID[id] ?? customFoods.first { $0.id == id } }

    /// The foods he logs most, as they stand in the guide now.
    func usualFoods(limit: Int = 16) -> [DietFood] {
        var counts: [String: (count: Int, food: MealFood, last: Date)] = [:]
        for meal in meals.prefix(300) {
            for f in meal.foods {
                let old = counts[f.id]
                counts[f.id] = ((old?.count ?? 0) + 1, f, max(old?.last ?? .distantPast, meal.at))
            }
        }
        return counts.values
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.last > $1.last }
            .prefix(limit)
            .map { entry in
                entry.food.foodID.flatMap(food) ?? DietFood(id: entry.food.id, name: entry.food.name, category: nil,
                                                            level: entry.food.level, groups: entry.food.groups)
            }
    }

    /// Foods matching what he typed, the ones that start with it first.
    func search(_ query: String) -> [DietFood] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }
        let usual = Dictionary(usualFoods(limit: 60).enumerated().map { ($1.id, $0) }, uniquingKeysWith: { a, _ in a })
        return allFoods.filter { $0.matches(q) }.sorted { a, b in
            let ap = a.name.lowercased().hasPrefix(q.lowercased()), bp = b.name.lowercased().hasPrefix(q.lowercased())
            if ap != bp { return ap }
            let au = usual[a.id] ?? .max, bu = usual[b.id] ?? .max
            if au != bu { return au < bu }
            return a.name < b.name
        }
    }

    /// A food of his own, kept so it comes up next time. Not rated until he says otherwise.
    @discardableResult
    func addCustomFood(_ name: String) -> DietFood {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if let existing = allFoods.first(where: { $0.name.caseInsensitiveCompare(clean) == .orderedSame }) { return existing }
        let food = DietFood(id: "custom:\(clean.lowercased())", name: clean, category: nil, level: .unknown)
        customFoods.append(food)
        customFoods.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        db?.run("insert or ignore into diet_foods (id, name, fodmap, groups, created_at) values (?, ?, ?, ?, ?)",
                [food.id, food.name, food.level.rawValue, nil, LocalDB.iso(.now)])
        return food
    }

    /// Rates one of his own foods; meals already logged keep the rating they had.
    func rate(_ food: DietFood, _ level: FodmapLevel) {
        guard let index = customFoods.firstIndex(where: { $0.id == food.id }) else { return }
        customFoods[index].level = level
        db?.run("update diet_foods set fodmap = ? where id = ?", [level.rawValue, food.id])
    }

    func removeCustomFood(_ food: DietFood) {
        customFoods.removeAll { $0.id == food.id }
        db?.run("delete from diet_foods where id = ?", [food.id])
    }

    // MARK: Logging meals

    /// Adds a meal, or replaces one with the same id.
    func save(_ meal: Meal) {
        let now = Date.now
        let isNew = !meals.contains { $0.id == meal.id }
        meals.removeAll { $0.id == meal.id }
        meals.append(meal)
        meals.sort { $0.at > $1.at }
        if phaseSince == nil { setPhase(phase, since: localDay(meal.at)) }
        db?.transaction { [db] in
            db?.run("""
                insert into diet_meals (id, at, day, slot, note, logged_at, updated_at) values (?, ?, ?, ?, ?, ?, ?)
                on conflict (id) do update set at = excluded.at, day = excluded.day, slot = excluded.slot,
                  note = excluded.note, updated_at = excluded.updated_at
                """, [meal.id, LocalDB.iso(meal.at), localDay(meal.at), meal.slot.rawValue, meal.note, LocalDB.iso(now), LocalDB.iso(now)])
            db?.run("delete from diet_meal_foods where meal_id = ?", [meal.id])
            for (position, f) in meal.foods.enumerated() {
                db?.run("insert into diet_meal_foods (meal_id, position, food_id, name, fodmap, groups) values (?, ?, ?, ?, ?, ?)",
                        [meal.id, position, f.foodID, f.name, f.level.rawValue, f.groups.isEmpty ? nil : f.groups.map(\.rawValue).joined(separator: ",")])
            }
        }
        // Only a meal logged as it happens gets the follow-up; a backfilled one is asked about on the card.
        if isNew || pendingFollowUps.contains(meal.id) { Task { await scheduleFollowUp(meal) } }
    }

    func delete(_ meal: Meal) {
        meals.removeAll { $0.id == meal.id }
        // A check about it stays, unlinked: how he felt is still worth keeping.
        for i in checks.indices where checks[i].mealID == meal.id { checks[i].mealID = nil }
        db?.run("delete from diet_meals where id = ?", [meal.id])
        cancelFollowUp(meal.id)
    }

    // MARK: How he felt

    /// Saves how he felt. A check about a meal replaces any earlier one about it.
    func save(_ check: GutCheck) {
        var check = check
        check.note = check.note?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        if let mealID = check.mealID, let old = self.check(for: mealID), old.id != check.id {
            deleteCheck(old)
        }
        if let mealID = check.mealID { cancelFollowUp(mealID) }
        checks.removeAll { $0.id == check.id }
        checks.append(check)
        checks.sort { $0.at > $1.at }
        db?.transaction { [db] in
            db?.run("""
                insert into diet_checks (id, meal_id, at, day, note, updated_at) values (?, ?, ?, ?, ?, ?)
                on conflict (id) do update set meal_id = excluded.meal_id, at = excluded.at, day = excluded.day,
                  note = excluded.note, updated_at = excluded.updated_at
                """, [check.id, check.mealID, LocalDB.iso(check.at), localDay(check.at), check.note, LocalDB.iso(.now)])
            db?.run("delete from diet_symptoms where check_id = ?", [check.id])
            for (symptom, severity) in check.symptoms {
                db?.run("insert into diet_symptoms (check_id, symptom, severity) values (?, ?, ?)", [check.id, symptom.rawValue, severity.rawValue])
            }
        }
    }

    func deleteCheck(_ check: GutCheck) {
        checks.removeAll { $0.id == check.id }
        db?.run("delete from diet_checks where id = ?", [check.id])
    }

    /// "Felt fine" after a meal, in one tap.
    func markFine(_ meal: Meal, at date: Date = .now) {
        save(GutCheck(id: check(for: meal.id)?.id ?? LocalDB.uuid(), at: date, mealID: meal.id, symptoms: [:], note: nil))
    }

    /// Adds one symptom to how he felt after a meal (from a notification button).
    func add(_ symptom: Symptom, after meal: Meal, severity: Severity = .moderate) {
        var check = check(for: meal.id) ?? GutCheck(id: LocalDB.uuid(), at: .now, mealID: meal.id, symptoms: [:], note: nil)
        check.symptoms[symptom] = max(check.symptoms[symptom] ?? severity, severity)
        save(check)
    }

    /// Stops the card asking about a meal.
    func skip(_ meal: Meal) {
        skipped.insert(meal.id)
        UserDefaults.standard.set(Array(skipped.suffix(60)), forKey: Self.skippedKey)
        cancelFollowUp(meal.id)
    }

    private static let skippedKey = "diet.skipped"

    // MARK: Phase

    func setPhase(_ phase: DietPhase, since day: String? = nil) {
        let day = day ?? localDay()
        self.phase = phase
        phaseSince = day
        db?.transaction { [db] in
            db?.run("insert or replace into settings (key, value) values ('diet.plan', ?)", [plan.rawValue])
            db?.run("insert or replace into settings (key, value) values ('diet.phase', ?)", [phase.rawValue])
            db?.run("insert or replace into settings (key, value) values ('diet.phase_since', ?)", [day])
        }
    }

    // MARK: Follow-up notifications

    nonisolated static let categoryPrefix = "diet."
    private nonisolated static let category = "diet.check"
    private nonisolated static let fine = "diet.fine"
    private nonisolated static let other = "diet.other"
    private nonisolated static let symptomPrefix = "diet.symptom."
    /// The symptoms offered as buttons; the rest are in the app.
    private static let quickSymptoms: [Symptom] = [.gutPain, .gas, .bloating, .nausea]
    /// How long after a meal to ask.
    private static let followUpAfter: TimeInterval = 2 * 3600

    /// Registered with the others in CheckinReminders, which is the notification delegate.
    static var notificationCategory: UNNotificationCategory {
        var actions = [UNNotificationAction(identifier: fine, title: "Feeling fine", options: [],
                                            icon: UNNotificationActionIcon(systemImageName: "face.smiling"))]
        actions += quickSymptoms.map { s in
            UNNotificationAction(identifier: symptomPrefix + s.rawValue, title: s.title, options: [],
                                 icon: UNNotificationActionIcon(systemImageName: s.symbol))
        }
        actions.append(UNNotificationAction(identifier: other, title: "Something else…", options: [.foreground],
                                            icon: UNNotificationActionIcon(systemImageName: "square.and.pencil")))
        return UNNotificationCategory(identifier: category, actions: actions, intentIdentifiers: [])
    }

    private static func requestID(_ mealID: String) -> String { "diet.check.\(mealID)" }

    /// Meals with a follow-up waiting, so an edit moves it rather than adding one for a backfilled meal.
    private var pendingFollowUps: Set<String> = []

    /// Asks how he feels two hours after a meal, if that's still ahead and not in the night.
    private func scheduleFollowUp(_ meal: Meal) async {
        guard !Demo.isOn else { return }
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [Self.requestID(meal.id)])
        pendingFollowUps.remove(meal.id)
        let fire = meal.at.addingTimeInterval(Self.followUpAfter)
        let hour = Calendar.current.component(.hour, from: fire)
        guard fire.timeIntervalSinceNow > 60, hour >= 7, hour < 23, check(for: meal.id) == nil else { return }
        guard (try? await center.requestAuthorization(options: [.alert, .sound])) == true else { return }
        let content = UNMutableNotificationContent()
        content.title = "How do you feel after \(meal.slot.title.lowercased())?"
        content.body = "\(meal.summary). Long-press to answer."
        content.sound = .default
        content.categoryIdentifier = Self.category
        content.threadIdentifier = Self.category
        content.userInfo = ["meal": meal.id]
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: fire.timeIntervalSinceNow, repeats: false)
        try? await center.add(UNNotificationRequest(identifier: Self.requestID(meal.id), content: content, trigger: trigger))
        pendingFollowUps.insert(meal.id)
    }

    private func cancelFollowUp(_ mealID: String) {
        pendingFollowUps.remove(mealID)
        let id = Self.requestID(mealID)
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [id])
        center.removeDeliveredNotifications(withIdentifiers: [id])
    }

    /// A button on the follow-up: answered in place, or "Something else…" opens the card.
    func answer(action: String, mealID: String?) async {
        load()
        guard let meal = meal(mealID) else {
            AppRouter.shared.open(.fitness, card: .diet)
            return
        }
        switch action {
        case Self.fine:
            markFine(meal)
        case let a where a.hasPrefix(Self.symptomPrefix):
            if let s = Symptom(rawValue: String(a.dropFirst(Self.symptomPrefix.count))) { add(s, after: meal) }
        default:
            askAbout = meal.id
            AppRouter.shared.open(.fitness, card: .diet)
        }
    }
}

// MARK: Insights

/// What tends to come before symptoms. Only meals he said how he felt after count.
@MainActor
struct DietInsights {
    struct Stat: Identifiable {
        var id: String
        var name: String
        var level: FodmapLevel
        var meals: Int
        var withSymptoms: Int
        var rate: Double { meals > 0 ? Double(withSymptoms) / Double(meals) : 0 }
    }

    struct GroupStat: Identifiable {
        var group: FodmapGroup
        var with: (meals: Int, symptoms: Int)
        var without: (meals: Int, symptoms: Int)
        var id: FodmapGroup { group }
        var rateWith: Double? { with.meals > 0 ? Double(with.symptoms) / Double(with.meals) : nil }
        var rateWithout: Double? { without.meals > 0 ? Double(without.symptoms) / Double(without.meals) : nil }
    }

    let checked: [(meal: Meal, check: GutCheck)]

    init(store: DietStore, days: Int = 90) {
        let cutoff = Date.now.addingTimeInterval(-Double(days) * 86400)
        checked = store.meals.filter { $0.at > cutoff }.compactMap { meal in store.check(for: meal.id).map { (meal, $0) } }
    }

    /// The share of checked meals followed by any symptom.
    var baseline: Double? {
        guard !checked.isEmpty else { return nil }
        return Double(checked.filter { !$0.check.isFine }.count) / Double(checked.count)
    }

    /// Each food eaten at least `minimum` times with a check after.
    func foods(minimum: Int = 2) -> [Stat] {
        var stats: [String: Stat] = [:]
        for (meal, check) in checked {
            for f in Set(meal.foods.map(\.id)) {
                guard let food = meal.foods.first(where: { $0.id == f }) else { continue }
                var s = stats[f] ?? Stat(id: f, name: food.name, level: food.level, meals: 0, withSymptoms: 0)
                s.meals += 1
                if !check.isFine { s.withSymptoms += 1 }
                stats[f] = s
            }
        }
        return stats.values.filter { $0.meals >= minimum }
    }

    /// Foods more often followed by symptoms than meals in general.
    var suspects: [Stat] {
        let base = baseline ?? 0
        return foods().filter { $0.withSymptoms >= 2 && $0.rate >= 0.5 && $0.rate > base }
            .sorted { $0.rate != $1.rate ? $0.rate > $1.rate : $0.meals > $1.meals }
    }

    /// Foods eaten a few times with no symptoms after.
    var agreeable: [Stat] {
        foods(minimum: 3).filter { $0.withSymptoms == 0 }.sorted { $0.meals > $1.meals }
    }

    /// Meals with each FODMAP group (from foods that aren't low) against meals without it.
    var groups: [GroupStat] {
        FodmapGroup.allCases.map { group in
            var with = (meals: 0, symptoms: 0), without = (meals: 0, symptoms: 0)
            for (meal, check) in checked {
                let bad = check.isFine ? 0 : 1
                if meal.groups.contains(group) { with.meals += 1; with.symptoms += bad } else { without.meals += 1; without.symptoms += bad }
            }
            return GroupStat(group: group, with: with, without: without)
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
