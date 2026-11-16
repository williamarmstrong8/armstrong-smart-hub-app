import Foundation
import UIKit
import UserNotifications

/// The check-in, twice a day, on the lock screen: at 8 am with the hub's
/// guess for the morning, and at 6 pm to confirm or correct the day. Each
/// notification answers itself without opening the app (queued in
/// CheckinStore if the hub is out of reach):
/// - a morning with a guess asks "Looks like you might be run down. Right?"
///   with Yes, No (I'm fine) and Edit;
/// - otherwise it's I'm fine, I'm sick and Edit.
/// Edit (or tapping the notification) opens Fitness on the check-in.
/// Mornings are time-sensitive, so they come through a Focus.
///
/// Local notifications can't change their text once scheduled, so the next
/// week is scheduled ahead with plain text and rescheduled whenever the
/// check-in page loads or an answer is saved: then today's carry the guess,
/// and a morning already answered is dropped. A push from the hub with the
/// same category and userInfo (day, guess, offered) is answered the same way.
///
/// This is also the app's notification delegate, so it hands the other kinds
/// (place arrivals, the health briefing) to their owners.
@MainActor
final class CheckinReminders: NSObject, UNUserNotificationCenterDelegate {
    static let shared = CheckinReminders()

    /// Set by the app once signed in, so a button can send its answer.
    var api: APIClient?

    private nonisolated static let category = "checkin"
    /// A morning with a guess: Yes / No, I'm fine / Edit.
    private nonisolated static let guessCategory = "checkin.guess"
    private nonisolated static let fine = "checkin.fine"
    private nonisolated static let sick = "checkin.sick"
    private nonisolated static let yes = "checkin.yes"
    private nonisolated static let no = "checkin.no"
    private nonisolated static let edit = "checkin.edit"
    private static let prefix = "checkin."
    private static let days = 7
    private static let times: [(slot: String, hour: Int)] = [("morning", 8), ("evening", 18)]

    private let center = UNUserNotificationCenter.current()

