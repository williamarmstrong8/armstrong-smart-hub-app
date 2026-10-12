import SwiftUI

/// Jarvis: a holographic HUD. A glowing core inside a ring of spectrum bars
/// that move with your voice (listening) or Jarvis's (speaking), wrapped in
/// segmented rings and tick marks that turn at different speeds and spin up
/// while it's thinking. Everything stays well inside the frame, and the glow
/// fades to nothing before the edge, so there's never a visible boundary.
struct Orb: View {
    let phase: VoiceAgent.Phase
    /// Reads the current (mic, output) levels, 0...1, every frame.
    let levels: () -> (mic: Float, output: Float)

    @State private var smoother = Smoother()
    @State private var spin = Spin()

    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let level = smoother.next(target: target(t))
            let angle = spin.advance(t: t, speed: speed)
            Canvas { ctx, size in
                draw(in: &ctx, size: size, t: t, angle: angle, level: level)
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityLabel(label)
    }

    private var label: String {
        switch phase {
        case .idle: "Jarvis"
        case .connecting: "Jarvis is waking up"
        case .listening: "Jarvis is listening"
        case .thinking: "Jarvis is thinking"
        case .speaking: "Jarvis is speaking"
        }
    }

    private func target(_ t: Double) -> Double {
        let (mic, out) = levels()
        switch phase {
        case .listening: return Double(mic)
        case .speaking: return min(Double(out) * 1.3, 1)
        case .thinking: return 0.3 + 0.12 * sin(t * 4)
        case .connecting: return 0.12 + 0.08 * sin(t * 6)
        case .idle: return 0.05
        }
    }

    /// Ring rotation speed, radians per second.
    private var speed: Double {
        switch phase {
        case .thinking: 2.4
        case .connecting: 1.4
        case .speaking: 0.7
        default: 0.4
        }
    }

    private var tint: Color {
        switch phase {
        case .thinking: Color(red: 0.45, green: 0.8, blue: 1)
        case .connecting, .idle: Color(red: 0.4, green: 0.65, blue: 0.85)
        default: Color(red: 0.3, green: 0.85, blue: 1)
        }
    }

    private func draw(in ctx: inout GraphicsContext, size: CGSize, t: Double, angle: Double, level: Double) {
        let d = min(size.width, size.height)
        let c = CGPoint(x: size.width / 2, y: size.height / 2)
        let tint = tint
        let line = max(1, d * 0.006)

        // Ambient glow, faded to zero well before the edge.
        let glowR = d * 0.48
        ctx.fill(
            Circle().path(in: CGRect(x: c.x - glowR, y: c.y - glowR, width: glowR * 2, height: glowR * 2)),
            with: .radialGradient(
                Gradient(stops: [
                    .init(color: tint.opacity(0.22 + 0.25 * level), location: 0),
                    .init(color: tint.opacity(0.06), location: 0.55),
                    .init(color: .clear, location: 1),
                ]),
                center: c, startRadius: 0, endRadius: glowR))

        ctx.drawLayer { hud in
            // A tight glow on every stroke; small enough to stay inside the frame.
            hud.addFilter(.shadow(color: tint.opacity(0.9), radius: d * 0.012))

            // Outer sweep: two thick arcs.
            let r4 = d * 0.40
            for k in 0..<2 {
                let start = angle * 1.6 + Double(k) * .pi
                hud.stroke(arc(c, r4, start, start + 1.9), with: .color(tint.opacity(0.85)), style: StrokeStyle(lineWidth: line * 2.2, lineCap: .round))
            }
            hud.stroke(Circle().path(in: rect(c, r4)), with: .color(tint.opacity(0.12)), lineWidth: line)

            // Tick ring, turning the other way.
            let r3 = d * 0.355
            for i in 0..<72 {
                let a = Double(i) / 72 * 2 * .pi - angle * 0.6
                let long = i % 6 == 0
                let inner = r3 - (long ? d * 0.03 : d * 0.014)
                var p = Path()
                p.move(to: point(c, inner, a))
                p.addLine(to: point(c, r3, a))
                hud.stroke(p, with: .color(tint.opacity(long ? 0.8 : 0.35)), lineWidth: line)
            }

            // Segmented ring.
            let r2 = d * 0.30
            hud.stroke(
                Circle().path(in: rect(c, r2)).applying(rotation(c, angle)),
                with: .color(tint.opacity(0.6)),
                style: StrokeStyle(lineWidth: line * 1.6, dash: [d * 0.05, d * 0.022]))

            // Spectrum: bars around the core that dance with the voice.
            let r1 = d * 0.19
            let bars = 64
            for i in 0..<bars {
                let a = Double(i) / Double(bars) * 2 * .pi
                let wave = 0.4 + 0.6 * abs(sin(Double(i) * 1.7 + t * 7 + sin(Double(i) * 0.31 + t * 2.3)))
                let len = d * (0.012 + 0.075 * level * wave)
                var p = Path()
                p.move(to: point(c, r1, a))
                p.addLine(to: point(c, r1 + len, a))
                hud.stroke(p, with: .color(tint.opacity(0.55 + 0.45 * level)), style: StrokeStyle(lineWidth: line * 1.3, lineCap: .round))
            }
            hud.stroke(Circle().path(in: rect(c, d * 0.165)), with: .color(tint.opacity(0.7)), lineWidth: line)
        }

        // Core: a bright center that swells with the voice.
        let core = d * (0.085 + 0.05 * level)
        ctx.fill(
            Circle().path(in: rect(c, core * 1.6)),
            with: .radialGradient(
                Gradient(colors: [.white, tint, tint.opacity(0)]),
                center: c, startRadius: 0, endRadius: core * 1.6))
    }

    private func rect(_ c: CGPoint, _ r: CGFloat) -> CGRect { CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2) }

    private func point(_ c: CGPoint, _ r: CGFloat, _ a: Double) -> CGPoint {
        CGPoint(x: c.x + cos(a) * r, y: c.y + sin(a) * r)
    }

    private func arc(_ c: CGPoint, _ r: CGFloat, _ from: Double, _ to: Double) -> Path {
        var p = Path()
        p.addArc(center: c, radius: r, startAngle: .radians(from), endAngle: .radians(to), clockwise: false)
        return p
    }

    private func rotation(_ c: CGPoint, _ a: Double) -> CGAffineTransform {
        CGAffineTransform(translationX: c.x, y: c.y).rotated(by: a).translatedBy(x: -c.x, y: -c.y)
    }
}

/// Eases the orb's size toward its target so it breathes instead of jittering.
private final class Smoother {
    private var value: Double = 0
    func next(target: Double) -> Double {
        let rate = target > value ? 0.35 : 0.1
        value += (min(max(target, 0), 1) - value) * rate
        return value
    }
}

/// Integrates rotation so changing speed (thinking spins up) never jumps.
private final class Spin {
    private var angle: Double = 0
    private var last: Double?
    private var current: Double = 0.4
    func advance(t: Double, speed: Double) -> Double {
        current += (speed - current) * 0.05
        if let last { angle += (t - last) * current }
        last = t
        return angle
    }
}
