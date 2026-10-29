import Foundation

// MARK: Calendar (lib/google-calendar.ts)

struct CalendarEvent: Decodable, Identifiable, Sendable {
    let id: String
    let title: String
    /// ISO timestamp, or "YYYY-MM-DD" for all-day events.
    let start: String
    let end: String
    let allDay: Bool
    let location: String?
    let calendar: String
    let color: String
    let url: String?
    /// A contact's birthday. Optional: older hubs and cached copies don't send it.
    let birthday: Bool?

    var startDate: Date? { ISO.parse(start) }
}

struct CalendarDay: Decodable, Identifiable, Sendable {
    let day: String
    let events: [CalendarEvent]
    var id: String { day }
}

struct CalendarResponse: Decodable, Sendable {
    /// connected, not_connected, missing_scope or unconfigured.
    let status: String
    let timeZone: String
    let upcomingDays: Int
    let today: String?
    let days: [CalendarDay]
    let error: String?
}

enum ISO {
    nonisolated(unsafe) private static let withFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    nonisolated(unsafe) private static let plain = ISO8601DateFormatter()

    static func parse(_ s: String) -> Date? { withFraction.date(from: s) ?? plain.date(from: s) }
}

// MARK: Habits (lib/habit-types.ts)

struct Habit: Codable, Identifiable, Equatable, Sendable {
    let id: String
    var name: String
    var color: String
    var icon: String?
    var position: Int
    let createdAt: String
}

struct Completion: Codable, Hashable, Sendable {
    let habitId: String
    let date: String
}

struct HabitsResponse: Codable, Sendable {
    let habits: [Habit]
    let completions: [Completion]
    let colors: [String]
    let historyDays: Int
}
