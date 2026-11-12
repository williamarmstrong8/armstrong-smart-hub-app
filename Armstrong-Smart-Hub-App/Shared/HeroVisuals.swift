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
#endif
