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

/// Two concentric rings for the day: habits done outside, steps inside.
struct HomeDayDial: View {
    var habits: Double
    var steps: Double
    var center: String
    var caption: String

    var body: some View {
        GeometryReader { geo in
            let size = min(geo.size.height - 8, 210)
            ZStack {
                Circle()
                    .fill(RadialGradient(colors: [Color.green.opacity(0.3), .clear], center: .center, startRadius: 0, endRadius: size * 0.7))
                    .frame(width: size * 1.4, height: size * 1.4)
                ring(habits, .green, width: size, line: size * 0.085)
                ring(steps, .orange, width: size * 0.72, line: size * 0.085)
                VStack(spacing: 0) {
                    Text(center).font(.system(size: size * 0.2, weight: .light).monospacedDigit())
                    Text(caption).font(.caption.weight(.medium)).tracking(1).textCase(.uppercase).foregroundStyle(HubDesign.secondary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .modifier(HeroFade())
        .accessibilityHidden(true)
    }

    private func ring(_ fraction: Double, _ tint: Color, width: CGFloat, line: CGFloat) -> some View {
        ZStack {
            Circle().stroke(tint.opacity(0.16), lineWidth: line)
            Circle().trim(from: 0, to: max(0.004, min(1, fraction)))
                .stroke(tint, style: StrokeStyle(lineWidth: line, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .opacity(fraction > 0 ? 1 : 0)
                .hubAnimation(value: fraction)
        }
        .frame(width: width, height: width)
    }
}

/// Net worth as a glowing line, oldest at the left.
struct NetWorthTrend: View {
    var series: [SeriesPoint]
    var tint: Color = .green

    var body: some View {
        let points = Array(series.suffix(90))
        let values = points.map(\.value)
        GeometryReader { geo in
            if let lo = values.min(), let hi = values.max(), values.count > 1 {
                let span = max(hi - lo, 1)
                let w = geo.size.width, h = geo.size.height
                let top = h * 0.16, bottom = h * 0.84
                let xy: (Int) -> CGPoint = { i in
                    CGPoint(x: w * Double(i) / Double(values.count - 1),
                            y: bottom - (bottom - top) * (values[i] - lo) / span)
                }
                let line = Path { p in
                    p.move(to: xy(0))
                    for i in 1..<values.count { p.addLine(to: xy(i)) }
                }
                ZStack {
                    line
                        .stroke(tint, style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                        .shadow(color: tint.opacity(0.6), radius: 8)
                    Path { p in
                        p.addPath(line)
                        p.addLine(to: CGPoint(x: w, y: h))
                        p.addLine(to: CGPoint(x: 0, y: h))
                        p.closeSubpath()
                    }
                    .fill(LinearGradient(colors: [tint.opacity(0.32), tint.opacity(0)], startPoint: .top, endPoint: .bottom))
                    Circle().fill(tint).frame(width: 10, height: 10)
                        .shadow(color: tint, radius: 6)
                        .position(xy(values.count - 1))
                }
                .overlay(alignment: .topLeading) {
                    if let first = points.first?.day, let last = points.last?.day {
                        Text("Net worth · \(Fmt.shortDate(first)) – \(Fmt.shortDate(last))")
                            .font(.caption.weight(.medium)).foregroundStyle(HubDesign.secondary)
                    }
                }
            } else {
                Text("Net worth history appears after a few days of syncing.")
                    .font(.footnote).foregroundStyle(HubDesign.secondary).multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .modifier(HeroFade())
        .accessibilityHidden(true)
    }
}

/// A slowly breathing orb of rings, with the total mindful minutes at its heart.
struct ReflectionOrb: View {
    var minutes: Int
    /// Mindful minutes for each of the last seven days, oldest first; the ring glows brighter for longer days.
    var week: [Int]
    var tint: Color = .teal
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var inhaled = false

    var body: some View {
        GeometryReader { geo in
            let size = min(geo.size.height - 8, 210)
            let peak = Double(max(week.max() ?? 0, 1))
            ZStack {
                ForEach(0..<3, id: \.self) { i in
                    Circle()
                        .strokeBorder(tint.opacity(0.5 - Double(i) * 0.14), lineWidth: 1.5)
                        .background(Circle().fill(tint.opacity(0.07)))
                        .frame(width: size * (0.62 + Double(i) * 0.19), height: size * (0.62 + Double(i) * 0.19))
                        .scaleEffect(inhaled ? 1.06 : 0.94)
                        .animation(reduceMotion ? nil : .easeInOut(duration: 4).repeatForever(autoreverses: true).delay(Double(i) * 0.25), value: inhaled)
                }
                // One bead per day around the orb, brighter the longer that day's sitting.
                ForEach(Array(week.enumerated()), id: \.offset) { i, m in
                    let angle = Double(i) / 7 * 2 * .pi - .pi / 2
                    Circle()
                        .fill(m > 0 ? tint.opacity(0.45 + 0.55 * Double(m) / peak) : tint.opacity(0.18))
                        .frame(width: m > 0 ? 12 : 8, height: m > 0 ? 12 : 8)
                        .shadow(color: m > 0 ? tint.opacity(0.8) : .clear, radius: 5)
                        .offset(x: cos(angle) * size * 0.5, y: sin(angle) * size * 0.5)
                }
                VStack(spacing: 0) {
                    Text("\(minutes)").font(.system(size: size * 0.24, weight: .light).monospacedDigit())
                    Text("mindful min").font(.caption.weight(.medium)).tracking(1).textCase(.uppercase).foregroundStyle(HubDesign.secondary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .modifier(HeroFade())
        .onAppear { inhaled = true }
        .accessibilityHidden(true)
    }
}
#endif
