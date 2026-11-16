import SwiftUI

/// Formatting that matches lib/format.ts on the web.
enum Fmt {
    static func currency(_ value: Double, _ code: String = "USD", cents: Bool = true) -> String {
        value.formatted(.currency(code: code).precision(.fractionLength(cents ? 2 : 0)))
    }

    /// Drops the cents for headline figures.
    static func compact(_ value: Double, _ code: String = "USD") -> String { currency(value, code, cents: false) }

    static func signed(_ value: Double, _ code: String = "USD") -> String {
        let sign = value > 0 ? "+" : value < 0 ? "−" : ""
        return sign + currency(abs(value), code)
    }

    static func axis(_ value: Double) -> String {
        value.formatted(.currency(code: "USD").notation(.compactName).precision(.fractionLength(0...1)))
    }

    static func relative(ms: Double) -> String {
        RelativeDateTimeFormatter().localizedString(for: Date(timeIntervalSince1970: ms / 1000), relativeTo: .now)
    }

    static func shortDate(_ date: Date) -> String { date.formatted(.dateTime.month(.abbreviated).day()) }

    /// When a transaction happened, the way you'd say it: "This morning", "Last night",
    /// "Friday night", "Nov 3, evening". Up to 5am counts as the night before. Banks that only
    /// give a day stamp it at midnight, so those just get the day ("Friday"), read in UTC
    /// when the stamp is UTC midnight so it doesn't slip back a day.
    static func spokenTime(_ seconds: Double, now: Date = .now) -> String {
        let date = Date(timeIntervalSince1970: seconds)
        var cal = Calendar.current
        let localMidnight = cal.startOfDay(for: date) == date
        let utcMidnight = seconds.truncatingRemainder(dividingBy: 86_400) == 0
        let dayOnly = localMidnight || utcMidnight
        if utcMidnight, let utc = TimeZone(identifier: "UTC") { cal.timeZone = utc }

        let hour = cal.component(.hour, from: date)
        // Small hours belong to the evening before.
        let day = cal.startOfDay(for: !dayOnly && hour < 5 ? date.addingTimeInterval(-6 * 3600) : date)
        // Compare calendar days, carrying a UTC day stamp over as the same local date.
        let local = Calendar.current
        let sameDay = local.date(from: cal.dateComponents([.year, .month, .day], from: day)) ?? day
        let days = local.dateComponents([.day], from: sameDay, to: local.startOfDay(for: now)).day ?? 0

        let part: String? = if dayOnly { nil } else {
            switch hour {
            case 5..<12: "morning"
            case 12..<17: "afternoon"
            case 17..<21: "evening"
            default: "night"
            }
        }
        let weekday = day.formatted(Date.FormatStyle(timeZone: cal.timeZone).weekday(.wide))

        switch days {
        case ..<1:
            guard let part else { return "Today" }
            return part == "night" ? "Tonight" : "This \(part)"
        case 1:
            guard let part else { return "Yesterday" }
            return part == "night" ? "Last night" : "Yesterday \(part)"
        case 2...6:
            return part.map { "\(weekday) \($0)" } ?? weekday
        default:
            let stamp = day.formatted(Date.FormatStyle(timeZone: cal.timeZone).month(.abbreviated).day())
            return part.map { "\(stamp), \($0)" } ?? stamp
        }
    }
}

/// Today as the device's local "YYYY-MM-DD", like localDay() on the web.
func localDay(_ date: Date = .now) -> String {
    let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
    return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
}

/// Shifts a "YYYY-MM-DD" day by whole days, without time-zone drift.
func addDays(_ day: String, _ delta: Int) -> String {
    guard let date = DayFormat.parse(day) else { return day }
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "UTC")!
    return DayFormat.formatter.string(from: cal.date(byAdding: .day, value: delta, to: date) ?? date)
}

extension Color {
    /// "#RRGGBB".
    init(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        let v = UInt64(s, radix: 16) ?? 0x888888
        self.init(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }

    /// "#RRGGBB", darkened as needed so white text on it stays readable.
    init(hexForWhiteText hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        let v = UInt64(s, radix: 16) ?? 0x888888
        var c = [Double((v >> 16) & 0xFF), Double((v >> 8) & 0xFF), Double(v & 0xFF)].map { $0 / 255 }
        func luminance(_ c: [Double]) -> Double {
            let l = c.map { $0 <= 0.03928 ? $0 / 12.92 : pow(($0 + 0.055) / 1.055, 2.4) }
            return 0.2126 * l[0] + 0.7152 * l[1] + 0.0722 * l[2]
        }
        // Contrast with white of at least 4.5:1 means luminance at most about 0.183.
        while luminance(c) > 0.183 { c = c.map { $0 * 0.93 } }
        self.init(red: c[0], green: c[1], blue: c[2])
    }

    init(rgb: [Int]) {
        let c = rgb + [0, 0, 0]
        self.init(red: Double(c[0]) / 255, green: Double(c[1]) / 255, blue: Double(c[2]) / 255)
    }

    static let positive = HubDesign.positive
    static let negative = HubDesign.danger
}

/// A category's tint and symbol, used on transactions and spending bars.
enum CategoryStyle {
    static func symbol(_ category: String) -> String {
        switch category {
        case "Income": return "arrow.down.circle"
        case "Transfers": return "arrow.left.arrow.right"
        case "Rent": return "house"
        case "Groceries": return "cart"
        case "Food & Drinks": return "fork.knife"
        case "Transport": return "car"
        case "Lifestyle": return "bag"
        case "Bills & Utilities": return "bolt"
        case "Subscriptions & Fees": return "repeat"
        case "Travel": return "airplane"
        case "Uncategorized": return "questionmark.circle"
        default: return "tag"
        }
    }

    static func color(_ category: String) -> Color {
        switch category {
        case "Income": return .green
        case "Transfers": return .gray
        case "Rent": return .red
        case "Groceries": return .mint
        case "Food & Drinks": return .orange
        case "Transport": return .blue
        case "Lifestyle": return .pink
        case "Bills & Utilities": return .yellow
        case "Subscriptions & Fees": return .purple
        case "Travel": return .cyan
        case "Uncategorized": return .secondary
        default: return .indigo
        }
    }
}
