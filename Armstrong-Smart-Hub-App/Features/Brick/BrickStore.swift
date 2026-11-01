import SwiftUI

#if os(iOS)
import FamilyControls
import ManagedSettings
import CoreNFC

/// Tap-to-block, like Brick. The shield itself is enforced by iOS (Managed Settings);
/// the tag is a plain NFC tag whose ID is the key. Nothing leaves the phone.
/// One store for the whole app, so timers and schedules are checked whichever tab is open.
@MainActor @Observable
final class BrickStore: NSObject {
    static let shared = BrickStore()

    /// Brick's own allowance: a few unlocks without the tag, for real emergencies.
    static let emergencyAllowance = 5

    private(set) var profiles: [BrickProfile] = []
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

    @ObservationIgnored private let defaults = BrickEngine.defaults
    @ObservationIgnored private var session: NFCTagReaderSession?
    /// Handles a scanned tag; returns what to show in the NFC sheet when it didn't work.
    @ObservationIgnored private var onTag: ((String) -> String?)?
    @ObservationIgnored private var ticker: Timer?

    override private init() {
        super.init()
        BrickEngine.moveFromStandardDefaults()
        profiles = load([BrickProfile].self, "brick.profiles") ?? []
        if profiles.isEmpty { profiles = [BrickProfile(name: "Focus")] }
        tags = load([BrickTag].self, "brick.tags") ?? []
        // Tags used to be able to start "whichever mode is selected"; now each has its own,
        // so those take the mode that was selected. The single tag from before tags had names comes along too.
        let wasSelected = defaults.string(forKey: "brick.selected").flatMap(UUID.init(uuidString:))
        let fallback = profiles.first { $0.id == wasSelected }?.id ?? profiles.first?.id
        if tags.isEmpty, let old = defaults.string(forKey: "brick.tag") {
            tags = [BrickTag(id: old, name: "My Brick")]
        }
        if tags.contains(where: { $0.profileID == nil }) {
            for i in tags.indices where tags[i].profileID == nil { tags[i].profileID = fallback }
            save(tags, "brick.tags")
        }
        if defaults.object(forKey: "brick.emergencyLeft") != nil {
            emergencyLeft = defaults.integer(forKey: "brick.emergencyLeft")
        }
        reload()
        // After reload, so a lockdown that's on keeps the tag that started it.
        pairLockdowns()
        authorized = AuthorizationCenter.shared.authorizationStatus == .approved
        if authorized { BrickEngine.syncSchedules() }
        startTicker()
        check()
    }

    var isBlocking: Bool { blockingProfileID != nil }
    /// A Brick or any lockdown is on.
    var anyOn: Bool { isBlocking || !lockdowns.isEmpty }
    func isOn(_ id: UUID) -> Bool { blockingProfileID == id || lockdowns.contains { $0.profileID == id } }
    var activeLockdowns: [BrickProfile] { lockdowns.compactMap { l in profiles.first { $0.id == l.profileID } } }
    var hasTag: Bool { !tags.isEmpty }
    var blockingProfile: BrickProfile? { profiles.first { $0.id == blockingProfileID } }
    /// The session running now, if bricked.
    var current: BrickSession? { sessions.last { $0.end == nil } }

    private func load<T: Decodable>(_ type: T.Type, _ key: String) -> T? { BrickEngine.load(type, key) }
    private func save<T: Encodable>(_ value: T, _ key: String) { BrickEngine.save(value, key) }

    /// What's on, the sessions and the schedules can change from the BrickMonitor extension while the app
    /// is closed, so they're read back from the shared state rather than trusted from memory.
    private func reload() {
        #if DEBUG
        if seeded { return }
        #endif
        let active = BrickEngine.blockingProfileID
        if active != blockingProfileID { blockingProfileID = active }
        let ends = BrickEngine.endsAt
        if ends != endsAt { endsAt = ends }
        let l = BrickEngine.lockdowns
        if l != lockdowns { lockdowns = l }
        let s = BrickEngine.sessions
        if s != sessions { sessions = s }
        let sc = BrickEngine.schedules
        if sc != schedules { schedules = sc }
    }

    // MARK: Modes

    func update(_ profile: BrickProfile) {
        guard let i = profiles.firstIndex(where: { $0.id == profile.id }) else { return }
        profiles[i] = profile
        save(profiles, "brick.profiles")
        if profile.lockdown { pairLockdowns() }
    }

