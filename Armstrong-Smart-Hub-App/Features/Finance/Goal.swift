import Foundation

/// Port of lib/goal.ts so the goal card re-projects instantly while editing.
struct GoalPath { let months: Int?; let contributed: Double; let growth: Double }

struct Projection {
    let current: Double
    let progress: Double
    let observedMonthly: Double?
    let monthly: Double
    let targetDate: Date?
    let invested: GoalPath
    let cash: GoalPath
    let boosts: [(extra: Double, months: Int?)]
}

enum GoalMath {
    private static let maxMonths = 100 * 12

    /// Slope of a least-squares line through the series, per month.
    static func monthlyTrend(_ series: [SeriesPoint]) -> Double? {
        guard series.count >= 21, let t0 = series.first?.day else { return nil }
        let xs = series.map { $0.day.timeIntervalSince(t0) / 86_400 }
        let ys = series.map(\.value)
        let mx = xs.reduce(0, +) / Double(xs.count)
        let my = ys.reduce(0, +) / Double(ys.count)
        var num = 0.0, den = 0.0
        for i in xs.indices {
            num += (xs[i] - mx) * (ys[i] - my)
            den += (xs[i] - mx) * (xs[i] - mx)
        }
        return den == 0 ? nil : (num / den) * (365.25 / 12)
    }

    private static func simulate(_ start: Double, _ target: Double, _ monthly: Double, _ rate: Double) -> GoalPath {
        var value = start
        var contributed = max(start, 0)
        if value >= target { return GoalPath(months: 0, contributed: contributed, growth: 0) }
        for m in 1...maxMonths {
            value = value * (1 + (value > 0 ? rate : 0)) + monthly
            contributed += monthly
            if value >= target { return GoalPath(months: m, contributed: contributed, growth: max(value - contributed, 0)) }
        }
        return GoalPath(months: nil, contributed: contributed, growth: max(value - contributed, 0))
    }

    static func project(current: Double, series: [SeriesPoint], goal: GoalSettings, now: Date = .now) -> Projection {
        let observed = monthlyTrend(series)
        let monthly = goal.monthlyContribution ?? max(observed ?? 0, 0)
        let rate = pow(1 + goal.annualReturnPct / 100, 1.0 / 12) - 1
        let invested = simulate(current, goal.target, monthly, rate)
        return Projection(
            current: current,
            progress: min(max(current / goal.target, 0), 1),
            observedMonthly: observed,
            monthly: monthly,
            targetDate: invested.months.flatMap { Calendar.current.date(byAdding: .month, value: $0, to: now) },
            invested: invested,
            cash: simulate(current, goal.target, monthly, 0),
            boosts: [500.0, 1_000.0].map { ($0, simulate(current, goal.target, monthly + $0, rate).months) }
        )
    }

    static func duration(_ months: Int?) -> String {
        guard let months else { return "100+ years" }
        if months == 0 { return "Reached" }
        let y = months / 12, m = months % 12
        if y == 0 { return "\(m) mo" }
        return m == 0 ? "\(y) yr" : "\(y) yr \(m) mo"
    }
}
