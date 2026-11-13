import SwiftUI

/// Sections for the hub's newer scores (lib/fitness/scores.ts in the hub):
/// readiness by contributor, sleep debt, chronotype, regularity, stage
/// balance, breathing, the strain target, zones, fitness and form, training
/// status, cardio recovery and the health monitor. Each draws nothing until
/// the hub sends its block, so the pages still work against an older hub.

enum ScoreFormat {
    /// Minutes after midnight (negative before it) as a clock time.
    static func clock(_ minutes: Int) -> String {
        let wrapped = ((minutes % 1440) + 1440) % 1440
        let date = Calendar.current.date(bySettingHour: wrapped / 60, minute: wrapped % 60, second: 0, of: .now) ?? .now
        return date.formatted(date: .omitted, time: .shortened)
    }

    static func learning(_ have: Int?, _ need: Int?, _ unit: String) -> String {
        "Needs \(need ?? 0) \(unit), has \(have ?? 0)"
    }

    static func levelColor(_ level: String?) -> Color? {
        switch level {
        case "none", "normal", "stable", "no signs", "very regular", "regular", "excellent", "good", "varied", "optimal": Fit.positive
        case "low", "fair", "moderate", "elevated", "variable", "minor signs", "somewhat irregular": Fit.fair
        case "high", "unstable", "major signs", "irregular", "pay attention": Fit.attention
        default: nil
        }
    }
}

// MARK: Readiness

/// The hub's readiness, contributor by contributor, the way Oura lays its out.
struct ContributorReadinessSection: View {
    var readiness: FitnessInsights.ContributorReadiness

    var body: some View {
        FitSection(title: "Why, by contributor", trailing: readiness.score.map { "\($0) · \((readiness.level ?? "").capitalized)" }) {
            VStack(spacing: 18) {
                ForEach(readiness.contributors) { part in
                    ContributorRow(title: part.label, detail: part.detail, fraction: part.score.map { Double($0) / 100 },
                                   tint: Status.color(part.score) == .primary ? Fit.readiness : Status.color(part.score))
                }
            }
            Takeaway(text: "Each part against your own baseline: last night's heart rate and HRV, how early your heart rate settled, sleep, and how yesterday and this week compare with your usual load.").font(.caption)
        }
    }
}

// MARK: Strain

struct StrainTargetSection: View {
    var target: FitnessInsights.Strain.Target
    var today: Double?

    var body: some View {
        FitSection(title: "Today's target", trailing: String(format: "%.0f–%.0f", target.low, target.high)) {
            ScaleBar(stops: [0, target.low, target.high, 21], colors: [Fit.faint, Fit.positive, Fit.fair], value: today ?? 0, labels: ("0", "21"))
            Takeaway(text: target.advice + (target.state.map { state in
                state == "below" ? " You're under the range so far." : state == "above" ? " You're past the range: enough for today." : " You're in the range."
            } ?? "")).font(.caption)
        }
    }
}

struct ZoneMinutesSection: View {
    var zone: FitnessInsights.Training.ZoneMinutes

    var body: some View {
        FitSection(title: "Active zone minutes", trailing: "\(zone.week) of \(zone.goal) this week") {
            DailyBarChart(points: zone.days.compactMap { d in DateOnly.parse(d.day).map { DayValue(date: $0, value: Double(d.minutes)) } },
                          tint: Fit.activity, height: 140)
            Takeaway(text: "A minute with your heart rate in the fat-burn zone earns one; cardio and peak minutes earn two. 150 a week is the health guideline.").font(.caption)
        }
    }
}

// MARK: Sleep

struct SleepStageBalanceSection: View {
    var stages: [FitnessInsights.Sleep.StageShare]

    var body: some View {
        FitSection(title: "Stage balance") {
            VStack(spacing: 0) {
                ForEach(Array(stages.enumerated()), id: \.element.id) { index, stage in
                    DetailRow(label: name(stage.key), value: "\(stage.share)% · \(word(stage)) (\(stage.low)–\(stage.high)%)",
                              valueColor: stage.status == "typical" ? nil : Fit.fair, last: index == stages.count - 1)
                }
            }
            Takeaway(text: "Each stage as a share of your sleep against the healthy range for adults.").font(.caption)
        }
    }

    private func name(_ key: String) -> String { ["deep": "Deep", "light": "Light", "rem": "REM"][key] ?? key }
    private func word(_ stage: FitnessInsights.Sleep.StageShare) -> String {
        stage.status == "typical" ? "typical" : stage.status == "low" ? "below range" : "above range"
    }
}

