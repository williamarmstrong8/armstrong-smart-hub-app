import Charts
import SwiftUI

// The hub's chart kit. It follows shadcn/ui's chart anatomy (a container that
// knows its width, horizontal grid only, quiet axes, a cursor with a tooltip
// that lights up the label under the finger) in SwiftUI, with Liquid Glass
// for the highlighted label and tooltip.

/// A y axis that runs from the lowest to the highest value shown (no empty
/// headroom), with evenly spaced gridlines on round numbers inside it.
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
        // The axis ends where the data does, so the tallest mark reaches the
        // top; gridlines go on round numbers inside that range (2 to 5 of them).
        var bottom = lo, top = hi
        if top - bottom < 1e-9 { bottom -= max(abs(bottom) * 0.1, 1); top += max(abs(top) * 0.1, 1); if lo >= 0 { bottom = max(bottom, 0) } }
        let magnitude = pow(10, floor(log10((top - bottom) / 4)))
        let step = [1.0, 2.0, 5.0, 10.0].map { $0 * magnitude }.first { (top - bottom) / $0 <= 4 } ?? 10 * magnitude
        var run: [Double] = []
        var tick = (bottom / step).rounded(.up) * step
        while tick <= top + step * 1e-6, run.count < 8 { run.append(tick); tick += step }
        domain = bottom...top
        ticks = run
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

/// Lays out time labels centered on their x (nudged in at the edges so none
/// spill past the chart) and skips any that would touch a label already
/// placed: pinned ones first, then right to left, so the newest stays.
struct TickLabelLayout: Layout {
    var xs: [CGFloat]
    var pinned: Set<Int> = []
    var gap: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        CGSize(width: proposal.width ?? 0, height: subviews.map { $0.sizeThatFits(.unspecified).height }.max() ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var taken: [ClosedRange<CGFloat>] = []
        let order = subviews.indices.filter { pinned.contains($0) } + subviews.indices.reversed().filter { !pinned.contains($0) }
        for index in order {
            let size = subviews[index].sizeThatFits(.unspecified)
            let x = bounds.minX + (index < xs.count ? xs[index] : 0)
            let center = max(min(x, bounds.maxX - size.width / 2), bounds.minX + size.width / 2)
            let span = (center - size.width / 2 - gap / 2)...(center + size.width / 2 + gap / 2)
            if taken.contains(where: { $0.overlaps(span) }) {
                // Out of sight: a label that doesn't fit isn't drawn.
                subviews[index].place(at: CGPoint(x: -10_000, y: -10_000), proposal: .unspecified)
            } else {
                taken.append(span)
                subviews[index].place(at: CGPoint(x: center, y: bounds.midY), anchor: .center, proposal: .unspecified)
            }
        }
    }
}

private struct PlacedTick: Identifiable {
    var date: Date
    var x: CGFloat
    var id: Date { date }
}

extension View {
    /// Time labels under the plot, each centered on its own date's x, never
    /// overlapping. Leave about 24pt below the chart for them.
    func glassXLabels(_ ticks: [Date], active: Date?, text: @escaping (Date) -> String) -> some View {
        chartXAxis(.hidden)
            .chartOverlay { proxy in
                GeometryReader { geo in
                    if let anchor = proxy.plotFrame {
                        let plot = geo[anchor]
                        let placed = ticks.sorted().compactMap { t in proxy.position(forX: t).map { PlacedTick(date: t, x: plot.minX + $0) } }
                        let layout = TickLabelLayout(xs: placed.map(\.x), pinned: placed.isEmpty ? [] : [placed.count - 1])
                        layout {
                            ForEach(placed) { tick in
                                ChartTickLabel(text: text(tick.date), active: tick.date == active)
                            }
                        }
                        .frame(width: geo.size.width, height: 20)
                        .offset(y: plot.maxY + 4)
                    }
                }
                .allowsHitTesting(false)
            }
    }
}
