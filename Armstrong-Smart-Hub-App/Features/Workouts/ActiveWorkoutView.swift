import SwiftUI

/// The workout in progress, laid out like Hevy's: big duration, volume, sets
/// and live heart rate with its zone up top, then one block per exercise
/// (picture, rest timer, note, a set grid of previous, weight, reps and check)
/// and a rest timer panel after every checked set. Each check stamps the set
/// with the time and the watch's reading, which the hub maps the full
/// heart-rate curve onto.
struct ActiveWorkoutView: View {
    @Environment(AppSession.self) private var session
    @Environment(WatchLink.self) private var watch
    @Environment(\.dismiss) private var dismiss
    @AppStorage("workouts.unit") private var defaultUnit: WeightUnit = .localDefault
    var store: WorkoutStore
    /// From the watch's profile, for zones; the session's peak stands in without it.
    var maxHr: Int?
    @State private var path = NavigationPath()
    @State private var picking = false
    @State private var confirmDiscard = false
    @State private var confirmEmpty = false
    @State private var showingSettings = false
    @State private var openNotes: Set<DraftExercise.ID> = []
    /// Exercises collapsed to one row each, to drag into a new order.
    @State private var reordering = false
    @State private var replacing: Replacing?

    /// The watch's reading, if it's recent enough to trust.
    private var liveBpm: Int? {
        guard let at = watch.heartRateAt, Date.now.timeIntervalSince(at) < 15 else { return nil }
        return watch.heartRate?.bpm
    }

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if let workout = store.active {
                    list(workout)
                } else {
                    Color.clear.onAppear { dismiss() }
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar { toolbar }
            .navigationDestination(for: ExerciseRoute.self) { ExerciseDetailPage(route: $0, store: store) }
            .navigationDestination(for: WorkoutRoute.self) { WorkoutDetailPage(id: $0.id, store: store) }
        }
        // Over every page of the stack: the rest timer's line around the screen.
        .overlay {
            RestStroke(store: store)
                .hubAnimation(value: store.restEndsAt != nil)
        }
        // While the workout is open, keep the heart rate coming: reconnect, or reopen a stream that went quiet.
        .task {
            while !Task.isCancelled {
                watch.keepHeartRateFlowing()
                try? await Task.sleep(for: .seconds(10))
            }
        }
        .sheet(isPresented: $picking, onDismiss: Self.hideKeyboard) {
            ExercisePicker(store: store) { store.addExercises($0) }
        }
        .sheet(item: $replacing) { target in
            ExercisePicker(store: store, replacing: true) { picked in
                if let exercise = picked.first { store.replaceExercise(target.id, with: exercise) }
            }
        }
        .presentationBackground { AmbientBackdrop() }
        .foregroundStyle(BrickLook.ink)
        .tint(HubDesign.action)
        .sheet(isPresented: $showingSettings) {
            WorkoutSettingsSheet(store: store, defaultUnit: $defaultUnit)
        }
        .alert("No sets checked off", isPresented: $confirmEmpty) {
            Button("Discard workout", role: .destructive) { store.discard(); dismiss() }
            Button("Keep logging", role: .cancel) {}
        } message: {
            Text("Check off at least one set to save this workout.")
        }
        .confirmationDialog("Discard this workout?", isPresented: $confirmDiscard, titleVisibility: .visible) {
            Button("Discard workout", role: .destructive) { store.discard(); dismiss() }
        }
        .task(id: store.restEndsAt) {
            guard let end = store.restEndsAt else { return }
            try? await Task.sleep(for: .seconds(max(0, end.timeIntervalSinceNow)))
            guard !Task.isCancelled, store.restEndsAt == end else { return }
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            store.skipRest()
        }
        .task(id: store.setTimer) {
            guard let timer = store.setTimer else { return }
            try? await Task.sleep(for: .seconds(max(0, timer.endsAt.timeIntervalSinceNow)))
            guard !Task.isCancelled, store.setTimer == timer else { return }
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            store.finishSetTimer(liveHr: liveBpm)
        }
        .onAppear {
            watch.ensureConnected()
        }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button { dismiss() } label: { Image(systemName: "chevron.down") }.accessibilityLabel("Minimize")
        }
        ToolbarItem(placement: .principal) {
            Text(store.active?.name ?? "Workout").font(.system(size: 20, weight: .regular)).lineLimit(1)
        }
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                if store.restEndsAt != nil {
                    Button("Skip rest", systemImage: "forward.end") { store.skipRest() }
                }
                Section("Start a rest timer") {
                    ForEach([30, 60, 90, 120, 180, 300], id: \.self) { seconds in
                        Button(WorkoutFormat.rest(seconds)) { store.startRest(TimeInterval(seconds)) }
                    }
                }
            } label: {
                Image(systemName: "timer")
            }
            .accessibilityLabel("Rest timer")
        }
        ToolbarItem(placement: .confirmationAction) {
            if reordering {
                Button { withAnimation(.snappy) { reordering = false } } label: { WorkoutToolbarLabel(title: "Done") }
            } else {
                Button {
                    if store.active?.completedSets.isEmpty ?? true { confirmEmpty = true } else { finish() }
                } label: { WorkoutToolbarLabel(title: "Finish") }
            }
        }
    }

    static func hideKeyboard() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }

    private func finish() {
        Task { await store.finish(api: session.api) }
        dismiss()
    }

    private func startReordering() {
        Self.hideKeyboard()
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        withAnimation(.snappy) { reordering = true }
    }

    private func list(_ workout: ActiveWorkout) -> some View {
        Group {
            if reordering { reorderList(workout) } else { fullList(workout) }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            RepsProgress(done: workout.repProgress.done, total: workout.repProgress.total)
        }
    }

    /// One row per exercise, held and dragged into a new order.
    private func reorderList(_ workout: ActiveWorkout) -> some View {
        List {
            Text("Hold and drag to reorder").font(.footnote).foregroundStyle(BrickLook.soft)
                .workoutRow(top: 12, bottom: 4)
                .moveDisabled(true)
            ForEach(workout.exercises) { exercise in
                ReorderRow(exerciseId: exercise.exerciseId, name: exercise.name, muscle: store.exercise(exercise.exerciseId)?.muscle)
                    .listRowBackground(Color.clear)
                    .deleteDisabled(true)
            }
            .onMove { store.moveExercises(from: $0, to: $1) }
        }
        .listStyle(.plain)
        .hubListStyle()
        .environment(\.editMode, .constant(.active))
    }

    private func fullList(_ workout: ActiveWorkout) -> some View {
        List {
            BrickCard {
                WorkoutStats(workout: workout, liveBpm: liveBpm, maxHr: maxHr, status: watch.heartRateStatus)
            }
            .workoutRow(top: 8, bottom: 16)

            if workout.exercises.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "dumbbell").font(.system(size: 34, weight: .light)).foregroundStyle(BrickLook.soft)
                    Text("Get started").font(.system(size: 26, weight: .regular))
                    Text("Add an exercise to start your workout").font(.subheadline).foregroundStyle(BrickLook.soft)
                }
                .frame(maxWidth: .infinity)
                .workoutRow(top: 24, bottom: 24)
            }

            ForEach(workout.exercises) { exercise in
                exerciseBlock(exercise, workout: workout)
            }

            Button { picking = true } label: {
                Label("Add Exercise", systemImage: "plus").blueButton()
            }
            .buttonStyle(.borderless)
            .workoutRow(top: 20, bottom: 6)

            HStack(spacing: 12) {
                Button { showingSettings = true } label: {
                    Text("Settings").greyButton(BrickLook.ink)
                }
                .buttonStyle(.borderless)
                Button { confirmDiscard = true } label: {
                    Text("Discard Workout").greyButton(Fit.attention)
                }
                .buttonStyle(.borderless)
            }
            .workoutRow(top: 6, bottom: 24)
        }
        .listStyle(.plain)
        .hubListStyle()
        .scrollDismissesKeyboard(.immediately)
    }

    @ViewBuilder
    private func exerciseBlock(_ exercise: DraftExercise, workout: ActiveWorkout) -> some View {
        ExerciseHeader(store: store, exercise: exercise, isLast: exercise.id == workout.exercises.last?.id,
                       onOpen: { path.append(ExerciseRoute(id: exercise.exerciseId, name: exercise.name, store: store)) },
                       onReplace: { Self.hideKeyboard(); replacing = Replacing(id: exercise.id) },
                       onReorder: startReordering)
        .workoutRow(top: 18, bottom: 4)

        ExerciseOptions(store: store, exercise: exercise, noteOpen: Binding(
            get: { openNotes.contains(exercise.id) || !(exercise.notes ?? "").isEmpty || store.lastNote(exercise.exerciseId) != nil },
            set: { open in if open { openNotes.insert(exercise.id) } else { openNotes.remove(exercise.id) } }))
            .workoutRow(top: 4, bottom: 8)

        ExerciseSetsHeader(isDuration: exercise.isDuration, unit: workout.unit)
            .workoutRow(top: 4, bottom: 2)

        ForEach(Array(exercise.sets.enumerated()), id: \.element.id) { index, set in
            SetRow(store: store, exercise: exercise, entry: set, number: number(of: index, in: exercise.sets),
                   previous: previous(exercise, index), unit: workout.unit, liveBpm: liveBpm)
                .swipeActions { Button("Delete", role: .destructive) { store.removeSet(exercise.id, set.id) } }
                .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                .listRowSeparator(.hidden)
                .listRowBackground(set.completedAt != nil ? BrickLook.live.opacity(0.22) : Color.clear)
        }

        Button { store.addSet(exercise: exercise.id) } label: {
            Label("Add Set", systemImage: "plus").greyButton(BrickLook.ink)
        }
        .buttonStyle(.borderless)
        .workoutRow(top: 10, bottom: 8)
    }

    /// Warm-ups get "W"; working sets are numbered without them.
    private func number(of index: Int, in sets: [DraftSet]) -> String {
        if let badge = sets[index].kind.badge { return badge }
        return "\(sets[..<index].filter { $0.kind != .warmup }.count + 1)"
    }

    private func previous(_ exercise: DraftExercise, _ index: Int) -> String {
        guard let last = store.home?.previous[exercise.exerciseId]?[safe: index] else { return "-" }
        if exercise.isDuration { return last.durationSeconds.map { WorkoutFormat.timer(String(Int($0))) } ?? "-" }
        let unit = store.active?.unit ?? .kg
        switch (last.weightKg, last.reps) {
        case let (w?, r?) where w > 0: return "\(unit.text(w)) \(unit.rawValue) × \(r)"
        case let (_, r?): return "\(r) reps"
        default: return "-"
        }
    }
}

