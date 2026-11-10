import SwiftUI

/// A light as a wide liquid-glass pill, stacked one per row. The knob slides to the right and the
/// pill glows in the lamp's color when it's on; the name sits inside, opposite the knob.
/// Tap toggles, hold adjusts.
struct LightSwitch: View {
    let entity: HAEntity
    let pending: Bool
    var large = false
    let onTap: () -> Void
    let onAdjust: () -> Void

    @GestureState private var pressed = false
    @State private var held = false

    var body: some View {
        let on = entity.isOn
        let tint = tintColor
        let height: CGFloat = large ? 104 : 80
        let inset: CGFloat = large ? 10 : 8
        let knob = height - inset * 2

        ZStack {
            // Warm glow bleeding in from the knob's side, like the day/night switch.
            Capsule()
                .fill(LinearGradient(
                    colors: [tint.opacity(on ? 0.95 : 0), tint.opacity(on ? 0.35 : 0), .clear],
                    startPoint: .trailing, endPoint: .leading
                ))
                .blur(radius: 6)
                .clipShape(.capsule)
                .opacity(on ? 1 : 0)

            HStack(spacing: 0) {
                if on { label(on: on) }
                Spacer(minLength: 0)
                if !on { label(on: on) }
            }
            .padding(.horizontal, knob * 0.45)

            Circle()
                .fill(.clear)
                .frame(width: knob, height: knob)
                .glassEffect(.regular.tint(on ? tint.opacity(0.85) : .clear).interactive(), in: .circle)
                .overlay {
                    Image(systemName: on ? "lightbulb.max.fill" : "lightbulb")
                        .font(.system(size: knob * 0.42, weight: .medium))
                        .foregroundStyle(on ? .white : .secondary)
                        .shadow(color: on ? tint.opacity(0.8) : .clear, radius: 6)
                }
                .frame(maxWidth: .infinity, alignment: on ? .trailing : .leading)
                .padding(.horizontal, inset)
        }
        .frame(maxWidth: .infinity)
        .frame(height: height)
        .glassEffect(.regular, in: .capsule)
        .overlay(Capsule().strokeBorder(.white.opacity(0.18), lineWidth: 1))
        .contentShape(.capsule)
        .scaleEffect(pressed ? 0.97 : 1)
        .opacity(entity.isUnavailable ? 0.5 : pending ? 0.8 : 1)
        .animation(.spring(duration: 0.35, bounce: 0.25), value: on)
        .animation(.spring(duration: 0.2), value: pressed)
        // A quick tap toggles; holding adjusts instead, without also toggling.
        .onTapGesture {
            if held { held = false } else if !entity.isUnavailable { onTap() }
        }
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.4)
                .updating($pressed) { value, state, _ in state = value }
                .onEnded { _ in
                    held = true
                    if !entity.isUnavailable { onAdjust() }
                }
        )
        .onChange(of: pressed) { _, down in if down { held = false } }
        .sensoryFeedback(.impact(weight: .medium), trigger: on)
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("\(entity.name), \(entity.stateLabel)")
        .accessibilityAction { onTap() }
        .accessibilityAction(named: "Adjust") { onAdjust() }
    }

    private func label(on: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(entity.name)
                .font(.system(size: large ? 22 : 18, weight: .medium))
                .lineLimit(1)
            Text(entity.stateLabel)
                .font(large ? .callout : .caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .lineLimit(1)
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, 6)
    }

    private var tintColor: Color {
        if let rgb = entity.rgbColor { return Color(rgb: rgb) }
        return .orange
    }
}
