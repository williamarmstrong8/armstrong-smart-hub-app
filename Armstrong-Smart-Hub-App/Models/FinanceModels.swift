import Foundation

/// Mirrors the shapes from lib/finance.ts, lib/recurring.ts and lib/goal.ts.
struct FinanceResponse: Decodable, Sendable {
    let configured: Bool
    let hasData: Bool?
    let sync: SyncStatus?
    let historyDays: Int?
    let dashboard: Dashboard?
    let recurring: [RecurringCharge]?
    let history: History?
    let goal: GoalSettings?
    let customCategories: [String]?
    let quickCategories: QuickCategories?
}

struct SyncStatus: Decodable, Sendable {
    let lastSuccessAt: Double?
    let failureReason: String?
    let notices: [String]
}

struct QuickCategories: Decodable, Sendable {
    let out: [String]
    let `in`: [String]
}

struct History: Decodable, Sendable {
    let series: [SeriesPoint]
    let source: String
}

struct SeriesPoint: Decodable, Identifiable, Sendable {
    let date: String
    let value: Double
    var id: String { date }
    var day: Date { DayFormat.parse(date) ?? .distantPast }
}

enum AccountKind: String, Decodable, Sendable { case cash, credit, loan, investment }

struct Account: Decodable, Identifiable, Sendable {
    let id: String
    let name: String
    let institution: String
    let currency: String
    let kind: AccountKind
    let isLiability: Bool
    let rawBalance: Double
    let magnitude: Double
    let contribution: Double
    let availableBalance: Double?
    let balanceDate: Double
}

struct Transaction: Decodable, Identifiable, Equatable, Sendable {
    let id: String
    let accountId: String
    let accountName: String
    let institution: String
    let currency: String
    let posted: Double
    let amount: Double
    let netEffect: Double
    let description: String
    let payee: String
    let memo: String?
    let pending: Bool
    let hold: Bool
    var category: String
    var categorySource: String

    var date: Date { Date(timeIntervalSince1970: posted) }
}

struct CategoryAmount: Decodable, Identifiable, Sendable {
    let category: String
    let amount: Double
    let share: Double?
    var id: String { category }
}

struct CashFlowMonth: Decodable, Identifiable, Sendable {
    let month: String
    let income: Double
    let spending: Double
    let net: Double
    var id: String { month }
}

struct Dashboard: Decodable, Sendable {
    struct Spending: Decodable, Sendable {
        let windowDays: Int
        let total: Double
        let byCategory: [CategoryAmount]
    }

    struct MonthSpending: Decodable, Sendable {
        let total: Double
        let lastMonthToDate: Double
        let byCategory: [CategoryAmount]
    }

    let accounts: [Account]
    var transactions: [Transaction]
    let currency: String
    let netWorth: Double
    let totalAssets: Double
    let totalLiabilities: Double
    let errors: [String]
    let netWorthSeries: [SeriesPoint]
    let cashFlow: [CashFlowMonth]
    let spending: Spending
    let monthSpending: MonthSpending
    let cash: Double
    var toReview: [Transaction]
    let income30d: Double
    let spending30d: Double
    let netFlow30d: Double
    let netWorthChange: Double
}

struct RecurringCharge: Decodable, Identifiable, Sendable {
    let id: String
    let name: String
    let category: String
    let accountName: String
    let cadence: String
    let amount: Double
    let previousAmount: Double?
    let lastCharged: Double
    let nextExpected: Double
    let monthlyCost: Double
    let chargeCount: Int
}

struct GoalSettings: Codable, Equatable, Sendable {
    var target: Double
    var monthlyContribution: Double?
    var annualReturnPct: Double

    static let `default` = GoalSettings(target: 1_000_000, monthlyContribution: nil, annualReturnPct: 7)
}

/// Built-in tags, in the web picker's order (lib/categories.ts).
let builtInCategories = [
    "Income", "Transfers", "Rent", "Groceries", "Food & Drinks", "Transport", "Lifestyle",
    "Bills & Utilities", "Subscriptions & Fees", "Travel",
]

enum DayFormat {
    static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static func parse(_ s: String) -> Date? { formatter.date(from: String(s.prefix(10))) }
}
