import SwiftUI

/// The workout in progress: one section per exercise with a set grid
/// (previous, weight, reps, check), live heart rate from the watch, and a rest
/// timer after every checked set. Each check stamps the set with the time and
/// the watch's reading, which the hub maps the full heart-rate curve onto.
struct ActiveWorkoutView: View {
    @Environment(AppSession.self) private var session
    @Environment(WatchLink.self) private var watch
    @Environment(\.dismiss) private var dismiss
    var store: WorkoutStore
    @State private var picking = false
    @State private var confirmDiscard = false
    @State private var confirmEmpty = false

    /// The watch's reading, if it's recent enough to trust.
    private var liveBpm: Int? {
        guard let at = watch.heartRateAt, Date.now.timeIntervalSince(at) < 15 else { return nil }
        return watch.heartRate?.bpm
    }

    var body: some View {
        NavigationStack {
            Group {
                if let workout = store.active {
                    list(workout)
                } else {
                    Color.clear.onAppear { dismiss() }
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Image(systemName: "chevron.down") }.accessibilityLabel("Minimize")
                }
                ToolbarItem(placement: .principal) {
                    if let start = store.active?.startedAt {
                        TimelineView(.periodic(from: start, by: 1)) { context in
                            Text(WorkoutFormat.clock(context.date.timeIntervalSince(start))).font(.headline).monospacedDigit()
                        }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Finish") {
                        if store.active?.completedSets.isEmpty ?? true { confirmEmpty = true } else { finish() }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Fit.positive)
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil) }
                }
            }
            .safeAreaInset(edge: .bottom) { RestBar(store: store) }
            .sheet(isPresented: $picking) {
                ExercisePicker(store: store) { store.addExercises($0) }
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
            .onAppear {
                if watch.savedWatchID != nil, watch.state != .connected, !watch.isBusy { watch.connectSaved() }
            }
        }
    }

    private func finish() {
        Task { await store.finish(api: session.api) }
        dismiss()
    }

    private func list(_ workout: ActiveWorkout) -> some View {
        List {
            Section { header(workout) }
                .listRowSeparator(.hidden)
            ForEach(workout.exercises) { exercise in
                Section {
                    ExerciseSetsHeader(isDuration: exercise.isDuration, unit: workout.unit)
                        .listRowSeparator(.hidden)
                    ForEach(Array(exercise.sets.enumerated()), id: \.element.id) { index, set in
                        SetRow(store: store, exercise: exercise, entry: set, number: number(of: index, in: exercise.sets),
                               previous: previous(exercise, index), unit: workout.unit, liveBpm: liveBpm)
                            .swipeActions { Button("Delete", role: .destructive) { store.removeSet(exercise.id, set.id) } }
                            .listRowSeparator(.hidden)
                    }
                    Button {
                        store.addSet(exercise: exercise.id)
                    } label: {
                        Label("Add set", systemImage: "plus").font(.subheadline.weight(.medium)).frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .listRowSeparator(.hidden)
                } header: {
                    ExerciseHeader(store: store, exercise: exercise, isLast: exercise.id == workout.exercises.last?.id)
                }
            }
            Section {
                Button { picking = true } label: {
                    Label("Add exercises", systemImage: "plus").font(.body.weight(.semibold)).frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                Button("Discard workout", role: .destructive) { confirmDiscard = true }
                    .frame(maxWidth: .infinity)
            }
            .listRowSeparator(.hidden)
        }
        .listStyle(.plain)
        .scrollDismissesKeyboard(.interactively)
    }

    private func header(_ workout: ActiveWorkout) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            TextField("Workout name", text: Binding(get: { store.active?.name ?? "" }, set: { store.active?.name = $0 }))
                .font(.title2.weight(.semibold))
            HStack(spacing: 22) {
                stat("Volume", WorkoutFormat.volume(workout.volumeKg, unit: workout.unit))
                stat("Sets", "\(workout.completedSets.filter { $0.kind != .warmup }.count)")
                VStack(alignment: .leading, spacing: 2) {
                    Text("Heart rate").font(.caption).foregroundStyle(Fit.muted)
                    if let bpm = liveBpm {
                        HStack(spacing: 4) {
                            Image(systemName: "heart.fill").foregroundStyle(Fit.heart).symbolEffect(.pulse)
                            Text("\(bpm)").monospacedDigit()
                        }
                        .font(.headline)
                    } else {
                        Text(watch.savedWatchID == nil ? "No watch" : "Connecting…").font(.subheadline).foregroundStyle(Fit.muted)
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(Fit.muted)
            Text(value).font(.headline).monospacedDigit()
        }
    }

    /// Warm-ups get "W"; working sets are numbered without them.
    private func number(of index: Int, in sets: [DraftSet]) -> String {
        if let badge = sets[index].kind.badge { return badge }
        return "\(sets[..<index].filter { $0.kind != .warmup }.count + 1)"
    }

    private func previous(_ exercise: DraftExercise, _ index: Int) -> String {
        guard let last = store.home?.previous[exercise.exerciseId]?[safe: index] else { return "–" }
        if exercise.isDuration { return last.durationSeconds.map { WorkoutFormat.clock($0) } ?? "–" }
        let unit = store.active?.unit ?? .kg
        switch (last.weightKg, last.reps) {
        case let (w?, r?) where w > 0: return "\(unit.text(w)) × \(r)"
        case let (_, r?): return "\(r) reps"
        default: return "–"
        }
    }
}

private struct ExerciseHeader: View {
    var store: WorkoutStore
    var exercise: DraftExercise
    var isLast: Bool

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(exercise.name).font(.headline).foregroundStyle(Fit.energy)
                HStack(spacing: 8) {
                    if exercise.superset != nil { Text("Superset").foregroundStyle(Fit.health) }
                    Label(restLabel, systemImage: "timer").labelStyle(.titleAndIcon)
                }
                .font(.caption)
                .foregroundStyle(Fit.muted)
            }
            Spacer()
            Menu {
                Menu("Rest timer") {
                    ForEach([0, 30, 60, 90, 120, 180, 240, 300], id: \.self) { seconds in
                        Button(seconds == 0 ? "Off" : WorkoutFormat.clock(TimeInterval(seconds))) {
                            store.updateExercise(exercise.id) { $0.restSeconds = seconds }
                        }
                    }
                }
                if exercise.superset != nil {
                    Button("Remove from superset") { store.updateExercise(exercise.id) { $0.superset = nil } }
                } else if !isLast {
                    Button("Superset with next") { supersetWithNext() }
                }
                Button("Remove exercise", role: .destructive) { store.removeExercise(exercise.id) }
            } label: {
                Image(systemName: "ellipsis").font(.body.weight(.semibold)).frame(width: 36, height: 30).contentShape(.rect)
            }
        }
        .textCase(nil)
    }

    private var restLabel: String {
        let seconds = exercise.restSeconds ?? WorkoutStore.defaultRest
        return seconds == 0 ? "Rest off" : "Rest \(WorkoutFormat.clock(TimeInterval(seconds)))"
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

private struct ExerciseSetsHeader: View {
    var isDuration: Bool
    var unit: WeightUnit

    var body: some View {
        HStack(spacing: 8) {
            Text("SET").frame(width: 34)
            Text("PREVIOUS").frame(maxWidth: .infinity, alignment: .leading)
            if isDuration {
                Text("SECONDS").frame(width: 120)
            } else {
                Text(unit.rawValue.uppercased()).frame(width: 64)
                Text("REPS").frame(width: 52)
            }
            Image(systemName: "checkmark").frame(width: 36)
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(Fit.muted)
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

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Menu {
                    Picker("Type", selection: Binding(get: { entry.kind }, set: { kind in store.update(exercise.id, entry.id) { $0.kind = kind } })) {
                        ForEach(SetKind.allCases) { Text($0.name).tag($0) }
                    }
                    Button("Delete set", role: .destructive) { store.removeSet(exercise.id, entry.id) }
                } label: {
                    Text(number)
                        .font(.subheadline.weight(.semibold)).monospacedDigit()
                        .foregroundStyle(kindColor)
                        .frame(width: 34, height: 32)
                        .background(Fit.track.opacity(done ? 0 : 0.6), in: .rect(cornerRadius: 6))
                }
                Button {
                    fillFromPrevious()
                } label: {
                    Text(previous).font(.subheadline).foregroundStyle(Fit.muted).lineLimit(1).minimumScaleFactor(0.8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                if exercise.isDuration {
                    field(repsText, hint: entry.repsHint, width: 120, decimal: false)
                } else {
                    field(weightText, hint: entry.weightHint, width: 64, decimal: true)
                    field(repsText, hint: entry.repsHint, width: 52, decimal: false)
                }
                Button {
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    store.toggle(exercise.id, entry.id, liveHr: liveBpm)
                } label: {
                    Image(systemName: "checkmark")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(done ? Color.white : Fit.muted)
                        .frame(width: 36, height: 32)
                        .background(done ? Fit.positive : Fit.track, in: .rect(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(done ? "Uncheck set" : "Check off set")
            }
            if done, entry.liveHr != nil || entry.isPR {
                HStack(spacing: 10) {
                    if let bpm = entry.liveHr {
                        HStack(spacing: 3) { Image(systemName: "heart.fill"); Text("\(bpm) bpm") }.foregroundStyle(Fit.heart)
                    }
                    if entry.isPR {
                        HStack(spacing: 3) { Image(systemName: "trophy.fill"); Text("PR") }.foregroundStyle(Fit.fair)
                    }
                }
                .font(.caption2.weight(.medium))
                .padding(.leading, 42)
            }
        }
        .listRowBackground(done ? Fit.positive.opacity(0.12) : Color.clear)
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
        TextField(hint.isEmpty ? "–" : hint, text: text)
            .keyboardType(decimal ? .decimalPad : .numberPad)
            .multilineTextAlignment(.center)
            .font(.body.weight(.medium)).monospacedDigit()
            .frame(width: width, height: 32)
            .background(Fit.track.opacity(done ? 0 : 0.6), in: .rect(cornerRadius: 6))
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

/// The countdown after a checked set, with ±15 s and skip.
private struct RestBar: View {
    var store: WorkoutStore

    var body: some View {
        if let end = store.restEndsAt {
            TimelineView(.periodic(from: .now, by: 0.5)) { context in
                let remaining = max(0, end.timeIntervalSince(context.date))
                VStack(spacing: 10) {
                    ProgressView(value: store.restTotal > 0 ? remaining / store.restTotal : 0).tint(Fit.energy)
                    HStack {
                        Button("−15") { store.adjustRest(by: -15) }.buttonStyle(.bordered)
                        Spacer()
                        VStack(spacing: 0) {
                            Text("Rest").font(.caption).foregroundStyle(Fit.muted)
                            Text(WorkoutFormat.clock(remaining.rounded(.up))).font(.title2.weight(.semibold)).monospacedDigit()
                        }
                        Spacer()
                        Button("+15") { store.adjustRest(by: 15) }.buttonStyle(.bordered)
                        Button("Skip") { store.skipRest() }.buttonStyle(.borderedProminent).tint(Fit.energy)
                    }
                }
                .padding(.horizontal, Fit.gutter)
                .padding(.vertical, 12)
                .background(.regularMaterial)
            }
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}
