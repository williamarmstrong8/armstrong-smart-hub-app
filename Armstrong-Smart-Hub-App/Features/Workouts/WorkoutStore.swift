import Foundation
import Observation
import UserNotifications

/// The workout logger. The workout in progress is written to disk on every
/// change, so a crash or a gym with no signal never loses it; finished
/// workouts wait on the phone until the hub takes them.
@MainActor
@Observable
final class WorkoutStore {
    private(set) var home: WorkoutsHome?
    private(set) var error: String?
    private(set) var pending: [ActiveWorkout] = []
    private(set) var isUploading = false
    private var details: [String: WorkoutDetail] = [:]

    var active: ActiveWorkout? {
        didSet { save(active, to: Self.activeURL) }
    }

    /// When the rest timer ends, and how long it was set for.
    private(set) var restEndsAt: Date?
    private(set) var restTotal: TimeInterval = 0

    static let defaultRest = 90

    init() {
        active = Self.read(ActiveWorkout.self, from: Self.activeURL)
        pending = Self.read([ActiveWorkout].self, from: Self.pendingURL) ?? []
    }

    // MARK: Hub

    func load(api: APIClient) async {
        await upload(api: api)
        do {
            home = try await api.get("/api/mobile/workouts")
            error = nil
        } catch is CancellationError {
        } catch {
            self.error = error.localizedDescription
        }
    }

    func cachedDetail(_ id: String) -> WorkoutDetail? { details[id] }

    func detail(_ id: String, api: APIClient, refresh: Bool = false) async -> WorkoutDetail? {
        if !refresh, let cached = details[id] { return cached }
        let detail: WorkoutDetail? = try? await api.get("/api/mobile/workouts/detail?id=\(id)")
        if let detail { details[id] = detail }
        return detail ?? details[id]
    }

    func delete(_ id: String, api: APIClient) async {
        struct Deleted: Decodable { var deleted: Bool }
        let _: Deleted? = try? await api.send(api.request("/api/mobile/workouts/detail?id=\(id)", method: "DELETE"))
        details[id] = nil
        await load(api: api)
    }

    var exercises: [Exercise] { home?.exercises ?? [] }
    var routines: [Routine] { home?.routines ?? [] }
    var workouts: [WorkoutSummary] { home?.workouts ?? [] }

    func exercise(_ id: String) -> Exercise? { exercises.first { $0.id == id } }

    func saveRoutine(_ routine: Routine, api: APIClient) async throws {
        struct OK: Decodable {}
        let _: OK = try await api.post("/api/mobile/workouts/routines",
                                       body: RoutineUpload(id: routine.id, name: routine.name, position: routine.position, exercises: routine.exercises))
        await load(api: api)
    }

    func deleteRoutine(_ id: String, api: APIClient) async {
        struct Deleted: Decodable { var deleted: Bool }
        let _: Deleted? = try? await api.send(api.request("/api/mobile/workouts/routines?id=\(id)", method: "DELETE"))
        await load(api: api)
    }

    func createExercise(name: String, muscle: String, equipment: String, kind: String, api: APIClient) async throws -> Exercise {
        struct Body: Encodable { var name, muscle, equipment, kind: String }
        let exercise: Exercise = try await api.post("/api/mobile/workouts/exercises", body: Body(name: name, muscle: muscle, equipment: equipment, kind: kind))
        await load(api: api)
        return exercise
    }

    // MARK: Logging

    func start(_ routine: Routine? = nil, unit: WeightUnit) {
        var workout = ActiveWorkout(name: routine?.name ?? Self.defaultName(), routineId: routine?.id, unit: unit)
        for item in routine?.exercises ?? [] {
            var exercise = draft(for: item.exerciseId, name: item.name, unit: unit, count: 0)
            exercise.restSeconds = item.restSeconds
            exercise.superset = item.superset
            let previous = home?.previous[item.exerciseId] ?? []
            exercise.sets = item.sets.enumerated().map { i, target in
                var set = DraftSet(kind: SetKind(rawValue: target.kind) ?? .normal)
                hint(&set, previous: previous[safe: i], target: target, unit: unit, duration: exercise.isDuration)
                return set
            }
            if exercise.sets.isEmpty { addSet(to: &exercise, unit: unit) }
            workout.exercises.append(exercise)
        }
        active = workout
        requestNotifications()
    }

