import SwiftUI

/// An Oura-style ambient background: soft, slowly morphing fields of icy blue, glacier teal and
/// lavender-white that give Liquid Glass something to refract. No hard shapes, just light and depth.
struct AmbientBackdrop: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let dark = scheme == .dark
        TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion)) { timeline in
            let t = reduceMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate / 9
            MeshGradient(width: 3, height: 4, points: points(t), colors: colors(dark: dark))
                .overlay { grain(dark: dark) }
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }

    /// Interior points wander a little; the border stays pinned so the edges never show a seam.
    private func points(_ t: Double) -> [SIMD2<Float>] {
        func w(_ x: Float, _ y: Float, _ i: Double, _ a: Float = 0.07) -> SIMD2<Float> {
            SIMD2(x + a * Float(sin(t + i)), y + a * Float(cos(t * 0.8 + i * 1.7)))
        }
        return [
            [0, 0], [0.5, 0], [1, 0],
            [0, 0.33], w(0.45, 0.30, 1), [1, 0.33],
            [0, 0.66], w(0.60, 0.68, 2), [1, 0.66],
            [0, 1], [0.5, 1], [1, 1],
        ]
    }

    private func colors(dark: Bool) -> [Color] {
        if dark {
            return [
                Color(red: 0.04, green: 0.07, blue: 0.16), Color(red: 0.09, green: 0.15, blue: 0.32), Color(red: 0.18, green: 0.14, blue: 0.34),
                Color(red: 0.06, green: 0.14, blue: 0.28), Color(red: 0.16, green: 0.36, blue: 0.52), Color(red: 0.12, green: 0.18, blue: 0.40),
                Color(red: 0.05, green: 0.12, blue: 0.24), Color(red: 0.20, green: 0.46, blue: 0.58), Color(red: 0.28, green: 0.30, blue: 0.56),
                Color(red: 0.03, green: 0.06, blue: 0.13), Color(red: 0.07, green: 0.16, blue: 0.30), Color(red: 0.10, green: 0.10, blue: 0.24),
            ]
        }
        return [
            Color(red: 0.62, green: 0.78, blue: 0.96), Color(red: 0.78, green: 0.86, blue: 0.98), Color(red: 0.86, green: 0.82, blue: 0.98),
            Color(red: 0.70, green: 0.86, blue: 0.97), Color(red: 0.98, green: 0.99, blue: 1.00), Color(red: 0.80, green: 0.84, blue: 0.98),
            Color(red: 0.56, green: 0.80, blue: 0.90), Color(red: 0.84, green: 0.93, blue: 0.98), Color(red: 0.74, green: 0.76, blue: 0.96),
            Color(red: 0.46, green: 0.66, blue: 0.86), Color(red: 0.60, green: 0.78, blue: 0.92), Color(red: 0.66, green: 0.68, blue: 0.90),
        ]
    }

    /// Fine, still film grain, the thing that makes these gradients feel printed, not digital.
    private func grain(dark: Bool) -> some View {
        Canvas { ctx, size in
            var rng = SystemRandomNumberGenerator()
            _ = rng
            for i in 0..<2200 {
                let s = Double(i)
                let x = (s * 127.1).truncatingRemainder(dividingBy: size.width)
                let y = (s * 311.7 + s * s * 0.37).truncatingRemainder(dividingBy: size.height)
                ctx.fill(Path(CGRect(x: x, y: y, width: 1, height: 1)),
                         with: .color((i % 2 == 0 ? Color.white : Color.black).opacity(dark ? 0.05 : 0.035)))
            }
        }
        .allowsHitTesting(false)
    }
}
