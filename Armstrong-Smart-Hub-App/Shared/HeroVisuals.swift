import SwiftUI

#if os(iOS)
/// The pictures at the top of Home, Finance and Reflection. Each draws the page's own data
/// where Fitness has the watch, fading into the sheet at its top and bottom edge.
private struct HeroFade: ViewModifier {
    func body(content: Content) -> some View {
        content.mask(
            LinearGradient(stops: [.init(color: .clear, location: 0),
                                   .init(color: .black, location: 0.1),
                                   .init(color: .black, location: 0.9),
                                   .init(color: .clear, location: 1)],
                           startPoint: .top, endPoint: .bottom)
        )
    }
}

/// The month as bare squares, weeks as rows: filled for each day in `done`, empty otherwise.
/// Today gets a brighter outline while it is still to be done.
struct MonthSquares: View {
    var date: Date = .now
    /// Days of the month (1...31) that count as done.
    var done: Set<Int>
    var side: CGFloat = 28
    var gap: CGFloat = 8

    var body: some View {
        let cal = Calendar.current
        let days = cal.range(of: .day, in: .month, for: date)?.count ?? 30
        let today = cal.component(.day, from: date)
        let first = cal.date(from: cal.dateComponents([.year, .month], from: date)) ?? date
        let lead = (cal.component(.weekday, from: first) - cal.firstWeekday + 7) % 7
        let rows = (lead + days + 6) / 7
        VStack(spacing: gap) {
            ForEach(0..<rows, id: \.self) { row in
                HStack(spacing: gap) {
                    ForEach(0..<7, id: \.self) { col in
                        square(row * 7 + col - lead + 1, today: today, days: days)
                    }
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(done.count) of \(today) days done this month")
    }

    @ViewBuilder
    private func square(_ day: Int, today: Int, days: Int) -> some View {
        let shape = RoundedRectangle(cornerRadius: 7, style: .continuous)
        if day < 1 || day > days {
            Color.clear.frame(width: side, height: side)
        } else if done.contains(day) {
            shape.fill(Color.green).frame(width: side, height: side)
        } else {
            shape.strokeBorder(HubDesign.ink.opacity(day == today ? 0.8 : 0.22), lineWidth: day == today ? 2 : 1.5)
                .frame(width: side, height: side)
        }
    }
}

/// This month's spending as a glowing running total by day, against last month's faint line.
/// Rent and transfers are left out, as in the hero's headline.
struct SpendTrend: View {
    var transactions: [Transaction]
    var tint: Color = .orange

    /// Running spend for each day of the month containing `date`, up to `through` (or the whole month).
    private static func running(_ txs: [Transaction], month date: Date, through: Int?) -> [Double] {
        let cal = Calendar.current
        let days = cal.range(of: .day, in: .month, for: date)?.count ?? 30
        var perDay = [Double](repeating: 0, count: days)
        for t in txs where t.netEffect < 0 && !t.hold && t.category != "Rent" && t.category != "Transfers"
            && cal.isDate(t.date, equalTo: date, toGranularity: .month) {
            perDay[min(cal.component(.day, from: t.date), days) - 1] += abs(t.netEffect)
        }
        var total = 0.0
        let upTo = min(through ?? days, days)
        return (0..<upTo).map { total += perDay[$0]; return total }
    }

    var body: some View {
        let cal = Calendar.current
        let today = cal.component(.day, from: .now)
        let prev = cal.date(byAdding: .month, value: -1, to: .now) ?? .now
        let now = Self.running(transactions, month: .now, through: today)
        let last = Self.running(transactions, month: prev, through: nil)
        let daysInMonth = cal.range(of: .day, in: .month, for: .now)?.count ?? 30
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let top = h * 0.16, bottom = h * 0.84
            let hi = max(now.max() ?? 0, last.max() ?? 0, 1)
            let xy: (Int, Double, Int) -> CGPoint = { i, v, count in
                CGPoint(x: w * Double(i) / Double(max(daysInMonth - 1, 1)), y: bottom - (bottom - top) * v / hi)
            }
            let lastLine = Path { p in
                for (i, v) in last.enumerated() { i == 0 ? p.move(to: xy(i, v, last.count)) : p.addLine(to: xy(i, v, last.count)) }
            }
            let line = Path { p in
                for (i, v) in now.enumerated() { i == 0 ? p.move(to: xy(i, v, now.count)) : p.addLine(to: xy(i, v, now.count)) }
            }
            ZStack {
                lastLine.stroke(HubDesign.secondary.opacity(0.5), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round, dash: [2, 5]))
                line
                    .stroke(tint, style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                    .shadow(color: tint.opacity(0.6), radius: 8)
                if let end = now.last {
                    let pt = xy(now.count - 1, end, now.count)
                    Path { p in
                        p.addPath(line)
                        p.addLine(to: CGPoint(x: pt.x, y: h))
                        p.addLine(to: CGPoint(x: 0, y: h))
                        p.closeSubpath()
                    }
                    .fill(LinearGradient(colors: [tint.opacity(0.32), tint.opacity(0)], startPoint: .top, endPoint: .bottom))
                    Circle().fill(tint).frame(width: 10, height: 10).shadow(color: tint, radius: 6).position(pt)
                }
            }
            .overlay(alignment: .topLeading) {
                HStack(spacing: 14) {
                    Label("This month", systemImage: "circle.fill").foregroundStyle(tint)
                    Label("Last month", systemImage: "circle").foregroundStyle(HubDesign.secondary)
                }
                .labelStyle(DotLabel())
                .font(.caption.weight(.medium))
            }
        }
        .modifier(HeroFade())
        .accessibilityHidden(true)
    }

    private struct DotLabel: LabelStyle {
        func makeBody(configuration: Configuration) -> some View {
            HStack(spacing: 5) { configuration.icon.font(.system(size: 6)); configuration.title }
        }
    }
}

/// A slowly breathing orb of rings, with the total mindful minutes at its heart.
struct ReflectionOrb: View {
    var minutes: Int
    /// Mindful minutes for each of the last seven days, oldest first; the ring glows brighter for longer days.
    var week: [Int]
    var tint: Color = .teal
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var inhaled = false

    var body: some View {
        GeometryReader { geo in
            let size = min(geo.size.height - 8, 210)
            let peak = Double(max(week.max() ?? 0, 1))
            ZStack {
                ForEach(0..<3, id: \.self) { i in
                    Circle()
                        .strokeBorder(tint.opacity(0.5 - Double(i) * 0.14), lineWidth: 1.5)
                        .background(Circle().fill(tint.opacity(0.07)))
                        .frame(width: size * (0.62 + Double(i) * 0.19), height: size * (0.62 + Double(i) * 0.19))
                        .scaleEffect(inhaled ? 1.06 : 0.94)
                        .animation(reduceMotion ? nil : .easeInOut(duration: 4).repeatForever(autoreverses: true).delay(Double(i) * 0.25), value: inhaled)
                }
                // One bead per day around the orb, brighter the longer that day's sitting.
                ForEach(Array(week.enumerated()), id: \.offset) { i, m in
                    let angle = Double(i) / 7 * 2 * .pi - .pi / 2
                    Circle()
                        .fill(m > 0 ? tint.opacity(0.45 + 0.55 * Double(m) / peak) : tint.opacity(0.18))
                        .frame(width: m > 0 ? 12 : 8, height: m > 0 ? 12 : 8)
                        .shadow(color: m > 0 ? tint.opacity(0.8) : .clear, radius: 5)
                        .offset(x: cos(angle) * size * 0.5, y: sin(angle) * size * 0.5)
                }
                VStack(spacing: 0) {
                    Text("\(minutes)").font(.system(size: size * 0.24, weight: .light).monospacedDigit())
                    Text("mindful min").font(.caption.weight(.medium)).tracking(1).textCase(.uppercase).foregroundStyle(HubDesign.secondary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .modifier(HeroFade())
        .onAppear { inhaled = true }
        .accessibilityHidden(true)
    }
}
#endif
