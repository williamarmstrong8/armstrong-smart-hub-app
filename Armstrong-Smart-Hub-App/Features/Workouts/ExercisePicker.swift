import SwiftUI

/// Search the library, filter by muscle, pick several at once, or add a custom exercise.
struct ExercisePicker: View {
    @Environment(\.dismiss) private var dismiss
    var store: WorkoutStore
    var onPick: ([Exercise]) -> Void
    @State private var search = ""
    @State private var muscle: String?
    @State private var picked: [Exercise] = []
    @State private var creating = false

    private static let muscles = ["chest", "back", "shoulders", "biceps", "triceps", "forearms",
                                  "quads", "hamstrings", "glutes", "calves", "core", "full_body", "cardio"]

    /// Exercises done before come first, then the rest alphabetically.
    private var results: [Exercise] {
        let used = Set(store.home?.previous.keys.map { $0 } ?? [])
        return store.exercises
            .filter { muscle == nil || $0.muscle == muscle }
            .filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }
            .sorted { a, b in
                let ua = used.contains(a.id), ub = used.contains(b.id)
                return ua != ub ? ua : a.name < b.name
            }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            chip("All", selected: muscle == nil) { muscle = nil }
                            ForEach(Self.muscles, id: \.self) { m in
                                chip(WorkoutFormat.label(m), selected: muscle == m) { muscle = muscle == m ? nil : m }
                            }
                        }
                    }
                    .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                }
                .listRowSeparator(.hidden)
                Section {
                    if store.exercises.isEmpty {
                        Text(store.error ?? "Loading the library…").foregroundStyle(.secondary)
                    }
                    ForEach(results) { exercise in
                        let order = picked.firstIndex(of: exercise)
                        Button {
                            if let order { picked.remove(at: order) } else { picked.append(exercise) }
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(exercise.name).foregroundStyle(.primary)
                                    Text("\(exercise.muscleName) · \(WorkoutFormat.label(exercise.equipment))\(exercise.custom ? " · Custom" : "")")
                                        .font(.caption).foregroundStyle(Fit.muted)
                                }
                                Spacer()
                                if let order {
                                    Text("\(order + 1)").font(.caption.weight(.bold)).foregroundStyle(.white)
                                        .frame(width: 24, height: 24).background(Fit.energy, in: .circle)
                                }
                            }
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .listStyle(.plain)
            .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search exercises")
            .navigationTitle("Add exercises")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(picked.isEmpty ? "Add" : "Add \(picked.count)") {
                        onPick(picked)
                        dismiss()
                    }
                    .disabled(picked.isEmpty)
                }
                ToolbarItem(placement: .bottomBar) {
                    Button { creating = true } label: { Label("New exercise", systemImage: "plus") }
                }
            }
            .sheet(isPresented: $creating) {
                NewExerciseSheet(store: store, name: search) { picked.append($0) }
            }
        }
    }

    private func chip(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.subheadline)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .foregroundStyle(selected ? Color(.systemBackground) : .primary)
                .background(selected ? Color.primary : Fit.track, in: .capsule)
        }
        .buttonStyle(.plain)
    }
}

private struct NewExerciseSheet: View {
    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    var store: WorkoutStore
    @State var name: String
    var onCreate: (Exercise) -> Void
    @State private var muscle = "chest"
    @State private var equipment = "barbell"
    @State private var kind = "weight_reps"
    @State private var saving = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                TextField("Name", text: $name)
                Picker("Muscle", selection: $muscle) {
                    ForEach(["chest", "back", "shoulders", "biceps", "triceps", "forearms", "quads", "hamstrings",
                             "glutes", "calves", "core", "full_body", "cardio"], id: \.self) { Text(WorkoutFormat.label($0)).tag($0) }
                }
                Picker("Equipment", selection: $equipment) {
                    ForEach(["barbell", "dumbbell", "machine", "cable", "bodyweight", "kettlebell", "band", "other"], id: \.self) {
                        Text(WorkoutFormat.label($0)).tag($0)
                    }
                }
                Picker("Logged as", selection: $kind) {
                    Text("Weight × reps").tag("weight_reps")
                    Text("Reps").tag("reps")
                    Text("Time").tag("duration")
                }
                if let error { Text(error).foregroundStyle(.red).font(.footnote) }
            }
            .navigationTitle("New exercise")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save() } }
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || saving)
                }
            }
        }
    }

    private func save() async {
        saving = true
        defer { saving = false }
        do {
            let exercise = try await store.createExercise(name: name.trimmingCharacters(in: .whitespaces), muscle: muscle,
                                                          equipment: equipment, kind: kind, api: session.api)
            onCreate(exercise)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
