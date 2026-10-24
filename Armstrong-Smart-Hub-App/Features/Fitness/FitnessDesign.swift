import Charts
import SwiftUI

/// The Fitness tab's look: the hub's palette (near-black or white, hairline
/// dividers, muted labels, tabular numbers) laid out the way Oura's app is:
/// no cards, content straight on the page, thin rings, light numbers and
/// contributor rows. Every chart on the tab goes through the components here
/// so axes, dates and readouts line up the same way everywhere.

// MARK: Tokens

enum Fit {
    /// A color with a light and a dark value (the hub's light and dark tokens).
    static func adaptive(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(UIColor { traits in
            let hex = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                           blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        })
    }

    /// Full-screen workout pages: white, or true black in dark mode (sheets are grey otherwise).
    static let page = adaptive(0xFFFFFF, 0x000000)
    static let hairline = adaptive(0xEBEBEB, 0x242424)
    static let track = adaptive(0xEBEBEB, 0x262626)
    static let muted = adaptive(0x666666, 0xA1A1A1)
    static let faint = adaptive(0xA1A1A1, 0x5C5C5C)

    // Accents, one per topic: the three scores are green, deep violet and yellow.
    static let readiness = adaptive(0x1E9E4A, 0x3DDC6E)
    static let sleep = adaptive(0x4B23C2, 0x8B6CFF)
    static let energy = adaptive(0xD9A300, 0xFFD60A)
    /// Buttons, the workout days and anything else to tap: the hub's blue.
    static let action = adaptive(0x0068D6, 0x52A8FF)
    static let activity = adaptive(0xA35200, 0xFF990A)
    static let heart = adaptive(0xCB2A2F, 0xFF6166)
    static let health = adaptive(0x8E44AD, 0xC58AF9)
    static let positive = adaptive(0x297A3A, 0x62C073)
    static let fair = adaptive(0xA35200, 0xFF990A)
    static let attention = adaptive(0xCB2A2F, 0xFF6166)

    /// Big headline numbers: light weight, tabular, like Oura's.
    static func number(_ size: CGFloat) -> Font { .system(size: size, weight: .light).monospacedDigit() }
    /// Smaller values in rows and grids.
    static let value = Font.system(size: 22, weight: .regular).monospacedDigit()
    static let label = Font.footnote
    static let axis = Font.caption2

    static let gutter: CGFloat = 20
}

/// Oura's words for a 0-100 score.
enum Status {
    static func word(_ score: Int?) -> String {
        guard let score else { return "No data" }
        return score >= 85 ? "Optimal" : score >= 70 ? "Good" : score >= 60 ? "Fair" : "Pay attention"
    }

    static func color(_ score: Int?) -> Color {
        guard let score else { return Fit.muted }
        return score >= 85 ? Fit.positive : score >= 70 ? .primary : score >= 60 ? Fit.fair : Fit.attention
    }
}

// MARK: Layout

/// A page: content on the plain background, sections divided by hairlines.
struct FitPage<Content: View>: View {
    var title: String
    @ViewBuilder var content: Content
    @Environment(\.fitnessRenderFlat) private var flat

    var body: some View {
        let stack = VStack(spacing: 0) { content }
            .padding(.horizontal, Fit.gutter)
            .padding(.bottom, 40)
            .frame(maxWidth: .infinity)
        Group {
            if flat {
                stack
            } else {
                // Up and down only. The content is held to exactly the screen's
                // width, so nothing on a page (a wide bar, a long line) can make
                // it wider and let it drag sideways, and it doesn't bounce when
                // it already fits.
                ScrollView(.vertical) { stack.containerRelativeFrame(.horizontal) }
                    .scrollBounceBehavior(.basedOnSize)
            }
        }
        // Fill the screen from the first frame: a page still loading would otherwise
        // shrink to its content, showing the background as a strip that then grows.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(BrickLook.page.ignoresSafeArea())
        .foregroundStyle(BrickLook.ink)
        .tint(BrickLook.ink)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(BrickLook.page, for: .navigationBar)
    }
}

/// A titled block with a hairline above it. No surface behind it.
struct FitSection<Content: View>: View {
    var title: String?
    var trailing: String?
    /// The trailing text's color, when it should stand out (a streak).
    var trailingTint: Color?
    var divider = true
    @ViewBuilder var content: Content
    @Environment(\.fitnessCards) private var cards

    var body: some View {
        if cards { card } else { plain }
    }

