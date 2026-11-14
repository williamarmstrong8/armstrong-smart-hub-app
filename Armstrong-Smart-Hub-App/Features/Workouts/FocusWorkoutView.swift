import SwiftUI

/// The simple view of a workout in progress: one exercise blown up to fill the
/// screen, with the set you're on in big type and a big check. The middle swaps
/// between the set, the rest countdown, a running timed set, what's up next
/// once an exercise is done, and Add Exercise / End Workout when nothing's left.
struct FocusWorkoutView: View {
    var store: WorkoutStore
    var workout: ActiveWorkout
    var liveBpm: Int?
    var onAddExercise: () -> Void
    var onFinish: () -> Void

    /// The exercise on screen; nil follows the first one with sets left.
    @State private var shownId: DraftExercise.ID?

    private var exercises: [DraftExercise] { workout.exercises }

    private var shown: DraftExercise? {
        if let shownId, let pinned = exercises.first(where: { $0.id == shownId }) { return pinned }
        return exercises.first(where: { $0.sets.contains { $0.completedAt == nil } }) ?? exercises.last
    }

    private var shownIndex: Int? { shown.flatMap { s in exercises.firstIndex { $0.id == s.id } } }

    /// The next exercise after the one on screen that still has sets to do, else any before it.
    private var nextUp: DraftExercise? {
        guard let i = shownIndex else { return nil }
        let pending = { (e: DraftExercise) in e.sets.contains { $0.completedAt == nil } }
        return exercises[(i + 1)...].first(where: pending) ?? exercises[..<i].first(where: pending)
    }

    var body: some View {
        VStack(spacing: 0) {
            if let exercise = shown {
                header(exercise)
                Spacer(minLength: 12)
                Group {
                    if store.restEndsAt != nil {
                        RestPanel(store: store, upNext: upNextText(after: exercise))
                    } else if let set = exercise.sets.first(where: { $0.completedAt == nil }) {
                        SetPanel(store: store, exercise: exercise, entry: set, workout: workout, liveBpm: liveBpm,
                                 position: setPosition(set, in: exercise), onChecked: { checked(exercise) })
                    } else if let next = nextUp {
                        NextUpPanel(store: store, finished: exercise, next: next) {
                            withAnimation(.snappy) { shownId = next.id }
                        }
                    } else {
                        AllDonePanel(onAddExercise: onAddExercise, onFinish: onFinish)
                    }
                }
                .transition(.blurReplace)
                Spacer(minLength: 12)
                SetDots(store: store, exercise: exercise)
                    .padding(.bottom, 12)
            } else {
                Spacer()
                AllDonePanel(onAddExercise: onAddExercise, onFinish: onFinish, empty: true)
                Spacer()
            }
        }
        .padding(.horizontal, 20)
        .animation(.snappy, value: store.restEndsAt != nil)
        .animation(.snappy, value: shown?.id)
        .animation(.snappy, value: shown?.sets.filter { $0.completedAt != nil }.count)
    }

