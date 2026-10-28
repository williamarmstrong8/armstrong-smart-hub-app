import SwiftUI

/// The weather at home: now, big; the next hours; then the coming days with
/// each day's range on one shared scale, like the Weather app. Used by Jarvis
/// and by the wall's Weather page.
struct WeatherCard: View {
    let data: WeatherData

    @State private var shown = false

    var body: some View {
        let c = data.current
        VStack(alignment: .leading, spacing: 36) {
            HStack(alignment: .center, spacing: 24) {
                Image(systemName: WeatherLook.symbol(c.code, isDay: c.isDay))
                    .symbolRenderingMode(.multicolor)
                    .font(.system(size: 84))
                    .symbolEffect(.bounce, value: shown)
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(c.temp)°")
                        .font(.system(size: 88, weight: .light).monospacedDigit())
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.title3.weight(.medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .minimumScaleFactor(0.8)
                }
            }

            // Wraps onto a second line rather than squeezing on a narrow screen.
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 64), spacing: 8)], spacing: 18) {
                ForEach(Array(data.hours.enumerated()), id: \.element.id) { i, h in
                    VStack(spacing: 8) {
                        Text(WeatherLook.hour(h.time, first: i == 0)).font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
                        Image(systemName: WeatherLook.symbol(h.code, isDay: h.isDay)).symbolRenderingMode(.multicolor).font(.title2)
                            .frame(height: 30)
                        Text("\(h.temp)°").font(.title3.weight(.medium)).monospacedDigit()
                        Text(rain(h.precipChance)).font(.caption.weight(.medium)).foregroundStyle(.cyan).monospacedDigit()
                    }
                    .opacity(shown ? 1 : 0)
                    .offset(y: shown ? 0 : 14)
                    .animation(.spring(duration: 0.5).delay(0.03 * Double(i)), value: shown)
                }
            }

            VStack(spacing: 0) {
                let low = data.days.map(\.low).min() ?? 0
                let high = data.days.map(\.high).max() ?? 1
                ForEach(Array(data.days.enumerated()), id: \.element.id) { i, d in
                    if i > 0 { Divider() }
                    HStack(spacing: 16) {
                        Text(WeatherLook.weekday(d.day, first: i == 0)).font(.title3.weight(.medium))
                            .frame(width: 76, alignment: .leading)
                        Image(systemName: WeatherLook.symbol(d.code)).symbolRenderingMode(.multicolor).font(.title2)
                            .frame(width: 40)
                        Text(rain(d.precipChance)).font(.subheadline.weight(.medium)).foregroundStyle(.cyan).monospacedDigit()
                            .frame(width: 44, alignment: .leading)
                        Text("\(d.low)°").font(.title3).foregroundStyle(.secondary).monospacedDigit()
                            .frame(width: 48, alignment: .trailing)
                        RangeBar(low: d.low, high: d.high, floor: low, ceiling: high, progress: shown ? 1 : 0)
                            .frame(height: 6)
                            .animation(.spring(duration: 0.7).delay(0.05 * Double(i)), value: shown)
                        Text("\(d.high)°").font(.title3.weight(.medium)).monospacedDigit()
                            .frame(width: 48, alignment: .leading)
                    }
                    .padding(.vertical, 12)
                }
            }
        }
        .onAppear { shown = true }
    }

    private var subtitle: String {
        var parts = [data.current.label, "Feels like \(data.current.feelsLike)°"]
        if let today = data.days.first { parts.append("H \(today.high)° L \(today.low)°") }
        return parts.joined(separator: " · ")
    }

    private func rain(_ chance: Int?) -> String {
        guard let chance, chance >= 20 else { return " " }
        return "\(chance)%"
    }
}

/// A day's low-to-high on the week's scale, cool to warm.
private struct RangeBar: View {
    let low: Int
    let high: Int
    let floor: Int
    let ceiling: Int
    let progress: Double

    var body: some View {
        GeometryReader { geo in
            let span = Double(max(ceiling - floor, 1))
            let start = Double(low - floor) / span
            let width = max(Double(high - low) / span, 0.04) * progress
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule()
                    .fill(LinearGradient(colors: [.cyan, .green, .yellow, .orange], startPoint: .leading, endPoint: .trailing))
                    .frame(width: geo.size.width * width)
                    .offset(x: geo.size.width * start)
            }
        }
    }
}
