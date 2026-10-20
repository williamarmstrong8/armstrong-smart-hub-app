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
                        Image(systemName: "figure.strengthtraining.traditional").font(.title2).foregroundStyle(Fit.positive).frame(width: 32)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(active.name).font(.system(size: 20))
                            TimelineView(.periodic(from: active.startedAt, by: 1)) { context in
                                Text("In progress · \(WorkoutFormat.clock(context.date.timeIntervalSince(active.startedAt))) · \(active.completedSets.count) sets")
                                    .font(.footnote).foregroundStyle(Fit.muted).monospacedDigit()
                            }
                        }
                        Spacer()
                        Text("Resume").font(.subheadline.weight(.semibold)).foregroundStyle(Fit.positive)
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
            } else {
                Button { onStart(nil) } label: {
                    Label("Start empty workout", systemImage: "plus").font(.body.weight(.semibold)).frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(Fit.positive)
                if !store.routines.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(store.routines) { routine in
                                Button { onStart(routine) } label: { RoutineChip(routine: routine) }.buttonStyle(.plain)
                            }
                        }
                    }
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
                    LinkRow(title: "Routines and history", subtitle: store.workouts.isEmpty ? "Build a routine to start from" : nil)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

private struct RoutineChip: View {
    var routine: Routine

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(routine.name).font(.subheadline.weight(.semibold)).lineLimit(1)
            Text(routine.exercises.map(\.name).joined(separator: ", ")).font(.caption).foregroundStyle(Fit.muted).lineLimit(2)
        }
        .frame(width: 160, height: 64, alignment: .topLeading)
        .padding(12)
        .background(Fit.track.opacity(0.6), in: .rect(cornerRadius: 12))
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

/// Every routine (start, edit, delete) and every logged workout.
struct WorkoutsPage: View {
    @Environment(AppSession.self) private var session
    @AppStorage("workouts.unit") private var unit: WeightUnit = .localDefault
    var store: WorkoutStore
    var onStart: (Routine?) -> Void
    @State private var editing: Routine?
    @State private var creating = false

    var body: some View {
        List {
            Section {
                ForEach(store.routines) { routine in
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(routine.name).font(.body.weight(.medium))
                            Text(routine.exercises.map(\.name).joined(separator: ", ")).font(.caption).foregroundStyle(Fit.muted).lineLimit(2)
                        }
                        Spacer()
                        Button("Start") { onStart(routine) }
                            .buttonStyle(.bordered).tint(Fit.positive)
                            .disabled(store.active != nil)
                    }
                    .contentShape(.rect)
                    .onTapGesture { editing = routine }
                    .swipeActions {
                        Button("Delete", role: .destructive) { Task { await store.deleteRoutine(routine.id, api: session.api) } }
                    }
                }
                Button { creating = true } label: { Label("New routine", systemImage: "plus") }
            } header: {
                Text("Routines")
            }

            Section("History") {
                if store.workouts.isEmpty {
                    Text("Finished workouts show here.").foregroundStyle(.secondary)
                }
                ForEach(store.workouts) { workout in
                    NavigationLink(value: WorkoutRoute(id: workout.id)) { WorkoutRow(workout: workout) }
                }
            }

            Section {
                Picker("Weight unit", selection: $unit) {
                    ForEach(WeightUnit.allCases) { Text($0.rawValue).tag($0) }
                }
            } footer: {
                Text("Weights are stored in kilograms on the hub and shown in this unit.")
            }
        }
        .navigationTitle("Workouts")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await store.load(api: session.api) }
        .sheet(item: $editing) { RoutineEditor(store: store, routine: $0) }
        .sheet(isPresented: $creating) { RoutineEditor(store: store) }
    }
}
