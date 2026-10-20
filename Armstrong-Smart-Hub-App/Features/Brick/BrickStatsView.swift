import SwiftUI

#if os(iOS)
import DeviceActivity

/// Stats page in the Fitness style: PeriodPicker, StatStrip, DailyBarChart, DetailRows.
/// Bottom: Apple's Screen Time report, drawn by the BrickReport extension
/// (iOS does not let an app read usage numbers directly).
struct BrickStatsView: View {
    let store: BrickStore
    @State private var days = 7

    private var cal: Calendar { .current }
    private var since: Date { cal.date(byAdding: .day, value: -(days - 1), to: cal.startOfDay(for: Date())) ?? Date() }
    private var recent: [BrickSession] { store.sessions.filter { $0.start >= since } }
    private func length(_ s: BrickSession) -> TimeInterval { (s.end ?? Date()).timeIntervalSince(s.start) }
    private var total: TimeInterval { recent.reduce(0) { $0 + length($1) } }

    private var streak: Int {
        let set = Set(store.sessions.map { cal.startOfDay(for: $0.start) })
        var d = cal.startOfDay(for: Date())
        if !set.contains(d) { d = cal.date(byAdding: .day, value: -1, to: d) ?? d }
        var n = 0
        while set.contains(d) { n += 1; d = cal.date(byAdding: .day, value: -1, to: d) ?? d }
        return n
    }

    /// Focus minutes per day.
    private var points: [DayValue] {
        (0..<days).reversed().map { i in
            let day = cal.date(byAdding: .day, value: -i, to: cal.startOfDay(for: Date())) ?? Date()
            let t = store.sessions.filter { cal.isDate($0.start, inSameDayAs: day) }.reduce(0) { $0 + length($1) }
            return DayValue(date: day, value: (t / 60).rounded())
        }
    }

    private var filter: DeviceActivityFilter {
        DeviceActivityFilter(segment: .daily(during: DateInterval(start: since, end: Date())),
                             users: .all, devices: .init([.iPhone]))
    }

    var body: some View {
        FitPage(title: "Stats") {
            VStack(spacing: 0) {
                BigNumber(value: format(total), unit: nil, caption: "focus time, last \(days) days", tint: Fit.activity)
                HStack { Spacer(); PeriodPicker(days: $days, options: [7, 30]); Spacer() }.padding(.bottom, 20)
                FitSection {
                    StatStrip(items: [("Sessions", "\(recent.count)"), ("Streak", "\(streak) d"),
                                      ("Average", format(recent.isEmpty ? 0 : total / Double(recent.count)))])
                }
                .padding(.bottom, 24)
                FitSection(title: "Focus per day", trailing: "minutes") {
                    DailyBarChart(points: points, tint: Fit.activity,
                                  format: { "\(Int($0.rounded())) min" })
                }
                .padding(.bottom, 24)
                FitSection(title: "Recent sessions") {
                    if store.sessions.isEmpty {
                        Text("No sessions yet").font(Fit.label).foregroundStyle(Fit.muted)
                    }
                    VStack(spacing: 0) {
                        let latest = Array(store.sessions.suffix(10).reversed())
                        ForEach(Array(latest.enumerated()), id: \.element.id) { index, s in
                            DetailRow(label: "\(s.profileName), \(s.start.formatted(date: .abbreviated, time: .shortened))",
                                      value: s.end == nil ? "Running" : format(length(s)),
                                      last: index == latest.count - 1)
                        }
                    }
                }
                .padding(.bottom, 24)
                FitSection(title: "Screen Time") {
                    DeviceActivityReport(DeviceActivityReport.Context("BrickScreenTime"), filter: filter)
                        .frame(minHeight: 420)
                }
            }
        }
    }

    private func format(_ t: TimeInterval) -> String {
        let m = Int(t / 60)
        return m >= 60 ? "\(m / 60)h \(m % 60)m" : "\(m)m"
    }
}
#endif
