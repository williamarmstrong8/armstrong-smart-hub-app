import Charts
import SwiftUI

/// The hub's Whoop, Oura, Garmin and Apple style scores
/// (lib/fitness/insights.ts and insight-metrics.ts in the hub): strain,
/// recovery, sleep need, resilience, training effect, load focus, threshold,
/// race times, ages and vitals. Every score that needs a baseline says how
/// many nights or days it still needs instead of guessing.
struct FitnessInsights: Decodable {
    var strain: Strain?
    var recovery: Recovery?
    var sleep: Sleep
    var stress: Stress
    var training: Training
    var age: Age?
    var vitals: Vitals?

    struct Strain: Decodable {
        var today: Double?
        var level: String?
        var week: [Day]
        struct Day: Decodable { var day: String; var strain: Double? }
    }

    /// Either `ready` with a score and zone, or `calibrating` with how many nights it has.
    struct Recovery: Decodable {
        var status: String
        var have: Int?
        var need: Int?
        var score: Int?
        var zone: String?
        /// What moved it: each input as standard deviations from your baseline (positive helps).
        var parts: [Part]?
        struct Part: Decodable, Identifiable { var key: String; var weight: Double; var z: Double; var id: String { key } }
    }

    struct Sleep: Decodable {
        var need: Need
        var lastNight: LastNight?
        var bedtimeSpread: Int?

        struct Need: Decodable { var hours: Double; var baseline: Double; var debt: Double; var strain: Double; var naps: Double }
        struct LastNight: Decodable {
            var asleepHours: Double
            var needed: Double?
            var performance: Int?
            var score: Int?
            var interruptions: Int
            var recoveryIndex: RecoveryIndex?
            var apple: AppleScore
        }
        struct RecoveryIndex: Decodable { var score: Int; var lowestHr: Int; var lowestAt: Double; var share: Double }
        struct AppleScore: Decodable { var score: Int; var duration: Int; var consistency: Int; var interruptions: Int }
    }

    struct Stress: Decodable {
        var now: Int?
        var today: Day
        var resilience: Resilience
        var bodyBattery: Battery?

        struct Day: Decodable { var stressedMinutes: Int; var restoredMinutes: Int; var summary: String? }
        struct Resilience: Decodable { var status: String; var have: Int?; var need: Int?; var level: String?; var daytime: Int?; var overnight: Int? }
        struct Battery: Decodable {
            var current: Int
            var high: Int
            var low: Int
            var series: [Point]
            struct Point: Decodable { var at: String; var value: Int }
        }
    }

    struct Training: Decodable {
        var lastWorkout: Workout?
        var focus: Focus
        var lactateThreshold: Threshold?
        var races: Races?
        var endurance: Endurance?
        var hill: Hill?
        var performanceCondition: Condition?
        var effortLoad: EffortLoad

        struct Workout: Decodable {
            var sport: String
            var at: String
            var minutes: Int
            var aerobic: Double?
            var aerobicLabel: String?
            var watchAerobic: Double?
            var anaerobic: Double?
            var anaerobicLabel: String?
            var watchAnaerobic: Double?
            var effort: Int?
            var strain: Double?
            var strainLevel: String?
        }
        struct Focus: Decodable { var low: Int; var high: Int; var anaerobic: Int; var status: String? }
        struct Threshold: Decodable { var heartRate: Int; var measured: Bool; var speed: Double?; var percentOfMax: Int }
        struct Races: Decodable {
            var fiveK: Int
            var tenK: Int
            var half: Int
            var marathon: Int
            enum CodingKeys: String, CodingKey { case fiveK = "5k", tenK = "10k", half, marathon }
        }
        struct Endurance: Decodable { var score: Int; var tier: String; var longLoad: Int }
        struct Hill: Decodable { var score: Int; var strength: Int; var endurance: Int; var climbed: Int }
        struct Condition: Decodable { var value: Int?; var at: String }
        struct EffortLoad: Decodable { var week: Int; var month: Int; var trend: String? }
    }

    struct Age: Decodable {
        var age: Int
        var cardioFitness: CardioFitness?
        var hubAge: HubAge?
        var paceOfAging: Double?

