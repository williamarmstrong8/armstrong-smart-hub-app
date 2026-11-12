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
#endif