    /// Exercise name and picture, with arrows to step through the others.
    private func header(_ exercise: DraftExercise) -> some View {
        VStack(spacing: 14) {
            HStack {
                stepButton("chevron.left", to: shownIndex.flatMap { $0 > 0 ? exercises[$0 - 1] : nil })
                Spacer()
                if let i = shownIndex {
                    Text("Exercise \(i + 1) of \(exercises.count)")
                        .font(.subheadline.weight(.medium)).foregroundStyle(BrickLook.soft).monospacedDigit()
                }
                Spacer()
                stepButton("chevron.right", to: shownIndex.flatMap { $0 + 1 < exercises.count ? exercises[$0 + 1] : nil })
            }
            ExerciseThumb(exerciseId: exercise.exerciseId, muscle: store.exercise(exercise.exerciseId)?.muscle, size: 132)
            Text(exercise.name)
                .font(.system(size: 30, weight: .semibold))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.7)
        }
        .padding(.top, 8)
    }

    private func stepButton(_ symbol: String, to target: DraftExercise?) -> some View {
        Button {
            guard let target else { return }
            ActiveWorkoutView.hideKeyboard()
            withAnimation(.snappy) { shownId = target.id }
        } label: {
            Image(systemName: symbol).font(.title3.weight(.semibold))
                .frame(width: 48, height: 48)
                .glassEffect(.regular, in: .circle)
        }
        .buttonStyle(.plain)
        .opacity(target == nil ? 0.3 : 1)
        .disabled(target == nil)
    }

    /// Once an exercise's last set is checked, keep it on screen so "up next" shows.
    private func checked(_ exercise: DraftExercise) {
        guard let now = store.active?.exercises.first(where: { $0.id == exercise.id }) else { return }
        if !now.sets.contains(where: { $0.completedAt == nil }) { shownId = exercise.id }
    }

    private func setPosition(_ set: DraftSet, in exercise: DraftExercise) -> String {
        guard let i = exercise.sets.firstIndex(where: { $0.id == set.id }) else { return "" }
        if set.kind == .warmup { return "Warm-up set" }
        let working = exercise.sets.filter { $0.kind != .warmup }
        let n = exercise.sets[..<i].filter { $0.kind != .warmup }.count + 1
        return "Set \(n) of \(working.count)"
    }

    private func upNextText(after exercise: DraftExercise) -> String? {
        let current = store.active?.exercises.first(where: { $0.id == exercise.id }) ?? exercise
        if let set = current.sets.first(where: { $0.completedAt == nil }) {
            return "\(setPosition(set, in: current)) · \(SetPanel.summary(set, isDuration: current.isDuration, unit: workout.unit))"
        }
        return nextUp?.name ?? "Nothing left — end when you're ready"
    }
}

// MARK: Set

/// The set you're on: weight and reps (or time) big enough to read across the
/// gym, last time's numbers, and a big check.
private struct SetPanel: View {
    var store: WorkoutStore
    var exercise: DraftExercise
    var entry: DraftSet
    var workout: ActiveWorkout
    var liveBpm: Int?
    var position: String
    var onChecked: () -> Void

    private var timing: WorkoutStore.SetTimer? { store.setTimer?.set == entry.id ? store.setTimer : nil }

    static func summary(_ set: DraftSet, isDuration: Bool, unit: WeightUnit) -> String {
        let reps = set.repsText.isEmpty ? set.repsHint : set.repsText
        if isDuration { return reps.isEmpty ? "Timed" : WorkoutFormat.timer(reps) }
        let weight = set.weightText.isEmpty ? set.weightHint : set.weightText
        switch (weight.isEmpty, reps.isEmpty) {
        case (false, false): return "\(weight) \(unit.rawValue) × \(reps)"
        case (true, false): return "\(reps) reps"
        case (false, true): return "\(weight) \(unit.rawValue)"
        default: return "Log it"
        }
    }

    var body: some View {
        VStack(spacing: 22) {
            Text(position.uppercased())
                .font(.system(size: 14, weight: .semibold)).tracking(1.2)
                .foregroundStyle(BrickLook.soft)

            if exercise.isDuration {
                timeBlock
            } else {
                HStack(spacing: 14) {
                    field(weightText, hint: entry.weightHint, label: workout.unit == .lb ? "LBS" : "KG", decimal: true)
                    Text("×").font(.system(size: 34, weight: .light)).foregroundStyle(BrickLook.soft)
                    field(repsText, hint: entry.repsHint, label: "REPS", decimal: false)
                }
            }

            checkButton
        }
    }

    private var weightText: Binding<String> {
        Binding(get: { entry.weightText }, set: { value in store.update(exercise.id, entry.id) { $0.weightText = value } })
    }

    private var repsText: Binding<String> {
        Binding(get: { entry.repsText }, set: { value in store.update(exercise.id, entry.id) { $0.repsText = value } })
    }

