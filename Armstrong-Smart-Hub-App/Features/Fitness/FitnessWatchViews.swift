import Charts
import SwiftUI

// MARK: Fitness sections

/// Endurance Score on Garmin's level scale, with how far to the next level.
struct EnduranceSection: View {
    var endurance: FitnessWatch.Endurance

    private static let levels = ["intermediate", "trained", "well trained", "expert", "superior", "elite"]

    var body: some View {
        FitSection(title: "Endurance score", trailing: endurance.level.capitalized) {
            HStack(alignment: .firstTextBaseline) {
                Text(endurance.score.formatted()).font(Fit.number(40))
                Spacer()
                if let next = endurance.nextLevel {
                    Text("\(Int(next.at) - endurance.score) to \(next.name)").font(Fit.label).foregroundStyle(Fit.muted)
                }
            }
            let low = endurance.gauge?.low ?? Double(endurance.score) * 0.6
            let high = endurance.gauge?.high ?? Double(endurance.score) * 1.6
            let stops = [low] + Self.levels.compactMap { endurance.bounds[$0] ?? nil } + [high]
            ScaleBar(stops: stops, colors: (0..<stops.count).map { Fit.positive.opacity(0.25 + 0.75 * Double($0) / Double(max(stops.count - 1, 1))) },
                     value: Double(endurance.score), labels: ("Recreational", "Elite"))
            Takeaway(text: "How long you can hold an effort, from all your training. It moves over weeks, not days.").font(.caption)
        }
    }
}

/// The watch's race predictions as plain rows.
struct RacesSection: View {
    var races: FitnessWatch.Races

    var body: some View {
        let rows: [(String, Int?, Double)] = [("5K", races.fiveK, 5000), ("10K", races.tenK, 10000),
                                             ("Half marathon", races.half, 21097.5), ("Marathon", races.marathon, 42195)]
        let shown = rows.filter { $0.1 != nil }
        FitSection(title: "Race predictions", trailing: "From your watch") {
            VStack(spacing: 0) {
                ForEach(Array(shown.enumerated()), id: \.offset) { index, row in
                    VStack(spacing: 0) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(row.0).font(.subheadline)
                            Spacer()
                            Text(FitnessFormat.pace(row.2 / Double(row.1 ?? 1)) ?? "").font(Fit.label).foregroundStyle(Fit.muted)
                                .padding(.trailing, 14)
                            Text(WatchFormat.raceTime(row.1 ?? 0)).font(.system(size: 20, weight: .light).monospacedDigit())
                                .frame(minWidth: 84, alignment: .trailing)
                        }
                        .padding(.vertical, 11)
                        if index < shown.count - 1 { FitDivider() }
                    }
                }
            }
        }
    }
}

/// Four weeks of load in Garmin's three buckets, against the watch's targets.
struct LoadFocusSection: View {
    var focus: FitnessWatch.Focus

    var body: some View {
        FitSection(title: "Load focus", trailing: "Last 4 weeks") {
            VStack(spacing: 20) {
                row("Low aerobic", focus.low, focus.targets.low, Fit.readiness)
                row("High aerobic", focus.high, focus.targets.high, Fit.activity)
                row("Anaerobic", focus.anaerobic, focus.targets.anaerobic, Fit.health)
            }
            Takeaway(text: focus.low + focus.high + focus.anaerobic < 1
                     ? "No training load in the last four weeks. The shaded bands are what your watch aims for."
                     : "The shaded bands are your watch's targets for your fitness. Aim to land each bar inside its band.").font(.caption)
        }
    }

    private func row(_ name: String, _ value: Double, _ band: FitnessWatch.Focus.Band?, _ tint: Color) -> some View {
        let top = max(value, focus.targets.low?.max ?? 0, focus.targets.high?.max ?? 0, 100) * 1.05
        return VStack(spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(name).font(.subheadline)
                Spacer()
                Text("\(Int(value.rounded()))").font(.subheadline).monospacedDigit()
                if let band { Text("target \(Int(band.min))–\(Int(band.max))").font(Fit.label).foregroundStyle(Fit.muted) }
            }
            GeometryReader { geo in
                let x = { (v: Double) in geo.size.width * min(1, v / top) }
                ZStack(alignment: .leading) {
                    Capsule().fill(Fit.track).frame(height: 3)
                    if let band {
                        Capsule().fill(tint.opacity(0.28)).frame(width: max(2, x(band.max) - x(band.min)), height: 7).offset(x: x(band.min))
                    }
                    Capsule().fill(tint).frame(width: max(3, x(value)), height: 3)
                }
                .frame(maxHeight: .infinity)
            }
            .frame(height: 8)
        }
    }
}

// MARK: Activity

/// One activity: a big headline number, the watch's verdict, heart rate with
/// zones, then laps or sets. Same plain style as the pages.
struct ActivityPage: View {
    @Environment(AppSession.self) private var session
    let activity: FitnessActivity
    let store: FitnessStore
    @State private var loaded: FitnessActivityDetail?
    @State private var loading = true

