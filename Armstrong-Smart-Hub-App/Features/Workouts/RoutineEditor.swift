import SwiftUI

/// Creates or edits a routine: exercises in order, each with a set count,
/// target reps and weight, and its rest time.
struct RoutineEditor: View {
    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    @AppStorage("workouts.unit") private var unit: WeightUnit = .localDefault
    var store: WorkoutStore
    @State var routine: Routine
    /// The routine's exercises with a stable identity while editing.
    @State private var items: [Editable]
    var isNew: Bool
    @State private var picking = false
    @State private var saving = false
    @State private var error: String?

    init(store: WorkoutStore, routine: Routine? = nil) {
        self.store = store
        let initial = routine ?? Routine(id: UUID().uuidString.lowercased(), name: "", position: store.routines.count, exercises: [])
        _routine = State(initialValue: initial)
        _items = State(initialValue: initial.exercises.map { Editable(item: $0) })
        isNew = !store.routines.contains { $0.id == initial.id }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    TextField("Routine name", text: $routine.name).font(.title3.weight(.semibold))
                }
                Section("Exercises") {
                    ForEach($items) { $editable in
                        ItemRow(item: $editable.item, unit: unit)
                    }
                    .onDelete { items.remove(atOffsets: $0) }
                    .onMove { items.move(fromOffsets: $0, toOffset: $1) }
                    Button { picking = true } label: { Label("Add exercises", systemImage: "plus") }
                }
                if let error { Text(error).foregroundStyle(.red).font(.footnote) }
            }
            .environment(\.editMode, .constant(.active))
            .navigationTitle(isNew ? "New routine" : "Edit routine")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save() } }
                        .disabled(routine.name.trimmingCharacters(in: .whitespaces).isEmpty || items.isEmpty || saving)
                }
            }
            .sheet(isPresented: $picking) {
                ExercisePicker(store: store) { picked in
                    items += picked.map { exercise in
                        let last = store.home?.previous[exercise.id]?.first { $0.kind != "warmup" }
                        let target = Routine.Target(kind: "normal", weightKg: last?.weightKg, reps: last?.reps ?? (exercise.isDuration ? nil : 8))
                        return Editable(item: Routine.Item(exerciseId: exercise.id, name: exercise.name, restSeconds: nil, superset: nil,
                                                           sets: Array(repeating: target, count: 3)))
                    }
                }
            }
        }
    }

    private func save() async {
        saving = true
        defer { saving = false }
        routine.name = routine.name.trimmingCharacters(in: .whitespaces)
        routine.exercises = items.map(\.item)
        do {
            try await store.saveRoutine(routine, api: session.api)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

private struct Editable: Identifiable {
    let id = UUID()
    var item: Routine.Item
}

/// "3 sets × 8 reps @ 135 lb", editable. Changing a value applies it to every working set.
private struct ItemRow: View {
    @Binding var item: Routine.Item
    var unit: WeightUnit
    @State private var weightText = ""
    @State private var repsText = ""

    private var working: Routine.Target? { item.sets.first { $0.kind != "warmup" } ?? item.sets.first }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(item.name).font(.headline)
            HStack(spacing: 12) {
                Stepper("\(item.sets.count) sets", value: Binding(get: { item.sets.count }, set: resize), in: 1...12)
                    .fixedSize()
                Spacer()
                TextField("reps", text: $repsText)
                    .keyboardType(.numberPad).multilineTextAlignment(.center).frame(width: 48)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: repsText) { _, text in apply { $0.reps = WorkoutFormat.number(text).map { Int($0) } } }
                Text("×").foregroundStyle(Fit.muted)
                TextField(unit.rawValue, text: $weightText)
                    .keyboardType(.decimalPad).multilineTextAlignment(.center).frame(width: 64)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: weightText) { _, text in apply { $0.weightKg = WorkoutFormat.number(text).map(unit.toKg) } }
            }
            .font(.subheadline)
            Picker("Rest", selection: Binding(get: { item.restSeconds ?? WorkoutStore.defaultRest }, set: { item.restSeconds = $0 })) {
                ForEach([0, 30, 60, 90, 120, 180, 240, 300], id: \.self) { seconds in
                    Text(seconds == 0 ? "Off" : WorkoutFormat.clock(TimeInterval(seconds))).tag(seconds)
                }
            }
            .font(.subheadline)
        }
        .padding(.vertical, 4)
        .onAppear {
            weightText = unit.text(working?.weightKg)
            repsText = working?.reps.map(String.init) ?? ""
        }
    }

    private func resize(_ count: Int) {
        if count < item.sets.count {
            item.sets.removeLast(item.sets.count - count)
        } else if let template = item.sets.last(where: { $0.kind != "warmup" }) ?? item.sets.last {
            item.sets += Array(repeating: Routine.Target(kind: "normal", weightKg: template.weightKg, reps: template.reps), count: count - item.sets.count)
        }
    }

    private func apply(_ change: (inout Routine.Target) -> Void) {
        for i in item.sets.indices where item.sets[i].kind != "warmup" { change(&item.sets[i]) }
    }
}