    /// A lockdown belongs to one tag. If several point at one (from before pairing, or a mode just made a
    /// lockdown), the one that started it keeps it, else the first; the rest lose their mode.
    private func pairLockdowns() {
        var changed = false
        for p in profiles where p.lockdown {
            let paired = tags.indices.filter { tags[$0].profileID == p.id }
            guard paired.count > 1 else { continue }
            let starter = lockdowns.first { $0.profileID == p.id }?.tagID
            let keep = paired.first { tags[$0].id == starter } ?? paired[0]
            for i in paired where i != keep { tags[i].profileID = nil }
            changed = true
        }
        if changed { save(tags, "brick.tags") }
    }

    /// The tag a lockdown is paired with, if any.
    func pairedTag(_ id: UUID) -> BrickTag? {
        guard profiles.first(where: { $0.id == id })?.lockdown == true else { return nil }
        return tags.first { $0.profileID == id }
    }

    @discardableResult
    func addProfile() -> UUID {
        let p = BrickProfile(name: "Mode \(profiles.count + 1)")
        profiles.append(p)
        save(profiles, "brick.profiles")
        return p.id
    }

    func delete(_ profile: BrickProfile) {
        guard !isOn(profile.id) else { message = "Turn it off first."; return }
        profiles.removeAll { $0.id == profile.id }
        // Its tags have no mode until another is picked.
        for i in tags.indices where tags[i].profileID == profile.id { tags[i].profileID = nil }
        save(tags, "brick.tags")
        if profiles.isEmpty { profiles = [BrickProfile(name: "Focus")] }
        save(profiles, "brick.profiles")
    }

    // MARK: Schedules

    @discardableResult
    func addSchedule() -> UUID {
        let s = BrickSchedule(name: "\(profiles.first?.name ?? "Brick") schedule", profileID: profiles.first?.id)
        schedules.append(s)
        save(schedules, "brick.schedules")
        BrickEngine.syncSchedules()
        return s.id
    }

    func update(_ schedule: BrickSchedule) {
        guard let i = schedules.firstIndex(where: { $0.id == schedule.id }) else { return }
        // Renaming (each keystroke) doesn't need iOS to re-register anything.
        var old = schedules[i], new = schedule
        old.name = ""; new.name = ""; old.lastFired = nil; new.lastFired = nil
        schedules[i] = schedule
        save(schedules, "brick.schedules")
        if old != new { BrickEngine.syncSchedules() }
    }

    func delete(_ schedule: BrickSchedule) {
        schedules.removeAll { $0.id == schedule.id }
        save(schedules, "brick.schedules")
        BrickEngine.syncSchedules()
    }

    func endDate(of s: BrickSchedule, on day: Date) -> Date? { BrickEngine.endDate(of: s, on: day) }

    /// Backup for the extension: starts a schedule's mode once a day, within an hour of its start time or any
    /// time before its end time. Checked while the app runs or when it opens.
    private func checkSchedules() {
        guard authorized else { return }
        let cal = Calendar.current
        let now = Date()
        for s in schedules where s.enabled {
            guard let at = cal.date(bySettingHour: s.hour, minute: s.minute, second: 0, of: now) else { continue }
            guard now >= at, now < (endDate(of: s, on: now) ?? at.addingTimeInterval(3600)) else { continue }
            BrickEngine.fire(s.id, now: now)
        }
        reload()
    }

    // MARK: Authorization

    func authorize() async {
        do {
            try await AuthorizationCenter.shared.requestAuthorization(for: .individual)
            authorized = AuthorizationCenter.shared.authorizationStatus == .approved
            if authorized { BrickEngine.syncSchedules() }
        } catch {
            message = "Screen Time access was not granted: \(error.localizedDescription)"
        }
    }

    // MARK: Tag

    /// Tap a new tag to add it as another key. It starts on the first Brick mode, never a lockdown, since those are
    /// paired with their own tag; `added` gets its ID so its page can open.
    func registerTag(added: @escaping (String) -> Void = { _ in }) {
        scan("Hold your phone to the new tag.") { [weak self] id in
            guard let self else { return nil }
            if let known = self.tags.first(where: { $0.id == id }) {
                return "That tag is already registered as \(known.name)."
            }
            self.tags.append(BrickTag(id: id, name: self.tags.isEmpty ? "My Brick" : "Tag \(self.tags.count + 1)",
                                      profileID: self.profiles.first { !$0.lockdown }?.id))
            self.save(self.tags, "brick.tags")
            added(id)
            return nil
        }
    }

