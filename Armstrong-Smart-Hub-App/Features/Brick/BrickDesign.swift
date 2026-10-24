import SwiftUI

#if os(iOS)
/// Brick's own look: warm gray page, a lighter rounded sheet on top, soft cards, slate bars.
enum BrickLook {
    static let page = Fit.adaptive(0xD5D1D0, 0x161414)
    static let sheet = Fit.adaptive(0xDCD8D7, 0x1E1C1C)
    static let card = Fit.adaptive(0xE5E2E0, 0x2A2727)
    static let pill = Fit.adaptive(0xE3DFDD, 0x2E2B2B)
    static let ink = Fit.adaptive(0x262322, 0xECE8E6)
    static let soft = Fit.adaptive(0x868180, 0x8F8A89)
    static let line = Fit.adaptive(0xC9C4C3, 0x3A3636)
    static let bar = Fit.adaptive(0x43505C, 0xA9B7C4)
    static let track = Fit.adaptive(0xD9D5D3, 0x3A3636)
    static let live = Fit.adaptive(0x5E7D6A, 0x7FB08F)

    static let cardRadius: CGFloat = 26
    /// The top sheet's bottom corners on Brick and Fitness: Brick's 64-point button's
    /// radius plus the gap around it, so the two curves run parallel.
    static let sheetRadius: CGFloat = 64 / 2 + Fit.gutter
}

// MARK: Pieces

/// A centered page heading, like "Schedules" or "Weekly Activity".
struct BrickHeading: View {
    var title: String
    var chevron = false
    var body: some View {
        HStack(spacing: 8) {
            Text(title).font(.system(size: 26, weight: .regular))
            if chevron { Image(systemName: "chevron.down").font(.system(size: 15, weight: .medium)) }
        }
        .foregroundStyle(BrickLook.ink)
    }
}

/// Small caps label, like "THIS WEEK" and "TODAY".
struct BrickCaps: View {
    var text: String
    var body: some View {
        Text(text.uppercased()).font(.system(size: 13, weight: .medium)).tracking(1.2)
    }
}

/// A soft rounded surface.
struct BrickCard<Content: View>: View {
    var padding: CGFloat = 22
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(BrickLook.card, in: RoundedRectangle(cornerRadius: BrickLook.cardRadius, style: .continuous))
    }
}

/// A settings-style row: line icon, title, value, chevron.
struct BrickRow: View {
    var icon: String
    var title: String
    var value: String?
    var dot = false
    var chevron = true

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: icon).font(.system(size: 20, weight: .light)).frame(width: 26)
            Text(title).font(.system(size: 18))
            Spacer(minLength: 8)
            if dot { Circle().fill(Color.blue).frame(width: 9, height: 9) }
            if let value { Text(value).font(.system(size: 18)).foregroundStyle(BrickLook.soft).monospacedDigit() }
            if chevron { Image(systemName: "chevron.right").font(.system(size: 14, weight: .medium)).foregroundStyle(BrickLook.soft) }
        }
        .foregroundStyle(BrickLook.ink)
        .padding(.vertical, 20)
        .contentShape(Rectangle())
    }
}

struct BrickDivider: View {
    var body: some View { Rectangle().fill(BrickLook.line).frame(height: 1) }
}

/// The round plus button under "Create schedule".
struct BrickPlus: View {
    var body: some View {
        Image(systemName: "plus").font(.system(size: 26, weight: .light))
            .foregroundStyle(BrickLook.ink)
            .frame(width: 66, height: 66)
            .background(BrickLook.pill, in: Circle())
            .shadow(color: .black.opacity(0.14), radius: 8, y: 5)
    }
}

