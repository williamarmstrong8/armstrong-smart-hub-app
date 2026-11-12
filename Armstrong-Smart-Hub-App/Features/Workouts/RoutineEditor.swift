import SwiftUI

/// Creates or edits a routine, laid out like the workout itself: one block per
/// exercise (picture, rest timer, a set grid of previous, weight and reps) with
/// Add Set under it and Add Exercise at the bottom.
struct RoutineEditor: View {
    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    @AppStorage("workouts.unit") private var unit: WeightUnit = .localDefault
    var store: WorkoutStore
    @State private var routine: Routine
    /// The routine's exercises and sets with a stable identity while editing.
    @State private var items: [EditableItem]
    private let isNew: Bool
    @State private var picking = false
    @State private var saving = false
    @State private var confirmDiscard = false
    @State private var error: String?
    /// Exercises collapsed to one row each, to drag into a new order.
    @State private var reordering = false
    @State private var replacing: ReplaceTarget?

    init(store: WorkoutStore, routine: Routine? = nil) {
        self.store = store
        let initial = routine ?? Routine(id: UUID().uuidString.lowercased(), name: "", position: store.routines.count, exercises: [])
        let unit = UserDefaults.standard.string(forKey: "workouts.unit").flatMap { WeightUnit(rawValue: $0) } ?? .localDefault
        _routine = State(initialValue: initial)
        _items = State(initialValue: initial.exercises.map { EditableItem($0, unit: unit, store: store) })
        isNew = !store.routines.contains { $0.id == initial.id }
    }

    private var canSave: Bool {
        !routine.name.trimmingCharacters(in: .whitespaces).isEmpty && !items.isEmpty && !saving
    }

