import SwiftUI

/// Adding and editing habits, from the Home tab and the iPad dashboard.
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