        struct CardioFitness: Decodable { var percentile: Int; var level: String; var lowFitness: Bool }
        struct HubAge: Decodable {
            var age: Double
            var fitnessAge: Int
            var difference: Double
            var parts: [Part]
            struct Part: Decodable, Identifiable { var key: String; var label: String; var years: Double; var id: String { key } }
        }
    }

    struct Vitals: Decodable {
        var readings: [Reading]
        var outliers: Int
        var calibrating: Bool
        struct Reading: Decodable, Identifiable {
            var key: String
            var value: Double?
            var low: Double?
            var high: Double?
            var outlier: Bool
            var have: Int
            var id: String { key }
        }
    }
}

private enum InsightFormat {
    static func hours(_ value: Double) -> String {
        let minutes = Int((value * 60).rounded())
        return "\(minutes / 60)h \(String(format: "%02d", minutes % 60))m"
    }

    static func raceTime(_ seconds: Int) -> String {
        seconds >= 3600
            ? String(format: "%d:%02d:%02d", seconds / 3600, seconds % 3600 / 60, seconds % 60)
            : String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    /// Pace for a speed in m/s, per mile or km by the phone's region.
    static func pace(_ speed: Double) -> String {
        let miles = Locale.current.measurementSystem == .us
        let seconds = Int(((miles ? 1609.344 : 1000) / speed).rounded())
        return String(format: "%d:%02d /%@", seconds / 60, seconds % 60, miles ? "mi" : "km")
    }

    static func recoveryColor(_ zone: String?) -> Color {
        switch zone { case "green": .green; case "yellow": .yellow; case "red": .red; default: .secondary }
    }

    static func effectColor(_ value: Double?) -> Color {
        guard let value else { return .secondary }
        return value < 2 ? .gray : value < 3 ? .blue : value < 4 ? .green : value < 5 ? .orange : .red
    }
}

/// A Whoop-style dial: a ring filled to `fraction`, a big value and a caption.
private struct Dial: View {
    var title: String
    var value: String
    var fraction: Double
    var tint: Color
    var caption: String?

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                Circle().stroke(Color.primary.opacity(0.08), lineWidth: 9)
                Circle().trim(from: 0, to: max(0, min(1, fraction)))
                    .stroke(tint, style: StrokeStyle(lineWidth: 9, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text(value)
                    .font(.system(size: 24, weight: .heavy, design: .rounded))
                    .monospacedDigit()
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
                    .padding(.horizontal, 8)
            }
            .frame(width: 88, height: 88)
            Text(title).font(.caption.weight(.semibold))
            if let caption {
                Text(caption).font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.center).lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

/// A labelled 0-`max` bar, for training effect and score parts.
private struct ScoreBar: View {
    var label: String
    var value: Double?
    var max: Double
    var tint: Color
    var detail: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(label).font(.caption.weight(.semibold))
                Spacer(minLength: 6)
                if let detail { Text(detail).font(.caption2).foregroundStyle(.secondary).lineLimit(1) }
            }
            Capsule().fill(Color.primary.opacity(0.08)).frame(height: 6)
                .overlay(alignment: .leading) {
                    if let value {
                        GeometryReader { geo in
                            Capsule().fill(tint).frame(width: Swift.max(6, geo.size.width * Swift.min(1, value / max)))
                        }
                    }
                }
        }
    }
}

// MARK: Recovery, strain, sleep (Whoop)

struct RecoveryStrainSection: View {
    var insights: FitnessInsights

