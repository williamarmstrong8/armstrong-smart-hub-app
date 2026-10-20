import SwiftUI

/// Opens a logged workout from a NavigationLink.
struct WorkoutRoute: Hashable {
    var id: String
}

/// The Fitness tab's Workouts section: resume or start a workout, routines, and recent workouts.
struct WorkoutsSection: View {
    var store: WorkoutStore
    var onStart: (Routine?) -> Void
    var onResume: () -> Void

    var body: some View {
        FitSection(title: "Workouts", trailing: store.pending.isEmpty ? nil : "\(store.pending.count) waiting to upload") {
            if let active = store.active {
                Button(action: onResume) {
                    HStack(spacing: 14) {
                        Image(systemName: "figure.strengthtraining.traditional").font(.title2).foregroundStyle(Fit.energy).frame(width: 32)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(active.name).font(.system(size: 20))
                            TimelineView(.periodic(from: active.startedAt, by: 1)) { context in
                                Text("In progress · \(WorkoutFormat.clock(context.date.timeIntervalSince(active.startedAt))) · \(WorkoutFormat.volume(active.volumeKg, unit: active.unit))")
                                    .font(.footnote).foregroundStyle(Fit.muted).monospacedDigit()
                            }
                        }
                        Spacer()
                        Text("Resume").font(.subheadline.weight(.semibold)).foregroundStyle(Fit.energy)
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
            } else {
                Button { onStart(nil) } label: {
                    Label("Start Empty Workout", systemImage: "plus").greyButton(.primary)
                }
                .buttonStyle(.plain)
                ForEach(store.routines.prefix(3)) { routine in
                    RoutineCard(store: store, routine: routine, canStart: true, onStart: { onStart(routine) })
                }
            }
            if let error = store.error, store.home == nil || !store.pending.isEmpty {
                Text(error).font(.footnote).foregroundStyle(Fit.attention)
            }
            VStack(spacing: 0) {
                ForEach(store.workouts.prefix(3)) { workout in
                    NavigationLink(value: WorkoutRoute(id: workout.id)) { WorkoutRow(workout: workout) }.buttonStyle(.plain)
                    Rectangle().fill(Fit.hairline).frame(height: 1)
                }
                NavigationLink { WorkoutsPage(store: store, onStart: onStart) } label: {
                    LinkRow(title: store.routines.count > 3 ? "All \(store.routines.count) routines and history" : "Routines and history",
                            subtitle: store.routines.isEmpty ? "Build a routine to start from" : nil)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// A routine as Hevy shows it: name and menu, its exercises, and Start Routine.
/// Tapping the card opens the editor.
struct RoutineCard: View {
    @Environment(AppSession.self) private var session
    var store: WorkoutStore
    var routine: Routine
    var canStart: Bool
    var onStart: () -> Void
    @State private var editing = false
    @State private var confirmDelete = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(routine.name).font(.headline).lineLimit(1)
                Spacer(minLength: 8)
                Menu {
                    Button("Edit Routine", systemImage: "pencil") { editing = true }
                    Button("Delete Routine", systemImage: "trash", role: .destructive) { confirmDelete = true }
                } label: {
                    Image(systemName: "ellipsis").font(.body.weight(.bold))
                        .frame(width: 32, height: 24).contentShape(.rect)
                }
                .foregroundStyle(.primary)
            }
            Text(summary).font(.subheadline).foregroundStyle(Fit.muted).lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: onStart) {
                Text("Start Routine")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 42)
                    .background(canStart ? Fit.energy : Fit.faint, in: .rect(cornerRadius: 10))
            }
            .buttonStyle(.plain)
            .disabled(!canStart)
        }
        .padding(14)
        .background(Fit.track.opacity(0.5), in: .rect(cornerRadius: 14))
        .contentShape(.rect)
        .onTapGesture { editing = true }
        .sheet(isPresented: $editing) { RoutineEditor(store: store, routine: routine) }
        .confirmationDialog("Delete \(routine.name)?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete routine", role: .destructive) { Task { await store.deleteRoutine(routine.id, api: session.api) } }
        }
    }

