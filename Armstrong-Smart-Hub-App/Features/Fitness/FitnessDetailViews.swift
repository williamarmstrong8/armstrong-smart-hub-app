import Charts
import SwiftUI

// MARK: Activities

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
                            TablerIcon(name: items[0].symbol, size: 22).foregroundStyle(.primary)
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
