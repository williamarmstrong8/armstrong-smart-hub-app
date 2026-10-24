import Charts
import SwiftUI

/// The Fitness tab, Oura-style: three score rings on top, then plain rows
/// that each open a page. Pages open with a big ring or number, then the
/// inputs behind it, a trend and the details, divided by hairlines. The
/// visual kit is in FitnessDesign.swift.
enum FitnessPage: Hashable {
    case readiness, recovery, strain, sleep, heart, energy, training, health

    var title: String {
        switch self {
        case .readiness: "Readiness"
        case .recovery: "Recovery"
        case .strain: "Strain"
        case .sleep: "Sleep"
        case .heart: "Heart"
        case .energy: "Energy & stress"
        case .training: "Fitness"
        case .health: "Health"
        }
    }

    @MainActor @ViewBuilder func view(store: FitnessStore) -> some View {
        switch self {
        case .readiness: ReadinessPage(store: store)
        case .recovery: RecoveryPage(store: store)
        case .strain: StrainPage(store: store)
        case .sleep: SleepPage(store: store)
        case .heart: HeartPage(store: store)
        case .energy: EnergyPage(store: store)
        case .training: TrainingPage(store: store)
        case .health: HealthPage(store: store)
        }
    }
}

/// Small conversions the pages share.
enum FitData {
    static func day(_ iso: String) -> Date? { ISO.parse(iso).map { Calendar.current.startOfDay(for: $0) } }

    static func points(_ points: [FitnessWatch.Point]) -> [DayValue] {
        points.compactMap { p in day(p.at).map { DayValue(date: $0, value: p.value) } }
    }

    /// Up to 24 hours ending at the newest reading (rounded up to the hour),
    /// starting at the first reading, at least 3 hours wide.
    static func window(_ points: [TimeValue]) -> (Date, Date) {
        let calendar = Calendar.current
        let dates = points.map(\.date)
        let end = calendar.dateInterval(of: .hour, for: dates.max() ?? .now)?.end ?? .now
        let first = dates.min().flatMap { calendar.dateInterval(of: .hour, for: $0)?.start } ?? end
        let start = max(end.addingTimeInterval(-24 * 3600), min(first, end.addingTimeInterval(-3 * 3600)))
        return (start, end)
    }

    static func hrvNights(_ store: FitnessStore) -> [DayValue] {
        (store.snapshot?.hrv ?? []).compactMap { n in n.date.flatMap { d in n.lastNightAverage.map { DayValue(date: d, value: $0) } } }
    }

    static func restingDays(_ store: FitnessStore) -> [DayValue] {
        store.days.compactMap { d in d.date.flatMap { date in d.restingHr.map { DayValue(date: date, value: Double($0)) } } }
    }

    /// The last `days` days; when the watch hasn't synced lately, its last stretch instead.
    static func last(_ days: Int, _ values: [DayValue]) -> [DayValue] {
        let sorted = values.sorted { $0.date < $1.date }
        let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: .now) ?? .distantPast
        let recent = sorted.filter { $0.date > cutoff }
        return recent.count >= 2 ? recent : Array(sorted.suffix(days))
    }
}

/// Why the day-long charts stop where they do: the watch hands over each
/// day's all-day file at midnight, and between times the hub only has what the
/// phone streamed live while it was connected.
struct AllDayNote: View {
    var store: FitnessStore

    var body: some View {
        if let through = store.allDayThrough, Date.now.timeIntervalSince(through) > 2 * 3600 {
            Takeaway(text: "Runs to \(through.formatted(.dateTime.weekday(.wide).hour().minute())). Today fills in live while the watch is connected to this phone; the rest arrives with the watch's all-day file at midnight.")
                .font(.caption)
        }
    }
}

enum Bands {
    static func recovery(_ zone: String?) -> Color {
        switch zone { case "green": Fit.positive; case "yellow": Fit.fair; case "red": Fit.attention; default: Fit.muted }
    }
}

/// A score's status color, or the page's accent where the status is plain "Good".
private func accent(_ score: Int?, _ tint: Color) -> Color {
    let color = Status.color(score)
    return color == .primary ? tint : color
}

// MARK: Overview

/// Readiness, Sleep and Energy as three bold rings, Oura's top row.
struct TodayScores: View {
    var store: FitnessStore

    var body: some View {
        let watch = store.snapshot?.watch
        let metrics = store.snapshot?.metrics
        let readiness = watch?.readiness?.score ?? metrics?.readiness.score
        let sleep = watch?.sleep?.overall ?? store.lastNight?.score
        let energy = store.currentBodyBattery ?? metrics?.bodyBattery?.current ?? store.snapshot?.insights?.stress.bodyBattery?.current
        HStack(alignment: .top, spacing: 0) {
            ring(.readiness, readiness, Fit.readiness, "Readiness")
            ring(.sleep, sleep, Fit.sleep, "Sleep")
            ring(.energy, energy, Fit.energy, "Energy")
        }
    }