    func update(_ tag: BrickTag) {
        guard let i = tags.firstIndex(where: { $0.id == tag.id }) else { return }
        guard !isKey(tags[i]) else { message = "\(tags[i].name) is ending something that's on. Turn it off first."; return }
        if let new = tag.profileID, new != tags[i].profileID {
            // Pointing a tag at a mode that's on would make it a key mid-session.
            guard !isOn(new) else { message = "That mode is on. Pick it once it's off."; return }
            if let other = pairedTag(new), other.id != tag.id {
                message = "That lockdown is paired with \(other.name). Only one tag can end it."
                return
            }
        }
        tags[i] = tag
        save(tags, "brick.tags")
    }

    func delete(_ tag: BrickTag) {
        guard !isKey(tag) else { message = "\(tag.name) is ending something that's on. Turn it off first."; return }
        tags.removeAll { $0.id == tag.id }
        save(tags, "brick.tags")
    }

    /// The mode a tag starts and ends.
    func profile(for tag: BrickTag) -> BrickProfile? {
        profiles.first { $0.id == tag.profileID }
    }

    /// Only a mode's own tags end it. A lockdown only ends with the tag that started it, so a tag pointed at it
    /// afterwards can't; one a schedule started ends with its paired tag.
    func canEnd(_ id: UUID, with tag: BrickTag) -> Bool {
        if let l = lockdowns.first(where: { $0.profileID == id }), let starter = l.tagID { return tag.id == starter }
        return tag.profileID == id
    }

    /// The tags that end a mode, by name.
    func keys(for id: UUID) -> String {
        let names = tags.filter { canEnd(id, with: $0) }.map(\.name)
        return names.isEmpty ? "its tag" : names.joined(separator: " or ")
    }

    /// A tag that would end something on now can't be changed or removed, so nothing gets stuck on.
    func isKey(_ tag: BrickTag) -> Bool {
        (blockingProfileID.map { canEnd($0, with: tag) } ?? false) || lockdowns.contains { canEnd($0.profileID, with: tag) }
    }

    /// What an in-app scan is for, so a tag only does what was tapped. `.main` is the Brick button: it unbricks
    /// with the Brick's own tag, or starts a tag's mode that's off. `.ending` is a lockdown's chip: only its tag works.
    enum TagScan { case main, ending(UUID) }

    /// The main gesture: tap a tag to start its mode, or to end what was tapped. A wrong tag says so in the
    /// NFC sheet and changes nothing.
    func tapTag(_ purpose: TagScan = .main) {
        guard authorized else { message = "Allow Screen Time access first."; return }
        guard hasTag else { message = "Register your Brick first."; return }
        let prompt: String
        switch purpose {
        case .main: prompt = isBlocking ? "Tap \(keys(for: blockingProfileID!)) to unbrick." : "Tap a Brick to start blocking."
        case .ending(let target): prompt = "Tap \(keys(for: target)) to end \(profiles.first { $0.id == target }?.name ?? "it")."
        }
        scan(prompt) { [weak self] id in
            guard let self else { return nil }
            let (ok, text) = self.handleTag(id, purpose)
            return ok ? nil : text
        }
    }

    /// An in-app scan: ends only what was tapped, and never a mode that's on with a different tag.
    private func handleTag(_ id: String, _ purpose: TagScan) -> (ok: Bool, text: String) {
        check()
        guard authorized else { return (false, "Allow Screen Time access first.") }
        guard let tag = tags.first(where: { $0.id == id }) else { return (false, "Wrong tag. That one isn't registered.") }
        let target: UUID?
        switch purpose {
        case .ending(let l): target = l
        case .main: target = blockingProfileID
        }
        if let target, canEnd(target, with: tag) {
            let name = profiles.first { $0.id == target }?.name ?? "it"
            end(target)
            return (true, "Ended \(name).")
        }
        let wrong = target.map { t in "Wrong tag. Only \(keys(for: t)) ends \(profiles.first { $0.id == t }?.name ?? "it")." }
        if case .ending = purpose { return (false, wrong ?? "Wrong tag.") }
        // The Brick button with another tag: it can start that tag's mode if it's off, but never end anything.
        guard let p = profile(for: tag) else { return (false, wrong ?? "Pick a mode for \(tag.name) first.") }
        if isOn(p.id) { return (false, wrong ?? "\(p.name) is on. Tap its lockdown to end it.") }
        if !p.lockdown, isBlocking { return (false, wrong ?? "Wrong tag.") }
        guard !p.isEmpty else { return (false, "Pick apps or restrictions for \(p.name) first.") }
        start(p, tagID: tag.id)
        return (true, p.lockdown ? "\(p.name) lockdown on." : "Bricked \(p.name).")
    }

