import SwiftUI

#if os(iOS)
import FamilyControls
import ManagedSettings
import CoreNFC

/// One blocking profile: which apps to shield, whether only the tag can unlock, and an optional timer.
struct BrickProfile: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var selection = FamilyActivitySelection()
    /// Strict: only the registered tag unlocks. Not strict: the in-app button also works.
    var strict = true
    /// Minutes until blocking ends by itself. nil means until the tag is tapped.
    var timerMinutes: Int?
}

/// Tap-to-block, like Brick. The shield itself is enforced by iOS (Managed Settings);
/// the tag is a plain NFC tag whose ID is the key. Nothing leaves the phone.
@MainActor @Observable
final class BrickStore: NSObject {
    private(set) var profiles: [BrickProfile] = []
    var selectedID: UUID?
    private(set) var tagID: String?
    private(set) var blockingProfileID: UUID?
    private(set) var endsAt: Date?
    private(set) var authorized = false
    var message: String?

    @ObservationIgnored private let settings = ManagedSettingsStore()
    @ObservationIgnored private let defaults = UserDefaults.standard
    @ObservationIgnored private var session: NFCTagReaderSession?
    @ObservationIgnored private var onTag: ((String) -> Void)?
    @ObservationIgnored private var ticker: Timer?

    override init() {
        super.init()
        if let data = defaults.data(forKey: "brick.profiles"),
           let saved = try? JSONDecoder().decode([BrickProfile].self, from: data) {
            profiles = saved
        }
        if profiles.isEmpty { profiles = [BrickProfile(name: "Focus")] }
        selectedID = profiles.first?.id
        tagID = defaults.string(forKey: "brick.tag")
        if let raw = defaults.string(forKey: "brick.active"), let id = UUID(uuidString: raw) {
            blockingProfileID = id
            let t = defaults.double(forKey: "brick.endsAt")
            endsAt = t > 0 ? Date(timeIntervalSince1970: t) : nil
        }
        authorized = AuthorizationCenter.shared.authorizationStatus == .approved
        startTicker()
        checkTimer()
    }

    var isBlocking: Bool { blockingProfileID != nil }
    var selected: BrickProfile? { profiles.first { $0.id == selectedID } }
    var blockingProfile: BrickProfile? { profiles.first { $0.id == blockingProfileID } }

    // MARK: Profiles

    func update(_ profile: BrickProfile) {
        guard let i = profiles.firstIndex(where: { $0.id == profile.id }) else { return }
        profiles[i] = profile
        saveProfiles()
    }

    func addProfile() {
        let p = BrickProfile(name: "Profile \(profiles.count + 1)")
        profiles.append(p)
        selectedID = p.id
        saveProfiles()
    }

    func delete(_ profile: BrickProfile) {
        guard profile.id != blockingProfileID else { message = "Unlock first."; return }
        profiles.removeAll { $0.id == profile.id }
        if profiles.isEmpty { profiles = [BrickProfile(name: "Focus")] }
        if selectedID == profile.id { selectedID = profiles.first?.id }
        saveProfiles()
    }

    private func saveProfiles() {
        if let data = try? JSONEncoder().encode(profiles) { defaults.set(data, forKey: "brick.profiles") }
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
        guard !isBlocking else { message = "Unlock before changing the tag."; return }
        scan("Hold your phone to the Brick tag to register it.") { [weak self] id in
            self?.tagID = id
            self?.defaults.set(id, forKey: "brick.tag")
            self?.message = "Tag registered."
        }
    }

    /// The main gesture: tap the tag to start or stop blocking.
    func tapTag() {
        guard authorized else { message = "Allow Screen Time access first."; return }
        guard tagID != nil else { message = "Register your tag first."; return }
        let prompt = isBlocking ? "Tap your Brick to unlock." : "Tap your Brick to start blocking."
        scan(prompt) { [weak self] id in
            guard let self else { return }
            guard id == self.tagID else { self.message = "That is not your registered tag."; return }
            self.isBlocking ? self.stop() : self.start()
        }
    }

    /// Non-strict profiles can be unlocked without the tag.
    func unlockWithoutTag() {
        guard let p = blockingProfile, !p.strict else { return }
        stop()
    }

    // MARK: Blocking

    private func start() {
        guard let p = selected else { return }
        let s = p.selection
        if s.applicationTokens.isEmpty && s.categoryTokens.isEmpty && s.webDomainTokens.isEmpty {
            message = "Pick apps to block in this profile first."
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
    }

    private func stop() {
        settings.clearAllSettings()
        blockingProfileID = nil
        endsAt = nil
        defaults.removeObject(forKey: "brick.active")
        defaults.removeObject(forKey: "brick.endsAt")
    }

    /// The timer is checked while the app runs and each time it opens.
    func checkTimer() {
        if let endsAt, endsAt <= Date(), isBlocking { stop() }
    }

    private func startTicker() {
        ticker = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkTimer() }
        }
    }

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
}

extension BrickStore: NFCTagReaderSessionDelegate {
    nonisolated func tagReaderSessionDidBecomeActive(_ session: NFCTagReaderSession) {}

    nonisolated func tagReaderSession(_ session: NFCTagReaderSession, didInvalidateWithError error: Error) {
        Task { @MainActor in
            self.session = nil
            self.onTag = nil
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
            session.alertMessage = "Done."
            session.invalidate()
            Task { @MainActor in
                let cb = self.onTag
                self.onTag = nil
                cb?(id)
            }
        }
    }
}
#endif
