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
/// Reflection's picture: a soft orb that breathes in and out (about a 10-second cycle) above a
/// still waterline, mirrored in the water below, with ripples spreading out from where the
/// reflection meets it. Holds still when Reduce Motion is on.
struct ReflectionPond: View {
    var tint: Color = .teal
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(paused: reduceMotion)) { context in
            let t = reduceMotion ? 2.5 : context.date.timeIntervalSinceReferenceDate
            Canvas { ctx, size in
                let w = size.width, h = size.height
                let horizon = h * 0.62
                let cx = w / 2
                // 0...1 breath: in over 5 s, out over 5 s.
                let breath = (1 - cos(t * .pi / 5)) / 2
                let r = min(w, h) * (0.2 + 0.05 * breath)
                let orbY = horizon - r - h * 0.06

                // Glow behind the orb.
                let glowR = r * 2.4
                ctx.fill(Path(ellipseIn: CGRect(x: cx - glowR, y: orbY - glowR, width: glowR * 2, height: glowR * 2)),
                         with: .radialGradient(Gradient(colors: [tint.opacity(0.28 + 0.12 * breath), tint.opacity(0)]),
                                               center: CGPoint(x: cx, y: orbY), startRadius: r * 0.6, endRadius: glowR))
                // The orb.
                ctx.fill(Path(ellipseIn: CGRect(x: cx - r, y: orbY - r, width: r * 2, height: r * 2)),
                         with: .radialGradient(Gradient(colors: [.white.opacity(0.95), tint.opacity(0.85), tint.opacity(0.55)]),
                                               center: CGPoint(x: cx - r * 0.3, y: orbY - r * 0.35), startRadius: 0, endRadius: r * 1.3))

                // Waterline.
                var line = Path()
                line.move(to: CGPoint(x: w * 0.08, y: horizon))
                line.addLine(to: CGPoint(x: w * 0.92, y: horizon))
                ctx.stroke(line, with: .linearGradient(Gradient(colors: [.clear, HubDesign.ink.opacity(0.35), .clear]),
                                                         startPoint: CGPoint(x: w * 0.08, y: horizon),
                                                         endPoint: CGPoint(x: w * 0.92, y: horizon)), lineWidth: 1)

                // The reflection: the orb flipped, squashed and faded, broken into shimmering bands.
                let reflY = horizon + (horizon - orbY) * 0.55
                let rx = r, ry = r * 0.55
                for i in 0..<7 {
                    let band = Double(i) / 7
                    let y = reflY - ry + CGFloat(band) * ry * 2
                    let half = rx * sqrt(max(0, 1 - pow((y - reflY) / ry, 2)))
                    let wobble = sin(t * 1.6 + Double(i) * 0.9) * Double(r) * 0.06
                    let rect = CGRect(x: cx - half + wobble, y: y, width: half * 2, height: ry * 2 / 7 * 0.6)
                    ctx.fill(Path(roundedRect: rect, cornerRadius: rect.height / 2),
                             with: .color(tint.opacity(0.35 * (1 - band * 0.8))))
                }

                // Ripples spreading from the water under the orb, three at a time.
                for k in 0..<3 {
                    let phase = (t / 6 + Double(k) / 3).truncatingRemainder(dividingBy: 1)
                    let rr = CGFloat(phase) * w * 0.42 + r * 0.6
                    let ripple = CGRect(x: cx - rr, y: horizon + 4 - rr * 0.12, width: rr * 2, height: rr * 0.24)
                    ctx.stroke(Path(ellipseIn: ripple), with: .color(HubDesign.ink.opacity(0.22 * (1 - phase))), lineWidth: 1)
                }
            }
        }
        .modifier(HeroFade())
        .accessibilityHidden(true)
    }
}
#endif
