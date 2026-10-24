import SwiftUI

/// Opens a logged workout from a NavigationLink.
struct WorkoutRoute: Hashable {
    var id: String
}

/// The Fitness tab's Workouts section: resume, or the routines (swipe
/// through them) and Start Empty Workout, straight on the page; then the
/// last workout on its own card. Routines and history open from the button
/// at the bottom of the page (RoutinesAndHistoryButton).
struct WorkoutsSection: View {
    var store: WorkoutStore
    var onStart: (Routine?) -> Void
    var onResume: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            start
            if let last = store.workouts.first {
                LastWorkoutCard(store: store, workout: last)
            }
        }
    }

    private var start: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let active = store.active {
                Button(action: onResume) {
                    HStack(spacing: 14) {
                        Image(systemName: "figure.strengthtraining.traditional").font(.title2).foregroundStyle(Fit.action).frame(width: 32)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(active.name).font(.system(size: 20))
                            TimelineView(.periodic(from: active.startedAt, by: 1)) { context in
                                Text("In progress · \(WorkoutFormat.clock(context.date.timeIntervalSince(active.startedAt))) · \(WorkoutFormat.volume(active.volumeKg, unit: active.unit))")
                                    .font(.footnote).foregroundStyle(Fit.muted).monospacedDigit()
                            }
                        }
                        Spacer()
                        Text("Resume").font(.subheadline.weight(.semibold)).foregroundStyle(Fit.action)
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
            } else {
                if !store.routines.isEmpty {
                    RoutineCarousel(store: store, onStart: onStart)
                    FitDivider()
                }
                Button { onStart(nil) } label: {
                    Label("Start Empty Workout", systemImage: "plus").blueButton()
                }
                .buttonStyle(.plain)
            }
            if let error = store.error, store.home == nil || !store.pending.isEmpty {
                Text(error).font(.footnote).foregroundStyle(Fit.attention)
            }
        }
        .padding(.bottom, 36)
    }
}

/// Every routine, one per page, swiped sideways with no end: the list
/// repeats, and it opens in the middle so it goes both ways.
struct RoutineCarousel: View {
    var store: WorkoutStore
    var onStart: (Routine?) -> Void
    @State private var position: Int?
    /// How many times the routines repeat; enough that nobody swipes to an end,
    /// few enough that the lazy stack doesn't have to estimate thousands of pages.
    private static let laps = 40

    var body: some View {
        let routines = store.routines
        if routines.count == 1, let only = routines.first {
            card(only)
        } else if !routines.isEmpty {
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: Fit.gutter * 2) {
                    ForEach(0..<routines.count * Self.laps, id: \.self) { index in
                        card(routines[index % routines.count])
                            .containerRelativeFrame(.horizontal)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollIndicators(.hidden)
            .scrollTargetBehavior(.viewAligned)
            .scrollPosition(id: $position)
            // The next routine slides in from the screen's edge, not the gutter.
            .scrollClipDisabled()
            .onAppear { if position == nil { position = Self.middle(routines.count) } }
            .onChange(of: routines.count) { _, count in position = Self.middle(count) }
        }
    }

    private func card(_ routine: Routine) -> some View {
        RoutineCard(store: store, routine: routine, canStart: true, onStart: { onStart(routine) })
    }

    /// The first routine, halfway along.
    private static func middle(_ count: Int) -> Int { count * (laps / 2) }
}

/// The newest workout at a glance: its kind's icon, name and day, three numbers, its volume
/// against the workouts before it, and what was in it. Opens the workout.
struct LastWorkoutCard: View {
    @AppStorage("workouts.unit") private var unit: WeightUnit = .localDefault
    var store: WorkoutStore
    var workout: WorkoutSummary