    /// "Morning workout", "Evening workout"...
    static func defaultName(_ date: Date = .now) -> String {
        switch Calendar.current.component(.hour, from: date) {
        case 4..<12: "Morning workout"
        case 12..<17: "Afternoon workout"
        case 17..<22: "Evening workout"
        default: "Night workout"
        }
    }

    func addExercises(_ picked: [Exercise]) {
        guard var workout = active else { return }
        for exercise in picked {
            workout.exercises.append(draft(for: exercise.id, name: exercise.name, unit: workout.unit, count: 3))
        }
        active = workout
    }

    private func draft(for exerciseId: String, name: String, unit: WeightUnit, count: Int) -> DraftExercise {
        var exercise = DraftExercise(exerciseId: exerciseId, name: name, isDuration: exercise(exerciseId)?.isDuration ?? false)
        for _ in 0..<count { addSet(to: &exercise, unit: unit) }
        return exercise
    }

    func addSet(exercise id: DraftExercise.ID) {
        guard var workout = active, let i = workout.exercises.firstIndex(where: { $0.id == id }) else { return }
        addSet(to: &workout.exercises[i], unit: workout.unit)
        active = workout
    }

    /// A new set, hinted with last time's set at the same position, else with the set above it.
    private func addSet(to exercise: inout DraftExercise, unit: WeightUnit) {
        var set = DraftSet()
        if let last = home?.previous[exercise.exerciseId]?[safe: exercise.sets.count] {
            set.kind = SetKind(rawValue: last.kind) ?? .normal
            hint(&set, previous: last, target: nil, unit: unit, duration: exercise.isDuration)
        } else if let above = exercise.sets.last {
            set.weightHint = above.weightText.isEmpty ? above.weightHint : above.weightText
            set.repsHint = above.repsText.isEmpty ? above.repsHint : above.repsText
        }
        exercise.sets.append(set)
    }

    private func hint(_ set: inout DraftSet, previous: WorkoutsHome.PreviousSet?, target: Routine.Target?, unit: WeightUnit, duration: Bool) {
        if duration {
            set.repsHint = (previous?.durationSeconds).map { String(Int($0)) } ?? ""
            return
        }
        let weight = target?.weightKg ?? previous?.weightKg
        let reps = target?.reps ?? previous?.reps
        set.weightHint = weight.map { unit.text($0) } ?? ""
        set.repsHint = reps.map(String.init) ?? ""
    }

    func update(_ exercise: DraftExercise.ID, _ set: DraftSet.ID, _ change: (inout DraftSet) -> Void) {
        guard var workout = active,
              let e = workout.exercises.firstIndex(where: { $0.id == exercise }),
              let s = workout.exercises[e].sets.firstIndex(where: { $0.id == set }) else { return }
        change(&workout.exercises[e].sets[s])
        active = workout
    }

    func updateExercise(_ id: DraftExercise.ID, _ change: (inout DraftExercise) -> Void) {
        guard var workout = active, let e = workout.exercises.firstIndex(where: { $0.id == id }) else { return }
        change(&workout.exercises[e])
        active = workout
    }

    func removeSet(_ exercise: DraftExercise.ID, _ set: DraftSet.ID) {
        updateExercise(exercise) { $0.sets.removeAll { $0.id == set } }
    }

    func removeExercise(_ id: DraftExercise.ID) {
        active?.exercises.removeAll { $0.id == id }
    }

    /// Checks a set off (filling empty fields from their hints) with the
    /// watch's current reading, and starts the rest timer; or unchecks it.
    func toggle(_ exercise: DraftExercise.ID, _ set: DraftSet.ID, liveHr: Int?) {
        guard let workout = active, let e = workout.exercises.first(where: { $0.id == exercise }) else { return }
        var startedRest = false
        update(exercise, set) { set in
            if set.completedAt != nil {
                set.completedAt = nil
                set.liveHr = nil
                set.isPR = false
                return
            }
            if set.weightText.isEmpty { set.weightText = set.weightHint }
            if set.repsText.isEmpty { set.repsText = set.repsHint }
            set.completedAt = .now
            set.liveHr = liveHr
            if set.kind != .warmup, !e.isDuration,
               let e1rm = WorkoutFormat.estimatedOneRepMax(kg: set.weight(workout.unit), reps: set.repCount) {
                let best = max(home?.bests[e.exerciseId]?.e1rmKg ?? 0, bestToday(e.exerciseId, excluding: set.id))
                set.isPR = best > 0 && e1rm > best + 0.01
            }
            startedRest = true
        }
        if startedRest {
            startRest(TimeInterval(e.restSeconds ?? Self.defaultRest))
            if let bpm = liveHr { record(bpm: bpm, at: .now) }
        }
    }

