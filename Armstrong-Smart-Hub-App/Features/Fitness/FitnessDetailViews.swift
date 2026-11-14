import Charts
import SwiftUI

// MARK: Activities

/// A workout as a plain row: icon, name and when, then its headline number.
struct ActivityRow: View {
    var activity: FitnessActivity

    var body: some View {
        HStack(spacing: 14) {
            TablerIcon(name: activity.symbol, size: 22).foregroundStyle(Fit.muted).frame(width: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(activity.title).font(.subheadline)
                if let start = activity.start {
                    Text(start, format: .dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute())
                        .font(.caption).foregroundStyle(Fit.muted)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 3) {
                Text(activity.hasDistance ? FitnessFormat.distance(activity.distanceMeters) : FitnessFormat.duration(activity.duration))
                    .font(.system(size: 17, weight: .light).monospacedDigit())
                Text(activity.hasDistance ? FitnessFormat.duration(activity.duration) : activity.avgHr.map { "\($0) bpm avg" } ?? "")
                    .font(.caption).foregroundStyle(Fit.muted).monospacedDigit()
            }
            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(Fit.faint)
        }
        .padding(.vertical, 12)
        .contentShape(.rect)
    }
}

struct ActivitiesView: View {
    let activities: [FitnessActivity]

    var body: some View {
        let calendar = Calendar.current
        let months = Dictionary(grouping: activities) { calendar.dateInterval(of: .month, for: $0.start ?? .distantPast)?.start ?? .distantPast }
        FitPage(title: "Activities") {
            ForEach(months.keys.sorted(by: >), id: \.self) { month in
                let items = (months[month] ?? []).sorted { ($0.start ?? .distantPast) > ($1.start ?? .distantPast) }
                FitSection(title: month.formatted(.dateTime.month(.wide).year()),
                           trailing: "\(items.count) · \(FitnessFormat.duration(items.compactMap(\.duration).reduce(0, +)))",
                           divider: month != months.keys.max()) {
                    VStack(spacing: 0) {
                        ForEach(items) { activity in
                            NavigationLink(value: activity) { ActivityRow(activity: activity) }.buttonStyle(.plain)
                            if activity.id != items.last?.id { FitDivider() }
                        }
                    }
                }
            }
        }
    }
}

// MARK: Sleep

/// Every night: tap a bar to open that night below.
struct SleepView: View {
    let nights: [SleepNight]
    @State private var selected: String?

    private var night: SleepNight? { nights.first { $0.id == selected } ?? nights.first }

    var body: some View {
        FitPage(title: "All nights") {
            FitSection(title: "Time asleep", divider: false) {
                let points = nights.prefix(30).compactMap { n in n.endDate.map { DayValue(date: Calendar.current.startOfDay(for: $0), value: Double(n.asleepSeconds) / 3600) } }
                DailyBarChart(points: points.sorted { $0.date < $1.date }, tint: Fit.sleep, goal: 8, yTicks: [0, 4, 8],
                              format: { WatchFormat.hours($0) })
                Picker("Night", selection: Binding(get: { night?.id ?? "" }, set: { selected = $0 })) {
                    ForEach(nights.prefix(30)) { n in
                        Text(n.startDate?.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()) ?? n.id).tag(n.id)
                    }
                }
                .pickerStyle(.menu)
                .tint(.primary)
            }
            if let night {
                FitSection(title: night.startDate?.formatted(.dateTime.weekday(.wide).month().day()) ?? "Night",
                           trailing: night.score.map { "Score \($0)" }) {
                    HypnogramView(night: night)
                    StageRows(night: night).padding(.top, 8)
                }
            }
        }
    }
}

// MARK: Trends

struct TrendsView: View {
    let store: FitnessStore
    @State private var days = 30

    var body: some View {
        let steps = store.days.compactMap { d in d.date.flatMap { date in d.steps.map { DayValue(date: date, value: Double($0)) } } }
        let average = steps.isEmpty ? nil : Int(steps.map(\.value).reduce(0, +) / Double(steps.count))
        FitPage(title: "Steps & training") {
            BigNumber(value: (store.today?.steps ?? 0).formatted(), unit: "steps",
                      caption: store.today?.stepGoal.map { "Today · goal \($0.formatted())" } ?? "Today")
            if !steps.isEmpty {
                FitSection(title: "Daily steps", trailing: average.map { "\($0.formatted()) average" }) {
                    PeriodPicker(days: $days)
                    DailyBarChart(points: FitData.last(days, steps), tint: Fit.positive, goal: store.today?.stepGoal.map(Double.init), period: days)
                }
            }
            dayTotals
            RestingSection(store: store)
            let weeks = weeklyMinutes()
            if !weeks.isEmpty {
                FitSection(title: "Training per week", trailing: "Minutes") {
                    DailyBarChart(points: weeks, tint: Fit.activity, height: 160, unit: .weekOfYear)
                    Takeaway(text: "Each bar is a week, labelled by its first day.").font(.caption)
                }
            }
            byActivity
        }
    }

    /// The newest finished day the watch summed up itself: distance, calories, floors, intensity.
    @ViewBuilder private var dayTotals: some View {
        if let day = store.days.first(where: { $0.distanceMeters != nil || $0.activeKcal != nil }) {
            let all: [(String, String?)] = [
                ("Distance", day.distanceMeters.map { FitnessFormat.distance($0) }),
                ("Active calories", day.activeKcal.map { "\($0.formatted()) kcal" }),
                ("Resting calories", day.restingKcal.map { "\($0.formatted()) kcal" }),
                ("Active time", day.activeSeconds.map { FitnessFormat.duration($0) }),
                ("Floors", day.floorsUp.map { up in "\(Int(up.rounded())) up · \(Int((day.floorsDown ?? 0).rounded())) down" }),
                ("Intensity minutes", day.intensityMinutes.map { "\($0) (\(day.moderateMinutes ?? 0) moderate, \(day.vigorousMinutes ?? 0) vigorous)" }),
            ]
            let rows = all.compactMap { label, value in value.map { (label, $0) } }
            FitSection(title: "Day totals", trailing: day.date.map { $0.formatted(.dateTime.weekday(.wide).month().day()) }) {
                VStack(spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                        DetailRow(label: row.0, value: row.1, last: index == rows.count - 1)
                    }
                }
            }
        }
    }

    private var byActivity: some View {
        let sports = Dictionary(grouping: store.activities, by: \.title).sorted { $0.value.count > $1.value.count }
        return FitSection(title: "By activity") {
            VStack(spacing: 0) {
                ForEach(Array(sports.enumerated()), id: \.offset) { index, item in
                    DetailRow(label: item.key, value: "\(item.value.count) · \(FitnessFormat.duration(item.value.compactMap(\.duration).reduce(0, +)))",
                              last: index == sports.count - 1)
                }
            }
        }
    }

    /// Workout minutes per week for the last 12 weeks, on each week's first day.
    private func weeklyMinutes() -> [DayValue] {
        let calendar = Calendar.current
        let cutoff = calendar.date(byAdding: .weekOfYear, value: -12, to: .now) ?? .distantPast
        let recent = store.activities.filter { ($0.start ?? .distantPast) > cutoff }
        let byWeek = Dictionary(grouping: recent) { calendar.dateInterval(of: .weekOfYear, for: $0.start ?? .now)?.start ?? .now }
        return byWeek.keys.sorted().map { week in
            DayValue(date: week, value: (byWeek[week] ?? []).compactMap(\.duration).reduce(0, +) / 60)
        }
    }
}
