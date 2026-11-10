import SwiftUI

/// A slow, quiet snowy-mountain scene to sit behind Liquid Glass so it has something to refract:
/// layered snow-capped ridges, drifting cloud, mist and a light snowfall. Day in light mode, dusk in dark.
struct MountainBackdrop: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let dark = scheme == .dark
        TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion)) { timeline in
            let t = reduceMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate
            Canvas { context, size in
                draw(&context, size: size, t: t, dark: dark)
            }
        }
        .drawingGroup()
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }

    // MARK: Drawing

    private func draw(_ ctx: inout GraphicsContext, size: CGSize, t: Double, dark: Bool) {
        let w = size.width, h = size.height

        // Sky
        let sky: [Color] = dark
            ? [Color(red: 0.05, green: 0.08, blue: 0.17), Color(red: 0.16, green: 0.22, blue: 0.38), Color(red: 0.36, green: 0.42, blue: 0.58)]
            : [Color(red: 0.52, green: 0.72, blue: 0.93), Color(red: 0.76, green: 0.87, blue: 0.97), Color(red: 0.95, green: 0.96, blue: 0.98)]
        ctx.fill(Path(CGRect(origin: .zero, size: size)),
                 with: .linearGradient(Gradient(colors: sky), startPoint: .zero, endPoint: CGPoint(x: 0, y: h * 0.7)))

        // Sun / moon glow, breathing slowly
        let pulse = 1 + 0.04 * sin(t / 5)
        let glowCenter = CGPoint(x: w * 0.78, y: h * 0.2)
        let glowColor: Color = dark ? Color(red: 0.75, green: 0.82, blue: 1) : Color(red: 1, green: 0.96, blue: 0.82)
        ctx.fill(Path(ellipseIn: CGRect(x: glowCenter.x - 160 * pulse, y: glowCenter.y - 160 * pulse, width: 320 * pulse, height: 320 * pulse)),
                 with: .radialGradient(Gradient(colors: [glowColor.opacity(dark ? 0.45 : 0.75), .clear]),
                                       center: glowCenter, startRadius: 0, endRadius: 160 * pulse))

        // Drifting cloud
        for i in 0..<5 {
            let seed = Double(i)
            let cw = w * (0.45 + 0.1 * seed.truncatingRemainder(dividingBy: 3))
            let speed = 6 + seed * 2.5
            let x = (t * speed + seed * w * 0.37).truncatingRemainder(dividingBy: w + cw * 2) - cw
            let y = h * (0.1 + 0.07 * seed)
            var layer = ctx
            layer.addFilter(.blur(radius: 22))
            layer.fill(Path(ellipseIn: CGRect(x: x, y: y, width: cw, height: cw * 0.22)),
                       with: .color((dark ? Color(red: 0.55, green: 0.62, blue: 0.8) : .white).opacity(dark ? 0.22 : 0.55)))
        }

        // Ridges, far to near
        let layers: [(base: Double, amp: Double, rock: Color, shade: Color, snow: Double)] = dark
            ? [(0.56, 0.20, Color(red: 0.22, green: 0.28, blue: 0.45), Color(red: 0.14, green: 0.19, blue: 0.33), 0.30),
               (0.68, 0.22, Color(red: 0.17, green: 0.22, blue: 0.37), Color(red: 0.10, green: 0.14, blue: 0.26), 0.26),
               (0.82, 0.20, Color(red: 0.11, green: 0.15, blue: 0.27), Color(red: 0.06, green: 0.09, blue: 0.18), 0.20)]
            : [(0.56, 0.20, Color(red: 0.62, green: 0.70, blue: 0.82), Color(red: 0.74, green: 0.81, blue: 0.9), 0.30),
               (0.68, 0.22, Color(red: 0.45, green: 0.55, blue: 0.70), Color(red: 0.62, green: 0.70, blue: 0.82), 0.26),
               (0.82, 0.20, Color(red: 0.30, green: 0.40, blue: 0.56), Color(red: 0.45, green: 0.55, blue: 0.70), 0.20)]

        for (i, l) in layers.enumerated() {
            let base = h * l.base, amp = h * l.amp
            var path = Path()
            path.move(to: CGPoint(x: 0, y: h))
            var x: CGFloat = 0
            while x <= w + 6 {
                path.addLine(to: CGPoint(x: x, y: base - ridge(Double(x) / Double(w), layer: i) * amp))
                x += 6
            }
            path.addLine(to: CGPoint(x: w, y: h))
            path.closeSubpath()

            let top = base - amp
            let snowEnd = top + amp * l.snow * 1.6
            ctx.fill(path, with: .linearGradient(
                Gradient(stops: [
                    .init(color: .white.opacity(dark ? 0.9 : 1), location: 0),
                    .init(color: .white.opacity(dark ? 0.85 : 0.95), location: 0.35),
                    .init(color: l.rock, location: 0.62),
                    .init(color: l.shade, location: 1),
                ]),
                startPoint: CGPoint(x: 0, y: top), endPoint: CGPoint(x: 0, y: max(snowEnd + amp, top + 1) + h * 0.12)))

            // Faces turned from the sun fall into shadow, so each peak reads as solid rock and snow.
            var xs: CGFloat = 0
            while xs <= w {
                let y0 = base - ridge(Double(xs) / Double(w), layer: i) * amp
                let y1 = base - ridge(Double(xs + 6) / Double(w), layer: i) * amp
                let slope = y1 - y0 // > 0: this face drops away to the right, away from the sun
                if slope > 0.4 {
                    let depth = min(amp * 0.5, slope * 9)
                    ctx.fill(Path(CGRect(x: xs, y: y0, width: 6.5, height: depth)),
                             with: .linearGradient(Gradient(colors: [l.shade.opacity(dark ? 0.55 : 0.5), .clear]),
                                                   startPoint: CGPoint(x: 0, y: y0), endPoint: CGPoint(x: 0, y: y0 + depth)))
                }
                xs += 6
            }

            // Mist between layers, drifting a little
            let mistY = base - amp * 0.15 + 8 * sin(t / 7 + Double(i))
            ctx.fill(Path(CGRect(x: 0, y: mistY, width: w, height: h - mistY)),
                     with: .linearGradient(Gradient(colors: [.clear, (dark ? Color(red: 0.4, green: 0.48, blue: 0.68) : .white).opacity(dark ? 0.18 : 0.4)]),
                                           startPoint: CGPoint(x: 0, y: mistY), endPoint: CGPoint(x: 0, y: mistY + amp * 0.7)))
        }

        // Snowfall
        for i in 0..<60 {
            let s = Double(i)
            let r = 1.2 + (s * 7.13).truncatingRemainder(dividingBy: 2.2)
            let speed = 14 + (s * 3.7).truncatingRemainder(dividingBy: 16)
            let y = ((s * 97.3).truncatingRemainder(dividingBy: h) + t * speed).truncatingRemainder(dividingBy: h + 20) - 10
            let x = (s * 53.9).truncatingRemainder(dividingBy: w) + 14 * sin(t / 3 + s)
            ctx.fill(Path(ellipseIn: CGRect(x: x, y: y, width: r * 2, height: r * 2)),
                     with: .color(.white.opacity(0.35 + (s * 1.7).truncatingRemainder(dividingBy: 0.4))))
        }
    }

    /// 0...1 sharp-peaked skyline, different per layer.
    private func ridge(_ u: Double, layer: Int) -> Double {
        let p = Double(layer) * 1.9
        let a = abs(sin(u * 5.2 + p))
        let b = abs(sin(u * 11.3 + p * 2.1)) * 0.35
        let c = abs(sin(u * 23 + p * 3.3)) * 0.12
        return min(1, (a * 0.75 + b + c) / 1.15)
    }
}