    /// Brick's look: a centered heading, then the content on a soft card.
    private var card: some View {
        VStack(spacing: 18) {
            if title != nil || trailing != nil {
                VStack(spacing: 6) {
                    if let title { Text(title).font(.system(size: 26, weight: .regular)).foregroundStyle(BrickLook.ink) }
                    if let trailing { BrickCaps(text: trailing).foregroundStyle(trailingTint ?? BrickLook.soft).monospacedDigit() }
                }
            }
            BrickCard(padding: 20) {
                VStack(alignment: .leading, spacing: 16) { content }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, 28)
    }

    private var plain: some View {
        VStack(alignment: .leading, spacing: 16) {
            if divider { Rectangle().fill(Fit.hairline).frame(height: 1).padding(.bottom, 8) }
            if title != nil || trailing != nil {
                HStack(alignment: .firstTextBaseline) {
                    if let title { Text(title).font(.headline) }
                    Spacer(minLength: 8)
                    if let trailing { Text(trailing).font(Fit.label).foregroundStyle(trailingTint ?? Fit.muted).monospacedDigit() }
                }
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 18)
    }
}

/// A paragraph of explanation under a headline or a chart.
struct Takeaway: View {
    var text: String
    var body: some View {
        Text(text).font(.subheadline).foregroundStyle(Fit.muted)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The thin score ring Oura uses: a 0-100 value, light number in the middle.
struct ScoreRing: View {
    var value: String
    var fraction: Double
    var tint: Color
    var size: CGFloat = 96
    var label: String?
    var track: Color = Fit.track
    /// The stroke as a share of the ring's size.
    var weight: CGFloat = 0.035

    var body: some View {
        VStack(spacing: 10) {
            ZStack {
                Circle().stroke(track, lineWidth: max(3, size * weight))
                Circle().trim(from: 0, to: max(0.002, min(1, fraction)))
                    .stroke(tint, style: StrokeStyle(lineWidth: max(3, size * weight), lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .opacity(fraction > 0 ? 1 : 0)
                    .animation(.smooth(duration: 0.8), value: fraction)
                Text(value)
                    .font(Fit.number(size * 0.34))
                    .minimumScaleFactor(0.5)
                    .lineLimit(1)
                    .padding(.horizontal, size * 0.12)
                    .contentTransition(.numericText())
            }
            .frame(width: size, height: size)
            if let label { Text(label).font(Fit.label).foregroundStyle(Fit.muted) }
        }
    }
}

/// The top of a score page: big ring, status word and a line of context.
struct ScoreHeader: View {
    var score: Int?
    var display: String?
    var fraction: Double?
    var tint: Color
    var status: String?
    var subtitle: String?
    var source: Bool?

    var body: some View {
        VStack(spacing: 14) {
            ScoreRing(value: display ?? score.map(String.init) ?? "–", fraction: fraction ?? Double(score ?? 0) / 100, tint: tint, size: 176)
            VStack(spacing: 4) {
                Text(status ?? Status.word(score)).font(.title3.weight(.semibold))
                if let subtitle { Text(subtitle).font(Fit.label).foregroundStyle(Fit.muted) }
            }
            if let source { SourceBadge(watch: source) }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 12)
        .padding(.bottom, 18)
    }
}

/// A big number with its unit and a muted caption, for pages without a score.
struct BigNumber: View {
    var value: String
    var unit: String?
    var caption: String?
    var tint: Color = .primary

    var body: some View {
        VStack(spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value).font(Fit.number(64)).foregroundStyle(tint).contentTransition(.numericText())
                if let unit { Text(unit).font(.title3).foregroundStyle(Fit.muted) }
            }
            if let caption { Text(caption).font(Fit.label).foregroundStyle(Fit.muted).multilineTextAlignment(.center) }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 16)
        .padding(.bottom, 18)
    }
}

/// One input to a score: name, how it's doing, and a thin bar.
struct ContributorRow: View {
    var title: String
    var detail: String
    var fraction: Double?
    var tint: Color = .primary
    var detailColor: Color?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.subheadline)
                Spacer(minLength: 8)
                Text(detail).font(.subheadline).foregroundStyle(detailColor ?? Fit.muted).monospacedDigit().lineLimit(1)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Fit.track)
                    if let fraction {
                        Capsule().fill(tint).frame(width: max(3, geo.size.width * min(1, max(0, fraction))))
                    }
                }
            }
            .frame(height: 3)
        }
        .opacity(fraction == nil ? 0.5 : 1)
    }
}

/// A score part as Oura shows it: name, status word, bar colored by status.
struct ScoredRow: View {
    var title: String
    var score: Int?

    var body: some View {
        ContributorRow(title: title, detail: score.map { "\(Status.word($0)) · \($0)" } ?? "No data",
                       fraction: score.map { Double($0) / 100 }, tint: Status.color(score) == .primary ? Color.primary.opacity(0.85) : Status.color(score),
                       detailColor: Status.color(score) == .primary ? nil : Status.color(score))
    }
}