struct SleepPatternSection: View {
    var sleep: FitnessInsights.Sleep

    var body: some View {
        FitSection(title: "Your pattern") {
            VStack(spacing: 0) {
                if let efficiency = sleep.lastNight?.efficiency {
                    DetailRow(label: "Sleep efficiency", value: "\(efficiency)%", valueColor: efficiency >= 85 ? nil : Fit.fair)
                }
                if let debt = sleep.debt {
                    DetailRow(label: "Sleep debt, 2 weeks",
                              value: debt.status == "ready" ? (debt.hours.map { $0 < 0.1 ? "None" : "\(WatchFormat.hours($0)) · \((debt.level ?? "").capitalized)" } ?? "–")
                                  : ScoreFormat.learning(debt.have, debt.need, "nights"),
                              valueColor: debt.status == "ready" ? ScoreFormat.levelColor(debt.level) : nil)
                }
                if let regularity = sleep.regularity {
                    DetailRow(label: "Sleep regularity",
                              value: regularity.status == "ready" ? "\(regularity.score ?? 0) of 100 · \((regularity.level ?? "").capitalized)"
                                  : ScoreFormat.learning(regularity.have, regularity.need, "days"),
                              valueColor: regularity.status == "ready" ? ScoreFormat.levelColor(regularity.level) : nil)
                }
                if let chronotype = sleep.chronotype {
                    if chronotype.status == "ready", let midpoint = chronotype.midpoint {
                        DetailRow(label: "Chronotype", value: "\((chronotype.type ?? "").capitalized) · midpoint \(ScoreFormat.clock(midpoint))")
                        if let bed = chronotype.bedtime, let wake = chronotype.wake {
                            DetailRow(label: "Usual night", value: "\(ScoreFormat.clock(bed))–\(ScoreFormat.clock(wake))")
                        }
                        if let jetlag = chronotype.socialJetlagMinutes {
                            DetailRow(label: "Weekend shift", value: jetlag < 60 ? "\(jetlag) min" : WatchFormat.hours(Double(jetlag) / 60),
                                      valueColor: jetlag >= 60 ? Fit.fair : nil)
                        }
                    } else {
                        DetailRow(label: "Chronotype", value: ScoreFormat.learning(chronotype.have, chronotype.need, "nights"))
                    }
                }
                let naps = sleep.naps ?? []
                DetailRow(label: "Naps, last 7 days",
                          value: naps.isEmpty ? "None" : "\(naps.count) · \(FitnessFormat.duration(Double(naps.map(\.minutes).reduce(0, +) * 60)))", last: true)
            }
            Takeaway(text: "Regularity is the chance you're asleep at the same times from one day to the next; over 87 is the most regular fifth of people. Debt adds every hour short of your need and pays back at half speed.").font(.caption)
        }
    }
}

struct BreathingSection: View {
    var breathing: FitnessInsights.Sleep.Breathing

    var body: some View {
        FitSection(title: "Overnight breathing", trailing: breathing.level.capitalized, trailingTint: ScoreFormat.levelColor(breathing.level)) {
            VStack(spacing: 0) {
                DetailRow(label: "Oxygen dips an hour", value: String(format: "%.1f", breathing.index))
                DetailRow(label: "Average blood oxygen", value: String(format: "%.0f%%", breathing.average))
                DetailRow(label: "Lowest", value: String(format: "%.0f%%", breathing.lowest))
                DetailRow(label: "Time under 90%", value: "\(breathing.minutesBelow90) min", last: true)
            }
            Takeaway(text: "Falls of 3 points or more in blood oxygen, from \(String(format: "%.1f", breathing.hours)) hours of readings. Under 5 an hour is normal. A wrist sensor is noisy, so watch the trend, not one night.").font(.caption)
        }
    }
}

// MARK: Training

struct TrainingStatusSection: View {
    var status: FitnessInsights.Training.Status

    var body: some View {
        FitSection(title: "Training status", trailing: status.label, trailingTint: color) {
            Takeaway(text: status.detail)
            if let trend = status.vo2maxTrend {
                DetailRow(label: "VO2 max against 4 weeks ago", value: trend == 0 ? "No change" : String(format: "%+.1f", trend), last: true)
            }
        }
    }

    private var color: Color? {
        switch status.key {
        case "productive", "peaking": Fit.positive
        case "maintaining", "recovery": nil
        case "no status": nil
        default: Fit.fair
        }
    }
}

struct FormSection: View {
    var form: FitnessInsights.Training.Form

