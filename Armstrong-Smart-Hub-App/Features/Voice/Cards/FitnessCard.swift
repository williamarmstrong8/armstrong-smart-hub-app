import SwiftUI

/// The one fitness number you asked about, big enough to read across the
/// room: readiness, sleep and Body Battery as a ring; steps, heart rate and
/// the last workout as a number.
struct FitnessCard: View {
    let data: FitnessCardData

    @State private var progress: Double = 0

    var body: some View {
        VStack(spacing: 24) {
            switch data.focus ?? "readiness" {
            case "sleep":
                ring(data.sleepScore, Fit.sleep, title: "Sleep", note: data.sleepSeconds.map(hours))
            case "bodyBattery":
                ring(data.bodyBattery, Fit.energy, title: "Body Battery", note: nil)
            case "steps":
                big(data.steps?.formatted() ?? "–", title: stepsTitle, note: data.stepGoal.map { "Goal \($0.formatted())" })
            case "heart":
                big(data.restingHr.map(String.init) ?? "–", title: "Resting heart rate", note: data.hrv.map { "HRV \($0) ms" })
            case "workout":
                if let w = data.lastWorkout {
                    big(w.sport.capitalized, title: "Last workout", note: workoutNote(w))
                } else {
                    big("–", title: "Last workout", note: "None yet")
                }
            default:
                ring(data.readiness, Fit.readiness, title: "Readiness", note: readinessNote)
            }
        }
        .frame(maxWidth: .infinity)
        .onAppear {
            withAnimation(.spring(duration: 1, bounce: 0.15).delay(0.1)) { progress = 1 }
        }
    }

    private func ring(_ value: Int?, _ tint: Color, title: String, note: String?) -> some View {
        VStack(spacing: 20) {
            ScoreRing(value: value.map(String.init) ?? "–", fraction: Double(value ?? 0) / 100 * progress, tint: tint, size: 340, weight: 0.05)
            caption(title, note ?? Status.word(value))
        }
    }

    private func big(_ value: String, title: String, note: String?) -> some View {
        VStack(spacing: 20) {
            Text(value)
                .font(.system(size: 160, weight: .light).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.4)
                .opacity(progress)
            caption(title, note)
        }
    }

    private func caption(_ title: String, _ note: String?) -> some View {
        VStack(spacing: 6) {
            Text(title).font(.system(size: 40, weight: .semibold, design: .rounded))
            if let note { Text(note).font(.title2.weight(.medium)).foregroundStyle(.secondary) }
        }
        .multilineTextAlignment(.center)
    }

    private var readinessNote: String {
        guard let r = data.readiness else { return "No readiness from the watch yet" }
        return r >= 75 ? "Ready to push" : r >= 40 ? "Fine for an easy day" : "Take it easy today"
    }

    private var stepsTitle: String {
        guard let day = data.stepsDay, day != DayFormat.string(.now, zone: .current),
              let date = DayFormat.parse(day) else { return "Steps today" }
        return "Steps " + date.formatted(Date.FormatStyle(timeZone: .gmt).weekday(.wide))
    }

    private func hours(_ seconds: Int) -> String { String(format: "%dh %02dm asleep", seconds / 3600, seconds % 3600 / 60) }

    private func workoutNote(_ w: FitnessCardData.Workout) -> String {
        var parts: [String] = []
        if let start = ISO.parse(w.startTime) { parts.append(start.formatted(.relative(presentation: .named))) }
        if let m = w.minutes { parts.append("\(m) min") }
        return parts.joined(separator: " · ")
    }
}
