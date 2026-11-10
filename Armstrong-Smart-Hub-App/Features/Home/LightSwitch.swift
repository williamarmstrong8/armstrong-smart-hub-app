import SwiftUI

/// A light as a wide liquid-glass pill, stacked one per row. Drag the knob to set the brightness
/// (it releases to the lamp when you let go); tap to switch on or off; double-tap for color and temperature.
struct LightSwitch: View {
    let entity: HAEntity
    let pending: Bool
    var large = false
    let onTap: () -> Void
    let onAdjust: () -> Void
    let onBrightness: (Int) -> Void

    @GestureState private var pressed = false
    /// 0...1 while the knob is being dragged; the lamp is only told on release.
    @State private var dragProgress: Double?
    @State private var dragBase: Double?

    var body: some View {
        let on = entity.isOn
        let tint = tintColor
        let height: CGFloat = large ? 104 : 80
        let inset: CGFloat = large ? 10 : 8
        let knob = height - inset * 2
        let adjustable = entity.supportsBrightness && !entity.isUnavailable
        let progress = dragProgress ?? (on ? max(0.04, Double(entity.brightnessPct) / 100) : 0)
        let lit = on || dragProgress != nil

        GeometryReader { geo in
            let travel = max(geo.size.width - knob - inset * 2, 1)
            let x = inset + travel * progress

            ZStack(alignment: .leading) {
                // Glow that follows the knob, in the lamp's color.
                Capsule()
                    .fill(LinearGradient(
                        colors: [tint.opacity(0.95), tint.opacity(0.35), .clear],
                        startPoint: UnitPoint(x: x / geo.size.width + 0.1, y: 0.5),
                        endPoint: UnitPoint(x: max(0, x / geo.size.width - 0.55), y: 0.5)
                    ))
                    .blur(radius: 6)
                    .clipShape(.capsule)
                    .opacity(lit ? 1 : 0)

                // The name sits on whichever side has more room.
                HStack(spacing: 0) {
                    if progress > 0.5 { label; Spacer(minLength: 0) } else { Spacer(minLength: 0); label }
                }
                .padding(.horizontal, knob * 0.45 + inset)
                .allowsHitTesting(false)

                Circle()
                    .fill(.clear)
                    .frame(width: knob, height: knob)
                    .glassEffect(.regular.tint(lit ? tint.opacity(0.85) : .clear).interactive(), in: .circle)
                    .overlay {
                        Image(systemName: lit ? "lightbulb.max.fill" : "lightbulb")
                            .font(.system(size: knob * 0.42, weight: .medium))
                            .foregroundStyle(lit ? .white : .secondary)
                            .shadow(color: lit ? tint.opacity(0.8) : .clear, radius: 6)
                    }
                    .offset(x: x)
                    .highPriorityGesture(
                        DragGesture(minimumDistance: 6)
                            .onChanged { g in
                                guard adjustable else { return }
                                if dragBase == nil { dragBase = progress }
                                dragProgress = min(1, max(0, (dragBase ?? 0) + g.translation.width / travel))
                            }
                            .onEnded { _ in
                                guard let p = dragProgress else { return }
                                dragProgress = nil
                                dragBase = nil
                                onBrightness(max(1, Int((p * 100).rounded())))
                            }
                    )
            }
        }
        .frame(height: height)
        .glassEffect(.regular, in: .capsule)
        .overlay(Capsule().strokeBorder(.white.opacity(0.18), lineWidth: 1))
        .contentShape(.capsule)
        .scaleEffect(pressed ? 0.98 : 1)
        .opacity(entity.isUnavailable ? 0.5 : pending ? 0.8 : 1)
        .animation(dragProgress == nil ? .spring(duration: 0.35, bounce: 0.2) : nil, value: progress)
        .animation(.spring(duration: 0.2), value: pressed)
        // Double-tap opens the color and temperature panel; a single tap toggles.
        .onTapGesture(count: 2) { if !entity.isUnavailable { onAdjust() } }
        .onTapGesture { if !entity.isUnavailable { onTap() } }
        .sensoryFeedback(.impact(weight: .medium), trigger: on)
        .sensoryFeedback(.selection, trigger: Int((dragProgress ?? 0) * 20))
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("\(entity.name), \(entity.stateLabel)")
        .accessibilityAction { onTap() }
        .accessibilityAction(named: "Color and temperature") { onAdjust() }
        .accessibilityAdjustableAction { direction in
            let step = direction == .increment ? 10 : -10
            onBrightness(min(100, max(1, entity.brightnessPct + step)))
        }
    }

    private var label: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(entity.name)
                .font(.system(size: large ? 22 : 18, weight: .medium))
                .lineLimit(1)
            Text(dragProgress.map { "\(max(1, Int(($0 * 100).rounded())))%" } ?? entity.stateLabel)
                .font(large ? .callout : .caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .lineLimit(1)
        }
        .foregroundStyle(.primary)
    }

    private var tintColor: Color {
        if let rgb = entity.rgbColor { return Color(rgb: rgb) }
        return .orange
    }
}
