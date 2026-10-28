import SwiftUI

/// Every light as a glowing tile. Changes animate in place: bulbs fade to their
/// new color, brightness bars slide, and the lights that just changed pulse.
struct LightsCard: View {
    let lights: [LightTile]
    let changed: [String]

    /// No title, just the lights, centered: as many across as fit, the rows centered too.
    var body: some View {
        ViewThatFits(in: .horizontal) {
            grid(4)
            grid(3)
            grid(2)
            grid(1)
        }
        .frame(maxWidth: .infinity)
    }

    /// Rows of `across` lights, each row centered (a short last row too).
    private func grid(_ across: Int) -> some View {
        let n = max(1, min(across, lights.count))
        let rows = stride(from: 0, to: lights.count, by: n).map { Array(lights[$0..<min($0 + n, lights.count)]) }
        return VStack(spacing: 52) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 40) {
                    ForEach(row) { light in
                        LightTileView(light: light, changed: changed.contains(light.id))
                            .frame(width: 200)
                    }
                }
            }
        }
        .fixedSize()
    }
}

private struct LightTileView: View {
    let light: LightTile
    let changed: Bool

    @State private var pulse = false

    var body: some View {
        let color = light.glowColor
        let level = light.on ? Double(light.brightnessPct ?? 100) / 100 : 0
        VStack(alignment: .center, spacing: 22) {
            ZStack {
                // The light's own glow, as bright as the light.
                Circle()
                    .fill(color.opacity(light.on ? 0.3 + 0.5 * level : 0))
                    .blur(radius: 40)
                    .scaleEffect(1.4)
                Circle()
                    .fill(light.on ? AnyShapeStyle(color.gradient) : AnyShapeStyle(Color.white.opacity(0.08)))
                    .overlay(Circle().strokeBorder(.white.opacity(light.on ? 0.25 : 0.15), lineWidth: 1))
                Image(systemName: light.on ? "lightbulb.fill" : "lightbulb")
                    .font(.system(size: 52, weight: .medium))
                    .foregroundStyle(light.on ? .white : .secondary)
                    .contentTransition(.symbolEffect(.replace))
            }
            .frame(width: 140, height: 140)

            VStack(spacing: 4) {
                Text(light.name).font(.title2.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.7)
                Text(light.on ? "\(light.brightnessPct ?? 100)%" : "Off")
                    .font(.title3.weight(.medium)).monospacedDigit()
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.1))
                    Capsule().fill(color.gradient).frame(width: max(0, geo.size.width * level))
                }
            }
            .frame(width: 170, height: 6)
        }
        .scaleEffect(pulse ? 1.05 : 1)
        .animation(.smooth(duration: 0.7), value: light)
        .onAppear { if changed { bump() } }
        .onChange(of: light) { if changed { bump() } }
    }

    private func bump() {
        withAnimation(.spring(duration: 0.35, bounce: 0.5).delay(0.15)) { pulse = true }
        withAnimation(.spring(duration: 0.5).delay(0.5)) { pulse = false }
    }
}

extension LightTile {
    /// The light's actual color: its RGB, its white temperature, or a warm default.
    var glowColor: Color {
        if let rgb, rgb.count == 3 { return Color(rgb: rgb) }
        if let kelvin {
            // 2000 K amber → 6500 K cool white.
            let t = min(max(Double(kelvin - 2000) / 4500, 0), 1)
            return Color(red: 1 - 0.08 * t, green: 0.62 + 0.33 * t, blue: 0.3 + 0.7 * t)
        }
        return Color(red: 1, green: 0.75, blue: 0.42)
    }
}
