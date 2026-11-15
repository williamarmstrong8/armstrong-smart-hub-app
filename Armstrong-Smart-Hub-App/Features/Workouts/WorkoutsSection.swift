import SwiftUI

/// Opens a logged workout from a NavigationLink.
struct WorkoutRoute: Hashable {
    var id: String
}

/// The Fitness tab's Workouts section: resume, or the routines (swipe
/// through them) and Start Empty Workout, then the last workout, all
/// straight on the page. Routines and history open from the button
/// at the bottom of the page (RoutinesAndHistoryButton).
struct WorkoutsSection: View {
    var store: WorkoutStore
    var onStart: (Routine?) -> Void
    var onResume: () -> Void

    var body: some View {
        VStack(spacing: HubLayout.sectionGap) {
            BrickCard { start }
            if let last = store.workouts.first {
                LastWorkoutCard(store: store, workout: last)
            }
            RoutinesAndHistoryButton(store: store, onStart: onStart)
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

/// The newest workout at a glance: what kind of session it was, where and when,
/// a bar of the muscles it worked, and three plain numbers. Opens the workout.
struct LastWorkoutCard: View {
    @AppStorage("workouts.unit") private var unit: WeightUnit = .localDefault
    var store: WorkoutStore
    var workout: WorkoutSummary
    @State private var places = WorkoutPlaces.shared

    var body: some View {
        let muscles = workout.exercises.compactMap { name in store.exercises.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.muscle }
        let type = WorkoutType.classify(name: workout.name, muscles: muscles)
        let place = places.place(workout.id)
        BrickCard {
            NavigationLink(value: WorkoutRoute(id: workout.id)) {
                VStack(alignment: .leading, spacing: 20) {
                    HStack(alignment: .center, spacing: 14) {
                        Image(systemName: type.symbol).font(.system(size: 22, weight: .medium)).foregroundStyle(BrickLook.ink)
                            .frame(width: 52, height: 52)
                            .glassGlare(.regular, in: .circle)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(type.title).font(.system(size: 24, weight: .regular)).foregroundStyle(BrickLook.ink).lineLimit(1)
                            Text(subtitle(type, place)).font(.subheadline).foregroundStyle(BrickLook.soft).lineLimit(1)
                        }
                        Spacer(minLength: 8)
                        Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(Fit.faint)
                    }
                    if !muscles.isEmpty { MuscleSplit(muscles: muscles) }
                    HStack(spacing: 12) {
                        stat(FitnessFormat.duration(workout.duration), "Time")
                        stat(WorkoutFormat.volumeNumber(workout.volumeKg, unit: unit), "Volume (\(unit.rawValue))")
                        stat("\(workout.sets)", "Sets")
                    }
                    if !store.pending.isEmpty {
                        Text("\(store.pending.count) waiting to upload").font(.footnote).foregroundStyle(BrickLook.soft)
                    }
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
        }
    }

    /// "Upper A · Yesterday · Equinox": the routine's name only when the type doesn't already say it.
    private func subtitle(_ type: WorkoutType, _ place: WorkoutPlace?) -> String {
        let named = workout.name.lowercased().contains(type.title.lowercased()) || workout.name.hasSuffix(" workout")
        return [named ? nil : workout.name,
                workout.start.map { $0.formatted(.relative(presentation: .named)).capitalizedFirst },
                place?.name].compactMap { $0 }.joined(separator: " · ")
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value).font(Fit.value).foregroundStyle(BrickLook.ink).lineLimit(1).minimumScaleFactor(0.6)
            Text(label).font(.caption).foregroundStyle(BrickLook.soft)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The muscles a workout worked, as one bar split by exercise count, biggest first, with a short key under it.
struct MuscleSplit: View {
    var muscles: [String]

    var body: some View {
        let counts = Dictionary(grouping: muscles, by: { $0 }).mapValues(\.count)
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
        let top = Array(counts.prefix(4))
        let rest = counts.dropFirst(4).reduce(0) { $0 + $1.value }
        let parts = top.map { (WorkoutFormat.label($0.key), $0.value) } + (rest > 0 ? [("Other", rest)] : [])
        let total = Double(muscles.count)
        VStack(alignment: .leading, spacing: 10) {
            GeometryReader { geo in
                HStack(spacing: 3) {
                    ForEach(Array(parts.enumerated()), id: \.offset) { index, part in
                        Capsule().fill(Self.shade(index))
                            .frame(width: max(8, (geo.size.width - CGFloat(parts.count - 1) * 3) * Double(part.1) / total))
                    }
                }
            }
            .frame(height: 12)
            HStack(spacing: 12) {
                ForEach(Array(parts.enumerated()), id: \.offset) { index, part in
                    HStack(spacing: 5) {
                        Circle().fill(Self.shade(index)).frame(width: 8, height: 8)
                        Text(part.0).font(.caption).foregroundStyle(BrickLook.soft).lineLimit(1)
                    }
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Muscles: " + parts.map { "\($0.0) \($0.1)" }.joined(separator: ", "))
    }

    /// One blue, lighter for each smaller share.
    static func shade(_ index: Int) -> Color { Fit.action.opacity([1, 0.7, 0.48, 0.32, 0.2][min(index, 4)]) }
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
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 46)
            .glassGlare(.regular.tint(Fit.action.opacity(0.35)), in: .rect(cornerRadius: 12, style: .continuous))
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
                    .glassGlare(.regular.tint((canStart ? Fit.action : Fit.faint).opacity(0.7)).interactive(canStart), in: .rect(cornerRadius: 12, style: .continuous))
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
                FitSection(title: "Routines", trailing: store.routines.isEmpty ? nil : "\(store.routines.count)", divider: false) {
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
            .frame(maxWidth: .infinity)
        }
        // Fill the screen from the first frame: a page still loading would otherwise
        // shrink to its content, showing the background as a strip that then grows.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .hubPageStyle()
        .environment(\.fitnessCards, true)
        .navigationTitle("Workouts")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await store.load(api: session.api) }
        .sheet(isPresented: $creating) { RoutineEditor(store: store) }
    }
}