/// A plain label and value with a hairline under it.
struct DetailRow: View {
    var label: String
    var value: String
    var valueColor: Color?
    var last = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text(label).font(.subheadline)
                Spacer(minLength: 12)
                Text(value).font(.subheadline).foregroundStyle(valueColor ?? Fit.muted).monospacedDigit().multilineTextAlignment(.trailing)
            }
            .padding(.vertical, 11)
            if !last { FitDivider() }
        }
    }
}

/// Two or three values side by side, label under each, no boxes.
struct StatStrip: View {
    var items: [(label: String, value: String)]

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                VStack(alignment: .center, spacing: 3) {
                    Text(item.value).font(Fit.value).lineLimit(1).minimumScaleFactor(0.6)
                    Text(item.label).font(Fit.label).foregroundStyle(Fit.muted).lineLimit(1)
                }
                .padding(.horizontal, 6)
                .frame(maxWidth: .infinity)
                // The hairline sits on the column's edge, so every column is the same width.
                .overlay(alignment: .leading) {
                    if index > 0 { Rectangle().fill(Fit.hairline).frame(width: 1, height: 36) }
                }
            }
        }
    }
}

/// A row on the overview that opens a page: label, value, caption, a small chart.
struct OverviewRow<Chart: View>: View {
    var title: String
    var value: String
    var unit: String?
    var caption: String?
    /// A second, muted line under the caption, for a row that sums up several numbers.
    var detail: String? = nil
    var tint: Color
    @ViewBuilder var chart: Chart

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(Fit.label).foregroundStyle(Fit.muted)
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(value).font(.system(size: 26, weight: .light).monospacedDigit()).lineLimit(1).minimumScaleFactor(0.6)
                    if let unit { Text(unit).font(Fit.label).foregroundStyle(Fit.muted) }
                }
                if let caption { Text(caption).font(.caption).foregroundStyle(tint).lineLimit(1) }
                if let detail { Text(detail).font(.caption).foregroundStyle(Fit.muted).lineLimit(1).minimumScaleFactor(0.85) }
            }
            Spacer(minLength: 8)
            chart.frame(width: 96, height: 34)
            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(Fit.faint)
        }
        .padding(.vertical, 14)
        .contentShape(.rect)
    }
}

/// A tiny trend line or bar run for overview rows. No axes.
struct MiniTrend: View {
    var values: [Double]
    var tint: Color
    var bars = false

