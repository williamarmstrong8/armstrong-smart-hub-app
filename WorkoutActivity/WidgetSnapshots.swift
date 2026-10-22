import Foundation

// Shared by the app and the WorkoutWidgets extension: what the Home, Habits,
// Fitness and Brick widgets show. The app writes a snapshot whenever its own
// copy changes; the widgets read it, and the light and habit widgets also ask
// the hub themselves when they can.

nonisolated enum WidgetKind {
    static let lights = "LightsWidget"
    static let habits = "HabitsWidget"
    static let fitness = "FitnessWidget"
    static let brick = "BrickWidget"
    static let lightControl = "LightControl"
}

/// JSON in the app group's defaults.
nonisolated enum SharedStore {
    static func read<T: Decodable>(_ type: T.Type, _ key: String) -> T? {
        guard let data = SharedHub.defaults?.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    static func write<T: Encodable>(_ value: T?, _ key: String) {
        if let value, let data = try? JSONEncoder().encode(value) {
            SharedHub.defaults?.set(data, forKey: key)
        } else {
            SharedHub.defaults?.removeObject(forKey: key)
        }
    }
}

/// Local "YYYY-MM-DD" days, the way the habit board counts them.
nonisolated enum SharedDay {
    static func string(_ date: Date = .now) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    static func shift(_ day: String, _ delta: Int) -> String {
        let p = day.split(separator: "-").compactMap { Int($0) }
        guard p.count == 3, let date = Calendar.current.date(from: DateComponents(year: p[0], month: p[1], day: p[2] + delta)) else { return day }
        return string(date)
    }
}

// MARK: Lights

nonisolated struct LightItem: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var name: String
    var room: String?
    var isOn: Bool
    /// 1 to 100 while on; nil for a plain on/off light.
    var brightnessPct: Int?
    var isUnavailable: Bool

    /// From Home Assistant's state and 0 to 255 brightness, like HAEntity does it.
    init(id: String, name: String, room: String?, state: String, brightness: Double?) {
        self.id = id
        self.name = name
        self.room = room
        let s = state.lowercased()
        isOn = s == "on"
        isUnavailable = s == "unavailable" || s == "unknown"
        brightnessPct = isOn ? brightness.map { max(1, Int(($0 / 255 * 100).rounded())) } : nil
    }
}

nonisolated struct LightsSnapshot: Codable, Sendable {
    /// Every light, so a widget or control can be pointed at one Home hides.
    var lights: [LightItem]
    /// The ones Home shows, in order: what a widget shows until lights are picked for it.
    var shown: [String]
    /// When a widget button last changed a light, so the next reload trusts this copy over a hub
    /// that hasn't caught up yet.
    var touchedAt: Date?

    static let key = "widget.lights"
    static func read() -> LightsSnapshot? { SharedStore.read(LightsSnapshot.self, key) }
    func write() { SharedStore.write(self, Self.key) }

    var recentlyTouched: Bool { (touchedAt ?? .distantPast).timeIntervalSinceNow > -8 }

    var shownLights: [LightItem] { shown.compactMap { id in lights.first { $0.id == id } } }

    /// Records a change made from a widget or control.
    mutating func set(_ id: String, on: Bool) {
        guard let i = lights.firstIndex(where: { $0.id == id }) else { return }
        lights[i].isOn = on
        if !on { lights[i].brightnessPct = nil }
        touchedAt = .now
    }
}

/// GET /api/home, only as much as the light widgets need.
nonisolated struct WidgetHomePayload: Decodable, Sendable {
    struct Entity: Decodable, Sendable {
        var id: String
        var name: String
        var state: String
        var room: String?
        var control: String
        var brightness: Double?
    }

    var entities: [Entity]?
    var visible: [String]?

    var snapshot: LightsSnapshot {
        let all = (entities ?? []).filter { $0.control == "light" }
            .map { LightItem(id: $0.id, name: $0.name, room: $0.room, state: $0.state, brightness: $0.brightness) }
        return LightsSnapshot(lights: all, shown: LightsSnapshot.shownIDs(all, visible: visible))
    }
}

nonisolated extension LightsSnapshot {
    /// The lights Home shows: the picked devices, or everything available until some are picked.
    static func shownIDs(_ all: [LightItem], visible: [String]?) -> [String] {
        if let visible {
            let picked = Set(visible)
            return all.filter { picked.contains($0.id) }.map(\.id)
        }
        return all.filter { !$0.isUnavailable }.map(\.id)
    }
}