    private func field(_ text: Binding<String>, hint: String, label: String, decimal: Bool) -> some View {
        VStack(spacing: 6) {
            TextField(hint.isEmpty ? "-" : hint, text: text)
                .keyboardType(decimal ? .decimalPad : .numberPad)
                .multilineTextAlignment(.center)
                .font(.system(size: 52, weight: .semibold)).monospacedDigit()
                .minimumScaleFactor(0.5)
                .frame(maxWidth: .infinity)
                .frame(height: 84)
                .glassEffect(.regular, in: .rect(cornerRadius: 20))
            Text(label).font(.system(size: 13, weight: .semibold)).tracking(1.0).foregroundStyle(BrickLook.soft)
        }
    }

    /// A timed set: the time big, with a play button that counts it down.
    private var timeBlock: some View {
        VStack(spacing: 14) {
            Group {
                if let timing {
                    TimelineView(.periodic(from: .now, by: 0.25)) { context in
                        let left = max(0, timing.endsAt.timeIntervalSince(context.date)).rounded(.up)
                        Text(WorkoutFormat.timer(String(Int(left))))
                            .foregroundStyle(BrickLook.bar)
                    }
                } else {
                    TextField(entry.repsHint.isEmpty ? "00:00" : WorkoutFormat.timer(entry.repsHint), text: Binding(
                        get: { WorkoutFormat.timer(entry.repsText) },
                        set: { value in store.update(exercise.id, entry.id) { $0.repsText = WorkoutFormat.seconds(fromTyped: value) } }))
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.center)
                }
            }
            .font(.system(size: 64, weight: .semibold)).monospacedDigit()
            .frame(maxWidth: .infinity)
            .frame(height: 96)
            .glassEffect(.regular, in: .rect(cornerRadius: 20))

            Button {
                ActiveWorkoutView.hideKeyboard()
                store.toggleSetTimer(exercise.id, entry.id)
            } label: {
                Label(timing == nil ? "Start timer" : "Stop timer", systemImage: timing == nil ? "play.fill" : "stop.fill")
                    .font(.body.weight(.semibold))
                    .padding(.horizontal, 22)
                    .frame(height: 46)
                    .glassEffect(.regular, in: .capsule)
            }
            .buttonStyle(.plain)
        }
    }

    private var checkButton: some View {
        Button {
            UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
            ActiveWorkoutView.hideKeyboard()
            store.toggle(exercise.id, entry.id, liveHr: liveBpm)
            onChecked()
        } label: {
            Image(systemName: "checkmark")
                .font(.system(size: 54, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 128, height: 128)
                .background(BrickLook.live, in: .circle)
                .shadow(color: BrickLook.live.opacity(0.35), radius: 16, y: 6)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Check off set")
    }
}

// MARK: Rest

/// The rest countdown filling the middle, with ±15 s, skip, and what's next.
private struct RestPanel: View {
    var store: WorkoutStore
    var upNext: String?

    var body: some View {
        VStack(spacing: 22) {
            Text("REST").font(.system(size: 14, weight: .semibold)).tracking(1.2).foregroundStyle(BrickLook.soft)
            if let end = store.restEndsAt {
                TimelineView(.periodic(from: .now, by: 0.25)) { context in
                    let left = max(0, end.timeIntervalSince(context.date))
                    let fraction = store.restTotal > 0 ? min(1, left / store.restTotal) : 0
                    ZStack {
                        Circle().stroke(BrickLook.line, lineWidth: 10)
                        Circle().trim(from: 0, to: fraction)
                            .stroke(BrickLook.live, style: StrokeStyle(lineWidth: 10, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                        Text(WorkoutFormat.timer(String(Int(left.rounded(.up)))))
                            .font(.system(size: 60, weight: .semibold)).monospacedDigit()
                    }
                    .frame(width: 220, height: 220)
                }
            }
            HStack(spacing: 12) {
                pill("−15s") { store.adjustRest(by: -15) }
                pill("Skip") { store.skipRest() }
                pill("+15s") { store.adjustRest(by: 15) }
            }
            if let upNext {
                VStack(spacing: 4) {
                    Text("UP NEXT").font(.system(size: 12, weight: .semibold)).tracking(1.0).foregroundStyle(BrickLook.soft)
                    Text(upNext).font(.title3.weight(.medium)).multilineTextAlignment(.center)
                }
            }
        }
    }

    private func pill(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.body.weight(.semibold)).monospacedDigit()
                .frame(width: 84, height: 48)
                .glassEffect(.regular, in: .capsule)
        }
        .buttonStyle(.plain)
    }
}

// MARK: Next up

/// After an exercise's last set: the next one, ready to start.
private struct NextUpPanel: View {
    var store: WorkoutStore
    var finished: DraftExercise
    var next: DraftExercise
    var onStart: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Label("\(finished.name) done", systemImage: "checkmark.circle.fill")
                .font(.headline).foregroundStyle(BrickLook.live)
            VStack(spacing: 12) {
                Text("UP NEXT").font(.system(size: 12, weight: .semibold)).tracking(1.0).foregroundStyle(BrickLook.soft)
                ExerciseThumb(exerciseId: next.exerciseId, muscle: store.exercise(next.exerciseId)?.muscle, size: 72)
                Text(next.name).font(.system(size: 24, weight: .semibold)).multilineTextAlignment(.center)
                Text("\(next.sets.filter { $0.completedAt == nil }.count) sets to go")
                    .font(.subheadline).foregroundStyle(BrickLook.soft)
            }
            .padding(20)
            .frame(maxWidth: .infinity)
            .glassEffect(.regular, in: .rect(cornerRadius: 24))
            Button(action: onStart) {
                Label("Start \(next.name)", systemImage: "arrow.right").blueButton().lineLimit(1)
            }
            .buttonStyle(.plain)
        }
    }
}

