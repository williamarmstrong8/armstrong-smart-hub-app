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

    var blockedCount: Int {
        selection.applicationTokens.count + selection.categoryTokens.count + selection.webDomainTokens.count
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

/// Bricks the phone at a time of day on chosen weekdays. The tag still ends it.
struct BrickSchedule: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var hour = 9
    var minute = 0
    /// Calendar weekdays, 1 is Sunday.
    var weekdays: Set<Int> = [2, 3, 4, 5, 6]
    var profileID: UUID?
    var enabled = true
    /// The last day it bricked, so it fires once a day.
    var lastFired: Date?
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
    private(set) var tagID: String?
    private(set) var blockingProfileID: UUID?
    private(set) var endsAt: Date?
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
        tagID = defaults.string(forKey: "brick.tag")
        if defaults.object(forKey: "brick.emergencyLeft") != nil {
            emergencyLeft = defaults.integer(forKey: "brick.emergencyLeft")
        }
        if let raw = defaults.string(forKey: "brick.active"), let id = UUID(uuidString: raw) {
            blockingProfileID = id
            let t = defaults.double(forKey: "brick.endsAt")
            endsAt = t > 0 ? Date(timeIntervalSince1970: t) : nil
        }
        authorized = AuthorizationCenter.shared.authorizationStatus == .approved
        startTicker()
        check()
    }

    var isBlocking: Bool { blockingProfileID != nil }
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
        guard profile.id != blockingProfileID else { message = "Unbrick first."; return }
        profiles.removeAll { $0.id == profile.id }
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

    /// A schedule bricks within an hour of its start time, once a day, while the app runs or when it opens.
    private func checkSchedules() {
        guard !isBlocking, authorized else { return }
        let cal = Calendar.current
        let now = Date()
        for s in schedules where s.enabled && s.weekdays.contains(cal.component(.weekday, from: now)) {
            guard let at = cal.date(bySettingHour: s.hour, minute: s.minute, second: 0, of: now),
                  now >= at, now < at.addingTimeInterval(3600),
                  !(s.lastFired.map { cal.isDate($0, inSameDayAs: now) } ?? false),
                  let p = profiles.first(where: { $0.id == s.profileID }) ?? selected else { continue }
            var fired = s
            fired.lastFired = now
            update(fired)
            start(p)
            return
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

    /// Tap a tag to make it the only key. Replaces any earlier tag.
    func registerTag() {
        guard !isBlocking else { message = "Unbrick before changing the tag."; return }
        scan("Hold your phone to the Brick tag to register it.") { [weak self] id in
            self?.tagID = id
            self?.defaults.set(id, forKey: "brick.tag")
            self?.message = "Tag registered."
        }
    }

    /// The main gesture: tap the tag to start or stop blocking.
    func tapTag() {
        guard authorized else { message = "Allow Screen Time access first."; return }
        guard tagID != nil else { message = "Register your Brick first."; return }
        let prompt = isBlocking ? "Tap your Brick to unbrick." : "Tap your Brick to start blocking."
        scan(prompt) { [weak self] id in
            guard let self else { return }
            guard id == self.tagID else { self.message = "That is not your registered Brick."; return }
            if self.isBlocking {
                self.stop()
            } else if let p = self.selected {
                self.start(p)
            }
        }
    }

    /// Non-strict modes can be unlocked without the tag.
    func unlockWithoutTag() {
        guard let p = blockingProfile, !p.strict else { return }
        stop()
    }

    /// Unbrick without the tag, from the small allowance.
    func emergencyUnbrick() {
        guard isBlocking, emergencyLeft > 0 else { return }
        emergencyLeft -= 1
        defaults.set(emergencyLeft, forKey: "brick.emergencyLeft")
        stop()
    }

    // MARK: Blocking

    private func start(_ p: BrickProfile) {
        let s = p.selection
        if p.blockedCount == 0 {
            message = "Pick apps to block in \(p.name) first."
            return
        }
        settings.shield.applications = s.applicationTokens.isEmpty ? nil : s.applicationTokens
        settings.shield.applicationCategories = s.categoryTokens.isEmpty ? nil : .specific(s.categoryTokens)
        settings.shield.webDomains = s.webDomainTokens.isEmpty ? nil : s.webDomainTokens
        settings.shield.webDomainCategories = s.categoryTokens.isEmpty ? nil : .specific(s.categoryTokens)
        blockingProfileID = p.id
        endsAt = p.timerMinutes.map { Date().addingTimeInterval(Double($0) * 60) }
        defaults.set(p.id.uuidString, forKey: "brick.active")
        defaults.set(endsAt?.timeIntervalSince1970 ?? 0, forKey: "brick.endsAt")
        now = Date()
        sessions.append(BrickSession(profileName: p.name, start: now))
        save(sessions, "brick.sessions")
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
    }

    /// Timers and schedules are checked while the app runs and each time it opens.
    func check() {
        // The system's answer can arrive after launch, or change in Settings; never trust a single read.
        let approved = AuthorizationCenter.shared.authorizationStatus == .approved
        if approved != authorized { authorized = approved }
        if isBlocking { now = Date() }
        if let endsAt, endsAt <= Date(), isBlocking { stop(byTimer: true) }
        checkSchedules()
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
        tagID = "04a3b2c1d4e580"
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