    private func ring(_ page: FitnessPage, _ score: Int?, _ tint: Color, _ label: String) -> some View {
        NavigationLink(value: page) {
            VStack(spacing: 8) {
                ScoreRing(value: score.map(String.init) ?? "–", fraction: Double(score ?? 0) / 100, tint: tint, size: 100,
                          track: tint.opacity(0.16), weight: 0.09)
                Text(label).font(.subheadline.weight(.medium))
            }
            .frame(maxWidth: .infinity)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }
}

/// Everything else on the overview, one plain row each.
struct OverviewList: View {
    var store: FitnessStore

    var body: some View {
        VStack(spacing: 0) {
            row(.heart) { LiveHeartRow(store: store) }
            stress
            strain
            fitness
            endurance
            race
            recovery
            age
            NavigationLink { TrendsView(store: store) } label: { LiveStepsRow(store: store) }
                .buttonStyle(.plain)
        }
    }

    private var stress: some View {
        let metrics = store.snapshot?.metrics
        let value = store.currentStress ?? store.snapshot?.insights?.stress.now ?? metrics?.stress?.average
        return row(.energy) {
            OverviewRow(title: "Stress", value: value.map(String.init) ?? "–", unit: nil,
                        caption: value.map(stressWord), tint: value.map { MetricColor.stress($0) } ?? Fit.muted) {
                MiniTrend(values: Self.thin(store.series(.stress).map { Double($0.value) }, to: 24), tint: Fit.fair, bars: true)
            }
        }
    }

    private var strain: some View {
        let strain = store.snapshot?.insights?.strain
        return row(.strain) {
            OverviewRow(title: "Strain", value: strain?.today.map { String(format: "%.1f", $0) } ?? "–", unit: "of 21",
                        caption: strain?.level?.capitalized, tint: Fit.activity) {
                MiniTrend(values: strain?.week.map { $0.strain ?? 0 } ?? [], tint: Fit.activity, bars: true)
            }
        }
    }

    private var fitness: some View {
        let watch = store.snapshot?.watch
        let vo2 = store.snapshot?.metrics?.vo2max?.value ?? watch?.vo2max?.value
        return row(.training) {
            OverviewRow(title: "VO2 max", value: vo2.map { String(format: "%.0f", $0) } ?? "–", unit: "ml/kg/min",
                        caption: store.snapshot?.insights?.age?.cardioFitness.map { $0.level.capitalized }, tint: Fit.activity) {
                MiniTrend(values: watch?.vo2max?.history.suffix(12).map(\.value) ?? [], tint: Fit.activity)
            }
        }
    }

    @ViewBuilder private var endurance: some View {
        if let endurance = store.snapshot?.watch?.endurance {
            row(.training) {
                OverviewRow(title: "Endurance score", value: endurance.score.formatted(), unit: nil, caption: endurance.level.capitalized, tint: Fit.positive) {
                    MiniTrend(values: endurance.history.map(\.value), tint: Fit.positive)
                }
            }
        }
    }

    @ViewBuilder private var race: some View {
        if let races = store.snapshot?.watch?.races, let five = races.fiveK {
            row(.training) {
                OverviewRow(title: "5K prediction", value: WatchFormat.raceTime(five), unit: nil,
                            caption: races.half.map { "Half marathon \(WatchFormat.raceTime($0))" }, tint: Fit.muted) {
                    MiniTrend(values: races.history.map { -$0.value }, tint: Fit.muted)
                }
            }
        }
    }

    private var recovery: some View {
        let recovery = store.snapshot?.insights?.recovery
        let ready = recovery?.status == "ready"
        return row(.recovery) {
            OverviewRow(title: "Recovery", value: ready ? recovery?.score.map { "\($0)%" } ?? "–" : "–", unit: nil,
                        caption: ready ? recovery?.zone.map { "\($0.capitalized) zone" } : "Learning your baseline",
                        tint: ready ? Bands.recovery(recovery?.zone) : Fit.muted) {
                MiniTrend(values: FitData.hrvNights(store).sorted { $0.date < $1.date }.map(\.value), tint: Fit.readiness)
            }
        }
    }

    private var age: some View {
        let hub = store.snapshot?.insights?.age?.hubAge
        return row(.health) {
            OverviewRow(title: "Hub age", value: hub.map { String(format: "%.0f", $0.age) } ?? "–", unit: hub == nil ? nil : "years",
                        caption: hub.map { $0.difference <= 0 ? String(format: "%.1f younger than you", -$0.difference) : String(format: "%.1f older than you", $0.difference) },
                        tint: (hub?.difference ?? 0) <= 0 ? Fit.positive : Fit.fair) {
                Color.clear
            }
        }
    }

    private func row<Content: View>(_ page: FitnessPage, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 0) {
            NavigationLink(value: page) { content() }.buttonStyle(.plain)
            FitDivider()
        }
    }

    private func stressWord(_ value: Int) -> String {
        value <= 25 ? "Restful" : value <= 50 ? "Low" : value <= 75 ? "Medium" : "High"
    }