extension View {
    /// A full-width row of a workout list: no separator, no highlight.
    func workoutRow(top: CGFloat, bottom: CGFloat) -> some View {
        listRowInsets(EdgeInsets(top: top, leading: 16, bottom: bottom, trailing: 16))
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
    }
}

extension Text {
    /// A full-width grey button label, like Hevy's Add Set.
    func greyButton(_ tint: Color) -> some View {
        font(.body.weight(.medium))
            .foregroundStyle(tint)
            .frame(maxWidth: .infinity)
            .frame(height: 46)
            .modifier(GreyFill())
    }
}

extension Label where Title == Text, Icon == Image {
    func greyButton(_ tint: Color) -> some View {
        font(.body.weight(.medium))
            .foregroundStyle(tint)
            .frame(maxWidth: .infinity)
            .frame(height: 46)
            .modifier(GreyFill())
    }
}

// MARK: Stats

/// Duration, volume and sets in big numbers, then live heart rate with its
/// zone and how long the workout has spent in each one.
private struct WorkoutStats: View {
    var workout: ActiveWorkout
    var liveBpm: Int?
    var maxHr: Int?
    var status: String

    private var peak: Double {
        Double(maxHr ?? Int(workout.heartRate.compactMap { $0.count == 2 ? $0[1] : nil }.max() ?? 190))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 12) {
                TimelineView(.periodic(from: workout.startedAt, by: 1)) { context in
                    stat("Duration", WorkoutFormat.elapsed(context.date.timeIntervalSince(workout.startedAt)), tint: BrickLook.bar)
                }
                stat("Volume", WorkoutFormat.volume(workout.volumeKg, unit: workout.unit))
            }
            Rectangle().fill(BrickLook.line).frame(height: 1)
            heart
            zones
        }
    }

    private func stat(_ label: String, _ value: String, tint: Color = .primary) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.footnote).foregroundStyle(BrickLook.soft)
            Text(value).font(.system(size: 26, weight: .semibold)).monospacedDigit()
                .foregroundStyle(tint).lineLimit(1).minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The live reading, else the workout's last one if it's under a minute old,
    /// so the zone stays lit through a dropped reading.
    private var zoneBpm: Double? {
        if let liveBpm { return Double(liveBpm) }
        guard let last = workout.heartRate.last, last.count == 2,
              Date.now.timeIntervalSince(workout.startedAt.addingTimeInterval(last[0])) < 60 else { return nil }
        return last[1]
    }

    private var currentZone: Int? { zoneBpm.flatMap { HeartZones.zone($0, max: peak) } }

    private var heart: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 4) {
                BrickCaps(text: "Heart rate").foregroundStyle(BrickLook.soft)
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "heart.fill")
                        .font(.title2)
                        .foregroundStyle(Fit.heart)
                        .symbolEffect(.pulse, isActive: liveBpm != nil)
                    if let bpm = liveBpm {
                        Text("\(bpm)").font(.system(size: 44, weight: .light)).monospacedDigit()
                            .contentTransition(.numericText(value: Double(bpm)))
                            .animation(.snappy, value: bpm)
                        Text("bpm").font(.subheadline).foregroundStyle(BrickLook.soft)
                    } else {
                        Text(status).font(.title3).foregroundStyle(BrickLook.soft)
                    }
                }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 4) {
                if let zone = currentZone, let bpm = zoneBpm {
                    Text("Zone \(zone + 1)").font(.title3.weight(.bold)).foregroundStyle(HeartZones.colors[zone])
                    Text("\(HeartZones.names[zone]) · \(Int((bpm / peak * 100).rounded()))% max")
                        .font(.caption).foregroundStyle(BrickLook.soft)
                }
                if let summary = summary {
                    Text(summary).font(.caption).foregroundStyle(BrickLook.soft).monospacedDigit()
                }
            }
        }
    }

    /// "Avg 128 · Max 161" from the readings so far.
    private var summary: String? {
        let bpm = workout.heartRate.compactMap { $0.count == 2 ? $0[1] : nil }
        guard !bpm.isEmpty, let max = bpm.max() else { return nil }
        return "Avg \(Int((bpm.reduce(0, +) / Double(bpm.count)).rounded())) · Max \(Int(max))"
    }

    /// Five zones; the one your heart rate is in now is boxed, lit and marked.
    private var zones: some View {
        let time = HeartZones.time(workout.heartRate, max: peak)
        return HStack(spacing: 6) {
            ForEach(0..<5, id: \.self) { zone in
                let on = currentZone == zone
                let color = HeartZones.colors[zone]
                VStack(spacing: 6) {
                    Image(systemName: "arrowtriangle.down.fill")
                        .font(.system(size: 8))
                        .foregroundStyle(color)
                        .opacity(on ? 1 : 0)
                    RoundedRectangle(cornerRadius: 4)
                        .fill(color.opacity(on ? 1 : 0.25))
                        .frame(height: on ? 14 : 8)
                    Text("Z\(zone + 1)").font(.caption.weight(on ? .bold : .medium))
                        .foregroundStyle(on ? color : BrickLook.soft)
                    Text(time[zone] >= 1 ? WorkoutFormat.elapsed(time[zone]) : "–")
                        .font(.caption2).foregroundStyle(on ? BrickLook.ink : BrickLook.soft).monospacedDigit()
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .padding(.horizontal, 4)
                .background(on ? color.opacity(0.16) : .clear, in: .rect(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(on ? color : .clear, lineWidth: 1.5))
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .animation(.snappy, value: currentZone)
    }
}

/// The exercise being swapped out, for the Replace sheet.
private struct Replacing: Identifiable {
    let id: DraftExercise.ID
}

// MARK: Progress

/// Under the header: reps checked off out of every rep planned in the workout.
private struct RepsProgress: View {
    var done: Int
    var total: Int

    private var fraction: Double { total > 0 ? min(1, Double(done) / Double(total)) : 0 }

    var body: some View {
        VStack(spacing: 6) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(BrickLook.line)
                    Capsule().fill(BrickLook.bar).frame(width: geo.size.width * fraction)
                }
            }
            .frame(height: 6)
            HStack {
                Text("\(done) of \(total) reps")
                Spacer()
                Text("\(Int((fraction * 100).rounded()))%")
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(BrickLook.soft)
            .monospacedDigit()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .glassGlare(.regular, in: .rect(cornerRadius: 16, style: .continuous))
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
        .animation(.snappy, value: done)
        .accessibilityElement(children: .combine)
    }
}

/// An exercise collapsed to one row while reordering.
struct ReorderRow: View {
    var exerciseId: String
    var name: String
    var muscle: String?

    var body: some View {
        HStack(spacing: 12) {
            ExerciseThumb(exerciseId: exerciseId, muscle: muscle, size: 40)
            Text(name).font(.body.weight(.medium)).lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }
}

// MARK: Exercise

private struct ExerciseHeader: View {
    var store: WorkoutStore
    var exercise: DraftExercise
    var isLast: Bool
    var onOpen: () -> Void
    var onReplace: () -> Void
    var onReorder: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onOpen) {
                HStack(spacing: 12) {
                    ExerciseThumb(exerciseId: exercise.exerciseId, muscle: store.exercise(exercise.exerciseId)?.muscle, size: 48)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(exercise.name).font(.system(size: 20, weight: .regular)).foregroundStyle(BrickLook.ink)
                            .multilineTextAlignment(.leading)
                        if exercise.superset != nil {
                            Text("Superset").font(.caption.weight(.medium)).foregroundStyle(Fit.health)
                        }
                    }
                }
                .contentShape(.rect)
            }
            .buttonStyle(.borderless)
            .simultaneousGesture(LongPressGesture(minimumDuration: 0.4).onEnded { _ in onReorder() })
            Spacer(minLength: 8)
            Menu {
                Button("Replace exercise", systemImage: "arrow.triangle.2.circlepath", action: onReplace)
                Button("Reorder exercises", systemImage: "arrow.up.arrow.down", action: onReorder)
                if exercise.superset != nil {
                    Button("Remove from superset", systemImage: "link") { store.updateExercise(exercise.id) { $0.superset = nil } }
                } else if !isLast {
                    Button("Superset with next", systemImage: "link") { supersetWithNext() }
                }
                Button("Remove exercise", systemImage: "trash", role: .destructive) { store.removeExercise(exercise.id) }
            } label: {
                Image(systemName: "ellipsis").font(.body.weight(.bold)).rotationEffect(.degrees(90))
                    .frame(width: 36, height: 36).contentShape(.rect)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(BrickLook.ink)
        }
    }

    private func supersetWithNext() {
        guard let workout = store.active, let i = workout.exercises.firstIndex(where: { $0.id == exercise.id }),
              i + 1 < workout.exercises.count else { return }
        let group = (workout.exercises.compactMap(\.superset).max() ?? 0) + 1
        let next = workout.exercises[i + 1].id
        store.updateExercise(exercise.id) { $0.superset = group }
        store.updateExercise(next) { $0.superset = workout.exercises[i + 1].superset ?? group }
    }
}

