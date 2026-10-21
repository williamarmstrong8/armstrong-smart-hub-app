import SwiftUI

#if os(iOS)
/// Brick in the hub's look: grouped background, rounded cards, the accent color.
enum BrickLook {
    /// Bricked time, in bars and day tracks.
    static let bar = Color.accentColor
    static let track = Color(.tertiarySystemFill)
    /// The "bricked right now" dot.
    static let live = Color.positive
}

// MARK: Pieces

/// A tinted circle with a symbol, as Finance's rows have.
struct BrickIcon: View {
    var name: String
    var color: Color = .accentColor
    var body: some View {
        Image(systemName: name).font(.subheadline)
            .foregroundStyle(color)
            .frame(width: 32, height: 32)
            .background(color.opacity(0.13), in: .circle)
    }
}

/// Rows stacked in one card.
struct BrickList<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(spacing: 0) { content }
            .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 16))
    }
}

/// A settings-style row: icon, title, value, chevron.
struct BrickRow: View {
    var icon: String
    var title: String
    var value: String?
    var dot = false
    var chevron = true

    var body: some View {
        HStack(spacing: 12) {
            BrickIcon(name: icon)
            Text(title).font(.subheadline.weight(.medium))
            Spacer(minLength: 8)
            if dot { Circle().fill(Color.accentColor).frame(width: 8, height: 8) }
            if let value { Text(value).font(.subheadline).foregroundStyle(.secondary).monospacedDigit() }
            if chevron { Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary) }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }
}

/// Page background and title for every nested page.
struct BrickPage<Content: View>: View {
    var title: String
    @ViewBuilder var content: Content
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) { content }
                .padding(16)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// A small note under a card.
struct BrickNote: View {
    var text: String
    var body: some View {
        Text(text).font(.footnote).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 4)
    }
}

// MARK: Charts

/// The week as daily bars in hours, through the hub's shared chart.
struct BrickWeekChart: View {
    var days: [DayValue]   // value in seconds
    var height: CGFloat = 160

    var body: some View {
        let top = (days.map(\.value).max() ?? 0) / 3600
        let scale = Double(max(2, Int((top / 2).rounded(.up)) * 2))
        DailyBarChart(points: days.map { DayValue(date: $0.date, value: $0.value / 3600) },
                      tint: BrickLook.bar, domain: 0...scale, yTicks: [0, scale / 2, scale], height: height,
                      format: { brickDuration($0 * 3600) })
    }
}

/// A day's 24 hours as a thin track, with each session drawn where it fell.
struct BrickDayTrack: View {
    var day: Date
    var sessions: [BrickSession]

    var body: some View {
        GeometryReader { geo in
            let start = Calendar.current.startOfDay(for: day)
            ZStack(alignment: .leading) {
                Capsule().fill(BrickLook.track)
                ForEach(sessions) { s in
                    let a = max(0, s.start.timeIntervalSince(start)) / 86400
                    let b = min(86400, (s.end ?? Date()).timeIntervalSince(start)) / 86400
                    Capsule().fill(BrickLook.bar)
                        .frame(width: max(6, CGFloat(b - a) * geo.size.width))
                        .offset(x: CGFloat(a) * geo.size.width)
                }
            }
        }
        .frame(height: 6)
    }
}

/// One day: total, sessions and where they fell. Today carries a live dot while bricked.
struct BrickDayRow: View {
    var day: Date
    var seconds: TimeInterval
    var sessions: [BrickSession]

    var body: some View {
        let today = Calendar.current.isDateInToday(day)
        let live = today && sessions.contains { $0.end == nil }
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                HStack(spacing: 6) {
                    if live { Circle().fill(BrickLook.live).frame(width: 7, height: 7) }
                    Text(today ? "Today" : day.formatted(.dateTime.weekday(.wide).month(.abbreviated).day()))
                        .font(.subheadline.weight(.medium))
                }
                Spacer()
                Text(brickDuration(seconds)).font(.subheadline.weight(.semibold)).monospacedDigit()
                Text(sessions.count == 1 ? "· 1 session" : "· \(sessions.count) sessions")
                    .font(.subheadline).foregroundStyle(.secondary).monospacedDigit()
            }
            BrickDayTrack(day: day, sessions: sessions)
        }
    }
}

/// "2h 28m", or "12m" under an hour.
func brickDuration(_ seconds: TimeInterval) -> String {
    let m = Int(seconds / 60)
    return m >= 60 ? "\(m / 60)h \(m % 60)m" : "\(m)m"
}

// MARK: Numbers for the pages

extension BrickStore {
    private var cal: Calendar { .current }

    /// Sessions that touch this day.
    func sessions(on day: Date) -> [BrickSession] {
        let start = cal.startOfDay(for: day)
        let end = start.addingTimeInterval(86400)
        return sessions.filter { $0.start < end && ($0.end ?? Date()) > start }
    }

    /// Bricked time within this day, splitting sessions that cross midnight.
    func seconds(on day: Date) -> TimeInterval {
        let start = cal.startOfDay(for: day)
        let end = start.addingTimeInterval(86400)
        return sessions(on: day).reduce(0) { sum, s in
            sum + max(0, min(end, s.end ?? Date()).timeIntervalSince(max(start, s.start)))
        }
    }

    /// The seven days of a week, `offset` weeks back from this one.
    func week(_ offset: Int = 0) -> [DayValue] {
        let base = cal.date(byAdding: .weekOfYear, value: -offset, to: Date()) ?? Date()
        let first = cal.dateInterval(of: .weekOfYear, for: base)?.start ?? cal.startOfDay(for: base)
        return (0..<7).map { i in
            let d = cal.date(byAdding: .day, value: i, to: first) ?? first
            return DayValue(date: d, value: seconds(on: d))
        }
    }

    /// Average over the week's finished days since the first session. nil until one full day has passed.
    func average(_ week: [DayValue]) -> TimeInterval? {
        guard let first = sessions.map(\.start).min() else { return nil }
        let today = cal.startOfDay(for: Date())
        let done = week.filter { $0.date < today && $0.date >= cal.startOfDay(for: first) }
        guard !done.isEmpty else { return nil }
        return done.reduce(0) { $0 + $1.value } / Double(done.count)
    }

    /// Days in a row with a session, counting today if it has one.
    var streak: Int {
        let set = Set(sessions.map { cal.startOfDay(for: $0.start) })
        var d = cal.startOfDay(for: Date())
        if !set.contains(d) { d = cal.date(byAdding: .day, value: -1, to: d) ?? d }
        var n = 0
        while set.contains(d) { n += 1; d = cal.date(byAdding: .day, value: -1, to: d) ?? d }
        return n
    }
}

extension BrickSchedule {
    /// "1:30 pm · Weekdays"
    var summary: String {
        let time = Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: Date()) ?? Date()
        let t = time.formatted(date: .omitted, time: .shortened).lowercased()
        let days: String
        switch weekdays {
        case [2, 3, 4, 5, 6]: days = "Weekdays"
        case [1, 7]: days = "Weekends"
        case Set(1...7): days = "Every day"
        case []: days = "Never"
        default:
            let symbols = Calendar.current.shortWeekdaySymbols
            days = weekdays.sorted().map { symbols[$0 - 1] }.joined(separator: ", ")
        }
        return "\(t) · \(days)"
    }
}
#endif