/// Page background and title for every nested page.
struct BrickPage<Content: View>: View {
    var title: String
    @ViewBuilder var content: Content
    var body: some View {
        ScrollView {
            VStack(spacing: 16) { content }
                .padding(.horizontal, Fit.gutter)
                .padding(.top, 12)
                .padding(.bottom, 48)
                // A page with little on it (no schedules yet) would otherwise shrink to its content.
                .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(BrickLook.page.ignoresSafeArea())
        .foregroundStyle(BrickLook.ink)
        .tint(BrickLook.ink)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(BrickLook.page, for: .navigationBar)
    }
}

/// Brick's look for a List or Form: warm page, soft card rows, slate tint.
extension View {
    func brickList() -> some View {
        self.scrollContentBackground(.hidden)
            .background(BrickLook.page.ignoresSafeArea())
            .foregroundStyle(BrickLook.ink)
            .tint(BrickLook.ink)
            .listRowSeparatorTint(BrickLook.line)
    }

    /// Brick's page behind a scroll view or stack in a sheet.
    func brickBackdrop() -> some View {
        self.background(BrickLook.page.ignoresSafeArea())
            .foregroundStyle(BrickLook.ink)
            .tint(BrickLook.ink)
    }
}

/// The top row every tab shares: account on the left, the page's own buttons on the right.
struct BrickTopBar<Trailing: View>: View {
    @ViewBuilder var trailing: Trailing
    var body: some View {
        HStack {
            AccountButton().frame(width: 28, height: 28)
            Spacer()
            trailing.frame(minWidth: 28, minHeight: 28)
        }
        // A fixed row height, so the account button sits at the same spot whatever the trailing button's size.
        .frame(height: 32)
        .font(.system(size: 22, weight: .light))
        .foregroundStyle(BrickLook.ink)
    }
}

/// A small rounded fact under a hero.
struct BrickPill: View {
    var text: String
    var icon: String?
    var body: some View {
        HStack(spacing: 8) {
            if let icon { Image(systemName: icon) }
            Text(text)
        }
        .font(.system(size: 16)).monospacedDigit()
        .foregroundStyle(BrickLook.soft)
        .padding(.horizontal, 16).padding(.vertical, 11)
        .background(BrickLook.pill, in: .capsule)
    }
}

/// The opening of every tab, so moving between them feels like one app: a caps line, a big light
/// title, a line under it, and pills. Sizes and spacing live here and nowhere else.
struct BrickHero<Pills: View>: View {
    var caption: String
    var title: String
    var subtitle: String?
    var subtitleColor: Color = BrickLook.soft
    @ViewBuilder var pills: Pills

    var body: some View {
        VStack(spacing: 12) {
            BrickCaps(text: caption).foregroundStyle(BrickLook.soft)
            Text(title)
                .font(.system(size: 56, weight: .light).monospacedDigit())
                .multilineTextAlignment(.center)
                .minimumScaleFactor(0.5).lineLimit(2)
                .contentTransition(.numericText())
            if let subtitle {
                Text(subtitle).font(.system(size: 18)).foregroundStyle(subtitleColor).multilineTextAlignment(.center)
            }
            HStack(spacing: 10) { pills }.padding(.top, 10)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
    }
}

// MARK: Charts

/// Brick's week chart: dashed hour lines, labels at the right, one slate bar per day.
struct BrickWeekChart: View {
    var days: [DayValue]   // value in seconds
    var height: CGFloat = 200

    private var scaleHours: Int {
        let top = (days.map(\.value).max() ?? 0) / 3600
        return max(4, Int((top / 2).rounded(.up)) * 2)
    }