    /// Registers the buttons and takes over notification answers. Call at launch.
    func start() {
        center.delegate = self
        let edit = UNNotificationAction(identifier: Self.edit, title: "Edit", options: [.foreground],
                                        icon: UNNotificationActionIcon(systemImageName: "square.and.pencil"))
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Self.category, actions: [
                UNNotificationAction(identifier: Self.fine, title: "I'm fine", options: [], icon: UNNotificationActionIcon(systemImageName: "face.smiling")),
                UNNotificationAction(identifier: Self.sick, title: "I'm sick", options: [], icon: UNNotificationActionIcon(systemImageName: "thermometer.medium")),
                edit,
            ], intentIdentifiers: []),
            UNNotificationCategory(identifier: Self.guessCategory, actions: [
                UNNotificationAction(identifier: Self.yes, title: "Yes", options: [], icon: UNNotificationActionIcon(systemImageName: "checkmark")),
                UNNotificationAction(identifier: Self.no, title: "No, I'm fine", options: [], icon: UNNotificationActionIcon(systemImageName: "face.smiling")),
                edit,
            ], intentIdentifiers: []),
            PlaceMonitor.notificationCategory,
            HealthBriefing.notificationCategory,
        ])
    }

    /// Replaces the next week of check-in notifications from what the store knows now.
    func schedule(_ store: CheckinStore) async {
        guard !Demo.isOn else { return }
        guard (try? await center.requestAuthorization(options: [.alert, .sound])) == true else { return }
        let pending = await center.pendingNotificationRequests().map(\.identifier).filter { $0.hasPrefix(Self.prefix) }
        center.removePendingNotificationRequests(withIdentifiers: pending)

        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        for offset in 0..<Self.days {
            guard let date = calendar.date(byAdding: .day, value: offset, to: today) else { continue }
            let day = Self.dayString(date)
            let answer = store.entry(for: day).flatMap(MorningCheckin.sick)
            for (slot, hour) in Self.times {
                guard let fire = calendar.date(bySettingHour: hour, minute: 0, second: 0, of: date), fire > .now else { continue }
                // Nothing to ask in the morning once the day is answered.
                if slot == "morning", answer != nil { continue }
                let content = UNMutableNotificationContent()
                content.sound = .default
                content.userInfo = ["day": day]
                content.title = slot == "morning" ? "Morning check-in" : "Evening check-in"
                // Only today's morning knows the guess; later days get the plain question.
                if slot == "morning", offset == 0, let top = Self.topGuess(store) {
                    content.categoryIdentifier = Self.guessCategory
                    content.userInfo["guess"] = top.key
                    content.userInfo["offered"] = store.options.map(\.key)
                    content.body = "Looks like you might be \(top.label.lowercased()). Right?"
                    if let reason = top.reason, !reason.isEmpty { content.subtitle = reason }
                } else {
                    content.categoryIdentifier = Self.category
                    content.body = Self.text(slot: slot, answer: answer, guessedFine: offset == 0 && store.guess != nil)
                }
                // Mornings come through a Focus: the check-in is only useful on the day.
                if slot == "morning" { content.interruptionLevel = .timeSensitive }
                let trigger = UNCalendarNotificationTrigger(dateMatching: calendar.dateComponents([.year, .month, .day, .hour, .minute], from: fire), repeats: false)
                try? await center.add(UNNotificationRequest(identifier: "\(Self.prefix)\(slot).\(day)", content: content, trigger: trigger))
            }
        }
    }

    /// Morning without a guess to put to the person. Evening: confirm the morning's answer, or ask.
    private static func text(slot: String, answer: Bool?, guessedFine: Bool) -> String {
        if slot == "morning" { return guessedFine ? "Looks like a normal day. Feeling fine?" : "Feeling fine today?" }
        switch answer {
        case true?: return "Still feeling sick?"
        case false?: return "Still feeling fine?"
        case nil: return "How was today: fine or sick?"
        }
    }

    /// The hub's likeliest card for this morning when it isn't "fine": the one to ask about.
    private static func topGuess(_ store: CheckinStore) -> CheckinOption? {
        guard store.guess != nil else { return nil }
        if let first = store.guess?.options?.first, first.key != "fine", (first.probability ?? 1) >= CheckinStore.threshold { return first }
        guard let state = store.likely.first else { return nil }
        return CheckinOption(key: state.state, label: state.label, probability: state.probability, reason: state.reasons.first.map { "\($0.label) \($0.value), usually \($0.usual)" })
    }

    static func dayString(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = .current
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: date)
    }

    // MARK: UNUserNotificationCenterDelegate

    /// A button pressed on a check-in: save that day's answer, keeping the rest of its check-in.
    /// Edit, or a tap on the notification itself, opens Fitness. Other kinds go to their owners.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let action = response.actionIdentifier
        let content = response.notification.request.content
        let category = content.categoryIdentifier
        let day = content.userInfo["day"] as? String
        if category.hasPrefix(PlaceMonitor.categoryPrefix) {
            await PlaceMonitor.shared.handle(action: action)
            return
        }
        if category == HealthBriefing.category {
            await Self.open("fitness")
            return
        }
        guard category == Self.category || category == Self.guessCategory, let day else { return }
        switch action {
        case Self.fine: await answer(day: day, feeling: "fine", offered: ["sick"])
        case Self.sick: await answer(day: day, feeling: "sick", offered: ["sick"])
        case Self.yes, Self.no:
            guard let guess = content.userInfo["guess"] as? String else { return }
            let offered = (content.userInfo["offered"] as? [String]) ?? [guess]
            await answer(day: day, feeling: action == Self.yes ? guess : "fine", offered: offered.contains(guess) ? offered : offered + [guess])
        case Self.edit, UNNotificationDefaultActionIdentifier: await Self.open("fitness")
        default: break
        }
    }

    /// Check-ins, the briefing, places and Jarvis's build updates show over the open app too;
    /// anything else (the rest timer) stays as it was: not shown.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        let category = notification.request.content.categoryIdentifier
        let shown = [Self.category, Self.guessCategory, HealthBriefing.category, "jarvis"].contains(category)
            || category.hasPrefix(PlaceMonitor.categoryPrefix)
        return shown ? [.banner, .sound] : []
    }

    private func answer(day: String, feeling: String, offered: [String]) async {
        let store = CheckinStore.shared
        guard let api else { return }
        let task = UIApplication.shared.beginBackgroundTask(withName: "Check-in answer")
        defer { if task != .invalid { UIApplication.shared.endBackgroundTask(task) } }
        await store.answer(day: day, feeling: feeling, offered: offered, api: api)
        await schedule(store)
    }

    /// Opens one of the app's tabs (armstronghub://fitness), as the widgets do.
    static func open(_ tab: String) async {
        guard let url = URL(string: "armstronghub://\(tab)") else { return }
        await UIApplication.shared.open(url)
    }
}