    var body: some View {
        if values.count < 2 {
            Color.clear
        } else {
            let low = values.min() ?? 0, high = values.max() ?? 1
            let span = max(high - low, 1)
            GeometryReader { geo in
                let step = geo.size.width / CGFloat(max(values.count - 1, 1))
                if bars {
                    let width = geo.size.width / CGFloat(values.count) * 0.55
                    HStack(alignment: .bottom, spacing: 0) {
                        ForEach(Array(values.enumerated()), id: \.offset) { index, value in
                            Capsule()
                                .fill(tint.opacity(index == values.count - 1 ? 1 : 0.45))
                                .frame(width: width, height: max(2, geo.size.height * CGFloat(value / max(high, 1))))
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .frame(height: geo.size.height, alignment: .bottom)
                } else {
                    Path { path in
                        for (index, value) in values.enumerated() {
                            let point = CGPoint(x: CGFloat(index) * step, y: geo.size.height * (1 - CGFloat((value - low) / span)) * 0.9 + 2)
                            if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
                        }
                    }
                    .stroke(tint, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                    Circle().fill(tint).frame(width: 5, height: 5)
                        .position(x: CGFloat(values.count - 1) * step,
                                  y: geo.size.height * (1 - CGFloat(((values.last ?? 0) - low) / span)) * 0.9 + 2)
                }
            }
        }
    }
}

/// Text buttons for a chart's time window, underlined when chosen.
struct PeriodPicker: View {
    @Binding var days: Int
    var options: [Int] = [7, 30, 90]

    var body: some View {
        HStack(spacing: 18) {
            ForEach(options, id: \.self) { option in
                Button {
                    withAnimation(.smooth) { days = option }
                } label: {
                    VStack(spacing: 4) {
                        Text(option >= 365 ? "1Y" : "\(option)D").font(Fit.label.weight(days == option ? .semibold : .regular))
                            .foregroundStyle(days == option ? Color.primary : Fit.muted)
                        Capsule().fill(days == option ? Color.primary : .clear).frame(width: 18, height: 2)
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// A colored dot and a word, for chart legends.
struct LegendDot: View {
    var color: Color
    var text: String
    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(text).font(.caption).foregroundStyle(Fit.muted)
        }
    }
}

// MARK: Charts

/// One value for one day.
struct DayValue: Identifiable, Equatable {
    var date: Date
    var value: Double
    var id: Date { date }
}

/// One value at a moment.
struct TimeValue: Identifiable, Equatable {
    var date: Date
    var value: Double
    var color: Color?
    var id: Date { date }
}

/// What a chart shows above itself: the touched value, else the latest.
private struct Readout: View {
    var value: String
    var caption: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(value).font(.system(size: 24, weight: .light).monospacedDigit()).contentTransition(.numericText())
            Text(caption).font(Fit.label).foregroundStyle(Fit.muted)
            Spacer(minLength: 0)
        }
        .frame(height: 30)
    }
}

/// Axis labels shared by every chart: small, muted.
private extension View {
    func fitYAxis(_ values: [Double]? = nil, format: @escaping (Double) -> String = { String(Int($0.rounded())) }) -> some View {
        chartYAxis {
            if let values {
                AxisMarks(position: .trailing, values: values) { value in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [2, 3])).foregroundStyle(Fit.hairline)
                    AxisValueLabel { if let v = value.as(Double.self) { Text(axisText(v, format)).font(Fit.axis).foregroundStyle(Fit.muted) } }
                }
            } else {
                AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { value in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [2, 3])).foregroundStyle(Fit.hairline)
                    AxisValueLabel { if let v = value.as(Double.self) { Text(axisText(v, format)).font(Fit.axis).foregroundStyle(Fit.muted) } }
                }
            }
        }
    }
}

/// Whole axis values without a decimal ("18", not "18.0").
private func axisText(_ value: Double, _ format: (Double) -> String) -> String {
    let text = format(value)
    return value == value.rounded() && text.contains(".") ? String(Int(value)) : text
}

/// The middle of a day: where a day-wide bar or a day's point is drawn, so
/// a label centered here sits right under it.
private func midday(_ date: Date) -> Date {
    Calendar.current.date(byAdding: .hour, value: 12, to: Calendar.current.startOfDay(for: date)) ?? date
}

/// Day labels for a run of days: every day up to a week, then a whole number
/// of days apart counting back from the last, so they're evenly spaced in
/// time even where days are missing. Each is at its day's middle.
private func dayTicks(_ dates: [Date], maxLabels: Int = 7) -> [Date] {
    let calendar = Calendar.current
    guard let first = dates.min(), let last = dates.max() else { return [] }
    let span = calendar.dateComponents([.day], from: calendar.startOfDay(for: first), to: calendar.startOfDay(for: last)).day ?? 0
    let step = max(1, Int((Double(span + 1) / Double(maxLabels)).rounded(.up)))
    return stride(from: 0, through: span, by: step).reversed()
        .compactMap { calendar.date(byAdding: .day, value: -$0, to: last) }.map(midday)
}

/// Week labels: the bars' own weeks, evenly picked, at the middle of each week.
private func weekTicks(_ dates: [Date], maxLabels: Int = 7) -> [Date] {
    let sorted = dates.sorted()
    let step = max(1, Int((Double(sorted.count) / Double(maxLabels)).rounded(.up)))
    let last = sorted.count - 1
    return sorted.enumerated().filter { (last - $0.offset) % step == 0 }
        .map { $0.element.addingTimeInterval(3.5 * 86400) }
}

private func dayLabel(_ date: Date, count: Int) -> String {
    count <= 7 ? date.formatted(.dateTime.weekday(.abbreviated)) : date.formatted(.dateTime.month(.abbreviated).day())
}

/// Daily bars: one per day, labels centered under bars, tap a bar to read it.
struct DailyBarChart: View {
    var points: [DayValue]
    var tint: Color
    var domain: ClosedRange<Double>?
    var goal: Double?
    var yTicks: [Double]?
    var height: CGFloat = 180
    var format: (Double) -> String = { Int($0.rounded()).formatted() }
    /// What the readout says when nothing is touched.
    var summary: String?
    var colorFor: ((Double) -> Color)?
    /// Bars a day wide, or a week wide for weekly totals.
    var unit: Calendar.Component = .day

    @State private var selected: Date?