    var body: some View {
        FloatingSection(title: "Recovery & strain", trailing: insights.strain?.level?.capitalized) {
            HStack(alignment: .top, spacing: 8) {
                recoveryDial
                Dial(title: "Strain",
                     value: insights.strain?.today.map { String(format: "%.1f", $0) } ?? "–",
                     fraction: (insights.strain?.today ?? 0) / 21, tint: .blue,
                     caption: "of 21 today")
                Dial(title: "Sleep",
                     value: insights.sleep.lastNight?.performance.map { "\($0)%" } ?? "–",
                     fraction: Double(insights.sleep.lastNight?.performance ?? 0) / 100, tint: .indigo,
                     caption: insights.sleep.lastNight.map { night in
                         night.needed.map { "\(InsightFormat.hours(night.asleepHours)) of \(InsightFormat.hours($0))" } ?? InsightFormat.hours(night.asleepHours)
                     })
            }
            if let week = insights.strain?.week, week.contains(where: { $0.strain != nil }) {
                let days = week.compactMap { day -> (Date, Double)? in
                    guard let strain = day.strain, let date = DateOnly.parse(day.day) else { return nil }
                    return (date, strain)
                }
                Chart(days, id: \.0) { day in
                    BarMark(x: .value("Day", day.0, unit: .day), y: .value("Strain", day.1), width: .ratio(0.5))
                        .foregroundStyle(.blue.gradient)
                        .cornerRadius(4)
                }
                .chartYScale(domain: 0...21)
                .chartYAxis { AxisMarks(values: [0, 10, 14, 18, 21]) { _ in AxisGridLine(); AxisValueLabel() } }
                .chartXAxis { AxisMarks(values: .stride(by: .day)) { _ in AxisValueLabel(format: .dateTime.weekday(.narrow)) } }
                .frame(height: 100)
            }
        }
    }

    @ViewBuilder private var recoveryDial: some View {
        if let recovery = insights.recovery, recovery.status == "ready", let score = recovery.score {
            Dial(title: "Recovery", value: "\(score)%", fraction: Double(score) / 100,
                 tint: InsightFormat.recoveryColor(recovery.zone), caption: recovery.zone.map { "\($0.capitalized) zone" })
        } else if let recovery = insights.recovery, let have = recovery.have, let need = recovery.need {
            Dial(title: "Recovery", value: "\(have)/\(need)", fraction: Double(have) / Double(max(need, 1)), tint: .secondary,
                 caption: "Learning your baseline")
        } else {
            Dial(title: "Recovery", value: "–", fraction: 0, tint: .secondary, caption: "Needs last night's HRV")
        }
    }
}

struct SleepCoachSection: View {
    var sleep: FitnessInsights.Sleep
    /// When the watch gives its own sleep need, the hub's breakdown of it is left out.
    var watchNeed = false