    /// What a tag does from a Shortcuts automation, tapped outside the app: end its mode if it's on, or start it.
    /// Returns whether it did something, and a line saying what.
    @discardableResult
    func handleTag(_ id: String) -> (ok: Bool, text: String) {
        check()
        guard authorized else { return (false, "Allow Screen Time access first.") }
        guard let tag = tags.first(where: { $0.id == id }) else {
            return (false, "That is not one of your registered tags.")
        }
        guard let p = profile(for: tag) else { return (false, "Pick a mode for \(tag.name) first.") }
        if isOn(p.id) {
            guard canEnd(p.id, with: tag) else { return (false, "Only \(keys(for: p.id)) ends \(p.name).") }
            end(p.id)
            return (true, "Ended \(p.name).")
        }
        guard !p.isEmpty else { return (false, "Pick apps or restrictions for \(p.name) first.") }
        if !p.lockdown, isBlocking {
            return (false, "\(blockingProfile?.name ?? "A Brick") is on. End it with \(keys(for: blockingProfileID!)) first.")
        }
        start(p, tagID: tag.id)
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
        if let id = blockingProfileID { end(id) }
        for l in lockdowns { end(l.profileID) }
    }

    // MARK: Blocking

    /// Starts a mode: a lockdown in its own store, or the Brick. `until` overrides the mode's timer (a schedule's end).
    private func start(_ p: BrickProfile, until: Date? = nil, tagID: String? = nil) {
        guard BrickEngine.start(p, until: until, tagID: tagID) else {
            message = "Pick apps or restrictions for \(p.name) first."
            return
        }
        now = Date()
        reload()
        WidgetSync.brick(self)
    }

    /// Ends whichever kind of mode this is.
    private func end(_ id: UUID, byTimer: Bool = false) {
        BrickEngine.end(id, byTimer: byTimer)
        now = Date()
        reload()
        WidgetSync.brick(self)
    }

    /// Timers and schedules are checked while the app runs and each time it opens.
    func check() {
        // The system's answer can arrive after launch, or change in Settings; never trust a single read.
        let approved = AuthorizationCenter.shared.authorizationStatus == .approved
        if approved != authorized { authorized = approved }
        reload()
        if isBlocking { now = Date() }
        if let endsAt, endsAt <= Date(), let id = blockingProfileID { end(id, byTimer: true) }
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
    @ObservationIgnored private var seeded = false

    /// Sample sessions for screenshots, in memory only; the saved state isn't read back while they show.
    func debugSeed() {
        seeded = true
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
        schedules = [BrickSchedule(name: "Mindfulness schedule", hour: 13, minute: 30, profileID: profiles.first?.id, enabled: false)]
        tags = [BrickTag(id: "04a3b2c1d4e580", name: "Desk", profileID: profiles.last?.id),
                BrickTag(id: "04f1e2d3c4b5a6", name: "Bedroom", profileID: profiles.first?.id)]
        emergencyLeft = 4
    }
    #endif

    // MARK: NFC

    private func scan(_ prompt: String, _ done: @escaping (String) -> String?) {
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
    /// Returns what went wrong, for the sheet.
    private func deliver(_ id: String) -> String? {
        let cb = onTag
        onTag = nil
        // Done with this scan: its closing invalidation shouldn't show an error.
        session = nil
        return cb?(id)
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
                // A wrong tag shows in the sheet itself, so it's clear nothing changed.
                if let problem = self.deliver(id) {
                    session.invalidate(errorMessage: problem)
                } else {
                    session.alertMessage = "Done."
                    session.invalidate()
                }
            }
        }
    }
}
#endif