/// The rest-timer and note pills under an exercise's name, and the note itself.
private struct ExerciseOptions: View {
    var store: WorkoutStore
    var exercise: DraftExercise
    @Binding var noteOpen: Bool

    private var rest: Int { exercise.restSeconds ?? WorkoutStore.defaultRest }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Menu {
                    Picker("Rest timer", selection: Binding(get: { rest }, set: { value in store.updateExercise(exercise.id) { $0.restSeconds = value } })) {
                        ForEach([0, 30, 45, 60, 90, 120, 150, 180, 240, 300], id: \.self) { Text(WorkoutFormat.rest($0)).tag($0) }
                    }
                } label: {
                    WorkoutPill(symbol: "timer", title: "Rest: \(WorkoutFormat.rest(rest))")
                }
                .buttonStyle(.borderless)
                Button { noteOpen.toggle() } label: { WorkoutPill(symbol: "note.text.badge.plus", title: "Note") }
                    .buttonStyle(.borderless)
            }
            if noteOpen {
                TextField(store.lastNote(exercise.exerciseId).map { "Last time: \($0)" } ?? "Add notes here...", text: Binding(
                    get: { exercise.notes ?? "" },
                    set: { value in store.updateExercise(exercise.id) { $0.notes = value.isEmpty ? nil : value } }),
                          axis: .vertical)
                    .font(.subheadline)
                    .lineLimit(1...4)
            }
        }
    }
}

