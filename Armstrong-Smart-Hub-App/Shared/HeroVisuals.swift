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
