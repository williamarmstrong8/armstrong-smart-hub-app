import Charts
import SwiftUI

/// A logged workout with heart rate mapped onto every set: the curve with each
/// set marked, then each set's average, peak, recovery and rest.
struct WorkoutDetailPage: View {
    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    @AppStorage("workouts.unit") private var unit: WeightUnit = .localDefault
    var id: String
    var store: WorkoutStore
    @State private var detail: WorkoutDetail?
    @State private var loading = true
    @State private var confirmDelete = false
    @State private var routineDraft: Routine?

    var body: some View {
        ScrollView {
            Group {
                if let detail {
                    content(detail)
                } else if loading {
                    ProgressView().padding(.top, 80)
                } else {
                    MessageView(title: "Couldn't load this workout", systemImage: "exclamationmark.triangle",
                                actionTitle: "Retry") { Task { await load(refresh: true) } }
                }
            }
            .frame(maxWidth: .infinity)
        }
        // Fill the screen from the first frame: a page still loading would otherwise
        // shrink to its content, showing the background as a strip that then grows.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(BrickLook.page.ignoresSafeArea())
        .foregroundStyle(BrickLook.ink)
        .tint(BrickLook.ink)
        .navigationTitle(detail?.name ?? "Workout")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(BrickLook.page, for: .navigationBar)
        .toolbar {
            if let detail {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button { routineDraft = routine(from: detail) } label: { Label("Save as routine", systemImage: "list.bullet.rectangle") }
                        Button(role: .destructive) { confirmDelete = true } label: { Label("Delete workout", systemImage: "trash") }
                    } label: { Image(systemName: "ellipsis") }
                }
            }
        }
        .confirmationDialog("Delete this workout?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                Task {
                    await store.delete(id, api: session.api)
                    dismiss()
                }
            }
        }
        .sheet(item: $routineDraft) { RoutineEditor(store: store, routine: $0) }
        .task { await load() }
        .refreshable { await load(refresh: true) }
    }

    private func load(refresh: Bool = false) async {
        if detail == nil { detail = store.cachedDetail(id) }
        loading = true
        detail = await store.detail(id, api: session.api, refresh: refresh || detail == nil)
        loading = false
    }

    private func content(_ detail: WorkoutDetail) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(spacing: 6) {
                Text(detail.name).font(.system(size: 26, weight: .regular)).multilineTextAlignment(.center)
                if let start = detail.start {
                    BrickCaps(text: start.formatted(.dateTime.weekday(.wide).month(.abbreviated).day().hour().minute()))
                        .foregroundStyle(BrickLook.soft)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.bottom, 18)

            BrickCard(padding: 20) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .leading), count: 3), spacing: 18) {
                stat("Duration", FitnessFormat.duration(duration(detail)))
                stat("Volume", WorkoutFormat.volume(detail.volumeKg, unit: unit))
                stat("Sets", "\(detail.exercises.flatMap(\.sets).filter { $0.kind != "warmup" }.count)")
                stat("Avg HR", detail.avgHr.map { "\($0)" } ?? "–")
                stat("Max HR", detail.maxHr.map { "\($0)" } ?? "–")
                stat("PRs", "\(detail.exercises.flatMap(\.sets).filter(\.pr).count)")
            }
            }
            .padding(.bottom, 28)

            FitSection(title: "Heart rate", trailing: source(detail)) {
                if detail.points.isEmpty {
                    Takeaway(text: "No heart rate for this workout. Keep the watch connected while logging, or start a Strength activity on it, and each set gets its own numbers.")
                } else {
                    chart(detail)
                }
            }

            SessionFeedbackSection(kind: "workout", id: detail.id)

            if let notes = detail.notes, !notes.isEmpty {
                FitSection(title: "Notes") { Takeaway(text: notes) }
            }

            ForEach(detail.exercises) { group in
                FitSection(title: nil) {
                    NavigationLink(value: ExerciseRoute(id: group.exerciseId, name: group.name, store: store)) {
                        HStack(spacing: 12) {
                            ExerciseThumb(exerciseId: group.exerciseId, muscle: store.exercise(group.exerciseId)?.muscle, size: 44)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(group.name).font(.system(size: 20, weight: .regular)).foregroundStyle(BrickLook.ink).multilineTextAlignment(.leading)
                                if group.superset != nil { Text("Superset").font(.caption).foregroundStyle(Fit.health) }
                            }
                            Spacer(minLength: 8)
                            Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(BrickLook.soft)
                        }
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    VStack(spacing: 12) {
                        ForEach(Array(group.sets.enumerated()), id: \.offset) { index, set in
                            setRow(set, label: label(index, group.sets))
                        }
                    }
                }
            }
        }
        .padding(.horizontal, Fit.gutter)
        .padding(.vertical, 16)
    }

    private func duration(_ detail: WorkoutDetail) -> Double? {
        guard let a = detail.start, let b = detail.end else { return nil }
        return b.timeIntervalSince(a)
    }

    private func source(_ detail: WorkoutDetail) -> String? {
        switch detail.hrSource {
        case "activity": "From the watch's recording"
        case "live": "From the live stream"
        default: nil
        }
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            BrickCaps(text: label).foregroundStyle(BrickLook.soft)
            Text(value).font(.system(size: 24, weight: .light)).monospacedDigit()
        }
    }

    /// The curve in minutes from the start, with a mark where each set ended.
    private func chart(_ detail: WorkoutDetail) -> some View {
        let start = detail.start ?? .now
        let marks = detail.exercises.flatMap(\.sets).compactMap { set -> (Double, Bool)? in
            guard let done = set.completed else { return nil }
            return (done.timeIntervalSince(start) / 60, set.kind == "warmup")
        }
        return Chart {
            ForEach(Array(detail.points.enumerated()), id: \.offset) { _, point in
                LineMark(x: .value("Minute", point.0 / 60), y: .value("bpm", point.1))
                    .foregroundStyle(Fit.heart)
                    .interpolationMethod(.monotone)
            }
            ForEach(Array(marks.enumerated()), id: \.offset) { _, mark in
                RuleMark(x: .value("Set", mark.0))
                    .foregroundStyle(mark.1 ? BrickLook.soft.opacity(0.5) : BrickLook.bar.opacity(0.55))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: mark.1 ? [2, 3] : []))
            }
        }
        .chartYScale(domain: .automatic(includesZero: false))
        .chartXAxis {
            AxisMarks { value in
                AxisGridLine().foregroundStyle(BrickLook.line)
                AxisValueLabel { if let m = value.as(Double.self) { Text("\(Int(m))m") } }
            }
        }
        .chartYAxis { AxisMarks(position: .trailing) { _ in AxisGridLine().foregroundStyle(BrickLook.line); AxisValueLabel() } }
        .font(Fit.axis)
        .frame(height: 180)
    }

    private func label(_ index: Int, _ sets: [WorkoutDetail.LoggedSet]) -> String {
        if let badge = SetKind(rawValue: sets[index].kind)?.badge { return badge }
        return "\(sets[..<index].filter { $0.kind != "warmup" }.count + 1)"
    }

    private func setRow(_ set: WorkoutDetail.LoggedSet, label: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label).font(.subheadline.weight(.semibold)).monospacedDigit()
                .foregroundStyle(set.kind == "warmup" ? Fit.fair : .primary)
                .frame(width: 22, alignment: .leading)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(load(set)).font(.body).monospacedDigit()
                    if set.pr { Image(systemName: "trophy.fill").font(.caption).foregroundStyle(Fit.fair) }
                }
                if let e1rm = set.e1rmKg, set.kind != "warmup" {
                    Text("Est. 1RM \(unit.text(e1rm)) \(unit.rawValue)").font(.caption).foregroundStyle(BrickLook.soft)
                }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 3) {
                if let peak = set.peakHr ?? set.endHr {
                    HStack(spacing: 4) {
                        Image(systemName: "heart.fill").font(.caption2).foregroundStyle(Fit.heart)
                        Text(set.avgHr.map { "\($0) avg · \(peak) peak" } ?? "\(peak)").monospacedDigit()
                    }
                    .font(.subheadline)
                }
                HStack(spacing: 8) {
                    if let drop = set.recoveryBpm, drop > 0 { Text("↓\(drop) in 1m") }
                    if let rest = set.restSeconds { Text("rest \(WorkoutFormat.clock(TimeInterval(rest)))") }
                }
                .font(.caption).foregroundStyle(BrickLook.soft).monospacedDigit()
            }
        }
    }

    private func load(_ set: WorkoutDetail.LoggedSet) -> String {
        if let seconds = set.durationSeconds { return WorkoutFormat.clock(seconds) }
        switch (set.weightKg, set.reps) {
        case let (w?, r?) where w > 0: return "\(unit.text(w)) \(unit.rawValue) × \(r)"
        case let (_, r?): return "\(r) reps"
        default: return "–"
        }
    }

    private func routine(from detail: WorkoutDetail) -> Routine {
        Routine(id: UUID().uuidString.lowercased(), name: detail.name, position: store.routines.count,
                exercises: detail.exercises.map { group in
                    Routine.Item(exerciseId: group.exerciseId, name: group.name, restSeconds: nil, superset: group.superset,
                                 sets: group.sets.map { Routine.Target(kind: $0.kind, weightKg: $0.weightKg, reps: $0.reps) })
                })
    }
}