/// A grey rounded pill with an icon, like Hevy's Rest and Note buttons.
struct WorkoutPill: View {
    var symbol: String
    var title: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
            Text(title).monospacedDigit()
        }
        .font(.subheadline.weight(.medium))
        .foregroundStyle(BrickLook.ink)
        .padding(.horizontal, 16)
        .frame(height: 38)
        .glassEffect(.regular, in: .capsule)
    }
}

/// Column widths of the set grid, shared by the workout and the routine editor.
enum WorkoutColumns {
    static let set: CGFloat = 40
    static let weight: CGFloat = 70
    static let reps: CGFloat = 58
    static let time: CGFloat = 112
    static let check: CGFloat = 44
}

private struct ExerciseSetsHeader: View {
    var isDuration: Bool
    var unit: WeightUnit

    var body: some View {
        HStack(spacing: 8) {
            Text("SET").frame(width: WorkoutColumns.set)
            Text("PREVIOUS").frame(maxWidth: .infinity)
            if isDuration {
                Text("TIME").frame(width: WorkoutColumns.time + 40)
            } else {
                Text(unit == .lb ? "LBS" : "KG").frame(width: WorkoutColumns.weight)
                Text("REPS").frame(width: WorkoutColumns.reps)
            }
            Image(systemName: "checkmark").frame(width: WorkoutColumns.check)
        }
        .font(.system(size: 12, weight: .medium))
        .tracking(1.0)
        .foregroundStyle(BrickLook.soft)
    }
}

