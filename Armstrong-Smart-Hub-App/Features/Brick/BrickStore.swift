import SwiftUI

#if os(iOS)
import FamilyControls
import ManagedSettings
import CoreNFC

/// One blocking mode: which apps to shield, whether only the tag can unlock, and an optional timer.
struct BrickProfile: Codable, Identifiable {
    var id = UUID()
    var name: String
    var selection = FamilyActivitySelection()
    /// Strict: only the registered tag (or an emergency unbrick) unlocks. Not strict: the in-app button also works.
    var strict = true
    /// Minutes until blocking ends by itself. nil means until the tag is tapped.
    var timerMinutes: Int?

    /// Content & Privacy limits that hold while this mode is on.
    var restrictions = BrickRestrictions()
    /// A lockdown runs alongside a Brick, isn't counted as Brick time, and only its own tag ends it.
    var lockdown = false

    var blockedCount: Int {
        selection.applicationTokens.count + selection.categoryTokens.count + selection.webDomainTokens.count
    }

    /// Nothing to block and nothing to restrict, so bricking would do nothing.
    var isEmpty: Bool { blockedCount == 0 && restrictions.count == 0 }

    init(name: String, strict: Bool = true, timerMinutes: Int? = nil) {
        self.name = name
        self.strict = strict
        self.timerMinutes = timerMinutes
    }

    // Modes saved before restrictions existed have no key for them.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        selection = try c.decodeIfPresent(FamilyActivitySelection.self, forKey: .selection) ?? FamilyActivitySelection()
        strict = try c.decodeIfPresent(Bool.self, forKey: .strict) ?? true
        timerMinutes = try c.decodeIfPresent(Int.self, forKey: .timerMinutes)
        restrictions = try c.decodeIfPresent(BrickRestrictions.self, forKey: .restrictions) ?? BrickRestrictions()
        lockdown = try c.decodeIfPresent(Bool.self, forKey: .lockdown) ?? false
    }
}

/// The Content & Privacy limits a mode can turn on, beyond shielding apps. iOS lifts them all on unbrick.
struct BrickRestrictions: Codable, Hashable {
    var adultWebsites = false
    var explicitMedia = false
    var appInstalls = false
    var appRemoval = false
    var inAppPurchases = false
    var siri = false
    var multiplayerGames = false
    var automaticTime = false

    /// How many are on.
    var count: Int {
        [adultWebsites, explicitMedia, appInstalls, appRemoval, inAppPurchases, siri, multiplayerGames, automaticTime]
            .filter { $0 }.count
    }

    init() {}

    // Any limit added later decodes as off.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func bool(_ k: CodingKeys) throws -> Bool { try c.decodeIfPresent(Bool.self, forKey: k) ?? false }
        adultWebsites = try bool(.adultWebsites)
        explicitMedia = try bool(.explicitMedia)
        appInstalls = try bool(.appInstalls)
        appRemoval = try bool(.appRemoval)
        inAppPurchases = try bool(.inAppPurchases)
        siri = try bool(.siri)
        multiplayerGames = try bool(.multiplayerGames)
        automaticTime = try bool(.automaticTime)
    }
}

/// One finished (or running) blocking session, kept for the activity page.
struct BrickSession: Codable, Identifiable, Hashable {
    var id = UUID()
    var profileName: String
    var start: Date
    var end: Date?
    /// True when the timer ended it, false when the tag or button did.
    var byTimer = false
}

/// One NFC tag. Its UID is the key; it can be tied to a mode so each tag starts its own kind of block.
struct BrickTag: Codable, Identifiable, Hashable {
    /// The tag's UID in hex.
    var id: String
    var name: String
    /// The mode this tag starts and ends. nil: starts the selected mode and ends whichever Brick is running (not lockdowns).
    var profileID: UUID?
}

