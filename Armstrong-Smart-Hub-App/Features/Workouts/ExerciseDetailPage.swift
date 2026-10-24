import Charts
import SwiftUI

/// Opens an exercise's page from a NavigationLink.
struct ExerciseRoute: Hashable {
    var id: String
    var name: String
    var muscle: String
    var kind: String

    init(_ exercise: Exercise) {
        id = exercise.id
        name = exercise.name
        muscle = exercise.muscle
        kind = exercise.kind
    }

    init(id: String, name: String, store: WorkoutStore) {
        let exercise = store.exercise(id)
        self.id = id
        self.name = name
        muscle = exercise?.muscle ?? ""
        kind = exercise?.kind ?? "weight_reps"
    }
}

/// One exercise, Hevy style: Summary (the movement playing, a progress chart
/// and personal records), History (every past session's sets) and How to.
struct ExerciseDetailPage: View {
    @Environment(AppSession.self) private var session
    @AppStorage("workouts.unit") private var unit: WeightUnit = .localDefault
    var route: ExerciseRoute
    var store: WorkoutStore
    @State private var tab = Page.summary
    @State private var history: ExerciseHistory?
    @State private var loading = true
    @State private var details: ExerciseMedia.Details?
    @State private var metric: Metric?
    @State private var range = Span.threeMonths

    enum Page: String, CaseIterable { case summary = "Summary", history = "History", howTo = "How to" }

    private var isDuration: Bool { route.kind == "duration" }

    /// Past sessions with today's checked sets in front, oldest last.
    private var sessions: [ExerciseHistory.Session] {
        let past = history?.sessions ?? []
        guard let today = store.inProgressSession(route.id) else { return past }
        return [today] + past
    }