private struct SetRow: View {
    var store: WorkoutStore
    var exercise: DraftExercise
    var entry: DraftSet
    var number: String
    var previous: String
    var unit: WeightUnit
    var liveBpm: Int?

    private var done: Bool { entry.completedAt != nil }
    private var timing: WorkoutStore.SetTimer? { store.setTimer?.set == entry.id ? store.setTimer : nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Menu {
                    Picker("Type", selection: Binding(get: { entry.kind }, set: { kind in store.update(exercise.id, entry.id) { $0.kind = kind } })) {
                        ForEach(SetKind.allCases) { Text($0.name).tag($0) }
                    }
                    Button("Delete set", systemImage: "trash", role: .destructive) { store.removeSet(exercise.id, entry.id) }
                } label: {
                    Text(number)
                        .font(.body.weight(.semibold)).monospacedDigit()
                        .foregroundStyle(kindColor)
                        .frame(width: WorkoutColumns.set, height: 40)
                        .glassFill(!done)
                }
                .buttonStyle(.borderless)
                Button(action: fillFromPrevious) {
                    Text(previous).font(.body).foregroundStyle(BrickLook.soft).lineLimit(1).minimumScaleFactor(0.7)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderless)
                if exercise.isDuration {
                    timeField
                } else {
                    field(weightText, hint: entry.weightHint, width: WorkoutColumns.weight, decimal: true)
                    field(repsText, hint: entry.repsHint, width: WorkoutColumns.reps, decimal: false)
                }
                Button {
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    if !done { ActiveWorkoutView.hideKeyboard() }
                    store.toggle(exercise.id, entry.id, liveHr: liveBpm)
                } label: {
                    Image(systemName: "checkmark")
                        .font(.body.weight(.bold))
                        .foregroundStyle(done ? BrickLook.page : BrickLook.soft)
                        .frame(width: WorkoutColumns.check, height: 40)
                        .background(done ? BrickLook.live : Color.clear, in: .rect(cornerRadius: 8))
                        .glassFill(!done)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(done ? "Uncheck set" : "Check off set")
            }
            if done, entry.isPR {
                HStack(spacing: 10) {
                    HStack(spacing: 3) { Image(systemName: "trophy.fill"); Text("PR") }.foregroundStyle(Fit.fair)
                }
                .font(.caption2.weight(.medium))
                .padding(.leading, WorkoutColumns.set + 8)
            }
        }
        .animation(.snappy, value: done)
    }

    private var kindColor: Color {
        switch entry.kind {
        case .warmup: Fit.fair
        case .drop: Fit.health
        case .failure: Fit.attention
        case .normal: .primary
        }
    }

    private var weightText: Binding<String> {
        Binding(get: { entry.weightText }, set: { value in store.update(exercise.id, entry.id) { $0.weightText = value } })
    }

    private var repsText: Binding<String> {
        Binding(get: { entry.repsText }, set: { value in store.update(exercise.id, entry.id) { $0.repsText = value } })
    }

    private func field(_ text: Binding<String>, hint: String, width: CGFloat, decimal: Bool) -> some View {
        TextField(hint.isEmpty ? "-" : hint, text: text)
            .keyboardType(decimal ? .decimalPad : .numberPad)
            .multilineTextAlignment(.center)
            .font(.body.weight(done ? .bold : .medium)).monospacedDigit()
            .frame(width: width, height: 40)
            .glassFill(!done)
    }

    /// A timed set: a play button that counts the set down, and the time typed
    /// like a microwave ("500" is 5:00).
    private var timeField: some View {
        HStack(spacing: 8) {
            if !done {
                Button {
                    ActiveWorkoutView.hideKeyboard()
                    store.toggleSetTimer(exercise.id, entry.id)
                } label: {
                    Image(systemName: timing == nil ? "play.fill" : "stop.fill")
                        .font(.footnote)
                        .foregroundStyle(BrickLook.bar)
                        .frame(width: 32, height: 32)
                        .overlay(Circle().stroke(BrickLook.bar, lineWidth: 2))
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(timing == nil ? "Start timer" : "Stop timer")
            }
            Group {
                if let timing {
                    TimelineView(.periodic(from: .now, by: 0.25)) { context in
                        let left = max(0, timing.endsAt.timeIntervalSince(context.date)).rounded(.up)
                        Text(WorkoutFormat.timer(String(Int(left))))
                            .font(.body.weight(.semibold)).monospacedDigit().foregroundStyle(BrickLook.bar)
                    }
                } else {
                    TextField(entry.repsHint.isEmpty ? "00:00" : WorkoutFormat.timer(entry.repsHint), text: Binding(
                        get: { WorkoutFormat.timer(entry.repsText) },
                        set: { value in store.update(exercise.id, entry.id) { $0.repsText = WorkoutFormat.seconds(fromTyped: value) } }))
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.center)
                        .font(.body.weight(done ? .bold : .medium)).monospacedDigit()
                }
            }
            .frame(width: WorkoutColumns.time, height: 40)
            .glassFill(!done)
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(timing == nil ? Color.clear : BrickLook.bar, lineWidth: 1.5))
        }
        .frame(width: WorkoutColumns.time + 40, alignment: .trailing)
    }

    /// Tapping last time's numbers copies them into the fields.
    private func fillFromPrevious() {
        guard !done else { return }
        store.update(exercise.id, entry.id) { s in
            if !s.weightHint.isEmpty { s.weightText = s.weightHint }
            if !s.repsHint.isEmpty { s.repsText = s.repsHint }
        }
    }
}