    var body: some View {
        let calendar = Calendar.current
        let days = points.map { DayValue(date: calendar.startOfDay(for: $0.date), value: $0.value) }
        let chosen = selected.flatMap { s in days.first { calendar.isDate($0.date, equalTo: s, toGranularity: unit) } }
        VStack(alignment: .leading, spacing: 10) {
            if let chosen {
                Readout(value: format(chosen.value), caption: unit == .day ? chosen.date.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
                                                                         : "Week of \(chosen.date.formatted(.dateTime.month(.abbreviated).day()))")
            } else if let summary {
                Readout(value: summary, caption: "Tap a bar for a day")
            } else if let last = days.last {
                Readout(value: format(last.value),
                        caption: calendar.isDateInToday(last.date) ? "Today" : last.date.formatted(.dateTime.weekday(.wide).month(.abbreviated).day()))
            }
            Chart {
                ForEach(days) { day in
                    // Thin bars, as Oura draws them, however few days there are.
                    BarMark(x: .value("Day", day.date, unit: unit), y: .value("Value", day.value),
                            width: .fixed(days.count <= 8 ? 14 : days.count <= 16 ? 10 : days.count <= 35 ? 6 : 3))
                        .foregroundStyle((colorFor?(day.value) ?? tint).opacity(chosen == nil || chosen?.date == day.date ? 1 : 0.35))
                        .clipShape(Capsule())
                }
                if let goal {
                    RuleMark(y: .value("Goal", goal))
                        .foregroundStyle(Fit.muted)
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                }
            }
            .chartXSelection(value: $selected)
            .chartXAxis {
                AxisMarks(values: unit == .day ? dayTicks(days.map(\.date)) : weekTicks(days.map(\.date))) { value in
                    // Ticks sit at the bars' middles; the label centers on its tick.
                    AxisValueLabel(anchor: .top, collisionResolution: .disabled) {
                        if let date = value.as(Date.self) { Text(dayLabel(date, count: unit == .day ? days.count : 99)).font(Fit.axis).foregroundStyle(Fit.muted) }
                    }
                }
            }
            .fitYAxis(yTicks, format: format)
            .chartYScale(domain: domain ?? 0...max((days.map(\.value).max() ?? 1) * 1.1, goal ?? 0, 1))
            .frame(height: height)
        }
    }
}

/// A trend over days: a thin line, an optional "usual" band, tap to read a day.
struct TrendLineChart: View {
    var points: [DayValue]
    var tint: Color
    var band: ClosedRange<Double>?
    var domain: ClosedRange<Double>?
    var height: CGFloat = 160
    var format: (Double) -> String = { Int($0.rounded()).formatted() }

    @State private var selected: Date?

    var body: some View {
        let sorted = points.sorted { $0.date < $1.date }
        let chosen = selected.flatMap { s in sorted.min { abs($0.date.timeIntervalSince(s)) < abs($1.date.timeIntervalSince(s)) } }
        let values = sorted.map(\.value) + (band.map { [$0.lowerBound, $0.upperBound] } ?? [])
        let low = values.min() ?? 0, high = values.max() ?? 1
        let pad = max((high - low) * 0.15, 1)
        VStack(alignment: .leading, spacing: 10) {
            if let point = chosen ?? sorted.last {
                Readout(value: format(point.value),
                        caption: chosen == nil ? "Latest, \(point.date.formatted(.dateTime.month(.abbreviated).day()))" : point.date.formatted(.dateTime.weekday(.wide).month(.abbreviated).day()))
            }
            Chart {
                if let band, let first = sorted.first?.date, let last = sorted.last?.date {
                    RectangleMark(xStart: .value("From", first, unit: .day), xEnd: .value("To", last, unit: .day),
                                  yStart: .value("Low", band.lowerBound), yEnd: .value("High", band.upperBound))
                        .foregroundStyle(tint.opacity(0.1))
                }
                ForEach(sorted) { point in
                    LineMark(x: .value("Day", midday(point.date)), y: .value("Value", point.value))
                        .interpolationMethod(.monotone)
                        .foregroundStyle(tint)
                        .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                }
                if let point = chosen ?? sorted.last {
                    PointMark(x: .value("Day", midday(point.date)), y: .value("Value", point.value))
                        .foregroundStyle(tint).symbolSize(44)
                    if chosen != nil {
                        RuleMark(x: .value("Day", midday(point.date))).foregroundStyle(Fit.hairline).lineStyle(StrokeStyle(lineWidth: 1))
                    }
                }
            }
            .chartXSelection(value: $selected)
            .chartXScale(range: .plotDimension(padding: 18))
            .chartXAxis {
                AxisMarks(values: evenDates(sorted.map(\.date))) { value in
                    // Points sit at their days' middles, and so do the ticks; the label centers on its tick.
                    AxisValueLabel(anchor: .top, collisionResolution: .disabled) {
                        if let date = value.as(Date.self) { Text(date.formatted(.dateTime.month(.abbreviated).day())).font(Fit.axis).foregroundStyle(Fit.muted) }
                    }
                }
            }
            .fitYAxis(format: format)
            .chartYScale(domain: domain ?? (low - pad)...(high + pad))
            .frame(height: height)
        }
    }