/// Bricks the phone at a time of day on chosen weekdays, until an end time or a tag.
struct BrickSchedule: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var hour = 9
    var minute = 0
    /// When it ends by itself, for a work day. nil: runs until a tag (or the mode's own timer) ends it.
    var endHour: Int?
    var endMinute: Int?
    /// Calendar weekdays, 1 is Sunday.
    var weekdays: Set<Int> = [2, 3, 4, 5, 6]
    var profileID: UUID?
    var enabled = true
    /// The last day it bricked, so it fires once a day.
    var lastFired: Date?
}

/// A lockdown mode that's on, and when it ends by itself.
struct BrickLockdown: Codable, Hashable {
    var profileID: UUID
    var endsAt: Date?
}

/// Tap-to-block, like Brick. The shield itself is enforced by iOS (Managed Settings);
/// the tag is a plain NFC tag whose ID is the key. Nothing leaves the phone.
/// One store for the whole app, so timers and schedules are checked whichever tab is open.
@MainActor @Observable
final class BrickStore: NSObject {
    static let shared = BrickStore()

    /// Brick's own allowance: a few unlocks without the tag, for real emergencies.
    static let emergencyAllowance = 5

    private(set) var profiles: [BrickProfile] = []
    var selectedID: UUID? {
        didSet { defaults.set(selectedID?.uuidString, forKey: "brick.selected") }
    }
    private(set) var schedules: [BrickSchedule] = []
    private(set) var tags: [BrickTag] = [] {
        // Shortcuts offers tags by name in its phrases; keep that list current.
        didSet { BrickShortcuts.updateAppShortcutParameters() }
    }
    /// The Brick running now, the one that counts as Brick time.
    private(set) var blockingProfileID: UUID?
    private(set) var endsAt: Date?
    /// Lockdowns on now. Each has its own settings store, so they stack with the Brick and each other.
    private(set) var lockdowns: [BrickLockdown] = []
    private(set) var authorized = false
    private(set) var sessions: [BrickSession] = []
    private(set) var emergencyLeft = BrickStore.emergencyAllowance
    var message: String?
    /// The time the pages count a running session up to. Ticks while bricked, so totals grow live.
    private(set) var now = Date()

    @ObservationIgnored private let settings = ManagedSettingsStore()
    @ObservationIgnored private let defaults = UserDefaults.standard
    @ObservationIgnored private var session: NFCTagReaderSession?
    @ObservationIgnored private var onTag: ((String) -> Void)?
    @ObservationIgnored private var ticker: Timer?

    override private init() {
        super.init()
        profiles = load([BrickProfile].self, "brick.profiles") ?? []
        if profiles.isEmpty { profiles = [BrickProfile(name: "Focus")] }
        let saved = defaults.string(forKey: "brick.selected").flatMap(UUID.init(uuidString:))
        selectedID = profiles.contains { $0.id == saved } ? saved : profiles.first?.id
        sessions = load([BrickSession].self, "brick.sessions") ?? []
        schedules = load([BrickSchedule].self, "brick.schedules") ?? []
        tags = load([BrickTag].self, "brick.tags") ?? []
        // The single tag from before tags had names and modes.
        if tags.isEmpty, let old = defaults.string(forKey: "brick.tag") {
            tags = [BrickTag(id: old, name: "My Brick")]
            save(tags, "brick.tags")
        }
        if defaults.object(forKey: "brick.emergencyLeft") != nil {
            emergencyLeft = defaults.integer(forKey: "brick.emergencyLeft")
        }
        if let raw = defaults.string(forKey: "brick.active"), let id = UUID(uuidString: raw) {
            blockingProfileID = id
            let t = defaults.double(forKey: "brick.endsAt")
            endsAt = t > 0 ? Date(timeIntervalSince1970: t) : nil
        }
        lockdowns = load([BrickLockdown].self, "brick.lockdowns") ?? []
        authorized = AuthorizationCenter.shared.authorizationStatus == .approved
        startTicker()
        check()
    }

