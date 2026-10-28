import Charts
import SwiftUI

/// How you're doing, from the watch: the three Oura-style rings (readiness,
/// sleep, Body Battery), a row of numbers, and the week's steps.
struct FitnessCard: View {
    let data: FitnessCardData

    @State private var progress: Double = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 40) {
            CardHeader(title: "Fitness", detail: detail)

            HStack(alignment: .top, spacing: 16) {
                ring(data.readiness, "Readiness", Fit.readiness)
                ring(data.sleepScore, "Sleep", Fit.sleep)
                ring(data.bodyBattery, "Body Battery", Fit.energy)
            }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 24)], alignment: .leading, spacing: 24) {
                if let s = data.steps { stat(stepsLabel, s.formatted(), data.stepGoal.map { "of \($0.formatted())" }) }
                if let s = data.sleepSeconds { stat("Slept", String(format: "%dh %02dm", s / 3600, s % 3600 / 60), nil) }
                if let hr = data.restingHr { stat("Resting HR", "\(hr)", "bpm") }
                if let hrv = data.hrv { stat("HRV", "\(hrv)", "ms") }
                if let w = data.lastWorkout { stat("Last workout", w.sport.capitalized, workoutDetail(w)) }
            }

            if data.week.contains(where: { $0.steps != nil }) {
                Chart(data.week) { d in
                    BarMark(x: .value("Day", weekday(d.day)), y: .value("Steps", Double(d.steps ?? 0) * progress))
                        .cornerRadius(8)
                        .foregroundStyle(Fit.activity.opacity(d.id == data.week.last?.id ? 1 : 0.5))
                }
                .chartYAxis {
                    AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { v in
                        AxisGridLine().foregroundStyle(.quaternary)
                        AxisValueLabel { if let n = v.as(Double.self) { Text(Fmt.axis(n)).font(.body) } }
                    }
                }
                .chartXAxis { AxisMarks { AxisValueLabel().font(.title3) } }
                .frame(height: 180)
            }
        }
        .onAppear {
            withAnimation(.spring(duration: 0.9, bounce: 0.15).delay(0.15)) { progress = 1 }
        }
    }

    private var detail: String {
        guard let r = data.readiness else { return "No readiness from the watch yet" }
        return r >= 75 ? "Ready to push" : r >= 40 ? "Fine for an easy day" : "Take it easy today"
    }

    private var stepsLabel: String {
        guard let day = data.stepsDay else { return "Steps" }
        return day == DayFormat.string(.now, zone: .current) ? "Steps today" : "Steps \(weekday(day))"
    }

    private func ring(_ value: Int?, _ label: String, _ tint: Color) -> some View {
        ScoreRing(value: value.map(String.init) ?? "–", fraction: Double(value ?? 0) / 100 * progress, tint: tint, size: 150,
                  label: label, weight: 0.06)
            .frame(maxWidth: .infinity)
    }

    private func stat(_ label: String, _ value: String, _ detail: String?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.title3.weight(.medium)).foregroundStyle(.secondary).lineLimit(1)
            Text(value).font(.system(size: 40, weight: .light).monospacedDigit()).lineLimit(1).minimumScaleFactor(0.6)
            if let detail { Text(detail).font(.body).foregroundStyle(.secondary).lineLimit(1) }
        }
    }

    private func workoutDetail(_ w: FitnessCardData.Workout) -> String {
        var parts: [String] = []
        if let start = ISO.parse(w.startTime) { parts.append(start.formatted(.relative(presentation: .named))) }
        if let m = w.minutes { parts.append("\(m) min") }
        return parts.joined(separator: " · ")
    }

    private func weekday(_ day: String) -> String {
        guard let date = DayFormat.parse(day) else { return day }
        return date.formatted(Date.FormatStyle(timeZone: .gmt).weekday(.abbreviated))
    }
}