    private var detail: FitnessActivityDetail? { loaded ?? store.cachedDetail(activity.id) }

    var body: some View {
        FitPage(title: activity.title) {
            header
            StatStrip(items: stats).padding(.bottom, 8)
            if detail?.extras != nil || activity.trainingEffect != nil { verdict }
            SessionFeedbackSection(kind: "activity", id: activity.id)
            heartRate
            if let sets = detail?.extras?.sets.filter({ ($0.reps ?? 0) > 0 }), !sets.isEmpty { setsSection(sets) }
            if let laps = detail?.extras?.laps, laps.count > 1 { lapsSection(laps) }
            if let efforts = detail?.extras?.bestEfforts, !efforts.isEmpty { effortsSection(efforts) }
        }
        .task {
            loaded = await store.detail(activity.id, api: session.api)
            loading = false
        }
    }

    private var header: some View {
        VStack(spacing: 8) {
            TablerIcon(name: activity.symbol, size: 30).foregroundStyle(Fit.muted)
            if let start = activity.start {
                Text(start, format: .dateTime.weekday(.wide).month().day().hour().minute()).font(Fit.label).foregroundStyle(Fit.muted)
            }
            BigNumber(value: activity.hasDistance ? FitnessFormat.distance(activity.distanceMeters) : FitnessFormat.duration(activity.duration),
                      caption: benefitText)
                .padding(.top, -8)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 8)
    }

    private var benefitText: String? {
        guard let benefit = activity.primaryBenefit ?? detail?.extras?.primaryBenefit, benefit != "none" else { return nil }
        return "Trained: " + (benefit == "vo2max" ? "VO2 max" : benefit)
    }

    private var stats: [(label: String, value: String)] {
        var items: [(String, String)] = []
        if activity.hasDistance {
            items.append(("Time", FitnessFormat.duration(activity.duration)))
            if let pace = FitnessFormat.pace(activity.avgSpeed) { items.append(("Pace", pace)) }
        }
        items.append(("Avg HR", activity.avgHr.map { "\($0)" } ?? "–"))
        if !activity.hasDistance { items.append(("Max HR", activity.maxHr.map { "\($0)" } ?? "–")) }
        items.append(("Calories", activity.calories.map { "\($0)" } ?? "–"))
        return Array(items.prefix(3))
    }

    /// Training Effect, load, recovery and Performance Condition, as the watch scored them.
    private var verdict: some View {
        FitSection(title: "What it did", trailing: "From your watch") {
            VStack(spacing: 18) {
                ContributorRow(title: "Aerobic effect", detail: activity.trainingEffect.map { String(format: "%.1f of 5", $0) } ?? "–",
                               fraction: activity.trainingEffect.map { $0 / 5 }, tint: Fit.positive)
                ContributorRow(title: "Anaerobic effect", detail: activity.anaerobicEffect.map { String(format: "%.1f of 5", $0) } ?? "–",
                               fraction: activity.anaerobicEffect.map { $0 / 5 }, tint: Fit.health)
            }
            VStack(spacing: 0) {
                DetailRow(label: "Training load", value: activity.watchLoad.map { "\(Int($0.rounded()))" } ?? "–")
                DetailRow(label: "Recovery time", value: detail?.recoveryHours.map { $0 < 1 ? "None" : WatchFormat.hours($0) } ?? "–")
                if let condition = detail?.extras?.performanceCondition, condition != 0 {
                    DetailRow(label: "Performance condition", value: "\(condition > 0 ? "+" : "")\(condition)",
                              valueColor: condition > 0 ? Fit.positive : Fit.attention)
                }
                if let battery = detail?.extras?.endingBodyBattery {
                    DetailRow(label: "Body Battery after", value: "\(battery)", last: true)
                }
            }
        }
    }

    @ViewBuilder private var heartRate: some View {
        FitSection(title: "Heart rate", trailing: activity.maxHr.map { "max \($0) bpm" }) {
            if let detail, !detail.points.isEmpty {
                let start = activity.start ?? .now
                let points = detail.points.map { TimeValue(date: start.addingTimeInterval($0.0), value: $0.1) }
                let end = start.addingTimeInterval(max(activity.elapsedSeconds ?? 0, detail.points.last?.0 ?? 60))
                IntradayChart(points: points, tint: Fit.heart, from: start, to: end, style: .area, unit: " bpm")
                zones(detail.points.map(\.1))
            } else {
                Takeaway(text: loading ? "Loading…" : "No heart rate recorded.")
            }
        }
    }