    var body: some View {
        VStack(spacing: 0) {
            tabs
            ScrollView {
                switch tab {
                case .summary: summary
                case .history: historyList
                case .howTo: howTo
                }
            }
            .refreshable { await load() }
        }
        .background(BrickLook.page.ignoresSafeArea())
        .foregroundStyle(BrickLook.ink)
        .tint(BrickLook.ink)
        .navigationTitle(route.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(BrickLook.page, for: .navigationBar)
        .task { await load() }
        .task { details = await ExerciseMedia.details(route.id) }
    }

    private func load() async {
        if history == nil { history = store.cachedHistory(route.id) }
        loading = true
        history = await store.history(route.id, api: session.api)
        loading = false
    }

    // MARK: Tabs

    private var tabs: some View {
        HStack(spacing: 0) {
            ForEach(Page.allCases, id: \.self) { item in
                Button { withAnimation(.snappy) { tab = item } } label: {
                    VStack(spacing: 10) {
                        Text(item.rawValue).font(.system(size: 17)).foregroundStyle(tab == item ? BrickLook.ink : BrickLook.soft)
                        Capsule().fill(tab == item ? BrickLook.ink : Color.clear).frame(height: 3)
                    }
                    .frame(maxWidth: .infinity)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.top, 6)
        .overlay(alignment: .bottom) { Rectangle().fill(BrickLook.line).frame(height: 1) }
    }

    // MARK: Summary

    private var summary: some View {
        VStack(alignment: .leading, spacing: 0) {
            ExerciseAnimation(exerciseId: route.id, muscle: route.muscle)
                .clipShape(.rect(cornerRadius: BrickLook.cardRadius, style: .continuous))
                .padding(.horizontal, Fit.gutter)
                .padding(.top, 16)
            VStack(alignment: .leading, spacing: 4) {
                Text(route.name).font(.system(size: 26, weight: .regular))
                Text(muscleLine).font(.subheadline).foregroundStyle(BrickLook.soft)
            }
            .padding(.horizontal, Fit.gutter)
            .padding(.top, 20)
            progress
                .padding(.horizontal, Fit.gutter)
                .padding(.top, 20)
            records
                .padding(.horizontal, Fit.gutter)
        }
        .padding(.bottom, 40)
    }

    private var muscleLine: String {
        var line = "Primary: \(WorkoutFormat.label(route.muscle.isEmpty ? "other" : route.muscle))"
        if let secondary = details?.secondaryMuscles, !secondary.isEmpty {
            line += "\nSecondary: \(secondary.map(WorkoutFormat.label).joined(separator: ", "))"
        }
        return line
    }

    private var metrics: [Metric] {
        switch route.kind {
        case "duration": [.bestTime, .totalTime]
        case "reps": [.mostReps, .sessionReps]
        default: [.heaviest, .oneRepMax, .bestSetVolume, .sessionVolume, .sessionReps]
        }
    }

    @ViewBuilder private var progress: some View {
        let chosen = metric ?? metrics[0]
        let points = sessions.reversed().compactMap { session -> ChartPoint? in
            guard let date = session.start, date >= range.start, let value = chosen.value(session.sets) else { return nil }
            return ChartPoint(date: date, value: value, inProgress: session.inProgress)
        }
        BrickCard(padding: 20) {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                if let last = points.last {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(chosen.format(last.value, unit)).font(.system(size: 22, weight: .regular)).monospacedDigit()
                        Text(last.inProgress ? "(In progress)" : last.date.formatted(.dateTime.month(.abbreviated).day()))
                            .font(.title3).foregroundStyle(BrickLook.soft)
                    }
                } else {
                    Text(loading ? "Loading…" : "No sessions yet").font(.title3).foregroundStyle(BrickLook.soft)
                }
                Spacer(minLength: 8)
                Menu {
                    Picker("Range", selection: $range) {
                        ForEach(Span.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(range.rawValue)
                        Image(systemName: "chevron.down").font(.caption.weight(.semibold))
                    }
                    .font(.subheadline)
                    .foregroundStyle(BrickLook.ink)
                }
            }
            if points.isEmpty {
                Takeaway(text: "Log this exercise and its progress shows here.")
                    .frame(height: 120, alignment: .center)
            } else {
                chart(points, chosen)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(metrics, id: \.self) { item in
                        Button { metric = item } label: {
                            Text(item.title).font(.subheadline.weight(.medium))
                                .foregroundStyle(chosen == item ? BrickLook.page : BrickLook.ink)
                                .padding(.horizontal, 16).frame(height: 38)
                                .background(chosen == item ? BrickLook.bar : BrickLook.page, in: .capsule)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        }
    }

    private struct ChartPoint: Identifiable {
        var date: Date
        var value: Double
        var inProgress: Bool
        var id: Date { date }
    }

    private func chart(_ points: [ChartPoint], _ chosen: Metric) -> some View {
        let logged = points.filter { !$0.inProgress }
        // Today's point hangs off the last logged one with a dotted line, the way Hevy draws it.
        let today = points.last(where: \.inProgress).map { point in [logged.last, point].compactMap { $0 } } ?? []
        return Chart {
            ForEach(logged) { point in
                LineMark(x: .value("Date", point.date), y: .value(chosen.title, chosen.plot(point.value, unit)), series: .value("Series", "Logged"))
                    .foregroundStyle(BrickLook.bar)
                PointMark(x: .value("Date", point.date), y: .value(chosen.title, chosen.plot(point.value, unit)))
                    .foregroundStyle(BrickLook.bar)
                    .symbolSize(36)
            }
            ForEach(today) { point in
                LineMark(x: .value("Date", point.date), y: .value(chosen.title, chosen.plot(point.value, unit)), series: .value("Series", "Today"))
                    .foregroundStyle(BrickLook.bar)
                    .lineStyle(StrokeStyle(lineWidth: 2, dash: [3, 4]))
            }
        }
        .chartYScale(domain: .automatic(includesZero: false))
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 3)) { _ in
                AxisGridLine().foregroundStyle(BrickLook.line)
                AxisValueLabel(format: .dateTime.month(.abbreviated).day())
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { _ in
                AxisGridLine().foregroundStyle(BrickLook.line)
                AxisValueLabel()
            }
        }
        .font(Fit.axis)
        .frame(height: 190)
    }

    @ViewBuilder private var records: some View {
        let logged = sessions.filter { !$0.inProgress }.flatMap(\.sets).filter { $0.kind != "warmup" }
        let rows = recordRows(logged)
        if !rows.isEmpty {
            FitSection(title: nil) {
                HStack(spacing: 8) {
                    Image(systemName: "medal.fill").foregroundStyle(Fit.fair)
                    Text("Personal Records").font(.headline)
                }
                VStack(spacing: 0) {
                    ForEach(rows) { row in
                        HStack {
                            Text(row.title)
                            Spacer()
                            Text(row.value).foregroundStyle(BrickLook.soft).monospacedDigit()
                        }
                        .padding(.vertical, 14)
                        FitDivider()
                    }
                }
            }
            .padding(.top, 12)
        }
    }

    private struct Record: Identifiable {
        var title: String
        var value: String
        var id: String { title }
    }

    private func recordRows(_ sets: [WorkoutsHome.PreviousSet]) -> [Record] {
        guard !sets.isEmpty else { return [] }
        if isDuration {
            guard let best = sets.compactMap(\.durationSeconds).max() else { return [] }
            return [Record(title: "Best Time", value: FitnessFormat.duration(best))]
        }
        var rows: [Record] = []
        if let heaviest = sets.filter({ ($0.weightKg ?? 0) > 0 }).max(by: { ($0.weightKg ?? 0) < ($1.weightKg ?? 0) }), let kg = heaviest.weightKg {
            rows.append(Record(title: "Heaviest Weight", value: "\(unit.text(kg)) \(unit.rawValue)"))
        }
        if let e1rm = sets.compactMap({ WorkoutFormat.estimatedOneRepMax(kg: $0.weightKg, reps: $0.reps) }).max() {
            rows.append(Record(title: "Best 1RM", value: "\(unit.text(e1rm)) \(unit.rawValue)"))
        }
        if let best = sets.filter({ ($0.weightKg ?? 0) > 0 }).max(by: { Metric.setVolume($0) < Metric.setVolume($1) }),
           let kg = best.weightKg, let reps = best.reps {
            rows.append(Record(title: "Best Set Volume", value: "\(unit.text(kg)) \(unit.rawValue) × \(reps)"))
        }
        let sessionBest = sessions.filter { !$0.inProgress }.compactMap { Metric.sessionVolume.value($0.sets) }.max()
        if let sessionBest, sessionBest > 0 {
            rows.append(Record(title: "Best Session Volume", value: WorkoutFormat.volume(sessionBest, unit: unit)))
        }
        if let reps = sets.compactMap(\.reps).max() {
            rows.append(Record(title: "Most Reps", value: "\(reps) reps"))
        }
        return rows
    }

    // MARK: History

    @ViewBuilder private var historyList: some View {
        if sessions.isEmpty {
            Takeaway(text: loading ? "Loading…" : "No sessions of this exercise yet.")
                .padding(Fit.gutter)
        } else {
            LazyVStack(alignment: .leading, spacing: 16) {
                ForEach(sessions) { session in
                    BrickCard(padding: 20) { sessionCard(session) }
                }
            }
            .padding(.horizontal, Fit.gutter)
            .padding(.top, 16)
            .padding(.bottom, 40)
        }
    }

    private func sessionCard(_ session: ExerciseHistory.Session) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if session.inProgress {
                header(session)
            } else {
                NavigationLink(value: WorkoutRoute(id: session.workoutId)) {
                    HStack {
                        header(session)
                        Spacer()
                        Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(BrickLook.soft)
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
            HStack {
                Text("SET")
                Spacer()
                Text(isDuration ? "TIME" : "WEIGHT & REPS")
            }
            .font(.system(size: 12, weight: .medium))
            .tracking(1.0)
            .foregroundStyle(BrickLook.soft)
            ForEach(Array(session.sets.enumerated()), id: \.offset) { index, set in
                HStack {
                    Text(label(index, session.sets))
                        .font(.subheadline.weight(.semibold)).monospacedDigit()
                        .foregroundStyle(set.kind == "warmup" ? Fit.fair : set.kind == "drop" ? Fit.health : set.kind == "failure" ? Fit.attention : BrickLook.ink)
                        .frame(width: 28, alignment: .leading)
                    Spacer()
                    Text(describe(set)).font(.subheadline).monospacedDigit()
                }
            }
        }
    }

    private func header(_ session: ExerciseHistory.Session) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(session.workoutName).font(.system(size: 20, weight: .regular))
            Text(session.inProgress ? "In progress" : session.start?.formatted(.dateTime.weekday(.wide).month(.wide).day().year()) ?? "")
                .font(.subheadline).foregroundStyle(session.inProgress ? BrickLook.live : BrickLook.soft)
        }
    }

    private func label(_ index: Int, _ sets: [WorkoutsHome.PreviousSet]) -> String {
        if let badge = SetKind(rawValue: sets[index].kind)?.badge { return badge }
        return "\(sets[..<index].filter { $0.kind != "warmup" }.count + 1)"
    }

    private func describe(_ set: WorkoutsHome.PreviousSet) -> String {
        if let seconds = set.durationSeconds { return WorkoutFormat.clock(seconds) }
        switch (set.weightKg, set.reps) {
        case let (w?, r?) where w > 0: return "\(unit.text(w)) \(unit.rawValue) × \(r)"
        case let (_, r?): return "\(r) reps"
        default: return "–"
        }
    }

    // MARK: How to

    @ViewBuilder private var howTo: some View {
        VStack(alignment: .leading, spacing: 20) {
            ExerciseAnimation(exerciseId: route.id, muscle: route.muscle)
                .clipShape(.rect(cornerRadius: BrickLook.cardRadius, style: .continuous))
            if let steps = details?.instructions, !steps.isEmpty {
                ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                    HStack(alignment: .firstTextBaseline, spacing: 14) {
                        Text("\(index + 1)").font(.headline).foregroundStyle(BrickLook.soft).frame(width: 22, alignment: .leading)
                        Text(step).font(.body).fixedSize(horizontal: false, vertical: true)
                    }
                }
            } else {
                Takeaway(text: ExerciseMedia.has(route.id) ? "Loading the steps…" : "No instructions for this exercise.")
            }
        }
        .padding(.horizontal, Fit.gutter)
        .padding(.top, 16)
        .padding(.bottom, 40)
    }
}

// MARK: Progress metrics

extension ExerciseDetailPage {
    enum Span: String, CaseIterable {
        case month = "Last month", threeMonths = "Last 3 months", year = "Last year", all = "All time"

