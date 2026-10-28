import Charts
import SwiftUI

/// The answer to a money question: big numbers that count up, one simple
/// chart that grows in, and a few rows when they help.
struct FinanceCard: View {
    let data: FinanceCardData

    @State private var progress: Double = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 44) {
            CardHeader(title: data.title, detail: data.subtitle, symbol: "chart.bar.xaxis")

            // Wraps when three big numbers won't fit side by side.
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 32, alignment: .topLeading)], alignment: .leading, spacing: 28) {
                ForEach(Array(data.stats.enumerated()), id: \.element.id) { i, stat in
                    StatTile(stat: stat, currency: data.currency, delay: Double(i) * 0.08)
                }
            }

            if let chart = data.chart, !chart.points.isEmpty {
                FinanceChartView(chart: chart, currency: data.currency, progress: progress)
                    .frame(height: chart.style == .hbar ? CGFloat(chart.points.count) * 54 : 260)
            }

            if !data.rows.isEmpty {
                VStack(spacing: 0) {
                    ForEach(Array(data.rows.enumerated()), id: \.element.id) { i, row in
                        if i > 0 { Divider() }
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(row.title).font(.title3.weight(.semibold)).lineLimit(1)
                                if let s = row.subtitle { Text(s).font(.body).foregroundStyle(.secondary) }
                            }
                            Spacer()
                            Text(Fmt.signed(row.amount, data.currency))
                                .font(.title3.weight(.semibold)).monospacedDigit()
                                .foregroundStyle(row.amount > 0 ? Color.positive : .primary)
                        }
                        .padding(.vertical, 14)
                        .opacity(progress)
                        .offset(y: (1 - progress) * CGFloat(12 + i * 6))
                    }
                }
            }
        }
        .onAppear {
            withAnimation(.spring(duration: 0.9, bounce: 0.15).delay(0.15)) { progress = 1 }
        }
    }
}

private struct StatTile: View {
    let stat: FinanceStat
    let currency: String
    let delay: Double

    @State private var value: Double = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(stat.label).font(.title3.weight(.medium)).foregroundStyle(.secondary).lineLimit(2).minimumScaleFactor(0.8)
            CountingNumber(value: value, format: stat.format, currency: currency)
                .font(.system(size: 72, weight: .semibold, design: .rounded))
                .foregroundStyle(stat.tone == .positive ? Color.positive : .primary)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
            if let detail = stat.detail {
                Text(detail).font(.body).foregroundStyle(stat.tone == .negative ? Color.negative : .secondary).lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear {
            withAnimation(.easeOut(duration: 1.1).delay(delay)) { value = stat.value }
        }
        .onChange(of: stat.value) { _, new in
            withAnimation(.easeOut(duration: 0.8)) { value = new }
        }
    }
}

/// A number that counts smoothly to its value as it animates.
struct CountingNumber: View, Animatable {
    var value: Double
    let format: FinanceStat.Format
    let currency: String

    var animatableData: Double {
        get { value }
        set { value = newValue }
    }

    var body: some View {
        Text(text).monospacedDigit()
    }

    private var text: String {
        switch format {
        case .currency: Fmt.compact(value, currency)
        case .count: Int(value.rounded()).formatted()
        case .percent: "\(Int(value.rounded()))%"
        }
    }
}

private struct FinanceChartView: View {
    let chart: FinanceChart
    let currency: String
    let progress: Double

    var body: some View {
        switch chart.style {
        case .bar:
            Chart(Array(chart.points.enumerated()), id: \.element.id) { i, p in
                BarMark(x: .value("Period", p.label), y: .value("Amount", p.value * progress))
                    .cornerRadius(12)
                    .foregroundStyle(barColor(p.value).opacity(i == chart.points.count - 1 ? 1 : 0.4))
            }
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { v in
                    AxisGridLine().foregroundStyle(.quaternary)
                    AxisValueLabel { if let d = v.as(Double.self) { Text(Fmt.axis(d)).font(.body) } }
                }
            }
            .chartXAxis { AxisMarks { AxisValueLabel().font(.title3) } }

        case .hbar:
            Chart(chart.points) { p in
                BarMark(x: .value("Amount", p.value * progress), y: .value("Category", p.label))
                    .cornerRadius(12)
                    .foregroundStyle(CategoryStyle.color(p.label).gradient)
                    .annotation(position: .trailing, spacing: 8) {
                        Text(Fmt.compact(p.value, currency)).font(.title3.weight(.semibold)).monospacedDigit()
                            .foregroundStyle(.secondary)
                            .opacity(progress)
                    }
            }
            .chartXAxis(.hidden)
            .chartYAxis { AxisMarks { AxisValueLabel().font(.title3.weight(.medium)) } }
            .chartXScale(domain: 0...(chart.points.map(\.value).max() ?? 1) * 1.25)

        case .line:
            let low = chart.points.map(\.value).min() ?? 0
            let high = chart.points.map(\.value).max() ?? 1
            let pad = max((high - low) * 0.15, 1)
            Chart(chart.points) { p in
                AreaMark(x: .value("Date", p.label), yStart: .value("Base", low - pad), yEnd: .value("Value", p.value))
                    .interpolationMethod(.catmullRom)
                    .foregroundStyle(LinearGradient(colors: [Color.accentColor.opacity(0.3), .clear], startPoint: .top, endPoint: .bottom))
                LineMark(x: .value("Date", p.label), y: .value("Value", p.value))
                    .interpolationMethod(.catmullRom)
                    .lineStyle(StrokeStyle(lineWidth: 5, lineCap: .round))
                    .foregroundStyle(Color.accentColor)
            }
            .chartYScale(domain: (low - pad)...(high + pad))
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 4)) { AxisValueLabel().font(.title3) }
            }
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { v in
                    AxisGridLine().foregroundStyle(.quaternary)
                    AxisValueLabel { if let d = v.as(Double.self) { Text(Fmt.axis(d)).font(.body) } }
                }
            }
            // Draws left to right.
            .mask(alignment: .leading) {
                GeometryReader { geo in Rectangle().frame(width: geo.size.width * progress) }
            }
        }
    }

    private func barColor(_ value: Double) -> Color {
        value < 0 ? .negative : .accentColor
    }
}
