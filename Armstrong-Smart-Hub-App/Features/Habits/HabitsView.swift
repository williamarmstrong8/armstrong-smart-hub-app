import SwiftUI

/// Tap a circle when a habit is done today. Dates are this device's local day,
/// like the web board, which uses the browser's.
struct HabitsView: View {
    @Environment(AppSession.self) private var session
    @State private var store = HabitsStore()
    @State private var editing: HabitEditTarget?
    @State private var toast = Toast()

    var body: some View {
        NavigationStack {
            ScrollView {
                if !store.loaded, let error = store.error {
                    MessageView(title: "Couldn't load habits", systemImage: "exclamationmark.triangle", message: error,
                                actionTitle: "Try again") { Task { await store.load(api: session.api) } }
                } else if !store.loaded {
                    ProgressView().frame(maxWidth: .infinity, minHeight: 300)
                } else if store.habits.isEmpty {
                    MessageView(title: "No habits yet", systemImage: "circle.dashed", actionTitle: "Add your first habit") { editing = .new }
                } else {
                    VStack(alignment: .leading, spacing: 32) {
                        Text("**\(store.doneToday) of \(store.habits.count)** done today").foregroundStyle(.secondary)
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 20)], spacing: 36) {
                            ForEach(store.habits) { habit in
                                HabitTile(habit: habit, store: store, size: 128, toast: toast) { editing = .habit(habit) }
                            }
                        }
                        HabitHeatmap(habits: store.habits, today: store.today) { store.isDone($0, $1) }
                    }
                    .padding(16)
                }
            }
            .navigationTitle("Habits")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { AccountButton() }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Add habit", systemImage: "plus") { editing = .new }
                }
            }
            .task { if !store.loaded { await store.load(api: session.api) } }
            .refreshable { await store.load(api: session.api) }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.significantTimeChangeNotification)) { _ in store.rollDay() }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in store.rollDay() }
            .habitEditor($editing, store: store)
            .toast(toast)
        }
    }
}

enum HabitEditTarget: Identifiable {
    case new
    case habit(Habit)
    var id: String { if case .habit(let h) = self { return h.id } else { return "new" } }
}

extension View {
    func habitEditor(_ target: Binding<HabitEditTarget?>, store: HabitsStore) -> some View {
        sheet(item: target) { t in
            HabitEditor(habit: { if case .habit(let h) = t { return h } else { return nil } }(),
                        colors: store.colors.isEmpty ? ["#0F7B6C"] : store.colors) { result in
                switch result {
                case .saved(let h): store.saved(h)
                case .archived(let id): store.archived(id)
                }
            }
        }
    }
}

/// One habit: a big circle for today, the last 7 days, and the streak.
struct HabitTile: View {
    let habit: Habit
    let store: HabitsStore
    var size: CGFloat = 128
    let toast: Toast
    let onEdit: () -> Void

    @Environment(AppSession.self) private var session

    var body: some View {
        let color = Color(hex: habit.color)
        let today = store.today
        let doneToday = store.isDone(habit.id, today)
        VStack(spacing: size > 100 ? 12 : 8) {
            Button {
                toggle(today)
            } label: {
                ZStack {
                    Circle().strokeBorder(color, lineWidth: size > 100 ? 5 : 4)
                    Circle().fill(doneToday ? color : .clear).padding(doneToday ? 0 : 5)
                    if doneToday {
                        Image(systemName: "checkmark").font(.system(size: size * 0.38, weight: .bold)).foregroundStyle(.white)
                    } else if let icon = habit.icon {
                        Text(icon).font(.system(size: size * 0.38))
                    }
                }
                .frame(width: size, height: size)
                .contentShape(Circle())
            }
            .buttonStyle(PressableStyle())
            .disabled(store.isSaving(habit.id, today))
            .sensoryFeedback(.success, trigger: doneToday) { _, new in new }
            .accessibilityLabel("\(doneToday ? "Unmark" : "Mark") \(habit.name) as done today")

            Button(action: onEdit) {
                HStack(spacing: 4) {
                    Text(habit.name).font(size > 100 ? .headline : .subheadline.weight(.semibold))
                        .foregroundStyle(doneToday ? color : .primary).lineLimit(1)
                    Image(systemName: "pencil").font(.caption2).foregroundStyle(.tertiary)
                }
            }
            .buttonStyle(.plain)

            HStack(spacing: size > 100 ? 6 : 3) {
                ForEach((0..<7).map { addDays(today, $0 - 6) }, id: \.self) { day in
                    let on = store.isDone(habit.id, day)
                    Button { toggle(day) } label: {
                        Circle()
                            .strokeBorder(color, lineWidth: 1.5)
                            .background(Circle().fill(on ? color : .clear))
                            .frame(width: 12, height: 12)
                            .padding(3)
                            .overlay(day == today ? Circle().strokeBorder(color.opacity(0.5), lineWidth: 1) : nil)
                    }
                    .buttonStyle(.plain)
                    .disabled(store.isSaving(habit.id, day))
                    .accessibilityLabel("\(on ? "Unmark" : "Mark") \(habit.name) on \(day)")
                }
            }

            Text(store.streakText(habit)).font(.caption).foregroundStyle(.secondary).monospacedDigit().frame(height: 14)
        }
    }

    private func toggle(_ day: String) {
        Task { await store.toggle(habit, day, api: session.api, toast: toast) }
    }
}

private struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .animation(.spring(duration: 0.2), value: configuration.isPressed)
    }
}

/// The last 12 weeks, one row per habit.
struct HabitHeatmap: View {
    let habits: [Habit]
    let today: String
    let isDone: (String, String) -> Bool

    var body: some View {
        let days = (0..<84).map { addDays(today, $0 - 83) }
        VStack(alignment: .leading, spacing: 12) {
            Text("Last 12 weeks").font(.headline)
            ForEach(habits) { habit in
                VStack(alignment: .leading, spacing: 6) {
                    Text(habit.name).font(.caption).foregroundStyle(.secondary)
                    let color = Color(hex: habit.color)
                    LazyHGrid(rows: Array(repeating: GridItem(.fixed(9), spacing: 3), count: 7), spacing: 3) {
                        ForEach(days, id: \.self) { day in
                            RoundedRectangle(cornerRadius: 2)
                                .fill(isDone(habit.id, day) ? color : Color(.tertiarySystemFill))
                                .frame(width: 9, height: 9)
                        }
                    }
                    .frame(height: 7 * 9 + 6 * 3)
                }
            }
        }
        .padding(16)
        .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 16))
    }
}
