import Charts
import SwiftUI

// The hub's chart kit. It follows shadcn/ui's chart anatomy (a container that
// knows its width, horizontal grid only, quiet axes, a cursor with a tooltip
// that lights up the label under the finger) in SwiftUI, with Liquid Glass
// for the highlighted label and tooltip.

/// A y axis whose gridlines are evenly spaced and whose ends bound the data,
/// so nothing a chart draws can leave its range.
struct ChartScale {
    let domain: ClosedRange<Double>
    let ticks: [Double]

    /// `domain` pins the range (data is clamped into it); `fixedTicks` pins the
    /// step, and is extended by whole steps if the data climbs past it.
    init(low: Double, high: Double, domain pinned: ClosedRange<Double>? = nil, fixedTicks: [Double]? = nil) {
        let lo = min(low, high), hi = max(low, high)
        if let pinned {
            domain = pinned
            ticks = fixedTicks ?? [pinned.lowerBound, (pinned.lowerBound + pinned.upperBound) / 2, pinned.upperBound]
            return
        }
        if let fixedTicks, fixedTicks.count >= 2 {
            var run = fixedTicks.sorted()
            let step = run[1] - run[0]
            while step > 0, let last = run.last, last < hi - step * 0.001, run.count < 12 { run.append(last + step) }
            domain = run[0]...run[run.count - 1]
            ticks = run
            return
        }
        let raw = max((hi - lo) / 2, 1)
        let magnitude = pow(10, floor(log10(raw)))
        var step = magnitude
        var lower = floor(lo / step) * step
        for multiple in [1.0, 2.0, 5.0, 10.0] {
            step = multiple * magnitude
            lower = floor(lo / step) * step
            if lower + 2 * step >= hi - step * 0.001 { break }
        }
        domain = lower...(lower + 2 * step)
        ticks = [lower, lower + step, lower + 2 * step]
    }

    func clamp(_ value: Double) -> Double { min(max(value, domain.lowerBound), domain.upperBound) }
}

enum ChartTicks {
    /// The ticks that fit in `width` without their labels touching, evenly
    /// picked and counting back from the last so the newest always stays.
    static func fit<T>(_ ticks: [T], width: CGFloat, labelWidth: CGFloat) -> [T] {
        let room = max(1, Int(width / labelWidth))
        guard ticks.count > room else { return ticks }
        let step = Int((Double(ticks.count - 1) / Double(max(room - 1, 1))).rounded(.up))
        let last = ticks.count - 1
        return ticks.enumerated().filter { (last - $0.offset) % max(step, 1) == 0 }.map(\.element)
    }

    /// The tick closest to where the finger is, so its label can light up.
    static func nearest(_ ticks: [Date], to date: Date?) -> Date? {
        guard let date else { return nil }
        return ticks.min { abs($0.timeIntervalSince(date)) < abs($1.timeIntervalSince(date)) }
    }
}

/// Gives a chart its plot width (less the y labels) so it can decide how many
/// time labels fit, and a fixed height.
struct ChartContainer<Content: View>: View {
    var height: CGFloat
    private let content: (CGFloat) -> Content

    init(height: CGFloat, @ViewBuilder content: @escaping (CGFloat) -> Content) {
        self.height = height
        self.content = content
    }

    var body: some View {
        GeometryReader { geo in
            content(max(geo.size.width - 40, 1))
                .frame(width: geo.size.width, height: geo.size.height)
        }
        .frame(height: height)
    }
}

/// A time label under a chart. The one under the finger is bold on a glass pill.
struct ChartTickLabel: View {
    var text: String
    var active: Bool
    var strong = false
    var inset: CGFloat = 7

    var body: some View {
        let label = Text(text)
            .font(Fit.axis.weight(active ? .semibold : .regular))
            .multilineTextAlignment(.center)
            .foregroundStyle(active || strong ? Color.primary : Fit.muted)
            .padding(.horizontal, inset).padding(.vertical, 2)
            .fixedSize()
        if active {
            label.glassEffect(.regular, in: .capsule)
        } else {
            label
        }
    }
}

/// The small glass bubble over the touched mark.
struct ChartTooltip: View {
    var text: String

    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold).monospacedDigit())
            .foregroundStyle(Color.primary)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .glassEffect(.regular, in: .capsule)
    }
}

extension View {
    /// Dashed hairlines and small muted values at the right, on `scale`'s ticks.
    /// The plot is inset a little top and bottom so marks at the ends stay inside it.
    func glassYAxis(_ scale: ChartScale, format: @escaping (Double) -> String) -> some View {
        chartYScale(domain: scale.domain, range: .plotDimension(padding: 8))
            .chartYAxis {
                AxisMarks(position: .trailing, values: scale.ticks) { value in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [2, 3])).foregroundStyle(Fit.hairline)
                    AxisValueLabel {
                        if let v = value.as(Double.self) {
                            let text = format(v)
                            Text(v == v.rounded() && text.contains(".") ? String(Int(v)) : text)
                                .font(Fit.axis).foregroundStyle(Fit.muted)
                        }
                    }
                }
            }
    }
}
