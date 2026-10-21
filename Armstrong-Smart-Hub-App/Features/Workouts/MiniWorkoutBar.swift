import SwiftUI

/// The workout in progress, closed, as a card above the tab bar: name and
/// time, the next set or the rest countdown, and a check (or Skip) button.
/// Tapping it opens the workout again.
struct MiniWorkoutBar: View {
    @Environment(\.tabViewBottomAccessoryPlacement) private var placement
    var store: WorkoutStore

    var body: some View {
        if let workout = store.active {
            HStack(spacing: 12) {
                Button { store.isPresented = true } label: {
                    HStack(spacing: 10) {
                        Circle().fill(Fit.positive).frame(width: 8, height: 8)
                        VStack(alignment: .leading, spacing: 1) {
                            HStack(spacing: 6) {
                                Text(workout.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                                Text(workout.startedAt, style: .timer)
                                    .font(.subheadline).foregroundStyle(Fit.muted).monospacedDigit()
                            }
                            if placement != .inline {
                                detail.font(.caption).foregroundStyle(Fit.muted).lineLimit(1)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityHint("Opens the workout")
                action
            }
            .padding(.horizontal, 14)
        }
    }

    /// "Rest 0:42", or "Bench Press · Set 2 of 4".
    @ViewBuilder private var detail: some View {
        if let end = store.restEndsAt, end > .now {
            HStack(spacing: 4) {
                Text("Rest")
                Text(timerInterval: Date.now...end, countsDown: true).monospacedDigit().foregroundStyle(Fit.energy)
            }
        } else if let state = store.activityState, let name = state.exerciseName {
            Text("\(name) · \(state.setLabel)")
        } else {
            Text("All sets done")
        }
    }

    @ViewBuilder private var action: some View {
        if let end = store.restEndsAt, end > .now {
            Button("Skip") { store.skipRest() }
                .font(.subheadline.weight(.semibold))
                .buttonStyle(.borderedProminent)
                .tint(Fit.energy)
        } else if store.nextSet != nil {
            Button {
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                store.handle(.completeSet)
            } label: {
                Image(systemName: "checkmark").font(.subheadline.weight(.bold)).foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(Fit.positive, in: .circle)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Complete next set")
        }
    }
}
