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
/// A half-circle gauge: a track, an arc filled to `fraction` with a knob at its end, and `center`
/// (the big figure) sitting inside.
struct ArcGauge<Center: View>: View {
    var fraction: Double
    var tint: Color
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
                    .position(x: geo.size.width / 2 + CGFloat(cos(angle.radians)) * r,
                              y: r + lw + CGFloat(sin(angle.radians)) * r)
                center.position(x: geo.size.width / 2, y: r * 0.72 + lw)
            }
        }
        .accessibilityElement(children: .ignore)
    }
}
#endif