    /// Up to four days evenly spaced in time from the first to the last, so
    /// the labels are even however the readings are spread.
    private func evenDates(_ dates: [Date]) -> [Date] {
        let calendar = Calendar.current
        guard let first = dates.min(), let last = dates.max() else { return [] }
        let span = calendar.dateComponents([.day], from: calendar.startOfDay(for: first), to: calendar.startOfDay(for: last)).day ?? 0
        let count = min(4, span + 1)
        guard count > 1 else { return [midday(last)] }
        let offsets = (0..<count).map { Int((Double(span) * Double(count - 1 - $0) / Double(count - 1)).rounded()) }
        return offsets.compactMap { calendar.date(byAdding: .day, value: -$0, to: last) }.map(midday)
    }
}

/// A day's worth of readings on a fixed window, hours lined up on the hour.
struct IntradayChart: View {
    enum Style { case line, area, bars }

    var points: [TimeValue]
    var tint: Color
    var from: Date
    var to: Date
    var style: Style = .area
    var domain: ClosedRange<Double>?
    var height: CGFloat = 150
    var format: (Double) -> String = { Int($0.rounded()).formatted() }
    var unit: String = ""

    @State private var selected: Date?

    var body: some View {
        let sorted = points.filter { $0.date >= from && $0.date <= to }.sorted { $0.date < $1.date }
        let runs = Self.runs(sorted)
        let chosen = selected.flatMap { s in sorted.min { abs($0.date.timeIntervalSince(s)) < abs($1.date.timeIntervalSince(s)) } }
        let values = sorted.map(\.value)
        let low = values.min() ?? 0, high = values.max() ?? 1
        VStack(alignment: .leading, spacing: 10) {
            if let point = chosen ?? sorted.last {
                Readout(value: format(point.value) + unit,
                        caption: chosen == nil ? "Latest, \(moment(point.date))" : moment(point.date))
            }
            Chart {
                ForEach(Array(sorted.enumerated()), id: \.element.id) { index, point in
                    let run = runs[index]
                    switch style {
                    case .bars:
                        BarMark(x: .value("Time", point.date, unit: .minute), y: .value("Value", point.value), width: .fixed(2))
                            .foregroundStyle((point.color ?? tint).opacity(chosen == nil || chosen == point ? 1 : 0.4))
                    case .area:
                        AreaMark(x: .value("Time", point.date), yStart: .value("Floor", domain?.lowerBound ?? max(0, low - 5)), yEnd: .value("Value", point.value),
                                 series: .value("Run", run))
                            .interpolationMethod(.monotone)
                            .foregroundStyle(LinearGradient(colors: [tint.opacity(0.22), tint.opacity(0)], startPoint: .top, endPoint: .bottom))
                        LineMark(x: .value("Time", point.date), y: .value("Value", point.value), series: .value("Run", run))
                            .interpolationMethod(.monotone)
                            .foregroundStyle(tint)
                            .lineStyle(StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                    case .line:
                        LineMark(x: .value("Time", point.date), y: .value("Value", point.value), series: .value("Run", run))
                            .interpolationMethod(.monotone)
                            .foregroundStyle(tint)
                            .lineStyle(StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                    }
                }
                if let chosen {
                    RuleMark(x: .value("Time", chosen.date)).foregroundStyle(Fit.faint).lineStyle(StrokeStyle(lineWidth: 1))
                }
            }
            .chartXSelection(value: $selected)
            .chartXScale(domain: from...to)
            .chartXAxis {
                AxisMarks(values: ticks()) { _ in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [2, 3])).foregroundStyle(Fit.hairline)
                }
            }
            // Time labels placed at the chart's own x for each tick, centered on its gridline.
            .chartOverlay { proxy in
                GeometryReader { geo in
                    if let anchor = proxy.plotFrame {
                        let plot = geo[anchor]
                        ForEach(ticks(), id: \.self) { tick in
                            if let x = proxy.position(forX: tick) {
                                Text(tick.formatted(tickFormat)).font(Fit.axis).foregroundStyle(Fit.muted).fixedSize()
                                    .position(x: plot.minX + x, y: plot.maxY + 12)
                            }
                        }
                    }
                }
                .allowsHitTesting(false)
            }
            .fitYAxis(format: format)
            .chartYScale(domain: domain ?? max(0, low - (high - low) * 0.15 - 2)...(high + (high - low) * 0.15 + 2))
            .frame(height: height)
            .padding(.bottom, 20)
        }
    }