// MARK: Rest timer

/// The rest timer: a line around the edge of the screen that runs out clockwise from the top, so
/// there's nothing to cover the sets. Skip and +/-15 s stay on the lock screen's Live Activity.
struct RestStroke: View {
    var store: WorkoutStore

    private static let radius: CGFloat = {
        let screen = UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.screen }.first
        return (screen?.value(forKey: "_displayCornerRadius") as? CGFloat).flatMap { $0 > 0 ? $0 : nil } ?? 55
    }()

    var body: some View {
        if let end = store.restEndsAt {
            TimelineView(.animation) { context in
                let remaining = max(0, end.timeIntervalSince(context.date))
                let left = store.restTotal > 0 ? min(1, remaining / store.restTotal) : 0
                ScreenEdge(radius: Self.radius, inset: 2)
                    .trim(from: 0, to: left)
                    .stroke(BrickLook.live, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
            }
            .transition(.opacity)
        }
    }
}

/// The screen's outline from the top centre, clockwise.
private struct ScreenEdge: Shape {
    var radius: CGFloat
    var inset: CGFloat

    func path(in rect: CGRect) -> Path {
        let r = rect.insetBy(dx: inset, dy: inset)
        let c = max(radius - inset, 0)
        var p = Path()
        p.move(to: CGPoint(x: r.midX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX - c, y: r.minY))
        p.addArc(center: CGPoint(x: r.maxX - c, y: r.minY + c), radius: c, startAngle: .degrees(-90), endAngle: .degrees(0), clockwise: false)
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY - c))
        p.addArc(center: CGPoint(x: r.maxX - c, y: r.maxY - c), radius: c, startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false)
        p.addLine(to: CGPoint(x: r.minX + c, y: r.maxY))
        p.addArc(center: CGPoint(x: r.minX + c, y: r.maxY - c), radius: c, startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false)
        p.addLine(to: CGPoint(x: r.minX, y: r.minY + c))
        p.addArc(center: CGPoint(x: r.minX + c, y: r.minY + c), radius: c, startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false)
        p.closeSubpath()
        return p
    }
}