    /// The best estimated max already logged for this exercise in this workout.
    private func bestToday(_ exerciseId: String, excluding: DraftSet.ID) -> Double {
        guard let workout = active else { return 0 }
        return workout.exercises.filter { $0.exerciseId == exerciseId }.flatMap(\.sets)
            .filter { $0.id != excluding && $0.completedAt != nil && $0.kind != .warmup }
            .compactMap { WorkoutFormat.estimatedOneRepMax(kg: $0.weight(workout.unit), reps: $0.repCount) }
            .max() ?? 0
    }

    /// Keeps a live reading: every change, and at least every 5 s while steady.
    func record(bpm: Int, at date: Date) {
        guard var workout = active, workout.endedAt == nil else { return }
        let seconds = date.timeIntervalSince(workout.startedAt)
        guard seconds >= 0 else { return }
        if let last = workout.heartRate.last, last.count == 2 {
            if seconds - last[0] < 1 { return }
            if Int(last[1]) == bpm, seconds - last[0] < 5 { return }
        }
        workout.heartRate.append([seconds.rounded(), Double(bpm)])
        active = workout
    }

    // MARK: Rest timer

    func startRest(_ seconds: TimeInterval) {
        guard seconds > 0 else { return }
        restTotal = seconds
        restEndsAt = .now.addingTimeInterval(seconds)
        scheduleRestNotification()
    }

    func adjustRest(by seconds: TimeInterval) {
        guard let end = restEndsAt else { return }
        let next = end.addingTimeInterval(seconds)
        if next <= .now { skipRest(); return }
        restEndsAt = next
        restTotal = max(restTotal + seconds, next.timeIntervalSinceNow)
        scheduleRestNotification()
    }

    func skipRest() {
        restEndsAt = nil
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [Self.restNotification])
    }

    private static let restNotification = "workout.rest"

    private func requestNotifications() {
        Task { _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) }
    }

    /// So the end of a rest reaches the lock screen when the phone is pocketed.
    private func scheduleRestNotification() {
        guard let end = restEndsAt else { return }
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [Self.restNotification])
        let content = UNMutableNotificationContent()
        content.title = "Rest over"
        content.body = "Time for the next set."
        content.sound = .default
        content.interruptionLevel = .timeSensitive
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, end.timeIntervalSinceNow), repeats: false)
        center.add(UNNotificationRequest(identifier: Self.restNotification, content: content, trigger: trigger))
    }

    // MARK: Finish

    /// Ends the workout and sends it; it stays queued on the phone until the hub has it.
    func finish(api: APIClient) async {
        guard var workout = active else { return }
        workout.endedAt = .now
        skipRest()
        active = nil
        guard !workout.completedSets.isEmpty else { return }
        pending.append(workout)
        save(pending, to: Self.pendingURL)
        await load(api: api)
    }

    func discard() {
        skipRest()
        active = nil
    }

    private func upload(api: APIClient) async {
        guard !pending.isEmpty, !isUploading else { return }
        isUploading = true
        defer { isUploading = false }
        for workout in pending {
            do {
                let detail: WorkoutDetail = try await api.post("/api/mobile/workouts", body: WorkoutUpload(workout))
                details[detail.id] = detail
                pending.removeAll { $0.id == workout.id }
                save(pending, to: Self.pendingURL)
            } catch {
                self.error = "A finished workout is waiting to upload: \(error.localizedDescription)"
                return
            }
        }
    }

    // MARK: Disk

    private static var folder: URL {
        let url = URL.applicationSupportDirectory.appending(path: "Workouts", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    private static var activeURL: URL { folder.appending(path: "active.json") }
    private static var pendingURL: URL { folder.appending(path: "pending.json") }

    private static func read<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private func save<T: Encodable>(_ value: T?, to url: URL) {
        if let value, let data = try? JSONEncoder().encode(value) {
            try? data.write(to: url, options: .atomic)
        } else {
            try? FileManager.default.removeItem(at: url)
        }
    }
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