    /// Which unbroken stretch each point belongs to: a gap of 20 minutes or
    /// more (watch off, or a stretch no one has yet) starts a new one, so the
    /// line breaks there instead of drawing straight across it.
    private static func runs(_ points: [TimeValue]) -> [Int] {
        var run = 0
        return points.indices.map { i in
            if i > 0, points[i].date.timeIntervalSince(points[i - 1].date) >= 20 * 60 { run += 1 }
            return run
        }
    }

    /// Whole hours inside the window, every 6 (every 3 under half a day,
    /// every hour under 4); under 2 hours, every 10 or 15 minutes. Kept off
    /// the very edges so their labels don't clip.
    private func ticks() -> [Date] {
        let span = to.timeIntervalSince(from)
        let step: TimeInterval = span > 12 * 3600 ? 6 * 3600 : span > 4 * 3600 ? 3 * 3600 : span > 2 * 3600 ? 3600 : span > 3600 ? 900 : 600
        // Multiples of the step in local time, so 6 AM, 12 PM... or :00, :15...
        let offset = TimeInterval(TimeZone.current.secondsFromGMT(for: from))
        var tick = ((from.timeIntervalSince1970 + offset) / step).rounded(.up) * step - offset
        var out: [Date] = []
        let margin = span * 0.04
        while tick < to.timeIntervalSince1970 {
            let date = Date(timeIntervalSince1970: tick)
            if date.timeIntervalSince(from) > margin, to.timeIntervalSince(date) > margin { out.append(date) }
            tick += step
        }
        return out
    }

    /// "9:41 PM" today, else "Sun 9:41 PM", so a day-old reading doesn't pass for today's.
    private func moment(_ date: Date) -> String {
        Calendar.current.isDateInToday(date) ? date.formatted(date: .omitted, time: .shortened)
            : date.formatted(.dateTime.weekday(.abbreviated).hour().minute())
    }

    private var tickFormat: Date.FormatStyle {
        to.timeIntervalSince(from) > 2 * 3600 ? .dateTime.hour() : .dateTime.hour().minute()
    }
}

/// The night's stages in four lanes, awake on top, with bedtime and wake
/// time at the ends and hour ticks between, all on one shared scale.
struct HypnogramView: View {
    var night: SleepNight
    var height: CGFloat = 150

    private let lanes: [SleepNight.Stage] = [.awake, .rem, .light, .deep]

    var body: some View {
        let segments = night.segments
        let start = night.startDate ?? .now
        let end = night.endDate ?? start.addingTimeInterval(1)
        let span = max(end.timeIntervalSince(start), 1)
        VStack(spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(lanes) { stage in
                        Text(stage.name).font(Fit.axis).foregroundStyle(Fit.muted).frame(maxHeight: .infinity, alignment: .center)
                    }
                }
                .frame(width: 40, height: height)
                GeometryReader { geo in
                    let laneHeight = geo.size.height / CGFloat(lanes.count)
                    ZStack(alignment: .topLeading) {
                        ForEach(0..<lanes.count, id: \.self) { lane in
                            Rectangle().fill(Fit.hairline).frame(height: 1).offset(y: laneHeight * CGFloat(lane) + laneHeight / 2)
                        }
                        ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                            let lane = lanes.firstIndex(of: segment.stage) ?? 0
                            let x = geo.size.width * CGFloat(segment.start.timeIntervalSince(start) / span)
                            let width = max(2, geo.size.width * CGFloat(segment.end.timeIntervalSince(segment.start) / span))
                            RoundedRectangle(cornerRadius: 3)
                                .fill(segment.stage.color)
                                .frame(width: width, height: laneHeight * 0.62)
                                .offset(x: x, y: laneHeight * CGFloat(lane) + laneHeight * 0.19)
                        }
                    }
                }
                .frame(height: height)
            }
            HStack(spacing: 10) {
                Color.clear.frame(width: 40, height: 1)
                GeometryReader { geo in
                    ZStack(alignment: .topLeading) {
                        ForEach(hourTicks(start: start, end: end), id: \.self) { tick in
                            let x = geo.size.width * CGFloat(tick.timeIntervalSince(start) / span)
                            Text(tick.formatted(.dateTime.hour())).font(Fit.axis).foregroundStyle(Fit.faint)
                                .fixedSize()
                                .position(x: x, y: 7)
                        }
                        Text(start.formatted(date: .omitted, time: .shortened)).font(Fit.axis.weight(.semibold)).foregroundStyle(Fit.muted)
                            .fixedSize().frame(maxWidth: .infinity, alignment: .leading)
                        Text(end.formatted(date: .omitted, time: .shortened)).font(Fit.axis.weight(.semibold)).foregroundStyle(Fit.muted)
                            .fixedSize().frame(maxWidth: .infinity, alignment: .trailing)
                    }
                }
                .frame(height: 14)
            }
        }
    }

    /// Whole hours, every 2 on long nights, kept clear of the bedtime and wake labels.
    private func hourTicks(start: Date, end: Date) -> [Date] {
        let span = end.timeIntervalSince(start)
        let step: TimeInterval = span > 6 * 3600 ? 7200 : 3600
        guard var tick = Calendar.current.dateInterval(of: .hour, for: start)?.end else { return [] }
        var ticks: [Date] = []
        while tick < end {
            let share = tick.timeIntervalSince(start) / span
            let hour = Calendar.current.component(.hour, from: tick)
            if share > 0.2, share < 0.8, step == 3600 || hour % 2 == 0 { ticks.append(tick) }
            tick = tick.addingTimeInterval(3600)
        }
        return ticks
    }
}