    var body: some View {
        NavigationStack {
            Group {
                if reordering { reorderList } else { editList }
            }
            .navigationTitle(isNew ? "Create Routine" : "Edit Routine")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if reordering {
                        Button { withAnimation(.snappy) { reordering = false } } label: { WorkoutToolbarLabel(title: "Done") }
                    } else {
                        Button { Task { await save() } } label: { WorkoutToolbarLabel(title: "Save") }
                            .disabled(!canSave)
                            .opacity(canSave ? 1 : 0.4)
                    }
                }
            }
            .navigationDestination(for: ExerciseRoute.self) { ExerciseDetailPage(route: $0, store: store) }
            .sheet(isPresented: $picking, onDismiss: ActiveWorkoutView.hideKeyboard) {
                ExercisePicker(store: store) { picked in
                    items += picked.map { EditableItem(new: $0, unit: unit, store: store) }
                }
            }
            .sheet(item: $replacing, onDismiss: ActiveWorkoutView.hideKeyboard) { target in
                ExercisePicker(store: store, replacing: true) { picked in
                    guard let exercise = picked.first, let i = items.firstIndex(where: { $0.id == target.id }) else { return }
                    items[i].replace(with: exercise, unit: unit, store: store)
                }
            }
            .confirmationDialog("Delete this routine?", isPresented: $confirmDiscard, titleVisibility: .visible) {
                Button("Delete routine", role: .destructive) {
                    Task {
                        await store.deleteRoutine(routine.id, api: session.api)
                        dismiss()
                    }
                }
            }
        }
        .presentationBackground { AmbientBackdrop() }
        .foregroundStyle(BrickLook.ink)
        .tint(HubDesign.action)
    }

    private func startReordering() {
        ActiveWorkoutView.hideKeyboard()
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        withAnimation(.snappy) { reordering = true }
    }

    /// One row per exercise, held and dragged into a new order.
    private var reorderList: some View {
        List {
            Text("Hold and drag to reorder").font(.footnote).foregroundStyle(BrickLook.soft)
                .workoutRow(top: 12, bottom: 4)
                .moveDisabled(true)
            ForEach(items) { item in
                ReorderRow(exerciseId: item.exerciseId, name: item.name, muscle: item.muscle)
                    .listRowBackground(Color.clear)
                    .deleteDisabled(true)
            }
            .onMove { items.move(fromOffsets: $0, toOffset: $1) }
        }
        .listStyle(.plain)
        .hubListStyle()
        .environment(\.editMode, .constant(.active))
    }

    private var editList: some View {
        List {
            TextField("Routine title", text: $routine.name)
                .font(.system(size: 26, weight: .regular))
                .submitLabel(.done)
                .workoutRow(top: 12, bottom: 4)
            BrickDivider()
                .workoutRow(top: 8, bottom: 8)

            if items.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "dumbbell").font(.system(size: 34, weight: .light)).foregroundStyle(BrickLook.soft)
                    Text("Get started by adding an exercise to your routine.")
                        .font(.subheadline).foregroundStyle(BrickLook.soft).multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .workoutRow(top: 32, bottom: 24)
            }

            ForEach($items) { $item in
                block($item)
            }

            Button {
                // Otherwise iOS hands focus back to the last field when the picker closes.
                ActiveWorkoutView.hideKeyboard()
                picking = true
            } label: {
                Label("Add exercise", systemImage: "plus").blueButton()
            }
            .buttonStyle(.borderless)
            .workoutRow(top: 20, bottom: 8)

            if let error {
                Text(error).font(.footnote).foregroundStyle(Fit.attention).workoutRow(top: 4, bottom: 4)
            }

            if !isNew {
                Button { confirmDiscard = true } label: {
                    Text("Delete Routine").greyButton(Fit.attention)
                }
                .buttonStyle(.borderless)
                .workoutRow(top: 6, bottom: 24)
            }
        }
        .listStyle(.plain)
        .hubListStyle()
        .scrollDismissesKeyboard(.immediately)
    }

    @ViewBuilder
    private func block(_ item: Binding<EditableItem>) -> some View {
        let id = item.wrappedValue.id
        RoutineExerciseHeader(store: store, item: item.wrappedValue) { action in
            switch action {
            case .replace:
                ActiveWorkoutView.hideKeyboard()
                replacing = ReplaceTarget(id: id)
            case .reorder: startReordering()
            case .remove: items.removeAll { $0.id == id }
            }
        }
        .workoutRow(top: 18, bottom: 4)

        Menu {
            Picker("Rest timer", selection: Binding(get: { item.wrappedValue.restSeconds ?? WorkoutStore.defaultRest },
                                                    set: { item.wrappedValue.restSeconds = $0 })) {
                ForEach([0, 30, 45, 60, 90, 120, 150, 180, 240, 300], id: \.self) { Text(WorkoutFormat.rest($0)).tag($0) }
            }
        } label: {
            WorkoutPill(symbol: "timer", title: "Rest: \(WorkoutFormat.rest(item.wrappedValue.restSeconds ?? WorkoutStore.defaultRest))")
        }
        .buttonStyle(.borderless)
        .workoutRow(top: 4, bottom: 8)

        RoutineSetsHeader(isDuration: item.wrappedValue.isDuration, unit: unit)
            .workoutRow(top: 4, bottom: 2)

        ForEach(item.sets) { $set in
            RoutineSetRow(set: $set, number: number(set.id, in: item.wrappedValue.sets),
                          previous: previous(item.wrappedValue, set.id), isDuration: item.wrappedValue.isDuration,
                          canDelete: item.wrappedValue.sets.count > 1) {
                item.wrappedValue.sets.removeAll { $0.id == set.id }
            }
            .swipeActions {
                if item.wrappedValue.sets.count > 1 {
                    Button("Delete", role: .destructive) { item.wrappedValue.sets.removeAll { $0.id == set.id } }
                }
            }
            .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
        }

        Button { item.wrappedValue.addSet() } label: {
            Label("Add Set", systemImage: "plus").greyButton(BrickLook.ink)
        }
        .buttonStyle(.borderless)
        .workoutRow(top: 10, bottom: 8)
    }

    /// Warm-ups get "W"; working sets are numbered without them.
    private func number(_ id: EditableSet.ID, in sets: [EditableSet]) -> String {
        guard let index = sets.firstIndex(where: { $0.id == id }) else { return "" }
        if let badge = sets[index].kind.badge { return badge }
        return "\(sets[..<index].filter { $0.kind != .warmup }.count + 1)"
    }

    /// Last time's set at the same position, as the workout shows it.
    private func previous(_ item: EditableItem, _ id: EditableSet.ID) -> String {
        guard let index = item.sets.firstIndex(where: { $0.id == id }),
              let last = store.home?.previous[item.exerciseId]?[safe: index] else { return "-" }
        if item.isDuration { return last.durationSeconds.map { WorkoutFormat.timer(String(Int($0))) } ?? "-" }
        switch (last.weightKg, last.reps) {
        case let (w?, r?) where w > 0: return "\(unit.text(w)) \(unit.rawValue) × \(r)"
        case let (_, r?): return "\(r) reps"
        default: return "-"
        }
    }

    private func save() async {
        saving = true
        defer { saving = false }
        routine.name = routine.name.trimmingCharacters(in: .whitespaces)
        routine.exercises = items.map { $0.item(unit: unit) }
        do {
            try await store.saveRoutine(routine, api: session.api)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: Editing model

private struct EditableItem: Identifiable {
    let id = UUID()
    var exerciseId: String
    var name: String
    var muscle: String?
    var isDuration: Bool
    var restSeconds: Int?
    var superset: Int?
    var sets: [EditableSet]

    init(_ item: Routine.Item, unit: WeightUnit, store: WorkoutStore) {
        let exercise = store.exercise(item.exerciseId)
        exerciseId = item.exerciseId
        name = item.name
        muscle = exercise?.muscle
        let isDuration = exercise?.isDuration ?? false
        self.isDuration = isDuration
        restSeconds = item.restSeconds
        superset = item.superset
        sets = item.sets.map { target in
            EditableSet(kind: SetKind(rawValue: target.kind) ?? .normal,
                        weightText: isDuration ? "" : unit.text(target.weightKg),
                        repsText: target.reps.map(String.init) ?? "")
        }
        if sets.isEmpty { addSet() }
    }

    /// A freshly picked exercise: three sets at last time's numbers.
    init(new exercise: Exercise, unit: WeightUnit, store: WorkoutStore) {
        exerciseId = exercise.id
        name = exercise.name
        muscle = exercise.muscle
        isDuration = exercise.isDuration
        let last = store.home?.previous[exercise.id]?.first { $0.kind != "warmup" }
        let set = EditableSet(kind: .normal,
                              weightText: exercise.isDuration ? "" : unit.text(last?.weightKg),
                              repsText: exercise.isDuration ? (last?.durationSeconds).map { String(Int($0)) } ?? ""
                                                             : (last?.reps ?? 8).description)
        sets = (0..<3).map { _ in EditableSet(kind: set.kind, weightText: set.weightText, repsText: set.repsText) }
    }

    /// Swaps in another exercise, keeping the number of sets, their types and the rest time.
    mutating func replace(with exercise: Exercise, unit: WeightUnit, store: WorkoutStore) {
        let fresh = EditableItem(new: exercise, unit: unit, store: store)
        exerciseId = fresh.exerciseId
        name = fresh.name
        muscle = fresh.muscle
        isDuration = fresh.isDuration
        let template = fresh.sets[0]
        sets = sets.map { EditableSet(kind: $0.kind, weightText: template.weightText, repsText: template.repsText) }
    }

    /// A new set copies the last working set's numbers.
    mutating func addSet() {
        let template = sets.last { $0.kind != .warmup } ?? sets.last
        sets.append(EditableSet(kind: .normal, weightText: template?.weightText ?? "", repsText: template?.repsText ?? ""))
    }

    func item(unit: WeightUnit) -> Routine.Item {
        Routine.Item(exerciseId: exerciseId, name: name, restSeconds: restSeconds, superset: superset, sets: sets.map { set in
            Routine.Target(kind: set.kind.rawValue,
                           weightKg: isDuration ? nil : WorkoutFormat.number(set.weightText).map(unit.toKg),
                           reps: WorkoutFormat.number(set.repsText).map { Int($0) })
        })
    }
}

private struct EditableSet: Identifiable {
    let id = UUID()
    var kind: SetKind
    var weightText: String
    /// Reps, or seconds for a timed exercise.
    var repsText: String
}

// MARK: Rows

private enum HeaderAction { case replace, reorder, remove }

/// The exercise being swapped out, for the Replace sheet.
private struct ReplaceTarget: Identifiable {
    let id: UUID
}

private struct RoutineExerciseHeader: View {
    var store: WorkoutStore
    var item: EditableItem
    var onAction: (HeaderAction) -> Void

    var body: some View {
        HStack(spacing: 12) {
            NavigationLink(value: ExerciseRoute(id: item.exerciseId, name: item.name, store: store)) {
                HStack(spacing: 12) {
                    ExerciseThumb(exerciseId: item.exerciseId, muscle: item.muscle, size: 48)
                    Text(item.name).font(.system(size: 20, weight: .regular)).foregroundStyle(BrickLook.ink)
                        .multilineTextAlignment(.leading)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.borderless)
            .simultaneousGesture(LongPressGesture(minimumDuration: 0.4).onEnded { _ in onAction(.reorder) })
            Spacer(minLength: 8)
            Menu {
                Button("Replace exercise", systemImage: "arrow.triangle.2.circlepath") { onAction(.replace) }
                Button("Reorder exercises", systemImage: "arrow.up.arrow.down") { onAction(.reorder) }
                Button("Remove exercise", systemImage: "trash", role: .destructive) { onAction(.remove) }
            } label: {
                Image(systemName: "ellipsis").font(.body.weight(.bold)).rotationEffect(.degrees(90))
                    .frame(width: 36, height: 36).contentShape(.rect)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(BrickLook.ink)
        }
    }
}

private struct RoutineSetsHeader: View {
    var isDuration: Bool
    var unit: WeightUnit

    var body: some View {
        HStack(spacing: 8) {
            Text("SET").frame(width: WorkoutColumns.set)
            Text("PREVIOUS").frame(maxWidth: .infinity)
            if isDuration {
                Text("TIME").frame(width: WorkoutColumns.time)
            } else {
                Text(unit == .lb ? "LBS" : "KG").frame(width: WorkoutColumns.weight)
                Text("REPS").frame(width: WorkoutColumns.reps)
            }
        }
        .font(.system(size: 12, weight: .medium))
        .tracking(1.0)
        .foregroundStyle(BrickLook.soft)
    }
}

private struct RoutineSetRow: View {
    @Binding var set: EditableSet
    var number: String
    var previous: String
    var isDuration: Bool
    var canDelete: Bool
    var onDelete: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Menu {
                Picker("Type", selection: $set.kind) {
                    ForEach(SetKind.allCases) { Text($0.name).tag($0) }
                }
                if canDelete {
                    Button("Delete set", systemImage: "trash", role: .destructive, action: onDelete)
                }
            } label: {
                Text(number)
                    .font(.body.weight(.semibold)).monospacedDigit()
                    .foregroundStyle(kindColor)
                    .frame(width: WorkoutColumns.set, height: 40)
                    .glassFill()
            }
            .buttonStyle(.borderless)
            Text(previous).font(.body).foregroundStyle(BrickLook.soft).lineLimit(1).minimumScaleFactor(0.7)
                .frame(maxWidth: .infinity)
            if isDuration {
                field(Binding(get: { WorkoutFormat.timer(set.repsText) },
                              set: { set.repsText = WorkoutFormat.seconds(fromTyped: $0) }),
                      hint: "00:00", width: WorkoutColumns.time, decimal: false)
            } else {
                field($set.weightText, hint: "-", width: WorkoutColumns.weight, decimal: true)
                field($set.repsText, hint: "-", width: WorkoutColumns.reps, decimal: false)
            }
        }
    }

    private var kindColor: Color {
        switch set.kind {
        case .warmup: Fit.fair
        case .drop: Fit.health
        case .failure: Fit.attention
        case .normal: .primary
        }
    }

    private func field(_ text: Binding<String>, hint: String, width: CGFloat, decimal: Bool) -> some View {
        TextField(hint, text: text)
            .keyboardType(decimal ? .decimalPad : .numberPad)
            .multilineTextAlignment(.center)
            .font(.body.weight(.medium)).monospacedDigit()
            .frame(width: width, height: 40)
            .glassFill()
    }
}