    var isBlocking: Bool { blockingProfileID != nil }
    /// A Brick or any lockdown is on.
    var anyOn: Bool { isBlocking || !lockdowns.isEmpty }
    func isOn(_ id: UUID) -> Bool { blockingProfileID == id || lockdowns.contains { $0.profileID == id } }
    var activeLockdowns: [BrickProfile] { lockdowns.compactMap { l in profiles.first { $0.id == l.profileID } } }
    var hasTag: Bool { !tags.isEmpty }
    var selected: BrickProfile? { profiles.first { $0.id == selectedID } }
    var blockingProfile: BrickProfile? { profiles.first { $0.id == blockingProfileID } }
    /// The session running now, if bricked.
    var current: BrickSession? { sessions.last { $0.end == nil } }

    private func load<T: Decodable>(_ type: T.Type, _ key: String) -> T? {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(T.self, from: $0) }
    }

    private func save<T: Encodable>(_ value: T, _ key: String) {
        if let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: key) }
    }

    // MARK: Modes

    func update(_ profile: BrickProfile) {
        guard let i = profiles.firstIndex(where: { $0.id == profile.id }) else { return }
        profiles[i] = profile
        save(profiles, "brick.profiles")
    }

    @discardableResult
    func addProfile() -> UUID {
        let p = BrickProfile(name: "Mode \(profiles.count + 1)")
        profiles.append(p)
        selectedID = p.id
        save(profiles, "brick.profiles")
        return p.id
    }

    func delete(_ profile: BrickProfile) {
        guard !isOn(profile.id) else { message = "Turn it off first."; return }
        profiles.removeAll { $0.id == profile.id }
        // Its tags go back to starting whichever mode is selected.
        for i in tags.indices where tags[i].profileID == profile.id { tags[i].profileID = nil }
        save(tags, "brick.tags")
        if profiles.isEmpty { profiles = [BrickProfile(name: "Focus")] }
        if selectedID == profile.id { selectedID = profiles.first?.id }
        save(profiles, "brick.profiles")
    }

    // MARK: Schedules

    @discardableResult
    func addSchedule() -> UUID {
        let s = BrickSchedule(name: "\(selected?.name ?? "Brick") schedule", profileID: selectedID)
        schedules.append(s)
        save(schedules, "brick.schedules")
        return s.id
    }

    func update(_ schedule: BrickSchedule) {
        guard let i = schedules.firstIndex(where: { $0.id == schedule.id }) else { return }
        schedules[i] = schedule
        save(schedules, "brick.schedules")
    }

    func delete(_ schedule: BrickSchedule) {
        schedules.removeAll { $0.id == schedule.id }
        save(schedules, "brick.schedules")
    }

    /// When a schedule ends today, if it has an end time; past midnight if it ends before it starts.
    func endDate(of s: BrickSchedule, on day: Date) -> Date? {
        let cal = Calendar.current
        guard let h = s.endHour,
              let start = cal.date(bySettingHour: s.hour, minute: s.minute, second: 0, of: day),
              var end = cal.date(bySettingHour: h, minute: s.endMinute ?? 0, second: 0, of: day) else { return nil }
        if end <= start { end = cal.date(byAdding: .day, value: 1, to: end) ?? end }
        return end
    }

    /// A schedule starts its mode once a day: within an hour of its start time, or any time before its end
    /// time if it has one. Checked while the app runs or when it opens.
    private func checkSchedules() {
        guard authorized else { return }
        let cal = Calendar.current
        let now = Date()
        for s in schedules where s.enabled && s.weekdays.contains(cal.component(.weekday, from: now)) {
            guard let at = cal.date(bySettingHour: s.hour, minute: s.minute, second: 0, of: now) else { continue }
            let end = endDate(of: s, on: now)
            guard now >= at, now < (end ?? at.addingTimeInterval(3600)),
                  !(s.lastFired.map { cal.isDate($0, inSameDayAs: now) } ?? false),
                  let p = profiles.first(where: { $0.id == s.profileID }) ?? selected,
                  !isOn(p.id), p.lockdown || !isBlocking else { continue }
            var fired = s
            fired.lastFired = now
            update(fired)
            start(p, until: end)
        }
    }

    // MARK: Authorization

    func authorize() async {
        do {
            try await AuthorizationCenter.shared.requestAuthorization(for: .individual)
            authorized = AuthorizationCenter.shared.authorizationStatus == .approved
        } catch {
            message = "Screen Time access was not granted: \(error.localizedDescription)"
        }
    }

    // MARK: Tag

    /// Tap a new tag to add it as another key.
    func registerTag() {
        scan("Hold your phone to the new tag.") { [weak self] id in
            guard let self else { return }
            if let known = self.tags.first(where: { $0.id == id }) {
                self.message = "That tag is already registered as \(known.name)."
                return
            }
            self.tags.append(BrickTag(id: id, name: self.tags.isEmpty ? "My Brick" : "Tag \(self.tags.count + 1)"))
            self.save(self.tags, "brick.tags")
            self.message = "Tag registered."
        }
    }

    func update(_ tag: BrickTag) {
        guard let i = tags.firstIndex(where: { $0.id == tag.id }) else { return }
        guard !isKey(tags[i]) else { message = "\(tags[i].name) is ending something that's on. Turn it off first."; return }
        tags[i] = tag
        save(tags, "brick.tags")
    }

    func delete(_ tag: BrickTag) {
        guard !isKey(tag) else { message = "\(tag.name) is ending something that's on. Turn it off first."; return }
        tags.removeAll { $0.id == tag.id }
        save(tags, "brick.tags")
    }

    /// The mode a tag starts: its own, or the selected one.
    func profile(for tag: BrickTag) -> BrickProfile? {
        profiles.first { $0.id == tag.profileID } ?? selected
    }

    /// Whether a tag ends a mode: its own mode, or for Any tags, the running Brick and any lockdown with no tag of its own.
    func canEnd(_ id: UUID, with tag: BrickTag) -> Bool {
        if tag.profileID == id { return true }
        guard tag.profileID == nil else { return false }
        return id == blockingProfileID || !tags.contains { $0.profileID == id }
    }

    /// The tags that end a mode, by name.
    func keys(for id: UUID) -> String {
        tags.filter { canEnd(id, with: $0) }.map(\.name).joined(separator: " or ")
    }

    /// A tag that would end something on now can't be changed or removed, so nothing gets stuck on.
    func isKey(_ tag: BrickTag) -> Bool {
        (blockingProfileID.map { canEnd($0, with: tag) } ?? false) || lockdowns.contains { canEnd($0.profileID, with: tag) }
    }

    /// The main gesture: tap a tag to start its mode, or to end it.
    func tapTag() {
        guard authorized else { message = "Allow Screen Time access first."; return }
        guard hasTag else { message = "Register your Brick first."; return }
        let prompt = anyOn ? "Tap a Brick to start or end a mode." : "Tap a Brick to start blocking."
        scan(prompt) { [weak self] id in
            guard let self else { return }
            let (ok, text) = self.handleTag(id)
            if !ok { self.message = text }
        }
    }

    /// What a tag does, from the in-app scan or a Shortcuts automation: end its mode if it's on, or start it.
    /// Returns whether it did something, and a line saying what.
    @discardableResult
    func handleTag(_ id: String) -> (ok: Bool, text: String) {
        check()
        guard authorized else { return (false, "Allow Screen Time access first.") }
        guard let tag = tags.first(where: { $0.id == id }) else {
            return (false, "That is not one of your registered tags.")
        }
        // Its own mode; for an Any tag the running Brick, else a lockdown that has no tag of its own.
        let target = tag.profileID ?? blockingProfileID ?? lockdowns.first { canEnd($0.profileID, with: tag) }?.profileID
        if let on = target, isOn(on), canEnd(on, with: tag) {
            let name = profiles.first { $0.id == on }?.name ?? "Brick"
            end(on)
            return (true, "Ended \(name).")
        }
        guard let p = profile(for: tag) else { return (false, "No mode to start.") }
        guard !p.isEmpty else { return (false, "Pick apps or restrictions for \(p.name) first.") }
        if !p.lockdown, isBlocking {
            return (false, "\(blockingProfile?.name ?? "A Brick") is on. End it with \(keys(for: blockingProfileID!)) first.")
        }
        start(p)
        return (true, p.lockdown ? "\(p.name) lockdown on." : "Bricked \(p.name).")
    }

    /// Non-strict modes can be ended without the tag.
    func unlockWithoutTag(_ id: UUID) {
        guard let p = profiles.first(where: { $0.id == id }), !p.strict else { return }
        end(id)
    }

    /// Ends everything without a tag, from the small allowance.
    func emergencyUnbrick() {
        guard anyOn, emergencyLeft > 0 else { return }
        emergencyLeft -= 1
        defaults.set(emergencyLeft, forKey: "brick.emergencyLeft")
        if isBlocking { stop() }
        for l in lockdowns { end(l.profileID) }
    }

    // MARK: Blocking

    /// Starts a mode: a lockdown in its own store, or the Brick. `until` overrides the mode's timer (a schedule's end).
    private func start(_ p: BrickProfile, until: Date? = nil) {
        if p.isEmpty {
            message = "Pick apps or restrictions for \(p.name) first."
            return
        }
        let ends = until ?? p.timerMinutes.map { Date().addingTimeInterval(Double($0) * 60) }
        if p.lockdown {
            apply(p, to: lockdownStore(p.id))
            lockdowns.removeAll { $0.profileID == p.id }
            lockdowns.append(BrickLockdown(profileID: p.id, endsAt: ends))
            save(lockdowns, "brick.lockdowns")
            return
        }
        apply(p, to: settings)
        blockingProfileID = p.id
        endsAt = ends
        defaults.set(p.id.uuidString, forKey: "brick.active")
        defaults.set(endsAt?.timeIntervalSince1970 ?? 0, forKey: "brick.endsAt")
        now = Date()
        sessions.append(BrickSession(profileName: p.name, start: now))
        save(sessions, "brick.sessions")
        WidgetSync.brick(self)
    }

    /// Ends whichever kind of mode this is.
    private func end(_ id: UUID, byTimer: Bool = false) {
        if id == blockingProfileID {
            stop(byTimer: byTimer)
        } else {
            lockdownStore(id).clearAllSettings()
            lockdowns.removeAll { $0.profileID == id }
            save(lockdowns, "brick.lockdowns")
        }
    }

    private func lockdownStore(_ id: UUID) -> ManagedSettingsStore {
        ManagedSettingsStore(named: ManagedSettingsStore.Name("lockdown.\(id.uuidString)"))
    }

    /// Shields the mode's apps and sets its restrictions. nil leaves a setting as the user has it;
    /// clearing the store lifts them all.
    private func apply(_ p: BrickProfile, to store: ManagedSettingsStore) {
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

    private func stop(byTimer: Bool = false) {
        if let i = sessions.lastIndex(where: { $0.end == nil }) {
            sessions[i].end = byTimer ? (endsAt ?? Date()) : Date()
            sessions[i].byTimer = byTimer
            save(sessions, "brick.sessions")
        }
        settings.clearAllSettings()
        now = Date()
        blockingProfileID = nil
        endsAt = nil
        defaults.removeObject(forKey: "brick.active")
        defaults.removeObject(forKey: "brick.endsAt")
        WidgetSync.brick(self)
    }

    /// Timers and schedules are checked while the app runs and each time it opens.
    func check() {
        // The system's answer can arrive after launch, or change in Settings; never trust a single read.
        let approved = AuthorizationCenter.shared.authorizationStatus == .approved
        if approved != authorized { authorized = approved }
        if isBlocking { now = Date() }
        if let endsAt, endsAt <= Date(), isBlocking { stop(byTimer: true) }
        for l in lockdowns where (l.endsAt.map { $0 <= Date() } ?? false) { end(l.profileID, byTimer: true) }
        checkSchedules()
        WidgetSync.brick(self)
    }

    private func startTicker() {
        ticker = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.check() }
        }
    }

    #if DEBUG
    /// Sample sessions for screenshots, in memory only.
    func debugSeed() {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        func at(_ day: Int, _ h: Double) -> Date { cal.date(byAdding: .day, value: day, to: today)!.addingTimeInterval(h * 3600) }
        sessions = [
            BrickSession(profileName: "Mindfulness", start: at(-6, 9), end: at(-6, 10.6)),
            BrickSession(profileName: "Mindfulness", start: at(-4, 20), end: at(-4, 22.9)),
            BrickSession(profileName: "Deep work", start: at(-2, 13.5), end: at(-2, 15.2)),
            BrickSession(profileName: "Deep work", start: at(-1, 8), end: at(-1, 9.1)),
            BrickSession(profileName: "Mindfulness", start: at(-1, 19), end: at(-1, 20.4)),
            BrickSession(profileName: "Mindfulness", start: at(0, 13.5), end: at(0, 16)),
        ]
        profiles = [BrickProfile(name: "Mindfulness"), BrickProfile(name: "Deep work", strict: false, timerMinutes: 90)]
        selectedID = profiles.first?.id
        schedules = [BrickSchedule(name: "Mindfulness schedule", hour: 13, minute: 30, profileID: profiles.first?.id, enabled: false)]
        tags = [BrickTag(id: "04a3b2c1d4e580", name: "Desk", profileID: profiles.last?.id),
                BrickTag(id: "04f1e2d3c4b5a6", name: "Bedroom", profileID: profiles.first?.id)]
        emergencyLeft = 4
    }
    #endif

    // MARK: NFC

    private func scan(_ prompt: String, _ done: @escaping (String) -> Void) {
        guard NFCTagReaderSession.readingAvailable else {
            message = "This device cannot read NFC tags."
            return
        }
        onTag = done
        let s = NFCTagReaderSession(pollingOption: .iso14443, delegate: self, queue: nil)
        s?.alertMessage = prompt
        s?.begin()
        session = s
    }

    /// Hands the tag to whoever asked, once. Runs before the session is invalidated, so cleanup can't drop it.
    private func deliver(_ id: String) {
        let cb = onTag
        onTag = nil
        // Done with this scan: its closing invalidation shouldn't show an error.
        session = nil
        cb?(id)
    }
}