    var body: some View {
        FitSection(title: "Fitness and form", trailing: form.label) {
            StatStrip(items: [("Fitness", String(format: "%.0f", form.fitness)), ("Fatigue", String(format: "%.0f", form.fatigue)),
                              ("Form", String(format: "%+.0f", form.form))])
            let points = form.series.compactMap { d in DateOnly.parse(d.day).map { DayValue(date: $0, value: d.fitness) } }
            if points.count > 7 {
                TrendLineChart(points: points, tint: Fit.activity, height: 130, format: { String(format: "Fitness %.0f", $0) })
            }
            Takeaway(text: "Fitness is your training load averaged over 6 weeks, fatigue over 1. Form is the gap: well below zero means you're carrying fatigue, above 5 means fresh."
                     + (form.ramp.map { $0 > 8 ? String(format: " Fitness rose %.0f this week, faster than is safe to keep up.", $0) : "" } ?? "")).font(.caption)
        }
    }
}

struct ZoneDistributionSection: View {
    var zones: FitnessInsights.Training.Zones
    var monotony: FitnessInsights.Training.Monotony?

    var body: some View {
        let month = zones.month
        if month.minutes.contains(where: { $0 > 0 }) {
            FitSection(title: "Heart rate zones", trailing: month.pattern ?? "Last 4 weeks") {
                let top = Double(max(month.minutes.max() ?? 1, 1))
                VStack(spacing: 14) {
                    ForEach(Array(month.minutes.prefix(5).enumerated()), id: \.offset) { index, minutes in
                        ContributorRow(title: "Zone \(index + 1)", detail: FitnessFormat.duration(Double(minutes * 60)),
                                       fraction: Double(minutes) / top, tint: Self.colors[index])
                    }
                }
                if let low = month.low, let moderate = month.moderate, let high = month.high {
                    Takeaway(text: "\(low)% easy, \(moderate)% moderate, \(high)% hard over 4 weeks. Most endurance plans aim for about 80% easy and the rest hard."
                             + (monotony.map { $0.level == "high" ? " Your days this week were very alike: mix in an easy day." : "" } ?? "")).font(.caption)
                }
            }
        }
    }

    static let colors: [Color] = [Fit.faint, Fit.positive, Fit.energy, Fit.activity, Fit.attention]
}

struct CardioRecoveryRow: View {
    var recovery: FitnessInsights.Training.CardioRecovery
    var last = false

    var body: some View {
        DetailRow(label: "Cardio recovery, 2 min", value: "\(recovery.average) bpm · \(recovery.level.capitalized)",
                  valueColor: ScoreFormat.levelColor(recovery.level), last: last)
    }
}

// MARK: Health

struct HealthMonitorSection: View {
    var health: FitnessInsights.Health

    var body: some View {
        if let monitor = health.monitor {
            FitSection(title: "Health monitor", trailing: monitor.status == "ready" ? monitor.level?.capitalized : "Calibrating",
                       trailingTint: ScoreFormat.levelColor(monitor.level)) {
                if monitor.status == "ready", let signs = monitor.signs {
                    VStack(spacing: 18) {
                        ForEach(signs) { sign in
                            // Left of center is strain; the hub's z already points that way.
                            DivergingRow(title: sign.label, value: -sign.z, scale: 3, detail: detail(sign))
                        }
                    }
                    Takeaway(text: "Last night against your last 4 weeks. Heart rate or breathing up with HRV down, two or more at once, often shows a day or two before you feel ill.").font(.caption)
                } else {
                    Takeaway(text: "\(ScoreFormat.learning(monitor.have, monitor.need, "nights")). It compares each night's heart rate, HRV, breathing and blood oxygen with your usual.")
                }
                if let stability = health.hrvStability, stability.status == "ready", let cv = stability.cv {
                    DetailRow(label: "HRV swing, 7 nights", value: String(format: "%.0f%% · %@", cv, (stability.level ?? "").capitalized),
                              valueColor: ScoreFormat.levelColor(stability.level), last: true)
                }
            }
        }
    }

    private func detail(_ sign: FitnessInsights.Health.Monitor.Sign) -> String {
        switch sign.key {
        case "restingHr": String(format: "%.0f bpm, usually %.0f", sign.value, sign.usual)
        case "hrv": String(format: "%.0f ms, usually %.0f", sign.value, sign.usual)
        case "respiration": String(format: "%.1f /min, usually %.1f", sign.value, sign.usual)
        default: String(format: "%.0f%%, usually %.0f%%", sign.value, sign.usual)
        }
    }
}
