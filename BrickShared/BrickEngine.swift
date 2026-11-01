import Foundation

#if os(iOS)
import DeviceActivity
import FamilyControls
import ManagedSettings

/// Starting and ending modes, for the app and the BrickMonitor extension alike. The saved state in the
/// App Group is the one source of truth: whichever process starts or ends a mode writes it there,
/// and the app reads it back each time it checks.
enum BrickEngine {
    static let defaults = UserDefaults(suiteName: "group.com.paularmstrong.ArmstrongSmartHubApp") ?? .standard

    static func load<T: Decodable>(_ type: T.Type, _ key: String) -> T? {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(T.self, from: $0) }
    }

    static func save<T: Encodable>(_ value: T, _ key: String) {
        if let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: key) }
    }

    /// Brick used to keep everything in the app's own defaults, which the extension can't read.
    static func moveFromStandardDefaults() {
        guard !defaults.bool(forKey: "brick.inGroup") else { return }
        for (key, value) in UserDefaults.standard.dictionaryRepresentation() where key.hasPrefix("brick.") {
            defaults.set(value, forKey: key)
        }
        defaults.set(true, forKey: "brick.inGroup")
    }

    // MARK: State

    static var profiles: [BrickProfile] { load([BrickProfile].self, "brick.profiles") ?? [] }
    static var schedules: [BrickSchedule] { load([BrickSchedule].self, "brick.schedules") ?? [] }
    static var sessions: [BrickSession] { load([BrickSession].self, "brick.sessions") ?? [] }
    static var lockdowns: [BrickLockdown] { load([BrickLockdown].self, "brick.lockdowns") ?? [] }
    static var blockingProfileID: UUID? { defaults.string(forKey: "brick.active").flatMap(UUID.init(uuidString:)) }
    static var endsAt: Date? {
        let t = defaults.double(forKey: "brick.endsAt")
        return t > 0 ? Date(timeIntervalSince1970: t) : nil
    }

    static func isOn(_ id: UUID) -> Bool { blockingProfileID == id || lockdowns.contains { $0.profileID == id } }

    /// When a schedule ends on a day, if it has an end time; past midnight if it ends before it starts.
    static func endDate(of s: BrickSchedule, on day: Date) -> Date? {
        let cal = Calendar.current
        guard let h = s.endHour,
              let start = cal.date(bySettingHour: s.hour, minute: s.minute, second: 0, of: day),
              var end = cal.date(bySettingHour: h, minute: s.endMinute ?? 0, second: 0, of: day) else { return nil }
        if end <= start { end = cal.date(byAdding: .day, value: 1, to: end) ?? end }
        return end
    }

    // MARK: Starting and ending

    /// Starts a mode: a lockdown in its own store, or the Brick (which counts as a session).
    /// `until` overrides the mode's own timer, for a schedule's end. `tagID` is the tag that started it, which alone
    /// ends a lockdown. False when there's nothing to block.
    @discardableResult
    static func start(_ p: BrickProfile, until: Date? = nil, tagID: String? = nil) -> Bool {
        guard !p.isEmpty else { return false }
        let ends = until ?? p.timerMinutes.map { Date().addingTimeInterval(Double($0) * 60) }
        if p.lockdown {
            apply(p, to: lockdownStore(p.id))
            var l = lockdowns
            l.removeAll { $0.profileID == p.id }
            l.append(BrickLockdown(profileID: p.id, endsAt: ends, tagID: tagID))
            save(l, "brick.lockdowns")
        } else {
            apply(p, to: ManagedSettingsStore())
            defaults.set(p.id.uuidString, forKey: "brick.active")
            defaults.set(ends?.timeIntervalSince1970 ?? 0, forKey: "brick.endsAt")
            var s = sessions
            s.append(BrickSession(profileName: p.name, start: Date()))
            save(s, "brick.sessions")
        }
        watchTimer(p.id, until: ends)
        return true
    }

    /// Ends whichever kind of mode this is. `byTimer` dates the session to when the timer was due.
    static func end(_ id: UUID, byTimer: Bool = false) {
        if id == blockingProfileID {
            var s = sessions
            if let i = s.lastIndex(where: { $0.end == nil }) {
                s[i].end = byTimer ? (endsAt ?? Date()) : Date()
                s[i].byTimer = byTimer
                save(s, "brick.sessions")
            }
            ManagedSettingsStore().clearAllSettings()
            defaults.removeObject(forKey: "brick.active")
            defaults.removeObject(forKey: "brick.endsAt")
        } else {
            lockdownStore(id).clearAllSettings()
            var l = lockdowns
            l.removeAll { $0.profileID == id }
            save(l, "brick.lockdowns")
        }
        DeviceActivityCenter().stopMonitoring([timerActivity(id)])
    }

    /// Each lockdown has its own store, so it stacks with the Brick and other lockdowns; iOS applies the strictest.
    static func lockdownStore(_ id: UUID) -> ManagedSettingsStore {
        ManagedSettingsStore(named: ManagedSettingsStore.Name("lockdown.\(id.uuidString)"))
    }

    /// Shields the mode's apps and sets its restrictions. nil leaves a setting as the user has it;
    /// clearing the store lifts them all.
    static func apply(_ p: BrickProfile, to store: ManagedSettingsStore) {
        let s = p.selection
        store.shield.applications = s.applicationTokens.isEmpty ? nil : s.applicationTokens
        store.shield.applicationCategories = s.categoryTokens.isEmpty ? nil : .specific(s.categoryTokens)
        store.shield.webDomains = s.webDomainTokens.isEmpty ? nil : s.webDomainTokens
        store.shield.webDomainCategories = s.categoryTokens.isEmpty ? nil : .specific(s.categoryTokens)
        let r = p.restrictions
        func on(_ v: Bool) -> Bool? { v ? true : nil }
        store.webContent.blockedByFilter = r.adultWebsites ? .auto() : nil
        store.media.denyExplicitContent = on(r.explicitMedia)
        store.application.denyAppInstallation = on(r.appInstalls)
        store.application.denyAppRemoval = on(r.appRemoval)
        store.appStore.denyInAppPurchases = on(r.inAppPurchases)
        store.siri.denySiri = on(r.siri)
        store.gameCenter.denyMultiplayerGaming = on(r.multiplayerGames)
        store.gameCenter.denyAddingFriends = on(r.multiplayerGames)
        store.dateAndTime.requireAutomaticDateAndTime = on(r.automaticTime)
    }

    // MARK: Waking the extension

    static func scheduleActivity(_ id: UUID) -> DeviceActivityName { DeviceActivityName("schedule.\(id.uuidString)") }
    static func timerActivity(_ id: UUID) -> DeviceActivityName { DeviceActivityName("timer.\(id.uuidString)") }

    /// Asks iOS to wake the extension when a mode's timer runs out. iOS won't watch less than 15 minutes;
    /// shorter timers end when the app next checks.
    static func watchTimer(_ id: UUID, until: Date?) {
        let center = DeviceActivityCenter()
        center.stopMonitoring([timerActivity(id)])
        guard let until else { return }
        let cal = Calendar.current
        let parts: Set<Calendar.Component> = [.year, .month, .day, .hour, .minute, .second]
        let window = DeviceActivitySchedule(intervalStart: cal.dateComponents(parts, from: Date()),
                                            intervalEnd: cal.dateComponents(parts, from: until), repeats: false)
        try? center.startMonitoring(timerActivity(id), during: window)
    }

    /// Hands every schedule to iOS as a daily window, so the extension starts and ends it on time.
    /// Weekdays are checked when it starts. One without an end time gets a 15-minute window that only starts it.
    static func syncSchedules() {
        let center = DeviceActivityCenter()
        center.stopMonitoring(center.activities.filter { $0.rawValue.hasPrefix("schedule.") })
        for s in schedules where s.enabled && !s.weekdays.isEmpty {
            let startMinutes = s.hour * 60 + s.minute
            let endMinutes = s.endHour.map { $0 * 60 + (s.endMinute ?? 0) } ?? startMinutes + 15
            let window = DeviceActivitySchedule(
                intervalStart: DateComponents(hour: s.hour, minute: s.minute),
                intervalEnd: DateComponents(hour: (endMinutes / 60) % 24, minute: endMinutes % 60),
                repeats: true)
            try? center.startMonitoring(scheduleActivity(s.id), during: window)
        }
    }

    // MARK: Schedules

    /// Starts a schedule's mode if today is one of its days and it hasn't run today. `now` inside its window.
    static func fire(_ scheduleID: UUID, now: Date = Date()) {
        let cal = Calendar.current
        var all = schedules
        guard let i = all.firstIndex(where: { $0.id == scheduleID }) else { return }
        let s = all[i]
        guard s.enabled, s.weekdays.contains(cal.component(.weekday, from: now)),
              !(s.lastFired.map { cal.isDate($0, inSameDayAs: now) } ?? false),
              let p = profiles.first(where: { $0.id == s.profileID }),
              !isOn(p.id), p.lockdown || blockingProfileID == nil else { return }
        all[i].lastFired = now
        save(all, "brick.schedules")
        start(p, until: endDate(of: s, on: now))
    }

    /// Ends a schedule's mode at its end time. Only near the end time itself, so re-registering
    /// schedules mid-window (which can end the old window) never ends anything early.
    static func finish(_ scheduleID: UUID, now: Date = Date()) {
        guard let s = schedules.first(where: { $0.id == scheduleID }), let h = s.endHour,
              let p = profiles.first(where: { $0.id == s.profileID }), isOn(p.id) else { return }
        let cal = Calendar.current
        let nowMinutes = cal.component(.hour, from: now) * 60 + cal.component(.minute, from: now)
        let endMinutes = h * 60 + (s.endMinute ?? 0)
        let off = abs(nowMinutes - endMinutes)
        guard min(off, 24 * 60 - off) <= 2 else { return }
        end(p.id, byTimer: true)
    }

    /// Ends a mode whose timer is due.
    static func timerDue(_ id: UUID, now: Date = Date()) {
        let due = id == blockingProfileID ? endsAt : lockdowns.first { $0.profileID == id }?.endsAt
        guard let due, due <= now.addingTimeInterval(60) else { return }
        end(id, byTimer: true)
    }
}
#endif