/// Stage totals as Oura lists them: dot, name, time, share, thin bar.
struct StageRows: View {
    var night: SleepNight

    var body: some View {
        let total = Double(max(night.asleepSeconds + (night.awakeSeconds ?? 0), 1))
        VStack(spacing: 14) {
            ForEach([SleepNight.Stage.awake, .rem, .light, .deep]) { stage in
                let seconds = Double(night.seconds(stage))
                VStack(spacing: 7) {
                    HStack {
                        LegendDot(color: stage.color, text: stage.name)
                        Spacer()
                        Text(FitnessFormat.duration(seconds)).font(.subheadline).monospacedDigit()
                        Text("\(Int((seconds / total * 100).rounded()))%").font(.subheadline).foregroundStyle(Fit.muted).monospacedDigit()
                            .frame(width: 42, alignment: .trailing)
                    }
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Fit.track)
                            Capsule().fill(stage.color).frame(width: max(3, geo.size.width * seconds / total))
                        }
                    }
                    .frame(height: 3)
                }
            }
        }
    }
}

/// A value placed on a labelled scale, e.g. VO2 max against your age group.
struct ScaleBar: View {
    /// Band ends, low to high, with their colors.
    var stops: [Double]
    var colors: [Color]
    var value: Double
    var labels: (String, String)?

    var body: some View {
        let low = stops.first ?? 0, high = max(stops.last ?? 1, low + 1)
        // The watch's band ends can come out of order or past the ends; kept
        // in order and inside the bar, the segments can't run wider than it
        // (which let the page scroll sideways).
        let ends = stops.map { min(max($0, low), high) }.sorted()
        let at = { (v: Double) in (v - low) / (high - low) }
        let share = max(0, min(1, at(value)))
        VStack(spacing: 6) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    ForEach(0..<max(ends.count - 1, 0), id: \.self) { i in
                        Capsule().fill(colors[min(i, colors.count - 1)])
                            .frame(width: max(1, geo.size.width * (at(ends[i + 1]) - at(ends[i])) - 2), height: 4)
                            .offset(x: geo.size.width * at(ends[i]))
                    }
                }
                .frame(width: geo.size.width, alignment: .leading)
                .frame(maxHeight: .infinity)
                .overlay(alignment: .leading) {
                    Circle().fill(Color(.systemBackground)).frame(width: 14, height: 14)
                        .overlay(Circle().stroke(Color.primary, lineWidth: 2))
                        .offset(x: geo.size.width * share - 7)
                }
            }
            .frame(height: 14)
            if let labels {
                HStack {
                    Text(labels.0).font(Fit.axis).foregroundStyle(Fit.muted)
                    Spacer()
                    Text(labels.1).font(Fit.axis).foregroundStyle(Fit.muted)
                }
            }
        }
    }
}

/// A signed amount around a center line: left hurts, right helps.
struct DivergingRow: View {
    var title: String
    var value: Double
    /// The value that fills one side.
    var scale: Double
    var detail: String

    var body: some View {
        VStack(spacing: 7) {
            HStack {
                Text(title).font(.subheadline)
                Spacer()
                Text(detail).font(.subheadline).foregroundStyle(value >= 0 ? Fit.positive : Fit.attention).monospacedDigit()
            }
            GeometryReader { geo in
                let half = geo.size.width / 2
                let width = min(half, half * abs(value) / max(scale, 0.001))
                ZStack(alignment: .leading) {
                    Capsule().fill(Fit.track).frame(height: 3)
                    Rectangle().fill(Fit.muted).frame(width: 1, height: 9).offset(x: half)
                    Capsule().fill(value >= 0 ? Fit.positive : Fit.attention)
                        .frame(width: max(3, width), height: 3)
                        .offset(x: value >= 0 ? half : half - width)
                }
                .frame(maxHeight: .infinity)
            }
            .frame(height: 9)
        }
    }
}
