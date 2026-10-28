import SwiftUI

/// The weather at home, for reading across the room: the temperature huge,
/// what it's doing, and today's high and low. Used by Jarvis and by the
/// wall's Weather page.
struct WeatherCard: View {
    let data: WeatherData

    @State private var shown = false

    var body: some View {
        let c = data.current
        VStack(spacing: 16) {
            Image(systemName: WeatherLook.symbol(c.code, isDay: c.isDay))
                .symbolRenderingMode(.multicolor)
                .font(.system(size: 120))
                .symbolEffect(.bounce, value: shown)
            Text("\(c.temp)°")
                .font(.system(size: 180, weight: .light).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.5)
            Text(c.label)
                .font(.system(size: 40, weight: .semibold, design: .rounded))
            if let today = data.days.first {
                Text(detail(today))
                    .font(.title2.weight(.medium))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .opacity(shown ? 1 : 0)
        .scaleEffect(shown ? 1 : 0.94)
        .onAppear { withAnimation(.spring(duration: 0.6, bounce: 0.2)) { shown = true } }
    }

    /// "High 58° · Low 44° · Rain at 4 PM", the rain only when it's likely.
    private func detail(_ today: WeatherDay) -> String {
        var parts = ["High \(today.high)°", "Low \(today.low)°"]
        if let i = data.hours.firstIndex(where: { ($0.precipChance ?? 0) >= 50 }) {
            parts.append(i == 0 ? "Rain now" : "Rain at \(WeatherLook.hour(data.hours[i].time, first: false))")
        }
        return parts.joined(separator: " · ")
    }
}