/// Nothing left to do: add another exercise or end the workout.
private struct AllDonePanel: View {
    var onAddExercise: () -> Void
    var onFinish: () -> Void
    var empty = false

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: empty ? "dumbbell" : "flag.checkered")
                .font(.system(size: 44, weight: .light)).foregroundStyle(BrickLook.soft)
            Text(empty ? "Get started" : "All exercises done")
                .font(.system(size: 28, weight: .semibold))
            if !empty {
                Text("Add another exercise or wrap it up.").font(.subheadline).foregroundStyle(BrickLook.soft)
            }
            VStack(spacing: 12) {
                Button(action: onAddExercise) { Label("Add Exercise", systemImage: "plus").blueButton() }
                    .buttonStyle(.plain)
                if !empty {
                    Button(action: onFinish) { Text("End Workout").greyButton(BrickLook.ink) }
                        .buttonStyle(.plain)
                }
            }
            .padding(.top, 8)
        }
    }
}

// MARK: Sets row

/// The exercise's sets as a row of dots; a checked one can be tapped to uncheck it.
private struct SetDots: View {
    var store: WorkoutStore
    var exercise: DraftExercise

    var body: some View {
        HStack(spacing: 10) {
            ForEach(Array(exercise.sets.enumerated()), id: \.element.id) { index, set in
                let done = set.completedAt != nil
                let current = !done && exercise.sets.firstIndex(where: { $0.completedAt == nil }) == index
                Button {
                    guard done else { return }
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    store.toggle(exercise.id, set.id, liveHr: nil)
                } label: {
                    ZStack {
                        Circle().fill(done ? BrickLook.live : Color.clear)
                        Circle().stroke(done ? BrickLook.live : current ? BrickLook.ink : BrickLook.line, lineWidth: 2)
                        if done {
                            Image(systemName: "checkmark").font(.system(size: 13, weight: .bold)).foregroundStyle(.white)
                        } else {
                            Text(set.kind == .warmup ? "W" : "\(exercise.sets[..<index].filter { $0.kind != .warmup }.count + 1)")
                                .font(.caption.weight(.semibold)).monospacedDigit()
                                .foregroundStyle(current ? BrickLook.ink : BrickLook.soft)
                        }
                    }
                    .frame(width: 34, height: 34)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(done ? "Uncheck set \(index + 1)" : "Set \(index + 1)")
            }
            Button { store.addSet(exercise: exercise.id) } label: {
                Image(systemName: "plus").font(.system(size: 13, weight: .bold))
                    .frame(width: 34, height: 34)
                    .glassEffect(.regular, in: .circle)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Add set")
        }
    }
}
