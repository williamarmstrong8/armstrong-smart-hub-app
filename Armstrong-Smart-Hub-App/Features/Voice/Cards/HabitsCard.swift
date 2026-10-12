import SwiftUI

/// Today's habits: just the circles, the same as the dashboard's habits column.
/// Asking for status floats them all in; checking one off fills it and pops
/// the check, exactly like tapping it on the dashboard.
struct HabitsCard: View {
    let data: HabitsCardData

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(190), spacing: 48), count: max(1, min(data.habits.count, 5))), spacing: 48) {
            ForEach(Array(data.habits.enumerated()), id: \.element.id) { i, habit in
                HabitCircle(habit: habit, changed: habit.id == data.changedId, delay: Double(i) * 0.08)
            }
        }
        .frame(maxWidth: .infinity)
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
                        .font(.system(size: 64, weight: .bold))
                        .foregroundStyle(.white)
                        .transition(.scale.combined(with: .opacity))
                } else if let icon = habit.icon {
                    Text(icon).font(.system(size: 58))
                }
            }
            .frame(width: 160, height: 160)
            Text(habit.name)
                .font(.title2.weight(.semibold))
                .foregroundStyle(done ? color : .primary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
        }
        .frame(width: 190)
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
