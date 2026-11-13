import SwiftUI

#if os(iOS)
/// Compatibility names for shared hub surfaces; only chart colors belong to Brick.
enum BrickLook {
    static let page = HubDesign.page
    static let sheet = HubDesign.surface
    static let card = HubDesign.raised
    static let pill = HubDesign.track
    static let ink = HubDesign.ink
    static let soft = HubDesign.secondary
    static let line = HubDesign.separator
    static let bar = HubDesign.adaptive(0x43505C, 0xA9B7C4)
    static let track = HubDesign.track
    static let live = HubDesign.positive
    /// The grey of the "Brick" pressed into the device; the picture is the same in dark mode, so this is too.
    static let wordmark = HubDesign.adaptive(0x9B9692, 0x9B9692)
    /// The three rings under the device: time back, what it held, the yearly pace.
    static let backTint = HubDesign.adaptive(0x1E9E4A, 0x3DDC6E)
    static let heldTint = HubDesign.adaptive(0xD98A00, 0xFFB340)
    static let paceTint = HubDesign.adaptive(0x2F6FD6, 0x6FA8FF)

    static let cardRadius = HubLayout.cardRadius
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
            Text(title).font(.title2.weight(.regular))
            if chevron { Image(systemName: "chevron.down").font(.system(size: 15, weight: .medium)) }
        }
        .foregroundStyle(BrickLook.ink)
    }
}

/// Small caps label, like "THIS WEEK" and "TODAY".
struct BrickCaps: View {
    var text: String
    var body: some View {
        Text(text.uppercased()).font(.caption.weight(.medium)).tracking(1)
    }
}

/// A soft rounded surface.
struct BrickCard<Content: View>: View {
    var padding: CGFloat = HubLayout.cardPadding
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassGlare(.regular, in: RoundedRectangle(cornerRadius: BrickLook.cardRadius, style: .continuous))
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
            Text(title).font(.body).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            if dot { Circle().fill(HubDesign.action).frame(width: 9, height: 9) }
            if let value { Text(value).font(.body).foregroundStyle(BrickLook.soft).monospacedDigit() }
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
            .glassGlare(.regular, in: Circle())
    }
}

/// Page background and title for every nested page.
struct BrickPage<Content: View>: View {
    var title: String
    @ViewBuilder var content: Content
    var body: some View {
        ScrollView(.vertical) {
            LazyVStack(spacing: HubLayout.sectionGap) { content }
                .padding(.horizontal, HubLayout.gutter)
                .padding(.top, HubLayout.topInset)
                .padding(.bottom, HubLayout.bottomInset)
                .containerRelativeFrame(.horizontal)
        }
        .scrollBounceBehavior(.basedOnSize, axes: .vertical)
        .demoScroll()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .hubPageStyle()
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Compatibility modifiers for the shared list and page treatments.
extension View {
    func brickList() -> some View { hubListStyle() }
    func brickBackdrop() -> some View { hubPageStyle() }
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
        .font(.subheadline).monospacedDigit()
        .foregroundStyle(BrickLook.soft)
        .padding(.horizontal, 16).padding(.vertical, 11)
        .glassGlare(.regular, in: .capsule)
    }
}

/// The opening of every tab, so moving between them feels like one app: a caps line, a big light
/// title, a line under it, and pills. Sizes and spacing live here and nowhere else.
struct BrickHero<Visual: View, Stats: View>: View {
    var caption: String
    var title: String
    var subtitle: String?
    var subtitleColor: Color = BrickLook.soft
    /// The page's picture of its own data, where Fitness has the watch. It takes the spare height.
    @ViewBuilder var visual: Visual
    /// Three `HeroRing`s, as under Fitness's title.
    @ViewBuilder var stats: Stats
    @ScaledMetric(relativeTo: .largeTitle) private var titleSize: CGFloat = 34

    var body: some View {
        VStack(spacing: 0) {
            visual
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .frame(minHeight: 150)
                .padding(.top, 4)
            BrickCaps(text: caption).foregroundStyle(BrickLook.soft).padding(.top, 14)
            Text(title)
                .font(.system(size: titleSize, weight: .light).monospacedDigit())
                .multilineTextAlignment(.center)
                .lineLimit(1).minimumScaleFactor(0.6)
                .frame(maxWidth: .infinity, minHeight: HubLayout.minHitTarget)
                .padding(.top, subtitle == nil ? 12 : 2)
                .accessibilityAddTraits(.isHeader)
            if let subtitle {
                Text(subtitle).font(.subheadline).foregroundStyle(subtitleColor)
                    .multilineTextAlignment(.center).lineLimit(1).minimumScaleFactor(0.8)
                    .padding(.top, 2)
            }
            // Title block plus gap is 80pt either way (12 + 44 + 24 on Fitness), so the rings line up.
            HStack(alignment: .top, spacing: 0) { stats }
                .padding(.top, subtitle == nil ? HubLayout.sectionGap : 12)
        }
        .frame(maxWidth: .infinity)
        .frame(height: HubLayout.heroHeight, alignment: .top)
    }
}

/// One of the three rings under a hero title: a fraction, its number inside, a label below.
struct HeroRing: View {
    var value: String
    var fraction: Double
    var tint: Color
    var label: String

