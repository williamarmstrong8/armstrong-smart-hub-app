import Charts
import SwiftUI

// MARK: Activity

struct ActivityDetailView: View {
    @Environment(AppSession.self) private var session
    let activity: FitnessActivity
    let store: FitnessStore
    @State private var detail: FitnessActivityDetail?
    @State private var loading = true

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                header
                stats
                heartRate
            }
            .padding(16)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(activity.title)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            detail = await store.detail(activity.id, api: session.api)
            loading = false
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: activity.symbol)
                .font(.title).foregroundStyle(.white)
                .frame(width: 56, height: 56)
                .background(activity.color.gradient, in: .rect(cornerRadius: 14))
            VStack(alignment: .leading, spacing: 2) {
                Text(activity.title).font(.title3.bold())
                if let start = activity.start {
                    Text(start, format: .dateTime.weekday(.wide).month().day().hour().minute())
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
    }

    private var stats: some View {
        var items: [(String, String)] = [("Time", FitnessFormat.duration(activity.duration))]
        if activity.hasDistance {
            items.append(("Distance", FitnessFormat.distance(activity.distanceMeters)))
            if let pace = FitnessFormat.pace(activity.avgSpeed) { items.append(("Avg pace", pace)) }
        }
        items.append(("Avg HR", activity.avgHr.map { "\($0) bpm" } ?? "–"))
        items.append(("Max HR", activity.maxHr.map { "\($0) bpm" } ?? "–"))
        items.append(("Calories", activity.calories.map { "\($0) kcal" } ?? "–"))
        if let ascent = activity.ascentMeters, ascent > 0 {
            let measurement = Measurement(value: ascent, unit: UnitLength.meters)
            items.append(("Ascent", measurement.formatted(.measurement(width: .abbreviated, usage: .asProvided))))
        }
        if let effect = activity.trainingEffect { items.append(("Training effect", String(format: "%.1f", effect))) }
        if let elapsed = activity.elapsedSeconds, elapsed - (activity.movingSeconds ?? elapsed) > 60 {
            items.append(("Elapsed", FitnessFormat.duration(elapsed)))
        }
        return Card {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 16) {
                ForEach(items, id: \.0) { item in Stat(label: item.0, value: item.1) }
            }
        }
    }

    private var heartRate: some View {
        Card(title: "Heart rate") {
            if let detail, !detail.points.isEmpty {
                let points = detail.points
                Chart {
                    ForEach(points.indices, id: \.self) { i in
                        AreaMark(x: .value("Minutes", points[i].0 / 60), yStart: .value("Floor", (points.map(\.1).min() ?? 0) - 10), yEnd: .value("BPM", points[i].1))
                            .foregroundStyle(.linearGradient(colors: [.red.opacity(0.35), .red.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                            .interpolationMethod(.monotone)
                        LineMark(x: .value("Minutes", points[i].0 / 60), y: .value("BPM", points[i].1))
                            .foregroundStyle(.red)
                            .interpolationMethod(.monotone)
                    }
                    if let avg = activity.avgHr {
                        RuleMark(y: .value("Average", avg)).foregroundStyle(.secondary).lineStyle(StrokeStyle(lineWidth: 1, dash: [4]))
                    }
                }
                .chartYScale(domain: .automatic(includesZero: false))
                .chartXAxisLabel("minutes")
                .frame(height: 200)
                zones(points.map(\.1))
            } else if loading {
                ProgressView().frame(maxWidth: .infinity, minHeight: 120)
            } else {
                Text("No heart rate recorded.").foregroundStyle(.secondary)
            }
        }
    }

    /// Time in each zone, as a share of the samples (zones by % of the activity's max HR).
    private func zones(_ bpm: [Double]) -> some View {
        let peak = Double(activity.maxHr ?? Int(bpm.max() ?? 190))
        let bounds = [0.5, 0.6, 0.7, 0.8, 0.9]
        let colors: [Color] = [.gray, .blue, .green, .orange, .red]
        let counts = (0..<5).map { zone in
            bpm.filter { value in
                let share = value / max(peak, 1)
                return share >= bounds[zone] && (zone == 4 || share < bounds[zone + 1])
            }.count
        }
        let total = max(counts.reduce(0, +), 1)
        return VStack(alignment: .leading, spacing: 6) {
            ForEach((0..<5).reversed(), id: \.self) { zone in
                HStack(spacing: 8) {
                    Text("Zone \(zone + 1)").font(.caption).frame(width: 52, alignment: .leading)
                    GeometryReader { geometry in
                        Capsule().fill(colors[zone].gradient)
                            .frame(width: max(4, geometry.size.width * Double(counts[zone]) / Double(total)))
                    }
                    .frame(height: 10)
                    Text("\(Int((Double(counts[zone]) / Double(total) * 100).rounded()))%")
                        .font(.caption).monospacedDigit().foregroundStyle(.secondary).frame(width: 36, alignment: .trailing)
                }
            }
        }
        .padding(.top, 4)
    }
}

struct ActivitiesView: View {
    let activities: [FitnessActivity]

    var body: some View {
        let months = Dictionary(grouping: activities) { activity in
            Calendar.current.dateInterval(of: .month, for: activity.start ?? .distantPast)?.start ?? .distantPast
        }
        List {
            ForEach(months.keys.sorted(by: >), id: \.self) { month in
                let items = months[month] ?? []
                Section {
                    ForEach(items) { activity in
                        NavigationLink(value: activity) { ActivityRow(activity: activity) }
                    }
                } header: {
                    HStack {
                        Text(month, format: .dateTime.month(.wide).year())
                        Spacer()
                        Text("\(items.count) · \(FitnessFormat.duration(items.compactMap(\.duration).reduce(0, +)))")
                    }
                }
            }
        }
        .navigationTitle("Activities")
    }
}

// MARK: Sleep

struct SleepView: View {
    let nights: [SleepNight]
    @State private var selected: String?

    private var night: SleepNight? { nights.first { $0.id == selected } ?? nights.first }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                if let night {
                    Card(title: night.startDate.map { $0.formatted(.dateTime.weekday(.wide).month().day()) } ?? "Night") {
                        HStack {
                            Stat(label: "Asleep", value: FitnessFormat.duration(Double(night.asleepSeconds)))
                            if let start = night.startDate, let end = night.endDate {
                                Stat(label: "In bed", value: "\(start.formatted(date: .omitted, time: .shortened))–\(end.formatted(date: .omitted, time: .shortened))")
                            }
                            if let score = night.score { Stat(label: "Score", value: "\(score)") }
                        }
                        Hypnogram(night: night).frame(height: 160)
                        ForEach(SleepNight.Stage.allCases) { stage in
                            HStack {
                                Label(stage.name, systemImage: "circle.fill").labelStyle(TintedDot(color: stage.color))
                                Spacer()
                                Text(FitnessFormat.duration(Double(night.seconds(stage)))).monospacedDigit()
                                let total = Double(max(night.asleepSeconds + (night.awakeSeconds ?? 0), 1))
                                Text("\(Int(Double(night.seconds(stage)) / total * 100))%")
                                    .foregroundStyle(.secondary).monospacedDigit().frame(width: 40, alignment: .trailing)
                            }
                            .font(.subheadline)
                        }
                    }
                }
                Card(title: "Recent nights") {
                    Chart(nights.prefix(14).reversed()) { night in
                        ForEach(SleepNight.Stage.allCases.filter { $0 != .awake }) { stage in
                            BarMark(x: .value("Night", night.startDate ?? .now, unit: .day),
                                    y: .value("Hours", Double(night.seconds(stage)) / 3600))
                                .foregroundStyle(by: .value("Stage", stage.name))
                        }
                    }
                    .chartForegroundStyleScale(["Deep": Color.indigo, "Light": Color.blue, "REM": Color.cyan])
                    .chartXAxis { AxisMarks(values: .stride(by: .day)) { _ in AxisValueLabel(format: .dateTime.weekday(.narrow)) } }
                    .chartXSelection(value: Binding(get: { night?.startDate }, set: { date in
                        guard let date else { return }
                        selected = nights.first { $0.startDate.map { Calendar.current.isDate($0, inSameDayAs: date) } == true }?.id
                    }))
                    .frame(height: 160)
                    Text("Tap a bar to see that night.").font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(16)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Sleep")
    }
}

/// Stages through the night, deep at the bottom.
struct Hypnogram: View {
    let night: SleepNight

    private struct Segment: Identifiable {
        let id: Int
        let stage: SleepNight.Stage
        let start: Date
        let end: Date
    }

    var body: some View {
        let segments = night.segments.enumerated().map { Segment(id: $0.offset, stage: $0.element.stage, start: $0.element.start, end: $0.element.end) }
        Chart(segments) { segment in
            RectangleMark(xStart: .value("Start", segment.start), xEnd: .value("End", segment.end),
                          y: .value("Stage", segment.stage.name), height: .ratio(0.8))
                .foregroundStyle(segment.stage.color)
        }
        .chartYScale(domain: ["Awake", "REM", "Light", "Deep"])
        .chartXAxis { AxisMarks(values: .stride(by: .hour, count: 2)) { _ in AxisGridLine(); AxisValueLabel(format: .dateTime.hour()) } }
    }
}

// MARK: Trends

struct TrendsView: View {
    let store: FitnessStore

    var body: some View {
        let days = store.days.filter { $0.date != nil }.prefix(30).reversed()
        let stepDays = days.filter { $0.steps != nil }
        let resting = days.filter { $0.restingHr != nil }
        ScrollView {
            VStack(spacing: 16) {
                Card(title: "Steps", trailing: average(stepDays.compactMap(\.steps)).map { "avg \($0.formatted())" }) {
                    if stepDays.isEmpty { empty } else {
                        StepsChart(days: Array(stepDays), goal: store.today?.stepGoal).frame(height: 180)
                    }
                }
                Card(title: "Resting heart rate", trailing: average(resting.compactMap(\.restingHr)).map { "avg \($0) bpm" }) {
                    if resting.isEmpty { empty } else {
                        Chart(Array(resting)) { day in
                            LineMark(x: .value("Day", day.date ?? .now, unit: .day), y: .value("BPM", day.restingHr ?? 0))
                                .foregroundStyle(.indigo).interpolationMethod(.monotone)
                            PointMark(x: .value("Day", day.date ?? .now, unit: .day), y: .value("BPM", day.restingHr ?? 0))
                                .foregroundStyle(.indigo).symbolSize(16)
                        }
                        .chartYScale(domain: .automatic(includesZero: false))
                        .frame(height: 160)
                    }
                }
                Card(title: "Training per week") {
                    let weeks = weeklyMinutes()
                    if weeks.isEmpty { empty } else {
                        Chart(weeks, id: \.week) { week in
                            ForEach(week.sports, id: \.sport) { item in
                                BarMark(x: .value("Week", week.week, unit: .weekOfYear), y: .value("Minutes", item.minutes))
                                    .foregroundStyle(by: .value("Sport", FitnessFormat.name(item.sport)))
                            }
                        }
                        .chartYAxisLabel("minutes")
                        .frame(height: 180)
                    }
                }
                Card(title: "By activity") {
                    let sports = Dictionary(grouping: store.activities, by: \.title).sorted { $0.value.count > $1.value.count }
                    ForEach(sports, id: \.key) { title, items in
                        HStack {
                            Image(systemName: items[0].symbol).foregroundStyle(items[0].color).frame(width: 24)
                            Text(title)
                            Spacer()
                            Text("\(items.count) · \(FitnessFormat.duration(items.compactMap(\.duration).reduce(0, +)))")
                                .foregroundStyle(.secondary).monospacedDigit()
                        }
                        .font(.subheadline)
                    }
                }
            }
            .padding(16)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Trends")
    }

    private var empty: some View {
        Text("Not enough data yet.").font(.subheadline).foregroundStyle(.secondary)
    }

    private func average(_ values: [Int]) -> Int? {
        values.isEmpty ? nil : values.reduce(0, +) / values.count
    }

    /// Minutes of activity per week and sport, last 12 weeks.
    private func weeklyMinutes() -> [(week: Date, sports: [(sport: String, minutes: Double)])] {
        let calendar = Calendar.current
        let cutoff = calendar.date(byAdding: .weekOfYear, value: -12, to: .now) ?? .distantPast
        let recent = store.activities.filter { ($0.start ?? .distantPast) > cutoff }
        let byWeek = Dictionary(grouping: recent) { calendar.dateInterval(of: .weekOfYear, for: $0.start ?? .now)?.start ?? .now }
        return byWeek.keys.sorted().map { week in
            let bySport = Dictionary(grouping: byWeek[week] ?? [], by: \.sport)
            return (week, bySport.map { ($0.key, $0.value.compactMap(\.duration).reduce(0, +) / 60) })
        }
    }
}
