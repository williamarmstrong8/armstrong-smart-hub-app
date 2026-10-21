import Foundation
import UIKit
import UserNotifications

/// The check-in, twice a day, on the lock screen: at 8 am with the hub's
/// guess for the morning, and at 6 pm to confirm or correct the day. Each
/// notification answers itself: "I'm fine" and "I'm sick" save the day's
/// check-in without opening the app (queued in CheckinStore if the hub is out
/// of reach).
///
/// Local notifications can't change their text once scheduled, so the next
/// week is scheduled ahead with plain text and rescheduled whenever the
/// check-in page loads or an answer is saved: then today's carry the guess
/// ("Looks like you might be sick"), and a morning already answered is dropped.
@MainActor
final class CheckinReminders: NSObject, UNUserNotificationCenterDelegate {
    static let shared = CheckinReminders()

    /// Set by the app once signed in, so a button can send its answer.
    var api: APIClient?

    private nonisolated static let category = "checkin"
    private nonisolated static let fine = "checkin.fine"
    private nonisolated static let sick = "checkin.sick"
    private static let prefix = "checkin."
    private static let days = 7
    private static let times: [(slot: String, hour: Int)] = [("morning", 8), ("evening", 18)]

    private let center = UNUserNotificationCenter.current()

    /// Registers the buttons and takes over notification answers. Call at launch.
    func start() {
        center.delegate = self
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Self.category, actions: [
                UNNotificationAction(identifier: Self.fine, title: "I'm fine"),
                UNNotificationAction(identifier: Self.sick, title: "I'm sick"),
            ], intentIdentifiers: []),
        ])
    }

    /// Replaces the next week of check-in notifications from what the store knows now.
    func schedule(_ store: CheckinStore) async {
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
                content.categoryIdentifier = Self.category
                content.sound = .default
                content.userInfo = ["day": day]
                (content.title, content.body) = Self.text(slot: slot, answer: answer,
                                                          guessedSick: offset == 0 && store.guess != nil ? Self.guessedSick(store) : nil)
                let trigger = UNCalendarNotificationTrigger(dateMatching: calendar.dateComponents([.year, .month, .day, .hour, .minute], from: fire), repeats: false)
                try? await center.add(UNNotificationRequest(identifier: "\(Self.prefix)\(slot).\(day)", content: content, trigger: trigger))
            }
        }
    }

    /// Morning: the guess when there is one. Evening: confirm the morning's answer, or ask.
    private static func text(slot: String, answer: Bool?, guessedSick: Bool?) -> (String, String) {
        if slot == "morning" {
            switch guessedSick {
            case true?: return ("Morning check-in", "Looks like you might be sick. Right?")
            case false?: return ("Morning check-in", "Looks like a normal day. Feeling fine?")
            case nil: return ("Morning check-in", "Feeling fine today?")
            }
        }
        switch answer {
        case true?: return ("Evening check-in", "Still feeling sick?")
        case false?: return ("Evening check-in", "Still feeling fine?")
        case nil: return ("Evening check-in", "How was today: fine or sick?")
        }
    }

    private static func guessedSick(_ store: CheckinStore) -> Bool {
        store.likely.contains { $0.state == "sick" }
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
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let action = response.actionIdentifier
        let category = response.notification.request.content.categoryIdentifier
        let day = response.notification.request.content.userInfo["day"] as? String
        guard category == Self.category, action == Self.fine || action == Self.sick, let day else { return }
        await answer(day: day, sick: action == Self.sick)
    }

    /// Check-ins show over the open app too; anything else (the rest timer) stays as it was: not shown.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        notification.request.content.categoryIdentifier == Self.category ? [.banner, .sound] : []
    }

    private func answer(day: String, sick: Bool) async {
        let store = CheckinStore.shared
        guard let api else { return }
        let task = UIApplication.shared.beginBackgroundTask(withName: "Check-in answer")
        defer { if task != .invalid { UIApplication.shared.endBackgroundTask(task) } }
        await store.answer(day: day, sick: sick, api: api)
        await schedule(store)
    }
}