    var body: some View {
        let hours = scaleHours
        VStack(spacing: 14) {
            ZStack(alignment: .topLeading) {
                // Hour lines, top one is the scale's top.
                VStack(spacing: 0) {
                    ForEach(0...hours, id: \.self) { i in
                        let h = hours - i
                        ZStack(alignment: .topTrailing) {
                            Line().stroke(BrickLook.line, style: StrokeStyle(lineWidth: 1, dash: [3, 3])).frame(height: 1)
                            if h > 0 && h % 2 == 0 {
                                Text("\(h)h").font(.system(size: 13)).foregroundStyle(BrickLook.soft)
                                    .padding(.top, 6).padding(.trailing, Fit.gutter)
                            }
                        }
                        .frame(height: 1, alignment: .top)
                        if i < hours { Spacer(minLength: 0) }
                    }
                }
                HStack(alignment: .bottom, spacing: 0) {
                    ForEach(days) { d in
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(BrickLook.bar)
                            .frame(width: 26, height: max(0, CGFloat(d.value / 3600 / Double(hours)) * height))
                            .frame(maxWidth: .infinity)
                    }
                }
                .frame(height: height, alignment: .bottom)
                .padding(.leading, Fit.gutter).padding(.trailing, 52)
            }
            .frame(height: height)
            HStack(spacing: 0) {
                ForEach(days) { d in
                    let today = Calendar.current.isDateInToday(d.date)
                    VStack(spacing: 2) {
                        Text(d.date.formatted(.dateTime.weekday(.abbreviated)).uppercased())
                        Text(d.date.formatted(.dateTime.day()))
                    }
                    .font(.system(size: 14, weight: today ? .medium : .regular))
                    .foregroundStyle(today ? BrickLook.ink : BrickLook.soft)
                    .frame(maxWidth: .infinity)
                }
            }
            .padding(.leading, Fit.gutter).padding(.trailing, 52)
        }
    }
}

private struct Line: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.midY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        return p
    }
}

/// A day's 24 hours as a thin track, with each session drawn where it fell.
struct BrickDayTrack: View {
    var day: Date
    var sessions: [BrickSession]
    /// Where a running session ends for now; set at each redraw so the bar grows.
    var now = Date()

    var body: some View {
        GeometryReader { geo in
            let start = Calendar.current.startOfDay(for: day)
            ZStack(alignment: .leading) {
                Capsule().fill(BrickLook.track)
                ForEach(sessions) { s in
                    let a = max(0, s.start.timeIntervalSince(start)) / 86400
                    let b = min(86400, (s.end ?? now).timeIntervalSince(start)) / 86400
                    Capsule().fill(BrickLook.bar)
                        .frame(width: max(8, CGFloat(b - a) * geo.size.width))
                        .offset(x: CGFloat(a) * geo.size.width)
                }
            }
        }
        .frame(height: 9)
    }
}

/// One day: total, sessions and where they fell. The Today one carries a live dot.
struct BrickDayCard: View {
    var day: Date
    var seconds: TimeInterval
    var sessions: [BrickSession]

    var body: some View {
        let today = Calendar.current.isDateInToday(day)
        BrickCard {
            HStack(spacing: 8) {
                if today { Circle().fill(BrickLook.live).frame(width: 9, height: 9) }
                BrickCaps(text: today ? "Today" : day.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()))
                    .foregroundStyle(today ? BrickLook.ink : BrickLook.soft)
            }
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(brickDuration(seconds)).font(.system(size: 34, weight: .regular).monospacedDigit())
                    Text(sessions.count == 1 ? "1 session" : "\(sessions.count) sessions")
                        .font(.system(size: 17)).foregroundStyle(BrickLook.soft)
                }
                Spacer(minLength: 24)
                BrickDayTrack(day: day, sessions: sessions).frame(width: 140).padding(.bottom, 8)
            }
            .padding(.top, 10)
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
        return sessions.filter { $0.start < end && ($0.end ?? now) > start }
    }

    /// Bricked time within this day, splitting sessions that cross midnight.
    func seconds(on day: Date) -> TimeInterval {
        let start = cal.startOfDay(for: day)
        let end = start.addingTimeInterval(86400)
        return sessions(on: day).reduce(0) { sum, s in
            sum + max(0, min(end, s.end ?? now).timeIntervalSince(max(start, s.start)))
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
        guard let h = endHour,
              let end = Calendar.current.date(bySettingHour: h, minute: endMinute ?? 0, second: 0, of: Date()) else {
            return "\(t) · \(days)"
        }
        return "\(t)–\(end.formatted(date: .omitted, time: .shortened).lowercased()) · \(days)"
    }
}
#endif