    /// Evenly spaced values, so a sparkline isn't a solid block.
    static func thin(_ values: [Double], to count: Int) -> [Double] {
        guard values.count > count else { return values }
        let step = Double(values.count) / Double(count)
        return (0..<count).map { values[min(values.count - 1, Int(Double($0) * step))] }
    }
}

/// Heart rate with the watch's live beat. Its own view, since the beat changes every second.
private struct LiveHeartRow: View {
    @Environment(WatchLink.self) private var watch
    var store: FitnessStore

    var body: some View {
        let series = store.series(.heartRate)
        OverviewRow(title: "Heart rate", value: (watch.heartRate?.bpm ?? series.last?.value).map(String.init) ?? "–", unit: "bpm",
                    caption: store.restingHr.map { "Resting \($0)" }, tint: Fit.heart) {
            MiniTrend(values: OverviewList.thin(series.map { Double($0.value) }, to: 40), tint: Fit.heart)
        }
    }
}

/// Today's steps, the watch's live count when it's ahead of the hub's.
private struct LiveStepsRow: View {
    @Environment(WatchLink.self) private var watch
    var store: FitnessStore

    var body: some View {
        let steps = max(watch.steps?.count ?? 0, store.today?.steps ?? 0)
        let goal = store.today?.stepGoal ?? watch.steps?.goal
        OverviewRow(title: "Steps", value: steps.formatted(), unit: nil, caption: goal.map { "Goal \($0.formatted())" }, tint: Fit.muted) {
            MiniTrend(values: store.days.prefix(7).reversed().map { Double($0.steps ?? 0) }, tint: Fit.positive, bars: true)
        }
    }
}

/// The latest workouts as plain rows.
struct RecentActivities: View {
    var activities: [FitnessActivity]

    var body: some View {
        FitSection(trailing: activities.isEmpty ? nil : "\(activities.count) synced") {
            if activities.isEmpty {
                Takeaway(text: "Workouts from the watch show here after a sync.")
            } else {
                VStack(spacing: 0) {
                    ForEach(activities.prefix(3)) { activity in
                        NavigationLink(value: activity) { ActivityRow(activity: activity) }.buttonStyle(.plain)
                        FitDivider()
                    }
                    NavigationLink { ActivitiesView(activities: activities) } label: { LinkRow(title: "All activities") }
                        .buttonStyle(.plain)
                }
            }
        }
    }
}

/// A row that only opens something.
struct LinkRow: View {
    var title: String
    var subtitle: String?

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.subheadline)
                if let subtitle { Text(subtitle).font(.caption).foregroundStyle(Fit.muted) }
            }
            Spacer()
            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(Fit.faint)
        }
        .padding(.vertical, 14)
        .contentShape(.rect)
    }
}

// MARK: Readiness

struct ReadinessPage: View {
    var store: FitnessStore