// MARK: Settings

/// The workout's name, notes and weight unit.
private struct WorkoutSettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    var store: WorkoutStore
    @Binding var defaultUnit: WeightUnit

    var body: some View {
        NavigationStack {
            Form {
                Section("Workout") {
                    TextField("Workout name", text: Binding(get: { store.active?.name ?? "" }, set: { store.active?.name = $0 }))
                    TextField("Notes", text: Binding(get: { store.active?.notes ?? "" }, set: { store.active?.notes = $0 }), axis: .vertical)
                        .lineLimit(2...6)
                }
                .listRowBackground(BrickLook.card)
                Section {
                    Picker("Weight unit", selection: Binding(get: { store.active?.unit ?? defaultUnit }, set: { unit in
                        store.setUnit(unit)
                        defaultUnit = unit
                    })) {
                        ForEach(WeightUnit.allCases) { Text($0 == .lb ? "lbs" : "kg").tag($0) }
                    }
                    .listRowBackground(BrickLook.card)
                } footer: {
                    Text("Weights already typed are converted.")
                }
            }
            .brickList()
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .presentationBackground { AmbientBackdrop() }
        .presentationDetents([.medium, .large])
    }
}

/// The Liquid Glass fill behind a full-width button.
struct GreyFill: ViewModifier {
    func body(content: Content) -> some View {
        content.glassGlare(.regular, in: .rect(cornerRadius: 16, style: .continuous))
    }
}

extension View {
    /// A small Liquid Glass field behind a set's number, weight, reps or check.
    @ViewBuilder func glassFill(_ on: Bool = true) -> some View {
        if on { glassEffect(.regular, in: .rect(cornerRadius: 8)) } else { self }
    }
}

/// The filled slate pill for Finish, Done and Save in a workout's toolbar.
struct WorkoutToolbarLabel: View {
    var title: String
    var body: some View {
        Text(title)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(BrickLook.page)
            .padding(.horizontal, 16)
            .frame(height: 34)
            .background(BrickLook.bar, in: .capsule)
    }
}
