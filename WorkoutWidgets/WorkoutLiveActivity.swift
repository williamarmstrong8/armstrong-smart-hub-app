import AppIntents
import ActivityKit
import SwiftUI
import WidgetKit

/// The workout on the lock screen and in the Dynamic Island: the next set with
/// a check button, or the rest countdown with −15, +15 and Skip.
struct WorkoutLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: WorkoutActivityAttributes.self) { context in
            LockScreenView(attributes: context.attributes, state: context.state, resting: resting(context))
                .activityBackgroundTint(.black)
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            let resting = resting(context)
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label(context.attributes.name, systemImage: "dumbbell.fill")
                        .font(.caption.weight(.semibold)).foregroundStyle(WidgetColor.blue).lineLimit(1)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(context.attributes.startedAt, style: .timer)
                        .font(.caption.weight(.semibold)).monospacedDigit().multilineTextAlignment(.trailing)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(spacing: 10) {
                        if resting, let end = context.state.restEndsAt {
                            RestCountdown(endsAt: end, total: context.state.restTotal, font: .system(size: 32, weight: .medium))
                            RestButtons(height: 36)
                        } else {
                            HStack(alignment: .center) {
                                NextSetText(state: context.state)
                                Spacer(minLength: 8)
                                if context.state.exerciseName != nil { CompleteSetButton(size: 48) }
                            }
                        }
                        RepsBar(state: context.state)
                    }
                    .padding(.top, 4)
                }
            } compactLeading: {
                Image(systemName: resting ? "timer" : "dumbbell.fill").foregroundStyle(WidgetColor.blue)
            } compactTrailing: {
                if resting, let end = context.state.restEndsAt {
                    Text(timerInterval: Date.now...max(end, .now), countsDown: true)
                        .monospacedDigit().frame(maxWidth: 44)
                } else {
                    Text("\(context.state.setsDone)").monospacedDigit()
                }
            } minimal: {
                if resting, let end = context.state.restEndsAt {
                    Text(timerInterval: Date.now...max(end, .now), countsDown: true)
                        .monospacedDigit().font(.caption2)
                } else {
                    Image(systemName: "dumbbell.fill").foregroundStyle(WidgetColor.blue)
                }
            }
            .keylineTint(WidgetColor.blue)
        }
    }

    /// Resting until the timer runs out. The app marks the content stale at
    /// that moment, so this flips back to the next set even if the app is asleep.
    private func resting(_ context: ActivityViewContext<WorkoutActivityAttributes>) -> Bool {
        context.state.restEndsAt != nil && !context.isStale
    }
}

private struct LockScreenView: View {
    var attributes: WorkoutActivityAttributes
    var state: WorkoutActivityState
    var resting: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(attributes.name, systemImage: "dumbbell.fill")
                    .font(.subheadline.weight(.semibold)).foregroundStyle(WidgetColor.muted).lineLimit(1)
                Spacer()
                Text(attributes.startedAt, style: .timer)
                    .font(.subheadline.weight(.semibold)).monospacedDigit().multilineTextAlignment(.trailing)
                    .frame(maxWidth: 90, alignment: .trailing)
            }
            if resting, let end = state.restEndsAt {
                RestCountdown(endsAt: end, total: state.restTotal)
                RestButtons()
            } else {
                HStack(alignment: .center) {
                    NextSetText(state: state)
                    Spacer(minLength: 8)
                    if state.exerciseName != nil { CompleteSetButton() }
                }
            }
            RepsBar(state: state)
        }
        .foregroundStyle(.white)
        .padding(16)
    }
}
