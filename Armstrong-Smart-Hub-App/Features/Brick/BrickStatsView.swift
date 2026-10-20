import SwiftUI

#if os(iOS)
import DeviceActivity

/// Stats page. Top: Brick's own numbers (sessions, focus time, streak).
/// Bottom: Apple's Screen Time report, drawn by the BrickReport extension
/// (iOS does not let an app read usage numbers directly).
struct BrickStatsView: View {
    let store: BrickStore
    @State private var range = 7

    private var cal: Calendar { .current }
    private var since: Date { cal.date(byAdding: .day, value: -(range - 1), to: cal.startOfDay(for: Date())) ?? Date() }
    private var recent: [BrickSession] { store.sessions.filter { $0.start >= since } }
    private func length(_ s: BrickSession) -> TimeInterval { (s.end ?? Date()).timeIntervalSince(s.start) }
    private var total: TimeInterval { recent.reduce(0) { $0 + length($1) } }

    private var streak: Int {
        let days = Set(store.sessions.map { cal.startOfDay(for: $0.start) })
        var d = cal.startOfDay(for: Date())
        if !days.contains(d) { d = cal.date(byAdding: .day, value: -1, to: d) ?? d }
        var n = 0
        while days.contains(d) { n += 1; d = cal.date(byAdding: .day, value: -1, to: d) ?? d }
        return n
    }

    private var perDay: [(Date, TimeInterval)] {
        (0..<range).reversed().map { i in
            let day = cal.date(byAdding: .day, value: -i, to: cal.startOfDay(for: Date())) ?? Date()
            let t = store.sessions.filter { cal.isDate($0.start, inSameDayAs: day) }.reduce(0) { $0 + length($1) }
            return (day, t)
        }
    }

    private var filter: DeviceActivityFilter {
        DeviceActivityFilter(segment: .daily(during: DateInterval(start: since, end: Date())),
                             users: .all, devices: .init([.iPhone]))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                Picker("Range", selection: $range) {
                    Text("7 days").tag(7)
                    Text("30 days").tag(30)
                }.pickerStyle(.segmented)

                HStack(alignment: .top) {
                    stat("Focus time", format(total))
                    stat("Sessions", "\(recent.count)")
                    stat("Streak", "\(streak)d")
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Focus per day").font(.headline)
                    let maxV = max(perDay.map(\.1).max() ?? 1, 1)
                    HStack(alignment: .bottom, spacing: range == 7 ? 10 : 2) {
                        ForEach(perDay, id: \.0) { d, t in
                            RoundedRectangle(cornerRadius: 3)
                                .fill(Color.orange)
                                .frame(height: max(3, 110 * t / maxV))
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .frame(height: 110, alignment: .bottom)
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text("Recent sessions").font(.headline)
                    ForEach(store.sessions.suffix(10).reversed()) { s in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(s.profileName)
                                Text(s.start.formatted(date: .abbreviated, time: .shortened))
                                    .font(.footnote).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(s.end == nil ? "running" : format(length(s)))
                                .foregroundStyle(.secondary)
                        }
                    }
                    if store.sessions.isEmpty { Text("No sessions yet").foregroundStyle(.secondary) }
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Screen Time").font(.headline)
                    DeviceActivityReport(DeviceActivityReport.Context("BrickScreenTime"), filter: filter)
                        .frame(minHeight: 420)
                }
            }
            .padding(20)
        }
        .navigationTitle("Stats")
    }

    private func stat(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading) {
            Text(value).font(.title.bold().monospacedDigit())
            Text(title).font(.footnote).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func format(_ t: TimeInterval) -> String {
        let m = Int(t / 60)
        return m >= 60 ? "\(m / 60)h \(m % 60)m" : "\(m)m"
    }
}
#endif