    /// "Bench Press, Squat, Row · 9 sets".
    private var summary: String {
        let names = routine.exercises.map(\.name).joined(separator: ", ")
        let sets = routine.exercises.reduce(0) { $0 + $1.sets.count }
        return names.isEmpty ? "No exercises" : "\(names) · \(sets) sets"
    }
}

struct WorkoutRow: View {
    @AppStorage("workouts.unit") private var unit: WeightUnit = .localDefault
    var workout: WorkoutSummary

    var body: some View {
        HStack(spacing: 14) {
            TablerIcon(name: "barbell", size: 24).foregroundStyle(Fit.muted).frame(width: 32)
            VStack(alignment: .leading, spacing: 3) {
                Text(workout.name).font(.subheadline.weight(.medium))
                Text(subtitle).font(.caption).foregroundStyle(Fit.muted).lineLimit(1)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 3) {
                Text(WorkoutFormat.volume(workout.volumeKg, unit: unit)).font(.subheadline).monospacedDigit()
                if let hr = workout.avgHr {
                    Label("\(hr)", systemImage: "heart.fill").font(.caption).foregroundStyle(Fit.heart).monospacedDigit()
                }
            }
        }
        .padding(.vertical, 12)
        .contentShape(.rect)
    }

    private var subtitle: String {
        var parts: [String] = []
        if let start = workout.start { parts.append(start.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())) }
        if let duration = workout.duration { parts.append(FitnessFormat.duration(duration)) }
        parts.append("\(workout.sets) sets")
        return parts.joined(separator: " · ")
    }
}

/// Every routine (start, edit, delete) and every logged workout, on the
/// Fitness tab's plain page.
struct WorkoutsPage: View {
    @Environment(AppSession.self) private var session
    @AppStorage("workouts.unit") private var unit: WeightUnit = .localDefault
    var store: WorkoutStore
    var onStart: (Routine?) -> Void
    @State private var creating = false

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                FitSection(title: "Quick Start", divider: false) {
                    Button { onStart(nil) } label: {
                        Label(store.active == nil ? "Start Empty Workout" : "Resume Workout",
                              systemImage: store.active == nil ? "plus" : "play.fill").greyButton(.primary)
                    }
                    .buttonStyle(.plain)
                }

                FitSection(title: "Routines", trailing: store.routines.isEmpty ? nil : "\(store.routines.count)") {
                    Button { creating = true } label: {
                        Label("New Routine", systemImage: "doc.badge.plus").greyButton(.primary)
                    }
                    .buttonStyle(.plain)
                    if store.routines.isEmpty {
                        Takeaway(text: "A routine is a list of exercises with their sets, so you can start the same workout again in one tap.")
                    }
                    ForEach(store.routines) { routine in
                        RoutineCard(store: store, routine: routine, canStart: store.active == nil, onStart: { onStart(routine) })
                    }
                }

                FitSection(title: "History", trailing: store.workouts.isEmpty ? nil : "\(store.workouts.count) workouts") {
                    if store.workouts.isEmpty {
                        Takeaway(text: "Finished workouts show here.")
                    } else {
                        VStack(spacing: 0) {
                            ForEach(store.workouts) { workout in
                                NavigationLink(value: WorkoutRoute(id: workout.id)) { WorkoutRow(workout: workout) }.buttonStyle(.plain)
                                if workout.id != store.workouts.last?.id { Rectangle().fill(Fit.hairline).frame(height: 1) }
                            }
                        }
                    }
                }

                FitSection(title: "Settings") {
                    HStack {
                        Text("Weight unit").font(.subheadline)
                        Spacer()
                        Picker("Weight unit", selection: $unit) {
                            ForEach(WeightUnit.allCases) { Text($0 == .lb ? "lbs" : "kg").tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .fixedSize()
                    }
                    Takeaway(text: "Weights are stored in kilograms on the hub and shown in this unit.")
                }
            }
            .padding(.horizontal, Fit.gutter)
            .padding(.bottom, 40)
        }
        .background(Color(.systemBackground))
        .navigationTitle("Workouts")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await store.load(api: session.api) }
        .sheet(isPresented: $creating) { RoutineEditor(store: store) }
    }
}