extension BrickStore: NFCTagReaderSessionDelegate {
    nonisolated func tagReaderSessionDidBecomeActive(_ session: NFCTagReaderSession) {}

    nonisolated func tagReaderSession(_ session: NFCTagReaderSession, didInvalidateWithError error: Error) {
        Task { @MainActor in
            // Only clear if this is still the current scan; an older session must not clear a newer one.
            guard self.session === session else { return }
            self.session = nil
            self.onTag = nil
            // Cancelling, or closing after a good read, isn't worth a message; anything else is.
            let code = (error as? NFCReaderError)?.code
            if code != .readerSessionInvalidationErrorUserCanceled,
               code != .readerSessionInvalidationErrorFirstNDEFTagRead {
                self.message = "NFC scan failed: \(error.localizedDescription)"
            }
        }
    }

    nonisolated func tagReaderSession(_ session: NFCTagReaderSession, didDetect tags: [NFCTag]) {
        guard let first = tags.first else { return }
        var uid: Data?
        switch first {
        case .miFare(let t): uid = t.identifier
        case .iso7816(let t): uid = t.identifier
        case .iso15693(let t): uid = t.identifier
        case .feliCa(let t): uid = t.currentIDm
        @unknown default: break
        }
        guard let uid else {
            session.invalidate(errorMessage: "Could not read this tag.")
            return
        }
        let id = uid.map { String(format: "%02x", $0) }.joined()
        session.connect(to: first) { error in
            if error != nil {
                session.invalidate(errorMessage: "Could not read this tag.")
                return
            }
            Task { @MainActor in
                self.deliver(id)
                session.alertMessage = "Done."
                session.invalidate()
            }
        }
    }
}
#endif