        var start: Date {
            let calendar = Calendar.current
            switch self {
            case .month: return calendar.date(byAdding: .month, value: -1, to: .now) ?? .distantPast
            case .threeMonths: return calendar.date(byAdding: .month, value: -3, to: .now) ?? .distantPast
            case .year: return calendar.date(byAdding: .year, value: -1, to: .now) ?? .distantPast
            case .all: return .distantPast
            }
        }
    }

    /// What the chart plots per session. Values are kilograms, reps or seconds.
    enum Metric: Hashable {
        case heaviest, oneRepMax, bestSetVolume, sessionVolume, sessionReps, mostReps, bestTime, totalTime

        var title: String {
            switch self {
            case .heaviest: "Heaviest Weight"
            case .oneRepMax: "One Rep Max"
            case .bestSetVolume: "Best Set Volume"
            case .sessionVolume: "Session Volume"
            case .sessionReps: "Total Reps"
            case .mostReps: "Most Reps"
            case .bestTime: "Best Time"
            case .totalTime: "Total Time"
            }
        }

        static func setVolume(_ set: WorkoutsHome.PreviousSet) -> Double { (set.weightKg ?? 0) * Double(set.reps ?? 0) }

        func value(_ sets: [WorkoutsHome.PreviousSet]) -> Double? {
            let working = sets.filter { $0.kind != "warmup" }
            let values: [Double]
            switch self {
            case .heaviest: values = working.compactMap(\.weightKg).filter { $0 > 0 }
            case .oneRepMax: values = working.compactMap { WorkoutFormat.estimatedOneRepMax(kg: $0.weightKg, reps: $0.reps) }
            case .bestSetVolume: values = working.map(Self.setVolume).filter { $0 > 0 }
            case .sessionVolume:
                let total = working.map(Self.setVolume).reduce(0, +)
                return total > 0 ? total : nil
            case .sessionReps:
                let total = working.compactMap(\.reps).reduce(0, +)
                return total > 0 ? Double(total) : nil
            case .mostReps: values = working.compactMap(\.reps).map(Double.init)
            case .bestTime: values = sets.compactMap(\.durationSeconds)
            case .totalTime:
                let total = sets.compactMap(\.durationSeconds).reduce(0, +)
                return total > 0 ? total : nil
            }
            return values.max()
        }

        /// The value on the chart's axis: weight in the shown unit, time in seconds.
        func plot(_ value: Double, _ unit: WeightUnit) -> Double {
            switch self {
            case .heaviest, .oneRepMax, .bestSetVolume, .sessionVolume: unit.fromKg(value)
            default: value
            }
        }

        func format(_ value: Double, _ unit: WeightUnit) -> String {
            switch self {
            case .heaviest, .oneRepMax: "\(unit.text(value)) \(unit.rawValue)"
            case .bestSetVolume, .sessionVolume: WorkoutFormat.volume(value, unit: unit)
            case .sessionReps, .mostReps: "\(Int(value)) reps"
            case .bestTime, .totalTime: FitnessFormat.duration(value)
            }
        }
    }
}
