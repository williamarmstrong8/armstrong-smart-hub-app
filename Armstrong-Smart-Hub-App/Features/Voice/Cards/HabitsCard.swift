import SwiftUI

/// Today's habits: just the circles, the same as the dashboard's habits column.
/// Asking for status floats them all in; checking one off fills it and pops
/// the check, exactly like tapping it on the dashboard.
struct HabitsCard: View {
    let data: HabitsCardData

    /// Centered rows, as many across as fit (a short last row centered too).
    var body: some View {
        ViewThatFits(in: .horizontal) {
            rows(5)
            rows(4)
            rows(3)
            rows(2)
        }
        .frame(maxWidth: .infinity)
    }

    private func rows(_ across: Int) -> some View {
        let habits = Array(data.habits.enumerated())
        let n = max(1, min(across, habits.count))
        let rows = stride(from: 0, to: habits.count, by: n).map { Array(habits[$0..<min($0 + n, habits.count)]) }
        return VStack(spacing: 40) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(alignment: .top, spacing: 32) {
                    ForEach(row, id: \.element.id) { i, habit in
                        HabitCircle(habit: habit, changed: habit.id == data.changedId, delay: Double(i) * 0.08)
                            .frame(width: 170)
                    }
                }
            }
        }
        .fixedSize()
    }
}

/// Mirrors HabitButton on the dashboard.
private struct HabitCircle: View {
    let habit: HabitDot
    let changed: Bool
    let delay: Double

    @State private var done = false
    @State private var appeared = false

    var body: some View {
        let color = Color(hex: habit.color)
        VStack(spacing: 10) {
            ZStack {
                Circle().strokeBorder(color, lineWidth: 7)
                Circle().fill(done ? color : color.opacity(0.08)).padding(done ? 0 : 7)
                if done {
                    Image(systemName: "checkmark")
                        .font(.system(size: 56, weight: .bold))
                        .foregroundStyle(.white)
                        .transition(.scale.combined(with: .opacity))
                } else if let icon = habit.icon {
                    Text(icon).font(.system(size: 50))
                }
            }
            .frame(width: 140, height: 140)
            Text(habit.name)
                .font(.title2.weight(.semibold))
                .foregroundStyle(done ? color : .primary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity)
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared ? 0 : 24)
        .sensoryFeedback(.success, trigger: done) { old, new in changed && new && !old }
        .onAppear(perform: play)
        .onChange(of: habit) { play() }
    }

    private func play() {
        // A changed habit starts in its old state, then animates to the new one.
        done = changed ? !habit.done : habit.done
        withAnimation(.spring(duration: 0.5, bounce: 0.2).delay(delay)) { appeared = true }
        if changed {
            withAnimation(.spring(duration: 0.5, bounce: 0.2).delay(delay + 0.55)) { done = habit.done }
        }
    }
}