    /// Time in each zone by share of max heart rate (the watch's max, else the session's), Z5 on top.
    private func zones(_ bpm: [Double]) -> some View {
        let peak = Double(store.snapshot?.metrics?.profile?.maxHr ?? activity.maxHr ?? Int(bpm.max() ?? 190))
        let bounds = [0.5, 0.6, 0.7, 0.8, 0.9]
        let colors: [Color] = [Fit.faint, Fit.action, Fit.positive, Fit.activity, Fit.attention]
        let counts = (0..<5).map { zone in
            bpm.filter { value in
                let share = value / max(peak, 1)
                return share >= bounds[zone] && (zone == 4 || share < bounds[zone + 1])
            }.count
        }
        let total = max(counts.reduce(0, +), 1)
        let seconds = (activity.duration ?? 0) / Double(total)
        return VStack(spacing: 14) {
            ForEach((0..<5).reversed(), id: \.self) { zone in
                ContributorRow(title: "Zone \(zone + 1)",
                               detail: "\(FitnessFormat.duration(Double(counts[zone]) * seconds)) · \(Int((Double(counts[zone]) / Double(total) * 100).rounded()))%",
                               fraction: Double(counts[zone]) / Double(total), tint: colors[zone])
            }
        }
        .padding(.top, 8)
    }

    private func setsSection(_ sets: [ActivityExtras.StrengthSet]) -> some View {
        let volume = sets.reduce(0.0) { $0 + Double($1.reps ?? 0) * ($1.weightKg ?? 0) }
        return FitSection(title: "Sets", trailing: volume > 0 ? "\(sets.count) sets · \(WatchFormat.weight(volume)) moved" : "\(sets.count) sets") {
            VStack(spacing: 0) {
                ForEach(Array(sets.enumerated()), id: \.offset) { index, set in
                    VStack(spacing: 0) {
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Text("\(index + 1)").font(Fit.label).foregroundStyle(Fit.faint).monospacedDigit().frame(width: 20, alignment: .leading)
                            Text(set.exercise.map(WatchFormat.name) ?? "Set").font(.subheadline)
                            Spacer()
                            Text(set.reps.map { "\($0) reps" } ?? "").font(.subheadline).monospacedDigit()
                            Text(set.weightKg.flatMap { $0 > 0 ? WatchFormat.weight($0) : nil } ?? "Body").font(.subheadline).foregroundStyle(Fit.muted)
                                .monospacedDigit().frame(width: 64, alignment: .trailing)
                        }
                        .padding(.vertical, 11)
                        if index < sets.count - 1 { FitDivider() }
                    }
                }
            }
        }
    }

    private func lapsSection(_ laps: [ActivityExtras.Lap]) -> some View {
        let speeds = laps.compactMap(\.avgSpeed)
        let fastest = speeds.max() ?? 1, slowest = speeds.min() ?? 0
        return FitSection(title: "Laps", trailing: "\(laps.count)") {
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Text("Lap").frame(width: 28, alignment: .leading)
                    Text(activity.hasDistance ? "Pace" : "Time").frame(width: 84, alignment: .leading)
                    Spacer()
                    Text("HR").frame(width: 36, alignment: .trailing)
                }
                .font(Fit.axis).foregroundStyle(Fit.muted).padding(.bottom, 6)
                ForEach(Array(laps.enumerated()), id: \.offset) { index, lap in
                    VStack(spacing: 0) {
                        HStack(spacing: 12) {
                            Text("\(index + 1)").font(Fit.label).foregroundStyle(Fit.faint).monospacedDigit().frame(width: 28, alignment: .leading)
                            Text(activity.hasDistance ? (FitnessFormat.pace(lap.avgSpeed) ?? "–") : FitnessFormat.duration(lap.seconds))
                                .font(.subheadline).monospacedDigit().frame(width: 84, alignment: .leading)
                            GeometryReader { geo in
                                // Faster laps reach further; the slowest still shows.
                                let share = fastest > slowest ? 0.25 + 0.75 * ((lap.avgSpeed ?? slowest) - slowest) / (fastest - slowest) : 1
                                Capsule().fill(Fit.activity).frame(width: max(3, geo.size.width * share), height: 3).frame(maxHeight: .infinity)
                            }
                            .frame(height: 10)
                            Text(lap.avgHr.map { "\($0)" } ?? "–").font(.subheadline).monospacedDigit().foregroundStyle(Fit.muted)
                                .frame(width: 36, alignment: .trailing)
                        }
                        .padding(.vertical, 10)
                        if index < laps.count - 1 { FitDivider() }
                    }
                }
            }
        }
    }

    private func effortsSection(_ efforts: [ActivityExtras.BestEffort]) -> some View {
        let sorted = efforts.sorted { $0.meters < $1.meters }
        return FitSection(title: "Best efforts") {
            VStack(spacing: 0) {
                ForEach(Array(sorted.enumerated()), id: \.offset) { index, effort in
                    DetailRow(label: FitnessFormat.distance(effort.meters) + (effort.personalRecord ? "  ·  PR" : ""),
                              value: WatchFormat.raceTime(Int(effort.seconds.rounded())),
                              valueColor: effort.personalRecord ? Fit.positive : nil, last: index == sorted.count - 1)
                }
            }
        }
    }
}