    var body: some View {
        let metrics = store.snapshot?.metrics
        let watch = store.snapshot?.watch
        let score = watch?.readiness?.score ?? metrics?.readiness.score
        let level = watch?.readiness?.level ?? metrics?.readiness.level
        FitPage(title: "Readiness") {
            ScoreHeader(score: score, tint: Fit.readiness, status: level?.capitalized ?? Status.word(score),
                        subtitle: watch?.readiness.flatMap { ISO.parse($0.at) }.map { "Scored \($0.formatted(.dateTime.weekday(.wide).hour().minute()))" },
                        source: score == nil ? nil : watch?.readiness != nil)
            Takeaway(text: advice(level: level, recoveryHours: metrics?.load.recoveryHours))
            if let factors = metrics?.readiness.factors, !factors.isEmpty {
                FitSection(title: "Contributors") {
                    VStack(spacing: 18) {
                        ForEach(factors) { factor in
                            ContributorRow(title: factor.label, detail: factor.detail, fraction: factor.score.map { Double($0) / 100 },
                                           tint: accent(factor.score, Fit.readiness))
                        }
                    }
                    if let hub = metrics?.readiness.hubScore, metrics?.fromWatch("readiness") == true {
                        Takeaway(text: "These are the hub's read of the same inputs, which scores \(hub). The headline is your watch's.").font(.caption)
                    }
                }
            }
            if let history = watch?.readiness?.history, history.count > 1 {
                FitSection(title: "Trend", trailing: "Last \(history.count) days") {
                    DailyBarChart(points: FitData.points(history), tint: Fit.readiness, domain: 0...100, yTicks: [0, 50, 100],
                                  colorFor: { accent(Int($0), Fit.readiness) })
                }
            }
            FitSection(title: "Key metrics") {
                VStack(spacing: 0) {
                    DetailRow(label: "Recovery time", value: recoveryText(metrics: metrics, watch: watch))
                    DetailRow(label: "Sleep score", value: (watch?.readiness?.sleepScore ?? store.lastNight?.score).map(String.init) ?? "–")
                    DetailRow(label: "HRV, 7-night average", value: (watch?.readiness?.weeklyHrv ?? metrics?.hrv.weekly).map { "\(Int($0.rounded())) ms" } ?? "–")
                    DetailRow(label: "Resting heart rate", value: store.restingHr.map { "\($0) bpm" } ?? "–", last: true)
                }
            }
            FitSection {
                NavigationLink(value: FitnessPage.recovery) {
                    LinkRow(title: "Recovery against your baseline", subtitle: "HRV, resting heart rate, breathing and sleep")
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func recoveryText(metrics: FitnessMetrics?, watch: FitnessWatch?) -> String {
        if let watch = watch?.recovery { return watch.remainingHours < 1 ? "Recovered" : "\(WatchFormat.hours(watch.remainingHours)) to go" }
        guard let hours = metrics?.load.recoveryHours else { return "–" }
        return hours < 1 ? "Recovered" : "\(hours)h to go"
    }

    /// Garmin's guidance for each band, cut down to a line.
    private func advice(level: String?, recoveryHours: Int?) -> String {
        if let hours = recoveryHours, hours >= 12 { return "Still recovering: \(hours) hours to go. Keep today easy." }
        switch level {
        case "prime": return "Primed. A good day for your hardest session."
        case "high": return "Ready for a hard workout."
        case "moderate": return "Fine for a normal session. Save the big efforts for a better day."
        case "low": return "Go easy: a light session or a rest day."
        case "poor": return "Rest today. Sleep and recovery come first."
        default: return "Readiness appears after a night of sleep with the watch on."
        }
    }
}

// MARK: Recovery

struct RecoveryPage: View {
    var store: FitnessStore

    var body: some View {
        let recovery = store.snapshot?.insights?.recovery
        FitPage(title: "Recovery") {
            if let r = recovery, r.status == "ready", let score = r.score {
                ScoreHeader(score: score, display: "\(score)%", tint: Bands.recovery(r.zone), status: "\(r.zone?.capitalized ?? "") zone",
                            subtitle: "Last night against your own 30-night baseline")
                if let parts = r.parts, !parts.isEmpty {
                    FitSection(title: "What moved it") {
                        VStack(spacing: 18) {
                            ForEach(parts) { part in
                                DivergingRow(title: name(part.key), value: part.z, scale: 3, detail: String(format: "%+.1f SD", part.z))
                            }
                        }
                        Takeaway(text: "Each input against your usual, in standard deviations; right of center helps. HRV carries half the weight.").font(.caption)
                    }
                }
            } else {
                let have = recovery?.have ?? 0, need = recovery?.need ?? 4
                ScoreHeader(score: nil, display: "\(have)/\(need)", fraction: Double(have) / Double(max(need, 1)), tint: Fit.muted,
                            status: "Learning your baseline", subtitle: "\(have) of \(need) nights with HRV")
                Takeaway(text: "Recovery compares each night's HRV, resting heart rate, breathing and sleep with your own usual, so it needs a few nights before it can score one.")
            }
            HrvSection(store: store)
            RestingSection(store: store)
        }
    }

    private func name(_ key: String) -> String {
        ["hrv": "HRV", "restingHr": "Resting heart rate", "sleep": "Sleep", "respiration": "Breathing", "spo2": "Blood oxygen"][key] ?? key
    }
}

/// Overnight HRV with the watch's balanced range.
struct HrvSection: View {
    var store: FitnessStore
    @State private var days = 30

    var body: some View {
        let nights = FitData.hrvNights(store)
        let latest = store.snapshot?.hrv?.first
        if nights.count > 1 {
            let band = latest.flatMap { l in l.baselineBalancedLower.flatMap { low in l.baselineBalancedUpper.map { low...$0 } } }
            FitSection(title: "Heart rate variability", trailing: latest?.status.flatMap { $0 == "none" ? nil : $0.capitalized }) {
                PeriodPicker(days: $days, options: [7, 30])
                TrendLineChart(points: FitData.last(days, nights), tint: Fit.readiness, band: band, format: { "\(Int($0.rounded())) ms" })
                Takeaway(text: band == nil ? "Overnight HRV; higher generally means better recovered. Your balanced range fills in after about three weeks."
                                           : "Overnight HRV. The shaded band is your balanced range from the watch.").font(.caption)
            }
        }
    }
}

/// Daily resting heart rate.
struct RestingSection: View {
    var store: FitnessStore
    @State private var days = 30

    var body: some View {
        let resting = FitData.restingDays(store)
        if resting.count > 1 {
            FitSection(title: "Resting heart rate") {
                PeriodPicker(days: $days)
                TrendLineChart(points: FitData.last(days, resting), tint: Fit.heart, format: { "\(Int($0.rounded())) bpm" })
                Takeaway(text: "Lower usually means better recovered. A jump of a few beats can mean illness, alcohol or a hard day.").font(.caption)
            }
        }
    }
}

// MARK: Strain

struct StrainPage: View {
    var store: FitnessStore

    var body: some View {
        let insights = store.snapshot?.insights
        let strain = insights?.strain?.today
        FitPage(title: "Strain") {
            ScoreHeader(score: nil, display: strain.map { String(format: "%.1f", $0) } ?? "–", fraction: (strain ?? 0) / 21, tint: Fit.activity,
                        status: insights?.strain?.level?.capitalized ?? "No strain yet", subtitle: "Out of 21, from heart rate across the day")
            Takeaway(text: "Strain climbs fast at first and slowly after: 10 is a solid day, 14 a hard one, 18 and up an all-out effort.")
            if let week = insights?.strain?.week, week.contains(where: { $0.strain != nil }) {
                FitSection(title: "This week") {
                    DailyBarChart(points: week.compactMap { d in DateOnly.parse(d.day).map { DayValue(date: $0, value: d.strain ?? 0) } },
                                  tint: Fit.activity, domain: 0...21, yTicks: [0, 10, 14, 18],
                                  format: { String(format: "%.1f", $0) })
                }
            }
            if let workout = insights?.training.lastWorkout { LastWorkoutSection(workout: workout) }
            if let load = insights?.training.effortLoad, load.week > 0 || load.month > 0 {
                FitSection(title: "Training load", trailing: load.trend?.capitalized) {
                    VStack(spacing: 0) {
                        DetailRow(label: "Last 7 days, per day", value: "\(load.week)")
                        DetailRow(label: "Last 28 days, per day", value: "\(load.month)", last: true)
                    }
                    Takeaway(text: "Effort × minutes a day: the last week against the last four.").font(.caption)
                }
            }
        }
    }
}

struct LastWorkoutSection: View {
    var workout: FitnessInsights.Training.Workout

    var body: some View {
        FitSection(title: "Last workout", trailing: ISO.parse(workout.at)?.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())) {
            Text("\(FitnessFormat.name(workout.sport)), \(workout.minutes) min" + (workout.effort.map { " · effort \($0) of 10" } ?? ""))
                .font(.subheadline).foregroundStyle(Fit.muted)
            VStack(spacing: 18) {
                ContributorRow(title: "Aerobic effect", detail: effect(workout.watchAerobic ?? workout.aerobic, workout.aerobicLabel),
                               fraction: (workout.watchAerobic ?? workout.aerobic).map { $0 / 5 }, tint: Fit.positive)
                ContributorRow(title: "Anaerobic effect", detail: effect(workout.watchAnaerobic ?? workout.anaerobic, workout.anaerobicLabel),
                               fraction: (workout.watchAnaerobic ?? workout.anaerobic).map { $0 / 5 }, tint: Fit.health)
                if let strain = workout.strain {
                    ContributorRow(title: "Strain", detail: String(format: "%.1f", strain), fraction: strain / 21, tint: Fit.activity)
                }
            }
        }
    }

    private func effect(_ value: Double?, _ label: String?) -> String {
        guard let value else { return "–" }
        return String(format: "%.1f", value) + (label.map { " · \($0)" } ?? "")
    }
}

// MARK: Sleep

struct SleepPage: View {
    var store: FitnessStore
    @State private var days = 30

    var body: some View {
        let watch = store.snapshot?.watch
        FitPage(title: "Sleep") {
            if let night = store.lastNight {
                let score = watch?.sleep?.overall ?? night.score
                ScoreHeader(score: score, tint: Fit.sleep, subtitle: subtitle(night),
                            source: score == nil ? nil : (watch?.sleep != nil || night.watchScore != nil))
                Takeaway(text: needText(night: night))
                if let parts = watch?.sleep?.parts.rows, !parts.isEmpty {
                    FitSection(title: "Contributors") {
                        VStack(spacing: 18) {
                            ForEach(parts, id: \.0) { ScoredRow(title: $0.0, score: $0.1) }
                        }
                    }
                }
                FitSection(title: "Sleep stages", trailing: FitnessFormat.duration(Double(night.asleepSeconds)) + " asleep") {
                    HypnogramView(night: night)
                    StageRows(night: night).padding(.top, 8)
                }
                keyMetrics
            } else {
                ScoreHeader(score: nil, tint: Fit.sleep, status: "No sleep yet")
                Takeaway(text: "Sleep shows up after a night with the watch on, once it hands over the sleep file.")
            }
            trend
            habits
            if store.nights.count > 1 {
                FitSection {
                    NavigationLink { SleepView(nights: store.nights) } label: { LinkRow(title: "All nights") }.buttonStyle(.plain)
                }
            }
        }
    }

    private var keyMetrics: some View {
        let watch = store.snapshot?.watch
        let insights = store.snapshot?.insights
        return FitSection(title: "Key metrics") {
            VStack(spacing: 0) {
                DetailRow(label: "Sleep need tonight", value: (watch?.sleepNeed?.hours ?? insights?.sleep.need.hours).map(WatchFormat.hours) ?? "–")
                DetailRow(label: "Lowest heart rate", value: watch?.sleep?.lowestHr.map { "\($0) bpm" } ?? "–")
                DetailRow(label: "Body Battery charged", value: watch?.sleep?.batteryGained.map { $0 >= 0 ? "+\($0)" : "\($0)" } ?? "–")
                DetailRow(label: "Average stress", value: watch?.sleep?.avgStress.map { String(format: "%.0f", $0) } ?? "–")
                DetailRow(label: "Times woken", value: (watch?.sleep?.awakenings ?? insights?.sleep.lastNight?.interruptions).map(String.init) ?? "–", last: true)
            }
        }
    }

    @ViewBuilder private var trend: some View {
        let scores = store.nights.compactMap { n in n.endDate.flatMap { d in n.score.map { DayValue(date: Calendar.current.startOfDay(for: d), value: Double($0)) } } }
        if scores.count > 1 {
            FitSection(title: "Trend") {
                PeriodPicker(days: $days, options: [7, 30])
                DailyBarChart(points: FitData.last(days, scores), tint: Fit.sleep, domain: 0...100, yTicks: [0, 50, 100],
                              colorFor: { accent(Int($0), Fit.sleep) })
            }
        }
    }

    @ViewBuilder private var habits: some View {
        if let sleep = store.snapshot?.insights?.sleep, let night = sleep.lastNight {
            FitSection(title: "Habits") {
                VStack(spacing: 0) {
                    DetailRow(label: "Bedtime consistency", value: sleep.bedtimeSpread.map { "±\($0) min over 2 weeks" } ?? "Needs 3 nights")
                    if let index = night.recoveryIndex {
                        DetailRow(label: "Heart rate bottomed out", value: Date(timeIntervalSince1970: index.lowestAt / 1000).formatted(date: .omitted, time: .shortened))
                    }
                    DetailRow(label: "Apple-style sleep score", value: "\(night.apple.score)", last: true)
                }
            }
        }
    }

    private func subtitle(_ night: SleepNight) -> String {
        let asleep = FitnessFormat.duration(Double(night.asleepSeconds))
        guard let start = night.startDate, let end = night.endDate else { return asleep }
        return "\(asleep) asleep · \(start.formatted(date: .omitted, time: .shortened))–\(end.formatted(date: .omitted, time: .shortened))"
    }

    private func needText(night: SleepNight) -> String {
        guard let need = store.snapshot?.watch?.sleepNeed?.hours ?? store.snapshot?.insights?.sleep.lastNight?.needed else {
            return "Your sleep score weighs duration, deep and REM sleep, restlessness and how well your body recovered."
        }
        let asleep = Double(night.asleepSeconds) / 3600
        if asleep >= need { return "You got the \(WatchFormat.hours(need)) you needed." }
        let share = Int((asleep / need * 100).rounded())
        return "You slept \(share)% of the \(WatchFormat.hours(need)) you needed, \(WatchFormat.hours(need - asleep)) short. An earlier night tonight pays it back."
    }
}

// MARK: Heart

struct HeartPage: View {
    var store: FitnessStore
    @Environment(WatchLink.self) private var watch

    var body: some View {
        let readings = store.series(.heartRate)
        let points = readings.map { TimeValue(date: $0.date, value: Double($0.value)) }
        let now = watch.heartRate?.bpm ?? readings.last?.value
        FitPage(title: "Heart") {
            BigNumber(value: now.map(String.init) ?? "–", unit: "bpm",
                      caption: watch.heartRate == nil ? "Latest reading" : "Now, live from the watch", tint: Fit.heart)
            StatStrip(items: [("Resting", store.restingHr.map { "\($0)" } ?? "–"),
                              ("Lowest", points.map(\.value).min().map { "\(Int($0))" } ?? "–"),
                              ("Highest", points.map(\.value).max().map { "\(Int($0))" } ?? "–")])
                .padding(.bottom, 8)
            FitSection(title: "Through the day") {
                if points.isEmpty {
                    Takeaway(text: "All-day heart rate appears once the watch hands over a monitoring file.")
                } else {
                    let window = FitData.window(points)
                    IntradayChart(points: points, tint: Fit.heart, from: window.0, to: window.1, style: .area, unit: " bpm")
                    AllDayNote(store: store)
                }
            }
            RestingSection(store: store)
            HrvSection(store: store)
        }
    }
}

// MARK: Energy & stress

struct EnergyPage: View {
    var store: FitnessStore

    var body: some View {
        let insights = store.snapshot?.insights
        let metrics = store.snapshot?.metrics
        let live = store.currentBodyBattery
        let current = live ?? metrics?.bodyBattery?.current ?? insights?.stress.bodyBattery?.current
        FitPage(title: "Energy & stress") {
            // Hub readings (the watch's own series when it has one), then the phone's live ones.
            let points = store.series(.bodyBattery).map { TimeValue(date: $0.date, value: Double($0.value)) }
            let window = FitData.window(points)
            let day = points.filter { $0.date >= window.0 }
            ScoreHeader(score: current, tint: Fit.energy, status: current.map(batteryWord) ?? "No data", subtitle: "Body Battery",
                        source: current == nil ? nil : live != nil || store.bodyBatteryFromWatch || metrics?.fromWatch("bodyBattery") == true)
            if !day.isEmpty {
                let changes = zip(day.dropFirst(), day).map { $0.value - $1.value }
                StatStrip(items: [("Charged", "+\(Int(changes.filter { $0 > 0 }.reduce(0, +)))"),
                                  ("Drained", "\(Int(-changes.filter { $0 < 0 }.reduce(0, +)))"),
                                  ("High", "\(Int(day.map(\.value).max() ?? 0))")])
                    .padding(.bottom, 8)
                FitSection(title: "Through the day") {
                    IntradayChart(points: points, tint: Fit.energy, from: window.0, to: window.1, style: .area, domain: 0...100)
                    Takeaway(text: "Sleep and calm stretches charge it; stress and exercise drain it.").font(.caption)
                    AllDayNote(store: store)
                }
            }
            stress
            balance
        }
    }

    @ViewBuilder private var stress: some View {
        let points = store.series(.stress).map { TimeValue(date: $0.date, value: Double(max($0.value, 2)), color: MetricColor.stress($0.value)) }
        if !points.isEmpty {
            FitSection(title: "Stress", trailing: store.snapshot?.metrics?.stress?.average.map { "Average \($0)" }) {
                let window = FitData.window(points)
                IntradayChart(points: points, tint: Fit.fair, from: window.0, to: window.1, style: .bars, domain: 0...100, height: 120)
                HStack(spacing: 14) {
                    LegendDot(color: MetricColor.stress(10), text: "Rest")
                    LegendDot(color: MetricColor.stress(40), text: "Low")
                    LegendDot(color: MetricColor.stress(60), text: "Medium")
                    LegendDot(color: MetricColor.stress(90), text: "High")
                }
            }
        }
    }

    @ViewBuilder private var balance: some View {
        if let day = store.snapshot?.insights?.stress {
            FitSection(title: "Balance", trailing: day.today.summary?.capitalized) {
                VStack(spacing: 0) {
                    DetailRow(label: "Time stressed", value: FitnessFormat.duration(Double(day.today.stressedMinutes * 60)))
                    DetailRow(label: "Time restored", value: FitnessFormat.duration(Double(day.today.restoredMinutes * 60)))
                    DetailRow(label: "Resilience", value: day.resilience.status == "ready" ? (day.resilience.level?.capitalized ?? "–")
                              : "Needs \(day.resilience.need ?? 5) days, has \(day.resilience.have ?? 0)", last: true)
                }
            }
        }
    }

    private func batteryWord(_ value: Int) -> String {
        value >= 75 ? "Charged" : value >= 50 ? "Good" : value >= 25 ? "Running low" : "Drained"
    }
}

// MARK: Fitness (training)

struct TrainingPage: View {
    var store: FitnessStore

    var body: some View {
        let watch = store.snapshot?.watch
        FitPage(title: "Fitness") {
            vo2
            if let endurance = watch?.endurance { EnduranceSection(endurance: endurance) }
            if let races = watch?.races { RacesSection(races: races) }
            if let focus = watch?.focus { LoadFocusSection(focus: focus) }
            status
        }
    }

    @ViewBuilder private var vo2: some View {
        let watch = store.snapshot?.watch
        if let vo2 = store.snapshot?.metrics?.vo2max?.value ?? watch?.vo2max?.value {
            let fitness = store.snapshot?.insights?.age?.cardioFitness
            BigNumber(value: String(format: "%.1f", vo2), unit: nil,
                      caption: "VO2 max, ml/kg/min" + (fitness.map { " · \($0.level) for your age" } ?? ""), tint: Fit.activity)
            if let fitness {
                ScaleBar(stops: [0, 10, 50, 85, 100], colors: [Fit.attention, Fit.fair, Fit.faint, Fit.positive],
                         value: Double(fitness.percentile), labels: ("Low", "High"))
                Takeaway(text: "\(fitness.percentile)th percentile for your age and sex.").font(.caption).padding(.top, 6).padding(.bottom, 8)
            }
            if let history = watch?.vo2max?.history, history.count > 1 {
                FitSection(title: "VO2 max trend") {
                    TrendLineChart(points: FitData.points(history), tint: Fit.activity, format: { String(format: "%.1f", $0) })
                }
            }
        } else {
            BigNumber(value: "–", caption: "VO2 max comes from outdoor runs with steady pace and heart rate.")
        }
    }

    private var status: some View {
        let metrics = store.snapshot?.metrics
        let watch = store.snapshot?.watch
        return FitSection(title: "Training status", trailing: metrics?.load.status) {
            VStack(spacing: 0) {
                if let load = metrics?.load {
                    DetailRow(label: "Acute load, 7 days", value: "\(load.acute)")
                    DetailRow(label: "Chronic load, 28 days", value: "\(load.chronic)")
                    if let ratio = load.ratio { DetailRow(label: "Acute : chronic", value: String(format: "%.1f×", ratio)) }
                }
                if let threshold = watch?.lactateThreshold {
                    DetailRow(label: "Lactate threshold", value: "\(Int(threshold.hr)) bpm" + (FitnessFormat.pace(threshold.speed).map { " · \($0)" } ?? ""))
                }
                if let condition = store.snapshot?.insights?.training.performanceCondition, let value = condition.value {
                    DetailRow(label: "Performance condition", value: "\(value > 0 ? "+" : "")\(value)")
                }
                DetailRow(label: "HRV status", value: hrvStatus, last: true)
            }
        }
    }
}

extension TrainingPage {
    /// The watch's status, else the hub's; "none" and "building" mean no baseline yet.
    var hrvStatus: String {
        let status = store.snapshot?.hrv?.first?.status ?? store.snapshot?.metrics?.hrv.status
        guard let status, status != "none", status != "building" else { return "Building a baseline" }
        return status.capitalized
    }
}

// MARK: Health

struct HealthPage: View {
    var store: FitnessStore

    var body: some View {
        let insights = store.snapshot?.insights
        FitPage(title: "Health") {
            if let age = insights?.age, let hub = age.hubAge {
                BigNumber(value: String(format: "%.1f", hub.age), unit: "years",
                          caption: hub.difference <= 0 ? String(format: "Hub age, %.1f years younger than you", -hub.difference)
                                                       : String(format: "Hub age, %.1f years older than you", hub.difference),
                          tint: hub.difference <= 0 ? Fit.positive : Fit.fair)
                StatStrip(items: [("Your age", "\(age.age)"), ("Fitness age", "\(hub.fitnessAge)"),
                                  ("Cardio fitness", age.cardioFitness.map { "\($0.percentile)th" } ?? "–")])
                    .padding(.bottom, 8)
                FitSection(title: "What moves it") {
                    VStack(spacing: 18) {
                        ForEach(hub.parts) { part in
                            DivergingRow(title: part.label, value: -part.years, scale: 2,
                                         detail: part.years == 0 ? "±0 yrs" : String(format: "%+.1f yrs", part.years))
                        }
                    }
                    Takeaway(text: "Starts from the age your VO2 max matches, then adjusts for resting heart rate, HRV, sleep and exercise. Right of center makes you younger.").font(.caption)
                }
            } else {
                BigNumber(value: "–", caption: "Hub age needs your VO2 max and your age from the watch profile.")
            }
            if let vitals = insights?.vitals {
                FitSection(title: "Overnight vitals", trailing: vitals.calibrating ? "Calibrating" : vitals.outliers == 0 ? "All typical" : "\(vitals.outliers) outside range") {
                    VStack(spacing: 20) {
                        ForEach(vitals.readings) { RangeRow(reading: $0) }
                    }
                    if vitals.calibrating {
                        Takeaway(text: "Your typical ranges fill in after 7 nights of sleep data.").font(.caption)
                    }
                }
            }
        }
    }
}

/// A vital against your usual range: the band, and a dot where last night landed.
struct RangeRow: View {
    var reading: FitnessInsights.Vitals.Reading

    var body: some View {
        VStack(spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(name).font(.subheadline)
                Spacer()
                Text(reading.value.map(format) ?? "–").font(.subheadline).monospacedDigit()
                    .foregroundStyle(reading.outlier ? Fit.attention : .primary)
            }
            if let low = reading.low, let high = reading.high, let value = reading.value {
                let pad = max(high - low, 0.1)
                let lower = min(low - pad, value), upper = max(high + pad, value)
                GeometryReader { geo in
                    let x = { (v: Double) in geo.size.width * (v - lower) / (upper - lower) }
                    ZStack(alignment: .leading) {
                        Capsule().fill(Fit.track).frame(height: 3)
                        Capsule().fill(Fit.faint).frame(width: max(2, x(high) - x(low)), height: 3).offset(x: x(low))
                        Circle().fill(reading.outlier ? Fit.attention : Color.primary).frame(width: 9, height: 9).offset(x: x(value) - 4.5)
                    }
                    .frame(maxHeight: .infinity)
                }
                .frame(height: 10)
                Text("Usual \(format(low))–\(format(high))").font(Fit.axis).foregroundStyle(Fit.muted)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var name: String {
        ["heartRate": "Heart rate", "hrv": "HRV", "respiration": "Breathing rate", "spo2": "Blood oxygen", "sleepHours": "Sleep"][reading.key] ?? reading.key
    }

    private func format(_ value: Double) -> String {
        switch reading.key {
        case "heartRate": String(format: "%.0f bpm", value)
        case "hrv": String(format: "%.0f ms", value)
        case "respiration": String(format: "%.1f /min", value)
        case "spo2": String(format: "%.0f%%", value)
        case "sleepHours": WatchFormat.hours(value)
        default: String(format: "%.1f", value)
        }
    }
}

extension EnvironmentValues {
    /// FitnessRenderDebug: lay pages out without their scroll view so a renderer captures the full height.
    @Entry var fitnessRenderFlat = false
    /// The overview's Brick look: sections become centered headings over soft cards.
    @Entry var fitnessCards = false
}

/// A hairline between rows, visible on a card when the overview is in its card look.
struct FitDivider: View {
    @Environment(\.fitnessCards) private var cards
    var body: some View { Rectangle().fill(cards ? BrickLook.line : Fit.hairline).frame(height: 1) }
}