    var body: some View {
        FloatingSection(title: watchNeed ? "Sleep habits" : "Sleep need",
                        trailing: watchNeed ? nil : "\(InsightFormat.hours(sleep.need.hours)) tonight") {
            if !watchNeed {
            VStack(spacing: 10) {
                LabeledContent("Your baseline", value: InsightFormat.hours(sleep.need.baseline))
                if sleep.need.debt > 0 { LabeledContent("Sleep debt", value: "+\(InsightFormat.hours(sleep.need.debt))") }
                if sleep.need.strain > 0.05 { LabeledContent("Today's strain", value: "+\(InsightFormat.hours(sleep.need.strain))") }
                if sleep.need.naps > 0 { LabeledContent("Naps", value: "−\(InsightFormat.hours(sleep.need.naps))") }
            }
            .font(.subheadline)
            }
            if let night = sleep.lastNight {
                if !watchNeed { Divider().opacity(0.4) }
                HStack(alignment: .firstTextBaseline) {
                    Text("Last night").font(.subheadline.weight(.semibold))
                    Spacer()
                    Text("Apple-style score \(night.apple.score)").font(.subheadline).foregroundStyle(.secondary)
                }
                VStack(spacing: 9) {
                    ScoreBar(label: "Duration", value: Double(night.apple.duration), max: 50, tint: .indigo,
                             detail: InsightFormat.hours(night.asleepHours))
                    ScoreBar(label: "Bedtime consistency", value: Double(night.apple.consistency), max: 30, tint: .indigo,
                             detail: sleep.bedtimeSpread.map { "±\($0) min over 2 weeks" } ?? "Needs 3 nights")
                    ScoreBar(label: "Interruptions", value: Double(night.apple.interruptions), max: 20, tint: .indigo,
                             detail: night.interruptions == 1 ? "Woke once" : "Woke \(night.interruptions) times")
                    if let index = night.recoveryIndex {
                        ScoreBar(label: "Recovery index", value: Double(index.score), max: 100, tint: .teal,
                                 detail: "Lowest \(index.lowestHr) bpm at \(Date(timeIntervalSince1970: index.lowestAt / 1000).formatted(date: .omitted, time: .shortened))")
                    }
                }
                if night.recoveryIndex == nil {
                    Text("Recovery index appears once a sync carries overnight heart rate: it shows how early in the night your heart rate bottomed out.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}

// MARK: Daytime balance (Oura)

struct BalanceSection: View {
    var stress: FitnessInsights.Stress

    var body: some View {
        FloatingSection(title: "Stress & resilience", trailing: stress.today.summary?.capitalized) {
            HStack(alignment: .top, spacing: 12) {
                BigMetric(symbol: "battery-2", tint: .teal, title: "Body Battery",
                          value: stress.bodyBattery.map { "\($0.current)" } ?? "–")
                BigMetric(symbol: "activity", tint: .orange, title: "Stress now", value: stress.now.map(String.init) ?? "–")
                BigMetric(symbol: "target", tint: .purple, title: "Resilience", value: resilienceValue)
            }
            if let battery = stress.bodyBattery {
                let points = battery.series.compactMap { p in ISO.parse(p.at).map { ($0, p.value) } }
                Chart(points, id: \.0) { point in
                    AreaMark(x: .value("Time", point.0), y: .value("Battery", point.1))
                        .interpolationMethod(.monotone)
                        .foregroundStyle(LinearGradient(colors: [.teal.opacity(0.3), .teal.opacity(0)], startPoint: .top, endPoint: .bottom))
                    LineMark(x: .value("Time", point.0), y: .value("Battery", point.1))
                        .interpolationMethod(.monotone)
                        .foregroundStyle(.teal)
                }
                .chartYScale(domain: 0...100)
                .chartYAxis(.hidden)
                .chartXAxis { AxisMarks(values: .stride(by: .hour, count: 6)) { _ in AxisValueLabel(format: .dateTime.hour()) } }
                .frame(height: 90)
                Text("Body Battery from the watch: high \(battery.high), low \(battery.low) in the last day.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            VStack(spacing: 10) {
                LabeledContent("Stressed today", value: FitnessFormat.duration(Double(stress.today.stressedMinutes * 60)))
                LabeledContent("Restored today", value: FitnessFormat.duration(Double(stress.today.restoredMinutes * 60)))
            }
            .font(.subheadline)
            Text(resilienceCaption).font(.caption).foregroundStyle(.secondary)
        }
    }

    private var resilienceValue: String {
        if stress.resilience.status == "ready", let level = stress.resilience.level { return level.capitalized }
        return "\(stress.resilience.have ?? 0)/\(stress.resilience.need ?? 5)"
    }

    private var resilienceCaption: String {
        if stress.resilience.status == "ready", let daytime = stress.resilience.daytime, let overnight = stress.resilience.overnight {
            return "Resilience is 14 days of recovery against stress: daytime \(daytime)%, overnight \(overnight)%."
        }
        return "Resilience needs 5 days with a few hours of the watch's stress readings; it has \(stress.resilience.have ?? 0)."
    }
}

// MARK: Last workout (Garmin, Apple)

struct WorkoutEffectSection: View {
    var workout: FitnessInsights.Training.Workout

    var body: some View {
        FloatingSection(title: "Last workout", trailing: ISO.parse(workout.at)?.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())) {
            HStack(alignment: .firstTextBaseline) {
                Text("\(FitnessFormat.name(workout.sport)) · \(workout.minutes) min").font(.subheadline.weight(.semibold))
                Spacer()
                if let effort = workout.effort {
                    Text("Effort \(effort)/10").font(.subheadline.weight(.semibold)).foregroundStyle(effortColor(effort))
                }
            }
            VStack(spacing: 10) {
                ScoreBar(label: "Aerobic", value: workout.aerobic, max: 5, tint: InsightFormat.effectColor(workout.aerobic),
                         detail: effectDetail(workout.aerobic, workout.aerobicLabel, watch: workout.watchAerobic))
                ScoreBar(label: "Anaerobic", value: workout.anaerobic, max: 5, tint: InsightFormat.effectColor(workout.anaerobic),
                         detail: effectDetail(workout.anaerobic, workout.anaerobicLabel, watch: workout.watchAnaerobic))
                if let strain = workout.strain {
                    ScoreBar(label: "Strain", value: strain, max: 21, tint: .blue,
                             detail: String(format: "%.1f · %@", strain, workout.strainLevel ?? ""))
                }
            }
        }
    }

    private func effectDetail(_ value: Double?, _ label: String?, watch: Double?) -> String {
        guard let value else { return "–" }
        let watchText = watch.map { String(format: " · watch %.1f", $0) } ?? ""
        return String(format: "%.1f %@", value, label ?? "") + watchText
    }

    private func effortColor(_ effort: Int) -> Color {
        effort <= 3 ? .green : effort <= 6 ? .yellow : effort <= 8 ? .orange : .red
    }
}

// MARK: Training (Garmin)

struct TrainingInsightsSection: View {
    var training: FitnessInsights.Training
    /// When the watch gives its own load focus, Endurance Score, threshold and
    /// race predictions, the hub's estimates of them are left out.
    var watchCovers = false

    var body: some View {
        FloatingSection(title: "Training analysis", trailing: watchCovers ? nil : training.focus.status) {
            if !watchCovers {
            focus
            HStack(alignment: .top, spacing: 12) {
                BigMetric(symbol: "heart", tint: .red, title: "Threshold",
                          value: training.lactateThreshold.map { "\($0.heartRate)" } ?? "–")
                BigMetric(symbol: "run", tint: .green, title: "Endurance", value: training.endurance.map { "\($0.score)" } ?? "–")
                BigMetric(symbol: "mountain", tint: .brown, title: "Hill score", value: training.hill.map { "\($0.score)" } ?? "–")
            }
            }
            VStack(spacing: 10) {
                if !watchCovers, let threshold = training.lactateThreshold {
                    LabeledContent("Lactate threshold", value: thresholdText(threshold))
                }
                if !watchCovers, let endurance = training.endurance { LabeledContent("Endurance level", value: endurance.tier) }
                if let condition = training.performanceCondition, let value = condition.value {
                    LabeledContent("Performance condition", value: "\(value > 0 ? "+" : "")\(value) on \(ISO.parse(condition.at)?.formatted(.dateTime.month(.abbreviated).day()) ?? "last run")")
                }
                if let trend = training.effortLoad.trend {
                    LabeledContent("Training load", value: "\(trend.capitalized) · \(training.effortLoad.week) vs \(training.effortLoad.month) a day")
                }
            }
            .font(.subheadline)
            if !watchCovers, let races = training.races {
                Divider().opacity(0.4)
                Text("Race predictor").font(.subheadline.weight(.semibold))
                HStack {
                    race("5K", races.fiveK)
                    race("10K", races.tenK)
                    race("Half", races.half)
                    race("Marathon", races.marathon)
                }
            }
        }
    }

    @ViewBuilder private var focus: some View {
        let total = training.focus.low + training.focus.high + training.focus.anaerobic
        if total > 0 {
            VStack(alignment: .leading, spacing: 8) {
                GeometryReader { geo in
                    HStack(spacing: 2) {
                        Rectangle().fill(.blue).frame(width: geo.size.width * Double(training.focus.low) / Double(total))
                        Rectangle().fill(.orange).frame(width: geo.size.width * Double(training.focus.high) / Double(total))
                        Rectangle().fill(.purple).frame(width: geo.size.width * Double(training.focus.anaerobic) / Double(total))
                    }
                    .clipShape(Capsule())
                }
                .frame(height: 10)
                HStack(spacing: 12) {
                    Label("Low aerobic \(training.focus.low)", systemImage: "circle.fill").labelStyle(TintedDot(color: .blue))
                    Label("High \(training.focus.high)", systemImage: "circle.fill").labelStyle(TintedDot(color: .orange))
                    Label("Anaerobic \(training.focus.anaerobic)", systemImage: "circle.fill").labelStyle(TintedDot(color: .purple))
                }
                .font(.caption).foregroundStyle(.secondary)
            }
        } else {
            Text("Load focus fills in with the next 4 weeks of workouts: how your training splits between easy aerobic, hard aerobic and anaerobic work.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func thresholdText(_ threshold: FitnessInsights.Training.Threshold) -> String {
        let pace = threshold.speed.map { " · \(InsightFormat.pace($0))" } ?? ""
        return "\(threshold.heartRate) bpm\(pace)\(threshold.measured ? "" : " (estimated)")"
    }

    private func race(_ name: String, _ seconds: Int) -> some View {
        VStack(spacing: 2) {
            Text(InsightFormat.raceTime(seconds)).font(.subheadline.weight(.semibold)).monospacedDigit()
            Text(name).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: Health (Whoop, Apple)

struct HealthInsightsSection: View {
    var age: FitnessInsights.Age?
    var vitals: FitnessInsights.Vitals?

    var body: some View {
        FloatingSection(title: "Health", trailing: vitals.map { $0.calibrating ? "Calibrating" : $0.outliers == 0 ? "Vitals typical" : "\($0.outliers) outside range" }) {
            if let hub = age?.hubAge, let age {
                HStack(alignment: .top, spacing: 12) {
                    BigMetric(symbol: "target", tint: hub.difference <= 0 ? .green : .orange, title: "Hub age", value: String(format: "%.1f", hub.age))
                    BigMetric(symbol: "lungs", tint: .orange, title: "Fitness age", value: "\(hub.fitnessAge)")
                    BigMetric(symbol: "heart", tint: cardioColor, title: "Cardio fitness",
                              value: age.cardioFitness.map { "\($0.percentile)%" } ?? "–")
                }
                VStack(spacing: 9) {
                    ForEach(hub.parts) { part in
                        LabeledContent(part.label, value: part.years == 0 ? "±0 yrs" : String(format: "%+.1f yrs", part.years))
                    }
                }
                .font(.subheadline)
                Text(ageCaption(hub, age: age)).font(.caption).foregroundStyle(.secondary)
            }
            if let vitals {
                Divider().opacity(0.4)
                Text("Overnight vitals").font(.subheadline.weight(.semibold))
                VStack(spacing: 9) {
                    ForEach(vitals.readings) { reading in
                        HStack {
                            Text(name(reading.key))
                            Spacer()
                            if let low = reading.low, let high = reading.high {
                                Text("\(format(reading.key, low))–\(format(reading.key, high))").font(.caption).foregroundStyle(.secondary)
                            }
                            Text(reading.value.map { format(reading.key, $0) } ?? "–")
                                .monospacedDigit()
                                .foregroundStyle(reading.outlier ? .orange : .primary)
                                .frame(minWidth: 56, alignment: .trailing)
                        }
                        .font(.subheadline)
                    }
                }
                if vitals.calibrating {
                    Text("Your typical ranges appear after 7 nights of sleep data.").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var cardioColor: Color {
        guard let fitness = age?.cardioFitness else { return .secondary }
        return fitness.lowFitness ? .red : fitness.percentile >= 50 ? .green : .yellow
    }

    private func ageCaption(_ hub: FitnessInsights.Age.HubAge, age: FitnessInsights.Age) -> String {
        let cardio = age.cardioFitness.map { " Cardio fitness is \($0.level) for your age and sex." } ?? ""
        let diff = hub.difference <= 0 ? String(format: "%.1f years younger", -hub.difference) : String(format: "%.1f years older", hub.difference)
        return "Built from VO2max, resting heart rate, HRV, sleep and exercise: \(diff) than your age of \(age.age).\(cardio)"
    }

    private func name(_ key: String) -> String {
        switch key {
        case "heartRate": "Heart rate"
        case "hrv": "HRV"
        case "respiration": "Respiration"
        case "spo2": "SpO2"
        case "sleepHours": "Sleep"
        default: key
        }
    }

    private func format(_ key: String, _ value: Double) -> String {
        switch key {
        case "heartRate": String(format: "%.0f bpm", value)
        case "hrv": String(format: "%.0f ms", value)
        case "respiration": String(format: "%.1f", value)
        case "spo2": String(format: "%.0f%%", value)
        case "sleepHours": InsightFormat.hours(value)
        default: String(format: "%.1f", value)
        }
    }
}

/// "YYYY-MM-DD" as local midnight.
enum DateOnly {
    static func parse(_ day: String) -> Date? {
        let parts = day.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return Calendar.current.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }
}
