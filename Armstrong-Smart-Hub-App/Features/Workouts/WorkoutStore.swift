import Foundation
import Observation
// For MutableCollection.move(fromOffsets:toOffset:).
import SwiftUI
import UserNotifications

/// The workout logger. The workout in progress is written to disk on every
/// change, so a crash or a gym with no signal never loses it; finished
/// workouts wait on the phone until the hub takes them.
@MainActor
@Observable
final class WorkoutStore {
    /// One store for the app: the Fitness tab, the mini card above the tab bar
    /// and the lock screen buttons all work on the same workout.
    static let shared = WorkoutStore()

    private(set) var home: WorkoutsHome?
    private(set) var error: String?
    private(set) var pending: [ActiveWorkout] = []
    private(set) var isUploading = false
    private var details: [String: WorkoutDetail] = [:]
    private var histories: [String: ExerciseHistory] = [:]

    var active: ActiveWorkout? {
        didSet {
            save(active, to: Self.activeURL)
            changed()
        }
    }

    /// Whether the full-screen workout is showing (closed, it's the mini card).
    var isPresented = false

    /// The workout just finished, so the app can ask how it felt.
    var justFinished: FinishedWorkout?

    /// From the watch's profile, kept so heart rate zones work from any tab.
    var maxHr: Int? = UserDefaults.standard.object(forKey: "workouts.maxHr") as? Int {
        didSet { UserDefaults.standard.set(maxHr, forKey: "workouts.maxHr") }
    }

    /// When the rest timer ends, and how long it was set for.
    private(set) var restEndsAt: Date? {
        didSet { changed() }
    }
    private(set) var restTotal: TimeInterval = 0

    static let defaultRest = 90

    /// A timed set counting down: which set, when it ends and how long it was.
    struct SetTimer: Equatable {
        var exercise: DraftExercise.ID
        var set: DraftSet.ID
        var endsAt: Date
        var total: TimeInterval
    }
    private(set) var setTimer: SetTimer?

    private init() {
        // Demo mode starts with no workout in progress, so every take matches.
        active = Demo.isOn ? nil : Self.read(ActiveWorkout.self, from: Self.activeURL)
        pending = Self.read([ActiveWorkout].self, from: Self.pendingURL) ?? []
    }

