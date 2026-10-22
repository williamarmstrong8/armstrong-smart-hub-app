import AppIntents
import SwiftUI
import WidgetKit

@main
struct WorkoutWidgetsBundle: WidgetBundle {
    var body: some Widget {
        WorkoutLiveActivity()
        WorkoutHomeWidget()
        TVLiveActivity()
        LightsWidget()
        LightControl()
        HabitsWidget()
        FitnessWidget()
        BodyBatteryWidget()
        StepsWidget()
        BrickWidget()
    }
}

/// The app's Fitness colors, dark values (the lock screen and island are dark).
enum WidgetColor {
    static let blue = Color(red: 0x52 / 255, green: 0xA8 / 255, blue: 0xFF / 255)
    static let green = Color(red: 0x62 / 255, green: 0xC0 / 255, blue: 0x73 / 255)
    static let heart = Color(red: 0xFF / 255, green: 0x61 / 255, blue: 0x66 / 255)
    static let track = Color.white.opacity(0.16)
    static let muted = Color.white.opacity(0.6)
}

// MARK: Pieces shared by the lock screen, island and widget

/// Reps done out of reps planned, as a thin bar with the numbers.
struct RepsBar: View {
    var state: WorkoutActivityState

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(WidgetColor.track)
                    Capsule().fill(WidgetColor.blue).frame(width: geo.size.width * state.repFraction)
                }
            }
            .frame(height: 5)
            HStack {
                Text("\(state.repsDone) of \(state.repsTotal) reps")
                Spacer()
                if let bpm = state.bpm {
                    Label("\(bpm)", systemImage: "heart.fill").foregroundStyle(WidgetColor.heart)
                }
                Text(state.volume)
            }
            .font(.caption2.weight(.medium))
            .foregroundStyle(WidgetColor.muted)
            .monospacedDigit()
        }
    }
}

/// The big check button that completes the next set.
struct CompleteSetButton: View {
    var size: CGFloat = 52

    var body: some View {
        Button(intent: CompleteSetIntent()) {
            Image(systemName: "checkmark")
                .font(.system(size: size * 0.4, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: size, height: size)
                .background(WidgetColor.green, in: .rect(cornerRadius: size * 0.28))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Complete set")
    }
}

/// −15, +15 and Skip for the rest timer.
struct RestButtons: View {
    var height: CGFloat = 40

    var body: some View {
        HStack(spacing: 8) {
            pill("-15", AdjustRestIntent(seconds: -15), fill: WidgetColor.track)
            pill("+15", AdjustRestIntent(seconds: 15), fill: WidgetColor.track)
            pill("Skip", SkipRestIntent(), fill: WidgetColor.blue)
        }
    }

    private func pill(_ title: String, _ intent: some AppIntent, fill: Color) -> some View {
        Button(intent: intent) {
            Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                .frame(maxWidth: .infinity).frame(height: height)
                .background(fill, in: .rect(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }
}

/// The next set: exercise, which set, and the numbers to hit.
struct NextSetText: View {
    var state: WorkoutActivityState

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let name = state.exerciseName {
                Text(name).font(.headline).lineLimit(1)
                Text(state.setLabel).font(.subheadline).foregroundStyle(WidgetColor.muted)
                if !state.target.isEmpty {
                    Text(state.target).font(.title2.weight(.semibold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
                        .padding(.top, 4)
                }
            } else {
                Text("All sets done").font(.headline)
                Text("Open the app to finish").font(.subheadline).foregroundStyle(WidgetColor.muted)
            }
        }
    }
}

/// The rest countdown, ticking on its own.
struct RestCountdown: View {
    var endsAt: Date
    var total: TimeInterval
    var font: Font = .system(size: 40, weight: .medium)

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Rest").font(.subheadline).foregroundStyle(WidgetColor.muted)
            Text(timerInterval: Date.now...max(endsAt, .now), countsDown: true)
                .font(font).monospacedDigit()
            ProgressView(timerInterval: endsAt.addingTimeInterval(-max(total, 1))...endsAt, countsDown: true) {
                EmptyView()
            } currentValueLabel: {
                EmptyView()
            }
            .tint(WidgetColor.blue)
        }
    }
}
