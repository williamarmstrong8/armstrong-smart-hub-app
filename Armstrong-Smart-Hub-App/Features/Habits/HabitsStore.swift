import Foundation
import Observation

/// The habit board's state, shared by the Habits tab and the iPad dashboard.
/// Dates are this device's local day, like the web board uses the browser's.
@MainActor
@Observable
final class HabitsStore {
    private(set) var habits: [Habit] = []
    private(set) var done: Set<Completion> = []
    private(set) var saving: Set<Completion> = []
    private(set) var colors: [String] = []
    private(set) var historyDays = 365
    private(set) var loaded = false
    private(set) var error: String?
    var today = localDay()

    var doneToday: Int { habits.filter { isDone($0.id, today) }.count }

    func isDone(_ habitId: String, _ day: String) -> Bool { done.contains(Completion(habitId: habitId, date: day)) }
    func isSaving(_ habitId: String, _ day: String) -> Bool { saving.contains(Completion(habitId: habitId, date: day)) }

    /// Counts back from today, or from yesterday while today is still open.
    func streak(_ habit: Habit) -> Int {
        var count = 0
        var day = isDone(habit.id, today) ? today : addDays(today, -1)
        while isDone(habit.id, day) && count <= historyDays {
            count += 1
            day = addDays(day, -1)
        }
        return count
    }

    func streakText(_ habit: Habit) -> String {
        let s = streak(habit)
        guard s > 1 else { return "" }
        return s > historyDays ? "\(historyDays)+ day streak" : "\(s) day streak"
    }

    func load(api: APIClient) async {
        do {
            let r: HabitsResponse = try await api.get("/api/mobile/habits")
            habits = r.habits
            done = Set(r.completions)
            colors = r.colors
            historyDays = r.historyDays
            loaded = true
            error = nil
            today = localDay()
        } catch is CancellationError {
        } catch {
            self.error = error.localizedDescription
        }
    }

    func toggle(_ habit: Habit, _ date: String, api: APIClient, toast: Toast) async {
        let key = Completion(habitId: habit.id, date: date)
        guard !saving.contains(key) else { return }
        let next = !done.contains(key)
        if next { done.insert(key) } else { done.remove(key) }
        saving.insert(key)
        defer { saving.remove(key) }
        do {
            let _: Empty? = try await api.run("setCompletion", [.string(habit.id), .string(date), .bool(next)])
        } catch {
            if next { done.remove(key) } else { done.insert(key) }
            toast.error(error)
        }
    }

    func saved(_ habit: Habit) {
        if let i = habits.firstIndex(where: { $0.id == habit.id }) { habits[i] = habit } else { habits.append(habit) }
    }

    func archived(_ id: String) { habits.removeAll { $0.id == id } }

    func rollDay() { today = localDay() }
}
