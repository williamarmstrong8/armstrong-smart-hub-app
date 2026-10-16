import Charts
import SwiftUI

/// The hub's own physiology numbers (lib/fitness/physiology.ts in the hub):
/// Training Readiness, Body Battery, stress, VO2max, load and HRV status,
/// worked out from the watch's raw data rather than Garmin's firmware.
struct FitnessMetrics: Decodable {
    var readiness: Readiness
    var bodyBattery: BodyBattery?
    var stress: Stress?
    var vo2max: Vo2max?
    var load: Load
    var hrv: Hrv
    var vitals: Vitals

    struct Readiness: Decodable {
        var score: Int?
        var level: String?
        var factors: [Factor]

        struct Factor: Decodable, Identifiable {
            var key: String
            var label: String
            var score: Int?
            var weight: Double
            var detail: String
            var id: String { key }
        }
    }

    struct BodyBattery: Decodable {
        var current: Int
        var charged: Int
        var drained: Int
        var series: [Point]
        struct Point: Decodable { var at: String; var value: Int }
    }

    struct Stress: Decodable {
        var average: Int?
        var restMinutes: Int
        var series: [Point]
        struct Point: Decodable { var at: String; var value: Int?; var kind: String }
    }

    struct Vo2max: Decodable {
        var value: Double
        var asOf: String
        var watch: Double?
        var runs: [Run]
        struct Run: Decodable { var at: String; var value: Double; var watch: Double? }
    }

    struct Load: Decodable {
        var acute: Int
        var chronic: Int
        var ratio: Double?
        var recoveryHours: Int
        var status: String?
    }

    struct Hrv: Decodable {
        var lastNight: Double?
        var weekly: Double?
        var baseline: Range?
        var status: String
        struct Range: Decodable { var low: Double; var high: Double }
    }

    struct Vitals: Decodable {
        var spo2: Double?
        var respiration: Double?
        var skinTemp: Double?
        var isEmpty: Bool { spo2 == nil && respiration == nil && skinTemp == nil }
    }
}

enum MetricColor {
    /// Garmin's readiness bands: prime 95+, high 75-94, moderate 50-74, low 25-49, poor.
    static func readiness(_ score: Int?) -> Color {
        guard let score else { return .secondary }
        return score >= 75 ? .green : score >= 50 ? .yellow : score >= 25 ? .orange : .red
    }

    /// Stress bands: 0-25 rest, 26-50 low, 51-75 medium, 76-100 high.
    static func stress(_ value: Int) -> Color {
        value <= 25 ? .blue : value <= 50 ? .yellow : value <= 75 ? .orange : .red
    }
}

// MARK: Readiness

struct ReadinessSection: View {
    var readiness: FitnessMetrics.Readiness