    var body: some View {
        FitSection(title: "Last workout", trailing: store.pending.isEmpty ? nil : "\(store.pending.count) waiting to upload") {
            NavigationLink(value: WorkoutRoute(id: workout.id)) {
                VStack(alignment: .leading, spacing: 20) {
                    HStack(alignment: .center, spacing: 14) {
                        TablerIcon(name: WorkoutFormat.icon(name: workout.name), size: 24)
                            .foregroundStyle(Fit.action)
                            .frame(width: 48, height: 48)
                            .background(Fit.action.opacity(0.14), in: .circle)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(workout.name).font(.system(size: 22, weight: .regular)).lineLimit(1)
                            if let start = workout.start {
                                Text(start.formatted(.relative(presentation: .named)).capitalizedFirst)
                                    .font(.subheadline).foregroundStyle(BrickLook.soft)
                            }
                        }
                        Spacer(minLength: 8)
                        Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(Fit.faint)
                    }
                    HStack(alignment: .top, spacing: 12) {
                        stat(FitnessFormat.duration(workout.duration), "Time")
                        stat(WorkoutFormat.volumeNumber(workout.volumeKg, unit: unit), "Volume (\(unit.rawValue))")
                        stat(workout.avgHr.map(String.init) ?? "–", "Avg HR", tint: workout.avgHr == nil ? nil : Fit.heart)
                    }
                    volumeBars
                    if !workout.exercises.isEmpty {
                        Text(workout.exercises.joined(separator: " · "))
                            .font(.footnote).foregroundStyle(BrickLook.soft).lineLimit(2)
                    }
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
        }
    }

    private func stat(_ value: String, _ label: String, tint: Color? = nil) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value).font(Fit.value).foregroundStyle(tint ?? BrickLook.ink).lineLimit(1).minimumScaleFactor(0.6)
            Text(label).font(.caption).foregroundStyle(BrickLook.soft)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Volume of the last few workouts, oldest first, this one in blue.
    @ViewBuilder private var volumeBars: some View {
        let recent = Array(store.workouts.prefix(8).reversed())
        let top = recent.map(\.volumeKg).max() ?? 0
        if recent.count > 1, top > 0 {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .bottom, spacing: 6) {
                    ForEach(recent) { item in
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(item.id == workout.id ? Fit.action : BrickLook.track)
                            .frame(height: max(4, 56 * item.volumeKg / top))
                            .frame(maxWidth: .infinity)
                    }
                }
                .frame(height: 56, alignment: .bottom)
                Text("Volume, last \(recent.count) workouts").font(.caption).foregroundStyle(BrickLook.soft)
            }
        }
    }
}

/// Every routine and the full workout history, at the bottom of the Fitness page.
struct RoutinesAndHistoryButton: View {
    var store: WorkoutStore
    var onStart: (Routine?) -> Void

    var body: some View {
        NavigationLink { WorkoutsPage(store: store, onStart: onStart) } label: {
            Label("Routines and history", systemImage: "list.bullet").blueButton()
        }
        .buttonStyle(.plain)
    }
}

private extension String {
    /// "Yesterday", not "yesterday".
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}

extension Label where Title == Text, Icon == Image {
    /// A full-width button in the Start Routine blue, tinted rather than filled
    /// so the routines' own Start buttons stay the strongest thing on the page.
    func blueButton() -> some View {
        font(.body.weight(.semibold))
            .foregroundStyle(Fit.action)
            .frame(maxWidth: .infinity)
            .frame(height: 46)
            .background(Fit.action.opacity(0.14), in: .rect(cornerRadius: 12, style: .continuous))
    }
}

/// A routine as Hevy shows it: name and menu, its exercises, and Start Routine,
/// flat on whatever it sits on (callers put hairlines between). Tapping it opens the editor.
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
                    .background(canStart ? Fit.action : Fit.faint, in: .rect(cornerRadius: 10))
            }
            .buttonStyle(.plain)
            .disabled(!canStart)
        }
        .padding(.vertical, 4)
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
            TablerIcon(name: WorkoutFormat.icon(name: workout.name), size: 24).foregroundStyle(Fit.muted).frame(width: 32)
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
                              systemImage: store.active == nil ? "plus" : "play.fill").blueButton()
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
                        FitDivider()
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
                                if workout.id != store.workouts.last?.id { FitDivider() }
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
        .environment(\.fitnessCards, true)
        .background(BrickLook.page.ignoresSafeArea())
        .foregroundStyle(BrickLook.ink)
        .navigationTitle("Workouts")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await store.load(api: session.api) }
        .sheet(isPresented: $creating) { RoutineEditor(store: store) }
    }
}