    /// Keeps the lock screen, Dynamic Island and home screen widget in step.
    private func changed() {
        #if os(iOS)
        WorkoutActivityController.shared.sync(self)
        #endif
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

    func cachedHistory(_ exerciseId: String) -> ExerciseHistory? { histories[exerciseId] }

    /// The exercise's past sessions from the hub, with today's checked sets first when it's in the workout being logged.
    func history(_ exerciseId: String, api: APIClient) async -> ExerciseHistory? {
        let path = "/api/mobile/workouts/exercises?id=\(exerciseId.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? exerciseId)"
        if let fetched: ExerciseHistory = try? await api.get(path) { histories[exerciseId] = fetched }
        return histories[exerciseId]
    }

    /// The checked sets of an exercise in the workout being logged, as a session.
    func inProgressSession(_ exerciseId: String) -> ExerciseHistory.Session? {
        guard let workout = active else { return nil }
        let sets = workout.exercises.filter { $0.exerciseId == exerciseId }.flatMap { exercise in
            exercise.sets.filter { $0.completedAt != nil }.map { set in
                WorkoutsHome.PreviousSet(kind: set.kind.rawValue,
                                         weightKg: exercise.isDuration ? nil : set.weight(workout.unit),
                                         reps: exercise.isDuration ? nil : set.repCount,
                                         durationSeconds: exercise.isDuration ? WorkoutFormat.number(set.repsText) : nil)
            }
        }
        guard !sets.isEmpty else { return nil }
        return ExerciseHistory.Session(workoutId: workout.id.uuidString, workoutName: workout.name,
                                       startedAt: ISO8601DateFormatter().string(from: workout.startedAt), sets: sets, inProgress: true)
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
            if previous.isEmpty {
                exercise.sets = item.sets.map { target in
                    var set = DraftSet(kind: SetKind(rawValue: target.kind) ?? .normal)
                    hint(&set, previous: nil, target: target, unit: unit, duration: exercise.isDuration)
                    return set
                }
            } else {
                // As many sets, at the same weights and reps, as the last time this exercise was done.
                exercise.sets = previous.map { last in
                    var set = DraftSet(kind: SetKind(rawValue: last.kind) ?? .normal)
                    hint(&set, previous: last, target: nil, unit: unit, duration: exercise.isDuration)
                    return set
                }
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
            workout.exercises.append(draft(for: exercise.id, name: exercise.name, unit: workout.unit, count: max(home?.previous[exercise.id]?.count ?? 3, 1)))
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
            // A routine keeps a timed set's target seconds in `reps`.
            set.repsHint = (target?.reps.map(String.init) ?? (previous?.durationSeconds).map { String(Int($0)) }) ?? ""
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
        if setTimer?.set == set { setTimer = nil }
        updateExercise(exercise) { $0.sets.removeAll { $0.id == set } }
    }

    func moveExercises(from source: IndexSet, to destination: Int) {
        active?.exercises.move(fromOffsets: source, toOffset: destination)
    }

    /// Swaps an exercise for another, keeping its number of sets, their types and the rest time.
    func replaceExercise(_ id: DraftExercise.ID, with picked: Exercise) {
        guard var workout = active, let e = workout.exercises.firstIndex(where: { $0.id == id }) else { return }
        if setTimer?.exercise == id { setTimer = nil }
        let old = workout.exercises[e]
        var exercise = DraftExercise(id: old.id, exerciseId: picked.id, name: picked.name, isDuration: picked.isDuration)
        exercise.restSeconds = old.restSeconds
        exercise.superset = old.superset
        let previous = home?.previous[picked.id] ?? []
        exercise.sets = previous.isEmpty
            ? old.sets.map { DraftSet(kind: $0.kind) }
            : previous.map { last in
                var set = DraftSet(kind: SetKind(rawValue: last.kind) ?? .normal)
                hint(&set, previous: last, target: nil, unit: workout.unit, duration: picked.isDuration)
                return set
            }
        if exercise.sets.isEmpty { addSet(to: &exercise, unit: workout.unit) }
        workout.exercises[e] = exercise
        active = workout
    }

    func removeExercise(_ id: DraftExercise.ID) {
        if setTimer?.exercise == id { setTimer = nil }
        active?.exercises.removeAll { $0.id == id }
    }

    /// Switches the workout's unit, converting every typed and hinted weight.
    func setUnit(_ unit: WeightUnit) {
        guard var workout = active, workout.unit != unit else { return }
        let old = workout.unit
        func convert(_ text: String) -> String {
            WorkoutFormat.number(text).map { unit.text(old.toKg($0)) } ?? text
        }
        for e in workout.exercises.indices where !workout.exercises[e].isDuration {
            for s in workout.exercises[e].sets.indices {
                workout.exercises[e].sets[s].weightText = convert(workout.exercises[e].sets[s].weightText)
                workout.exercises[e].sets[s].weightHint = convert(workout.exercises[e].sets[s].weightHint)
            }
        }
        workout.unit = unit
        active = workout
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
        if setTimer?.set == set { setTimer = nil }
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

    // MARK: Timed sets

    /// Counts a timed set down from what's typed (else its hint, else a minute); tapping again stops it.
    func toggleSetTimer(_ exercise: DraftExercise.ID, _ set: DraftSet.ID) {
        if setTimer?.set == set { setTimer = nil; return }
        guard let entry = active?.exercises.first(where: { $0.id == exercise })?.sets.first(where: { $0.id == set }) else { return }
        let seconds = WorkoutFormat.number(entry.repsText) ?? WorkoutFormat.number(entry.repsHint) ?? 60
        guard seconds > 0 else { return }
        skipRest()
        setTimer = SetTimer(exercise: exercise, set: set, endsAt: .now.addingTimeInterval(seconds), total: seconds)
    }

    /// The timed set ran out: it's logged at full length and checked off.
    func finishSetTimer(liveHr: Int?) {
        guard let timer = setTimer else { return }
        setTimer = nil
        update(timer.exercise, timer.set) { $0.repsText = String(Int(timer.total.rounded())) }
        toggle(timer.exercise, timer.set, liveHr: liveHr)
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
        // The film never asks for notifications.
        guard !Demo.isOn else { return }
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
        setTimer = nil
        active = nil
        guard !workout.completedSets.isEmpty else { return }
        rememberNotes(workout)
        pending.append(workout)
        save(pending, to: Self.pendingURL)
        await load(api: api)
        justFinished = FinishedWorkout(id: workout.id.uuidString.lowercased(), name: workout.name)
    }

    // MARK: Exercise notes

    private static let notesKey = "workouts.lastNotes"

    /// The note left on an exercise the last time it was logged, shown the next time.
    func lastNote(_ exerciseId: String) -> String? {
        (UserDefaults.standard.dictionary(forKey: Self.notesKey) as? [String: String])?[exerciseId]
    }

    private func rememberNotes(_ workout: ActiveWorkout) {
        var all = (UserDefaults.standard.dictionary(forKey: Self.notesKey) as? [String: String]) ?? [:]
        for exercise in workout.exercises where exercise.sets.contains(where: { $0.completedAt != nil }) {
            let note = exercise.notes?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            all[exercise.exerciseId] = note.isEmpty ? nil : note
        }
        UserDefaults.standard.set(all, forKey: Self.notesKey)
    }

    func discard() {
        skipRest()
        setTimer = nil
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

/// A workout that just ended, for the "how did it feel?" sheet.
struct FinishedWorkout: Identifiable {
    var id: String
    var name: String
}