    var body: some View {
        VStack(spacing: 8) {
            ScoreRing(value: value, fraction: fraction, tint: tint, size: 100, track: tint.opacity(0.16), weight: 0.09)
            Text(label).font(.subheadline.weight(.medium))
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(value)
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
    /// Shown when the card opens the history page.
    var chevron = false

    var body: some View {
        let today = Calendar.current.isDateInToday(day)
        BrickCard {
            HStack(spacing: 8) {
                if today { Circle().fill(BrickLook.live).frame(width: 9, height: 9) }
                BrickCaps(text: today ? "Today" : day.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()))
                    .foregroundStyle(today ? BrickLook.ink : BrickLook.soft)
                if chevron {
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right").font(.system(size: 14, weight: .medium)).foregroundStyle(BrickLook.soft)
                }
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

// MARK: Time earned back

/// Brick time read as life rather than minutes: days back, what that time is worth, and where the pace leads.
enum BrickLifeBack {
    /// "2.4 days", "14 hours", "35 min".
    static func span(_ seconds: TimeInterval) -> String {
        let h = seconds / 3600
        if h >= 24 { return String(format: h >= 240 ? "%.0f days" : "%.1f days", h / 24) }
        if h >= 1 { return String(format: h >= 10 ? "%.0f hours" : "%.1f hours", h) }
        return "\(Int(seconds / 60)) min"
    }

    /// What the time would have held: books past a book's worth (about 7 hours), films past one, else episodes.
    static func worth(_ seconds: TimeInterval) -> (value: String, label: String) {
        let h = seconds / 3600
        if h >= 7 { return ("\(Int(h / 7))", Int(h / 7) == 1 ? "book's worth" : "books' worth") }
        if h >= 2 { return ("\(Int(h / 2))", Int(h / 2) == 1 ? "film's worth" : "films' worth") }
        let e = Int(seconds / (45 * 60))
        return ("\(e)", e == 1 ? "episode's worth" : "episodes' worth")
    }

    /// Days a year at a daily pace.
    static func yearly(_ pace: TimeInterval) -> String {
        let d = pace * 365 / 86400
        return d >= 10 ? String(format: "%.0f days", d) : String(format: "%.1f days", d)
    }

    /// Share of a 16-hour waking day.
    static func wakingShare(_ pace: TimeInterval) -> String {
        "\(Int((pace / (16 * 3600) * 100).rounded()))%"
    }
}

/// One ring under the device: a short number, what it counts, and how full the ring is.
struct BrickLifeRing {
    var value: String
    var label: String
    var fraction: Double
    var tint: Color
}

extension BrickLifeBack {
    /// Milestones the "back" ring fills toward, in hours: a day, two, five, ten, then every 25 days.
    private static func nextMilestone(_ hours: Double) -> Double {
        for h in [1.0, 6, 12, 24, 48, 120, 240] where hours < h { return h }
        return (floor(hours / 600) + 1) * 600
    }

    /// Time back so far: hours under a day, then days. The ring fills toward the next milestone.
    static func backRing(_ seconds: TimeInterval) -> BrickLifeRing {
        let h = seconds / 3600
        let goal = nextMilestone(h)
        let value: String, label: String
        if h >= 24 { value = String(format: h >= 240 ? "%.0f" : "%.1f", h / 24); label = "Days back" }
        else if h >= 1 { value = String(format: h >= 10 ? "%.0f" : "%.1f", h); label = "Hours back" }
        else { value = "\(Int(seconds / 60))"; label = "Minutes back" }
        return BrickLifeRing(value: value, label: label, fraction: h / goal, tint: BrickLook.backTint)
    }

    /// What the time would have held, the ring filling toward the next one.
    static func heldRing(_ seconds: TimeInterval) -> BrickLifeRing {
        let h = seconds / 3600
        let (unit, name): (Double, String) = h >= 7 ? (7, "Books") : (h >= 2 ? (2, "Films") : (0.75, "Episodes"))
        let n = h / unit
        return BrickLifeRing(value: "\(Int(n))", label: "\(name)' worth", fraction: n - floor(n), tint: BrickLook.heldTint)
    }

    /// Days a year at the recent daily pace; the ring is that pace's share of a 16-hour waking day.
    static func paceRing(_ pace: TimeInterval?) -> BrickLifeRing {
        guard let pace else { return BrickLifeRing(value: "–", label: "Days a year", fraction: 0, tint: BrickLook.paceTint) }
        let d = pace * 365 / 86400
        return BrickLifeRing(value: d >= 10 ? String(format: "%.0f", d) : String(format: "%.1f", d),
                             label: "Days a year", fraction: pace / (16 * 3600), tint: BrickLook.paceTint)
    }
}

/// Three rings under the device, the way Fitness shows its scores: life back so far, what it would
/// have held, and the days a year at this pace. Each opens the history.
struct BrickLifeStats: View {
    let store: BrickStore
    var size: CGFloat = 100

    var body: some View {
        let total = store.lifetimeSeconds
        HStack(alignment: .top, spacing: 0) {
            ring(BrickLifeBack.backRing(total))
            ring(BrickLifeBack.heldRing(total))
            ring(BrickLifeBack.paceRing(total >= 60 ? store.dailyPace : nil))
        }
    }

    private func ring(_ r: BrickLifeRing) -> some View {
        NavigationLink(value: BrickRoute.activity) {
            VStack(spacing: 8) {
                ScoreRing(value: r.value, fraction: r.fraction, tint: r.tint, size: size, weight: 0.09, glass: true)
                Text(r.label).font(.subheadline.weight(.medium)).lineLimit(1).minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(r.value) \(r.label)")
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

    /// Sessions that touch this day. A mode that is (or became) a lockdown isn't Brick time, so its sessions don't show.
    func sessions(on day: Date) -> [BrickSession] {
        let start = cal.startOfDay(for: day)
        let end = start.addingTimeInterval(86400)
        let lockdownNames = Set(profiles.filter(\.lockdown).map(\.name))
        return sessions.filter { $0.start < end && ($0.end ?? now) > start && !lockdownNames.contains($0.profileName) }
    }

    /// Bricked time within this day, splitting sessions that cross midnight. Overlapping sessions count once.
    func seconds(on day: Date) -> TimeInterval {
        let start = cal.startOfDay(for: day)
        let end = start.addingTimeInterval(86400)
        let spans = sessions(on: day)
            .map { (max(start, $0.start), min(end, $0.end ?? now)) }
            .filter { $0.1 > $0.0 }
            .sorted { $0.0 < $1.0 }
        var total: TimeInterval = 0
        var cur: (Date, Date)?
        for s in spans {
            if let c = cur, s.0 <= c.1 { cur = (c.0, max(c.1, s.1)) }
            else { if let c = cur { total += c.1.timeIntervalSince(c.0) }; cur = s }
        }
        if let c = cur { total += c.1.timeIntervalSince(c.0) }
        return total
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

    /// Every span of Brick time ever, overlaps counted once and lockdowns left out. Runs to now while bricked.
    var lifetimeSeconds: TimeInterval {
        let lockdownNames = Set(profiles.filter(\.lockdown).map(\.name))
        let spans = sessions
            .filter { !lockdownNames.contains($0.profileName) }
            .map { ($0.start, $0.end ?? now) }
            .filter { $0.1 > $0.0 }
            .sorted { $0.0 < $1.0 }
        var total: TimeInterval = 0
        var cur: (Date, Date)?
        for s in spans {
            if let c = cur, s.0 <= c.1 { cur = (c.0, max(c.1, s.1)) }
            else { if let c = cur { total += c.1.timeIntervalSince(c.0) }; cur = s }
        }
        if let c = cur { total += c.1.timeIntervalSince(c.0) }
        return total
    }

    /// The first day with Brick time, if any.
    var firstBrickDay: Date? {
        let lockdownNames = Set(profiles.filter(\.lockdown).map(\.name))
        return sessions.filter { !lockdownNames.contains($0.profileName) }.map(\.start).min().map { cal.startOfDay(for: $0) }
    }

    /// Average Brick time a day over the last four weeks' finished days (fewer if Brick is newer).
    /// Today counts too when it's the only day there is. nil before any session.
    var dailyPace: TimeInterval? {
        guard let first = firstBrickDay else { return nil }
        let today = cal.startOfDay(for: Date())
        let from = max(first, cal.date(byAdding: .day, value: -28, to: today) ?? first)
        let days = cal.dateComponents([.day], from: from, to: today).day ?? 0
        guard days > 0 else { return seconds(on: today) }
        let total = (0..<days).reduce(0.0) { t, i in
            t + seconds(on: cal.date(byAdding: .day, value: i, to: from) ?? from)
        }
        return total / Double(days)
    }

    /// The longest single session, lockdowns left out.
    var longestSession: TimeInterval {
        let lockdownNames = Set(profiles.filter(\.lockdown).map(\.name))
        return sessions.filter { !lockdownNames.contains($0.profileName) }
            .map { ($0.end ?? now).timeIntervalSince($0.start) }.max() ?? 0
    }

    /// The day with the most Brick time since the first one.
    var bestDay: DayValue? {
        guard let first = firstBrickDay else { return nil }
        let today = cal.startOfDay(for: Date())
        var d = first, best: DayValue?
        while d <= today {
            let v = seconds(on: d)
            if v > (best?.value ?? 0) { best = DayValue(date: d, value: v) }
            d = cal.date(byAdding: .day, value: 1, to: d) ?? today.addingTimeInterval(86400)
        }
        return best
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