    var body: some View {
        FloatingSection(title: "Training readiness", trailing: readiness.level?.capitalized) {
            HStack(alignment: .center, spacing: 22) {
                ZStack {
                    Circle().stroke(Color.primary.opacity(0.08), lineWidth: 10)
                    Circle().trim(from: 0, to: Double(readiness.score ?? 0) / 100)
                        .stroke(MetricColor.readiness(readiness.score), style: StrokeStyle(lineWidth: 10, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    Text(readiness.score.map(String.init) ?? "–")
                        .font(.system(size: 34, weight: .heavy, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                }
                .frame(width: 104, height: 104)
                VStack(alignment: .leading, spacing: 9) {
                    ForEach(readiness.factors) { factor in
                        FactorRow(factor: factor)
                    }
                }
            }
            if readiness.score == nil {
                Text("Readiness needs at least two of these. Sleep, HRV and stress fill in once the watch hands over its sleep and all-day files; recovery and load come from recent workouts.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

private struct FactorRow: View {
    var factor: FitnessMetrics.Readiness.Factor

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text(factor.label).font(.caption.weight(.semibold))
                Spacer(minLength: 6)
                Text(factor.detail).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            Capsule().fill(Color.primary.opacity(0.08)).frame(height: 4)
                .overlay(alignment: .leading) {
                    if let score = factor.score {
                        GeometryReader { geo in
                            Capsule().fill(MetricColor.readiness(score)).frame(width: max(4, geo.size.width * Double(score) / 100))
                        }
                    }
                }
        }
        .opacity(factor.score == nil ? 0.45 : 1)
    }
}

// MARK: Body Battery and stress

struct EnergySection: View {
    var battery: FitnessMetrics.BodyBattery?
    var stress: FitnessMetrics.Stress?

    var body: some View {
        FloatingSection(title: "Body Battery & stress", trailing: stress?.average.map { "stress \($0) avg" }) {
            if battery == nil && stress == nil {
                Text("Body Battery and stress are worked out from all-day heart rate, so they appear once the watch hands over a day of monitoring files.")
                    .font(.subheadline).foregroundStyle(.secondary)
            } else {
                if let battery {
                    HStack(alignment: .firstTextBaseline, spacing: 18) {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            TablerIcon(name: "battery-2", size: 22).foregroundStyle(.teal)
                            Text("\(battery.current)").font(.system(size: 40, weight: .heavy, design: .rounded)).foregroundStyle(.teal)
                        }
                        Spacer()
                        Stat(label: "Charged", value: "+\(battery.charged)")
                        Stat(label: "Drained", value: "−\(battery.drained)")
                    }
                    let points = battery.series.compactMap { p in ISO.parse(p.at).map { ($0, p.value) } }
                    Chart(points, id: \.0) { point in
                        AreaMark(x: .value("Time", point.0), y: .value("Battery", point.1))
                            .interpolationMethod(.monotone)
                            .foregroundStyle(LinearGradient(colors: [.teal.opacity(0.3), .teal.opacity(0)], startPoint: .top, endPoint: .bottom))
                        LineMark(x: .value("Time", point.0), y: .value("Battery", point.1))
                            .interpolationMethod(.monotone)
                            .foregroundStyle(.teal)
                            .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round))
                    }
                    .chartYScale(domain: 0...100)
                    .chartYAxis(.hidden)
                    .chartXAxis { AxisMarks(values: .stride(by: .hour, count: 6)) { _ in AxisValueLabel(format: .dateTime.hour()) } }
                    .frame(height: 110)
                }
                if let stress {
                    let points = stress.series.compactMap { p -> (Date, Int, Color)? in
                        guard let date = ISO.parse(p.at) else { return nil }
                        // Activity shows as a short grey bar, like Garmin's.
                        guard let value = p.value else { return (date, 8, Color.secondary.opacity(0.35)) }
                        return (date, max(value, 3), MetricColor.stress(value))
                    }
                    Chart(points, id: \.0) { point in
                        BarMark(x: .value("Time", point.0, unit: .minute), y: .value("Stress", point.1), width: .fixed(2))
                            .foregroundStyle(point.2)
                    }
                    .chartYScale(domain: 0...100)
                    .chartYAxis(.hidden)
                    .chartXAxis { AxisMarks(values: .stride(by: .hour, count: 6)) { _ in AxisValueLabel(format: .dateTime.hour()) } }
                    .frame(height: 70)
                    HStack(spacing: 12) {
                        ForEach([("Rest", Color.blue), ("Low", .yellow), ("Medium", .orange), ("High", .red)], id: \.0) { band in
                            Label(band.0, systemImage: "circle.fill").labelStyle(TintedDot(color: band.1))
                        }
                        Spacer()
                        Text("\(FitnessFormat.duration(Double(stress.restMinutes * 60))) rest").monospacedDigit()
                    }
                    .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}

// MARK: Performance

struct PerformanceSection: View {
    var metrics: FitnessMetrics

    var body: some View {
        FloatingSection(title: "Performance", trailing: metrics.load.status) {
            HStack(alignment: .top, spacing: 12) {
                BigMetric(symbol: "lungs", tint: .orange, title: "VO2 max",
                          value: metrics.vo2max.map { String(format: "%.0f", $0.value) } ?? "–")
                BigMetric(symbol: "clock-hour-4", tint: .purple, title: "Recovery",
                          value: metrics.load.recoveryHours > 0 ? "\(metrics.load.recoveryHours)h" : "Done")
                BigMetric(symbol: "chart-bar", tint: .pink, title: "7-day load", value: "\(metrics.load.acute)")
            }
            if let vo2 = metrics.vo2max {
                let runs = vo2.runs.compactMap { r in ISO.parse(r.at).map { ($0, r.value) } }
                if runs.count > 1 {
                    Chart(runs, id: \.0) { run in
                        LineMark(x: .value("Date", run.0), y: .value("VO2 max", run.1))
                            .interpolationMethod(.monotone)
                            .foregroundStyle(.orange)
                            .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round))
                        PointMark(x: .value("Date", run.0), y: .value("VO2 max", run.1))
                            .foregroundStyle(.orange).symbolSize(18)
                    }
                    .chartYScale(domain: .automatic(includesZero: false))
                    .chartXAxis { AxisMarks(values: .automatic(desiredCount: 4)) { _ in AxisValueLabel(format: .dateTime.month(.abbreviated)) } }
                    .frame(height: 90)
                }
                Text(vo2Caption(vo2)).font(.caption).foregroundStyle(.secondary)
            }
            VStack(spacing: 10) {
                if let ratio = metrics.load.ratio {
                    LabeledContent("Acute : chronic load", value: String(format: "%d : %d  (%.1f×)", metrics.load.acute, metrics.load.chronic, ratio))
                }
                LabeledContent("HRV status", value: hrvText)
                if !metrics.vitals.isEmpty {
                    if let spo2 = metrics.vitals.spo2 { LabeledContent("SpO2", value: String(format: "%.0f%%", spo2)) }
                    if let breaths = metrics.vitals.respiration { LabeledContent("Respiration", value: String(format: "%.0f brpm", breaths)) }
                    if let skin = metrics.vitals.skinTemp { LabeledContent("Skin temp", value: String(format: "%+.1f°", skin)) }
                }
            }
            .font(.subheadline)
        }
    }

    private func vo2Caption(_ vo2: FitnessMetrics.Vo2max) -> String {
        let date = ISO.parse(vo2.asOf).map { $0.formatted(.dateTime.month(.abbreviated).day()) } ?? ""
        let watch = vo2.watch.map { String(format: " · watch said %.1f", $0) } ?? ""
        return String(format: "%.1f ml/kg/min from heart rate vs pace on outdoor runs, as of %@", vo2.value, date) + watch
    }

    private var hrvText: String {
        let hrv = metrics.hrv
        guard hrv.status != "building" else { return hrv.lastNight.map { String(format: "%.0f ms · building baseline", $0) } ?? "Needs overnight data" }
        let weekly = hrv.weekly.map { String(format: "%.0f ms", $0) } ?? "–"
        return "\(hrv.status.capitalized) · \(weekly)"
    }
}
