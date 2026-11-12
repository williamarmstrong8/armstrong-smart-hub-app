import SwiftUI

/// Hevy's Add Exercise screen: search, equipment and muscle filters, recent
/// exercises first, a picture on every row and an info button that opens the
/// exercise's page. Pick several at once; they're added in the order tapped.
struct ExercisePicker: View {
    @Environment(\.dismiss) private var dismiss
    var store: WorkoutStore
    /// Picks one exercise to swap in: a tap picks it and closes.
    var replacing = false
    var onPick: ([Exercise]) -> Void
    @State private var search = ""
    @State private var muscle: String?
    @State private var equipment: String?
    @State private var picked: [Exercise] = []
    @State private var creating = false
    @State private var path = NavigationPath()

    static let muscles = ["chest", "back", "shoulders", "biceps", "triceps", "forearms",
                          "quads", "hamstrings", "glutes", "calves", "core", "full_body", "cardio"]
    static let equipmentKinds = ["barbell", "dumbbell", "machine", "cable", "bodyweight", "kettlebell", "band", "other"]

    private var filtering: Bool { !search.isEmpty || muscle != nil || equipment != nil }

    private func matches(_ exercise: Exercise) -> Bool {
        (muscle == nil || exercise.muscle == muscle)
            && (equipment == nil || exercise.equipment == equipment)
            && (search.isEmpty || exercise.name.localizedCaseInsensitiveContains(search))
    }

    /// Exercises from the latest workouts, newest first.
    private var recent: [Exercise] {
        var seen = Set<String>()
        var out: [Exercise] = []
        for name in store.workouts.flatMap(\.exercises) where !seen.contains(name) {
            seen.insert(name)
            if let exercise = store.exercises.first(where: { $0.name == name }) { out.append(exercise) }
            if out.count == 8 { break }
        }
        return out
    }

    private var all: [Exercise] {
        store.exercises.filter(matches).sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        NavigationStack(path: $path) {
            VStack(spacing: 0) {
                filters
                List {
                    if store.exercises.isEmpty {
                        Text(store.error ?? "Loading the library…").foregroundStyle(BrickLook.soft).listRowSeparator(.hidden)
                    }
                    if !filtering, !recent.isEmpty {
                        Section { ForEach(recent) { row($0) } } header: { header("Recent Exercises") }
                    }
                    Section {
                        ForEach(all) { row($0) }
                        if filtering, all.isEmpty {
                            Button { creating = true } label: {
                                Label("Create \"\(search.isEmpty ? "exercise" : search)\"", systemImage: "plus")
                            }
                            .listRowSeparator(.hidden)
                        }
                    } header: {
                        header(filtering ? "Results" : "All Exercises")
                    }
                }
                .listStyle(.plain)
                .listRowSeparatorTint(BrickLook.line)
                .scrollContentBackground(.hidden)
                .scrollDismissesKeyboard(.immediately)
                .contentMargins(.bottom, picked.isEmpty ? 0 : 90, for: .scrollContent)
            }
            .overlay(alignment: .bottom) { addButton }
            .hubPageStyle()
            .presentationBackground { AmbientBackdrop() }
            .navigationTitle(replacing ? "Replace Exercise" : "Add Exercise")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Create") { creating = true } }
            }
            .navigationDestination(for: ExerciseRoute.self) { ExerciseDetailPage(route: $0, store: store) }
            .navigationDestination(for: WorkoutRoute.self) { WorkoutDetailPage(id: $0.id, store: store) }
            .sheet(isPresented: $creating) {
                NewExerciseSheet(store: store, name: search) { picked.append($0) }
            }
        }
    }

    private var filters: some View {
        VStack(spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(BrickLook.soft)
                TextField("Search exercise", text: $search)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                if !search.isEmpty {
                    Button { search = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(BrickLook.soft) }
                        .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 14)
            .frame(height: 44)
            .background(BrickLook.card, in: .capsule)
            HStack(spacing: 12) {
                filterMenu(title: equipment.map(WorkoutFormat.label) ?? "All Equipment", selection: $equipment, options: Self.equipmentKinds, all: "All Equipment")
                filterMenu(title: muscle.map(WorkoutFormat.label) ?? "All Muscles", selection: $muscle, options: Self.muscles, all: "All Muscles")
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    private func filterMenu(title: String, selection: Binding<String?>, options: [String], all: String) -> some View {
        Menu {
            Picker(all, selection: selection) {
                Text(all).tag(String?.none)
                ForEach(options, id: \.self) { Text(WorkoutFormat.label($0)).tag(String?.some($0)) }
            }
        } label: {
            Text(title)
                .font(.body.weight(.medium))
                .foregroundStyle(selection.wrappedValue == nil ? BrickLook.ink : BrickLook.page)
                .lineLimit(1)
                .frame(maxWidth: .infinity)
                .frame(height: 44)
                .background(selection.wrappedValue == nil ? BrickLook.card : BrickLook.bar, in: .capsule)
        }
    }

    private func header(_ title: String) -> some View {
        BrickCaps(text: title).foregroundStyle(BrickLook.soft)
    }

    private func row(_ exercise: Exercise) -> some View {
        let order = picked.firstIndex(of: exercise)
        return HStack(spacing: 14) {
            Button {
                if replacing {
                    onPick([exercise])
                    dismiss()
                } else if let order { picked.remove(at: order) } else { picked.append(exercise) }
            } label: {
                HStack(spacing: 14) {
                    ExerciseThumb(exerciseId: exercise.id, muscle: exercise.muscle, size: 56)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(exercise.name).font(.body).foregroundStyle(BrickLook.ink).lineLimit(2)
                        Text(exercise.custom ? "\(exercise.muscleName) · Custom" : exercise.muscleName)
                            .font(.subheadline).foregroundStyle(BrickLook.soft)
                    }
                    Spacer(minLength: 4)
                    if let order {
                        Text("\(order + 1)").font(.caption.weight(.bold)).foregroundStyle(BrickLook.page)
                            .frame(width: 24, height: 24).background(BrickLook.bar, in: .circle)
                    }
                }
                .contentShape(.rect)
            }
            .buttonStyle(.borderless)
            Button { path.append(ExerciseRoute(exercise)) } label: {
                Image(systemName: "info")
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(BrickLook.soft)
                    .frame(width: 30, height: 30)
                    .background(BrickLook.card, in: .circle)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("About \(exercise.name)")
        }
        .padding(.vertical, 4)
        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
        .listRowBackground(
            HStack(spacing: 0) {
                Rectangle().fill(order == nil ? Color.clear : BrickLook.bar).frame(width: 4)
                Rectangle().fill(order == nil ? Color.clear : BrickLook.card)
            }
        )
    }

    @ViewBuilder private var addButton: some View {
        if !picked.isEmpty {
            Button {
                onPick(picked)
                dismiss()
            } label: {
                Text(picked.count == 1 ? "Add exercise" : "Add \(picked.count) exercises")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(BrickLook.page)
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
                    .background(BrickLook.bar, in: .rect(cornerRadius: 18, style: .continuous))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
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
                Group {
                TextField("Name", text: $name)
                Picker("Muscle", selection: $muscle) {
                    ForEach(ExercisePicker.muscles, id: \.self) { Text(WorkoutFormat.label($0)).tag($0) }
                }
                Picker("Equipment", selection: $equipment) {
                    ForEach(ExercisePicker.equipmentKinds, id: \.self) {
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
                .listRowBackground(BrickLook.card)
            }
            .brickList()
            .navigationTitle("New exercise")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save() } }
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || saving)
                }
            }
        }
        .presentationBackground { AmbientBackdrop() }
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
