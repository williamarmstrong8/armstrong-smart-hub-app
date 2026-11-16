import Foundation
import Observation
import UserNotifications

/// What's around the body data, from the hub (/api/mobile/fitness/context):
/// calendar load per day, spending per night, and charges that look like
/// drinks on nights the alcohol log hasn't answered. Kept on the phone so the
/// briefing and today's workout work offline.
///
/// A likely bar charge becomes a notification: "Drinks at Kingston Hall last
/// night?" with a button per count. The answer goes into the alcohol log, and
/// back to the hub so it learns which merchants are bars.
@MainActor
@Observable
final class LifeContext {
    static let shared = LifeContext()

    struct CalendarDay: Codable {
        var day: String
        var meetingHours: Double
        var meetings: Int
        var firstStart: Int?
        var lastEnd: Int?
        var backToBack: Int
    }

    struct SpendNight: Codable {
        var night: String
        var bar: Double
        var delivery: Double
        var rideshare: Double
    }

    struct BarCharge: Codable {
        var id: String
        var night: String
        var merchant: String
        var amount: Double
        var likelihood: Double
    }

    struct Snapshot: Codable {
        var calendar: [CalendarDay]?
        var spending: [SpendNight]
        var barCharges: [BarCharge]
    }

    private(set) var snapshot: Snapshot?
    var api: APIClient?

    private static let url = URL.applicationSupportDirectory.appending(path: "Fitness/context.json")
    private static let askedKey = "context.askedCharges"

    init() {
        if !Demo.isOn, let data = try? Data(contentsOf: Self.url), let saved = try? JSONDecoder().decode(Snapshot.self, from: data) {
            snapshot = saved
        }
    }

    func load() async {
        guard let api, !Demo.isOn else { return }
        guard let fresh: Snapshot = try? await api.get("/api/mobile/fitness/context?days=90") else { return }
        snapshot = fresh
        try? FileManager.default.createDirectory(at: Self.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(fresh) { try? data.write(to: Self.url, options: .atomic) }
        await askAboutCharges()
    }

    // MARK: Lookups

    func calendar(_ day: String) -> CalendarDay? { snapshot?.calendar?.first { $0.day == day } }
    var hasCalendar: Bool { snapshot?.calendar != nil }
    func spending(_ night: String) -> SpendNight? { snapshot?.spending.first { $0.night == night } }

    // MARK: "Drinks at …?"

    nonisolated static let categoryPrefix = "drinks.charge"
    private nonisolated static let category = "drinks.charge.ask"
    private nonisolated static let none = "drinks.none"
    private nonisolated static let unsure = "drinks.unsure"
    private nonisolated static let countPrefix = "drinks.count."

    nonisolated static var notificationCategory: UNNotificationCategory {
        var actions = (1...3).map { n in
            UNNotificationAction(identifier: countPrefix + "\(n)", title: n == 1 ? "1 drink" : "\(n) drinks", options: [])
        }
        actions.append(UNNotificationAction(identifier: countPrefix + "4", title: "4 or more", options: []))
        actions.append(UNNotificationAction(identifier: unsure, title: "Drank, not sure how many", options: []))
        actions.append(UNNotificationAction(identifier: none, title: "No drinks", options: []))
        return UNNotificationCategory(identifier: category, actions: actions, intentIdentifiers: [])
    }

    /// One notification per unanswered night, about its likeliest charge, asked once.
    private func askAboutCharges() async {
        guard let charges = snapshot?.barCharges, !charges.isEmpty else { return }
        var asked = Set(UserDefaults.standard.stringArray(forKey: Self.askedKey) ?? [])
        let byNight = Dictionary(grouping: charges, by: \.night)
        for (night, list) in byNight {
            guard !AlcoholStore.shared.isAnswered(night), let top = list.max(by: { $0.likelihood < $1.likelihood }),
                  !asked.contains(top.id) else { continue }
            asked.insert(top.id)
            let content = UNMutableNotificationContent()
            content.title = "Drinks at \(top.merchant)?"
            content.body = "\(top.amount.formatted(.currency(code: "USD"))) on \(Self.nightName(night)). Long-press to log how many."
            content.sound = .default
            content.categoryIdentifier = Self.category
            content.userInfo = ["night": night, "merchant": top.merchant]
            try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "drinks.charge.\(night)", content: content, trigger: nil))
        }
        UserDefaults.standard.set(Array(asked.suffix(200)), forKey: Self.askedKey)
    }

    private static func nightName(_ night: String) -> String {
        if night == AlcoholStore.night(of: Date.now.addingTimeInterval(-12 * 3600)) { return "last night" }
        let parts = night.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3, let date = Calendar.current.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])) else { return night }
        return date.formatted(.dateTime.weekday(.wide)) + " night"
    }

    /// A count, "not sure" or "no drinks" from the notification: logged, and taught to the hub.
    func answer(action: String, userInfo: [AnyHashable: Any]) async {
        guard let night = userInfo["night"] as? String, let merchant = userInfo["merchant"] as? String else { return }
        let alcohol = AlcoholStore.shared
        let drank: Bool
        switch action {
        case Self.none:
            alcohol.markDry(night)
            drank = false
        case Self.unsure:
            alcohol.markDrank(night)
            drank = true
        case let a where a.hasPrefix(Self.countPrefix):
            let n = Int(a.dropFirst(Self.countPrefix.count)) ?? 1
            alcohol.log([Self.usualKind: n], night: night, time: .evening)
            drank = true
        default:
            await CheckinReminders.route(.fitness)
            return
        }
        struct Teach: Encodable { var merchant: String; var drinks: Bool }
        if let api {
            let _: Empty? = try? await api.send(api.request("/api/mobile/fitness/context", method: "PUT", body: Teach(merchant: merchant, drinks: drank)))
        }
    }

    /// The kind you log most, for a count answered from a notification.
    private static var usualKind: DrinkKind {
        let counts = Dictionary(grouping: AlcoholStore.shared.entries, by: \.kind).mapValues { $0.reduce(0) { $0 + $1.count } }
        return counts.max(by: { $0.value < $1.value })?.key ?? .beer
    }
}
