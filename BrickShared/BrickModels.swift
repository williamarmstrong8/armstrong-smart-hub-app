import Foundation

#if os(iOS)
import FamilyControls

// Brick's saved shapes, shared by the app and the BrickMonitor extension, which starts and ends
// schedules and timers while the app is closed.

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
    /// The one mode this tag starts and ends. nil until one is picked (or after its mode is deleted).
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
#endif
