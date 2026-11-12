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

/// The month as a field of dots: one row per habit, one dot per day. A done day is lit in that
/// habit's colour, a missed or upcoming one is a dim grey dot, and today gets a ring.
struct HabitDots: View {
    struct Row: Identifiable {
        let id: String
        let color: Color
        /// Days of the month (1...31) this habit was done.
        let done: Set<Int>
    }
    var rows: [Row]
    var date: Date = .now

    var body: some View {
        let cal = Calendar.current
        let days = cal.range(of: .day, in: .month, for: date)?.count ?? 30
        let today = cal.component(.day, from: date)
        GeometryReader { geo in
            let gap: CGFloat = 4
            let dot = max(4, min(14, (geo.size.width - gap * CGFloat(days - 1)) / CGFloat(days)))
            VStack(spacing: gap + 2) {
                ForEach(rows) { row in
                    HStack(spacing: gap) {
                        ForEach(1...days, id: \.self) { d in
                            Circle()
                                .fill(row.done.contains(d) ? row.color : (d > today ? HubDesign.ink.opacity(0.08) : HubDesign.ink.opacity(0.2)))
                                .overlay { if d == today { Circle().strokeBorder(HubDesign.ink.opacity(0.8), lineWidth: 1.5).padding(-2) } }
                                .frame(width: dot, height: dot)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Habit calendar for the month")
    }
}
/// The month as a calendar of dots, weeks as rows. A day with something in it is lit in `tint`,
/// brighter the more it holds (`level` is 0...1); an empty past day is a dim dot, a coming day fainter.
/// Today gets a ring.
struct MonthDots: View {
    var date: Date = .now
    /// Intensity 0...1 for each day of the month (1...31) that has something.
    var levels: [Int: Double]
    var tint: Color
    var label: String

    var body: some View {
        let cal = Calendar.current
        let days = cal.range(of: .day, in: .month, for: date)?.count ?? 30
        let today = cal.component(.day, from: date)
        let first = cal.date(from: cal.dateComponents([.year, .month], from: date)) ?? date
        let lead = (cal.component(.weekday, from: first) - cal.firstWeekday + 7) % 7
        let rows = (lead + days + 6) / 7
        GeometryReader { geo in
            let gap: CGFloat = 12
            let dot = max(8, min(26, (geo.size.width - gap * 6) / 7))
            VStack(spacing: gap) {
                ForEach(0..<rows, id: \.self) { row in
                    HStack(spacing: gap) {
                        ForEach(0..<7, id: \.self) { col in
                            let d = row * 7 + col - lead + 1
                            if d < 1 || d > days {
                                Color.clear.frame(width: dot, height: dot)
                            } else {
                                Circle()
                                    .fill(fill(d, today: today))
                                    .overlay { if d == today { Circle().strokeBorder(HubDesign.ink.opacity(0.8), lineWidth: 1.5).padding(-3) } }
                                    .frame(width: dot, height: dot)
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
    }

    private func fill(_ d: Int, today: Int) -> Color {
        if let l = levels[d], l > 0 { return tint.opacity(0.35 + 0.65 * min(l, 1)) }
        return HubDesign.ink.opacity(d > today ? 0.08 : 0.2)
    }
}
/// A half-circle gauge: a track, an arc filled to `fraction` with a bright knob at its end, `0` and
/// `goal` under the two feet, and `center` (the big figure) sitting inside.
struct ArcGauge<Center: View>: View {
    var fraction: Double
    var tint: Color
    var goalLabel: String
    @ViewBuilder var center: Center

    var body: some View {
        GeometryReader { geo in
            let lw: CGFloat = 12
            let r = min(geo.size.width / 2 - lw, geo.size.height - lw * 2)
            let f = max(0, min(fraction, 1))
            let angle = Angle.degrees(180 + 180 * f)
            ZStack {
                Circle().trim(from: 0, to: 0.5)
                    .stroke(HubDesign.ink.opacity(0.14), style: StrokeStyle(lineWidth: lw, lineCap: .round))
                    .frame(width: r * 2, height: r * 2).rotationEffect(.degrees(180))
                    .position(x: geo.size.width / 2, y: r + lw)
                Circle().trim(from: 0, to: 0.5 * f)
                    .stroke(tint, style: StrokeStyle(lineWidth: lw, lineCap: .round))
                    .frame(width: r * 2, height: r * 2).rotationEffect(.degrees(180))
                    .position(x: geo.size.width / 2, y: r + lw)
                Circle().fill(.white).frame(width: lw + 6, height: lw + 6)
                    .shadow(color: tint, radius: 6)
                    .position(x: geo.size.width / 2 + CGFloat(cos(angle.radians)) * r,
                              y: r + lw + CGFloat(sin(angle.radians)) * r)
                center.position(x: geo.size.width / 2, y: r * 0.72 + lw)
                Text("0").font(.caption).foregroundStyle(HubDesign.secondary)
                    .position(x: geo.size.width / 2 - r, y: r + lw * 2 + 10)
                Text(goalLabel).font(.caption).foregroundStyle(HubDesign.secondary)
                    .position(x: geo.size.width / 2 + r, y: r + lw * 2 + 10)
            }
        }
        .accessibilityElement(children: .ignore)
    }
}
#endif