// MARK: Habits

nonisolated struct HabitItem: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var name: String
    /// "#RRGGBB".
    var color: String
    /// An emoji, or nil.
    var icon: String?
    var done: Bool
    var streak: Int
}

nonisolated struct HabitsSnapshot: Codable, Sendable {
    var day: String
    var habits: [HabitItem]
    var touchedAt: Date?

    static let key = "widget.habits"
    static func read() -> HabitsSnapshot? { SharedStore.read(HabitsSnapshot.self, key) }
    func write() { SharedStore.write(self, Self.key) }

    var doneCount: Int { habits.filter(\.done).count }
    var recentlyTouched: Bool { (touchedAt ?? .distantPast).timeIntervalSinceNow > -8 }

    /// Today's board from the habits and the days each was done, streaks counted like the app's.
    static func build(
        habits: [(id: String, name: String, color: String, icon: String?)],
        done: Set<String>, historyDays: Int, today: String = SharedDay.string()
    ) -> HabitsSnapshot {
        func isDone(_ id: String, _ day: String) -> Bool { done.contains(doneKey(id, day)) }
        let items = habits.map { h -> HabitItem in
            var count = 0
            var day = isDone(h.id, today) ? today : SharedDay.shift(today, -1)
            while isDone(h.id, day) && count <= historyDays {
                count += 1
                day = SharedDay.shift(day, -1)
            }
            let icon = h.icon.flatMap { $0.isEmpty ? nil : String($0.prefix(2)) }
            return HabitItem(id: h.id, name: h.name, color: h.color, icon: icon, done: isDone(h.id, today), streak: count)
        }
        return HabitsSnapshot(day: today, habits: items)
    }

    static func doneKey(_ habitId: String, _ day: String) -> String { "\(habitId)|\(day)" }
}

/// GET /api/mobile/habits, as the widget reads it.
nonisolated struct WidgetHabitsPayload: Decodable, Sendable {
    struct Habit: Decodable, Sendable { var id: String; var name: String; var color: String; var icon: String?; var position: Int }
    struct Done: Decodable, Sendable { var habitId: String; var date: String }

    var habits: [Habit]
    var completions: [Done]
    var historyDays: Int

    var snapshot: HabitsSnapshot {
        HabitsSnapshot.build(
            habits: habits.sorted { $0.position < $1.position }.map { ($0.id, $0.name, $0.color, $0.icon) },
            done: Set(completions.map { HabitsSnapshot.doneKey($0.habitId, $0.date) }),
            historyDays: historyDays)
    }
}

// MARK: Fitness

/// Today from the watch and the hub, as the Fitness page shows it.
nonisolated struct FitnessGlance: Codable, Sendable {
    var day: String
    var steps: Int?
    var stepGoal: Int?
    var bodyBattery: Int?
    var stress: Int?
    var restingHr: Int?
    var heartRate: Int?
    var heartRateAt: Date?
    var sleepSeconds: Int?
    var sleepScore: Int?
    var readiness: Int?
    var readinessLevel: String?
    var intensityMinutes: Int?
    var updatedAt: Date

    static let key = "widget.fitness"
    static func read() -> FitnessGlance? { SharedStore.read(FitnessGlance.self, key) }
    func write() { SharedStore.write(self, Self.key) }

    /// Steps only count for the day they were taken.
    var isToday: Bool { day == SharedDay.string() }
    var stepFraction: Double {
        guard let steps, let goal = stepGoal, goal > 0 else { return 0 }
        return min(1, Double(steps) / Double(goal))
    }
}

// MARK: Brick

nonisolated struct BrickGlance: Codable, Hashable, Sendable {
    var isBlocking: Bool
    var profileName: String?
    var startedAt: Date?
    var endsAt: Date?
    var strict: Bool
    /// Bricked time today from finished sessions; the running one counts from `startedAt`.
    var finishedTodaySeconds: TimeInterval
    var day: String
    var hasTag: Bool

    static let key = "widget.brick"
    static func read() -> BrickGlance? { SharedStore.read(BrickGlance.self, key) }
    func write() { SharedStore.write(self, Self.key) }

    func todaySeconds(at now: Date) -> TimeInterval {
        let finished = day == SharedDay.string(now) ? finishedTodaySeconds : 0
        guard isBlocking, let start = startedAt else { return finished }
        let from = max(start, Calendar.current.startOfDay(for: now))
        return finished + max(0, now.timeIntervalSince(from))
    }
}
