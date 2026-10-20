import Charts
import SwiftUI

// MARK: Readiness

/// The overview's headline: Training Readiness, the watch's own score when it
/// has one, with a line on what to do with it.
struct ReadinessHero: View {
    var store: FitnessStore

    var body: some View {
        let metrics = store.snapshot?.metrics
        let watch = store.snapshot?.watch?.readiness
        let score = watch?.score ?? metrics?.readiness.score
        let level = watch?.level ?? metrics?.readiness.level
        NavigationLink(value: FitnessPage.readiness) {
            VStack(spacing: 14) {
                GaugeRing(value: score.map(String.init) ?? "–", fraction: Double(score ?? 0) / 100,
                          tint: WatchFormat.readinessColor(level), label: "Training readiness",
                          caption: level?.capitalized, size: 176, lineWidth: 18)
                Text(advice(level: level, recoveryHours: metrics?.load.recoveryHours))
                    .font(.subheadline)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                if score != nil { SourceBadge(watch: watch != nil) }
            }
            .frame(maxWidth: .infinity)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    /// Garmin's guidance for each band, cut down to a line.
    private func advice(level: String?, recoveryHours: Int?) -> String {
        if let hours = recoveryHours, hours >= 12 {
            return "Still recovering: \(hours) h to go. Keep it easy today."
        }
        switch level {
        case "prime": return "Primed. A good day for your hardest session."
        case "high": return "Ready for a hard workout."
        case "moderate": return "Fine for a normal session; save the big efforts."
        case "low": return "Go easy: a light session or rest."
        case "poor": return "Rest today. Sleep and recovery come first."
        default: return "Readiness appears after a night of sleep with the watch on."
        }
    }
}

struct ReadinessPage: View {
    var store: FitnessStore

    var body: some View {
        let metrics = store.snapshot?.metrics
        let watch = store.snapshot?.watch
        PageScaffold(title: "Readiness") {
            ReadinessHero(store: store).disabled(true)
            HStack(alignment: .top, spacing: 0) {
                stat(watch?.recovery.map { $0.remainingHours < 1 ? "Done" : WatchFormat.hours($0.remainingHours) } ?? metrics.map { $0.load.recoveryHours < 1 ? "Done" : "\($0.load.recoveryHours)h" } ?? "–",
                     "Recovery")
                stat((watch?.readiness?.sleepScore ?? store.lastNight?.score).map(String.init) ?? "–", "Sleep score")
                stat((watch?.readiness?.weeklyHrv ?? metrics?.hrv.weekly).map { "\(Int($0.rounded())) ms" } ?? "–", "HRV 7-day")
            }
            if let history = watch?.readiness?.history, history.count > 1 { trend(history) }
            if let metrics {
                ReadinessSection(readiness: metrics.readiness)
                if let hub = metrics.readiness.hubScore, metrics.fromWatch("readiness") {
                    Text("The factors above are the hub's own read of the same inputs (it scores \(hub)); the headline is your watch's.")
                        .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            NavigationLink(value: FitnessPage.recovery) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Recovery against your baseline").font(.subheadline.weight(.semibold))
                        Text("HRV, resting heart rate, breathing and sleep, Whoop-style").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    TablerIcon(name: "chevron-right", size: 14).foregroundStyle(.tertiary)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
        }
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.system(size: 22, weight: .heavy, design: .rounded)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.6)
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private func trend(_ history: [FitnessWatch.Point]) -> some View {
        FloatingSection(title: "Last \(history.count) mornings", trailing: nil) {
            Chart(history.compactMap { p in p.date.map { ($0, p.value) } }, id: \.0) { day in
                BarMark(x: .value("Day", day.0, unit: .day), y: .value("Readiness", day.1), width: .ratio(0.55))
                    .foregroundStyle(MetricColor.readiness(Int(day.1)).gradient)
                    .cornerRadius(6)
                    .annotation(position: .top) { Text("\(Int(day.1))").font(.caption2).monospacedDigit() }
            }
            .chartYScale(domain: 0...100)
            .chartYAxis { AxisMarks(values: [25, 50, 75]) { _ in AxisGridLine(stroke: StrokeStyle(dash: [3, 3])) } }
            .chartXAxis { AxisMarks(values: .stride(by: .day)) { _ in AxisValueLabel(format: .dateTime.weekday(.abbreviated)) } }
            .frame(height: 160)
        }
    }
}

// MARK: Sleep

/// Garmin's sleep sub-scores, sleep need and what the night did for the battery.
struct WatchSleepSection: View {
    var sleep: FitnessWatch.Sleep
    var need: FitnessWatch.SleepNeed?

    var body: some View {
        FloatingSection(title: "Sleep score breakdown", trailing: sleep.overall.map { "\($0) overall" }) {
            VStack(spacing: 10) {
                ForEach(sleep.parts.rows, id: \.0) { row in
                    HStack(spacing: 10) {
                        Text(row.0).font(.subheadline).frame(width: 104, alignment: .leading)
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Color.primary.opacity(0.06))
                                Capsule().fill(color(row.1).gradient).frame(width: max(6, geo.size.width * Double(row.1) / 100))
                            }
                        }
                        .frame(height: 10)
                        Text("\(row.1)").font(.caption.weight(.semibold)).monospacedDigit().frame(width: 28, alignment: .trailing)
                    }
                }
            }
            HStack(alignment: .top, spacing: 0) {
                item(need.map { WatchFormat.hours($0.hours) } ?? "–", "Need tonight")
                item(sleep.lowestHr.map { "\($0) bpm" } ?? "–", "Lowest HR")
                item(sleep.batteryGained.map { $0 >= 0 ? "+\($0)" : "\($0)" } ?? "–", "Battery charged")
            }
            if let need, let usual = need.usualHours, need.hours > usual {
                Text("Your watch wants \(WatchFormat.hours(need.hours - usual)) more than your usual \(WatchFormat.hours(usual)), to pay back recent sleep debt or strain.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func color(_ score: Int) -> Color {
        score >= 80 ? .green : score >= 60 ? .blue : score >= 40 ? .orange : .red
    }

    private func item(_ value: String, _ label: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.system(size: 20, weight: .heavy, design: .rounded)).monospacedDigit()
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: Training

/// Endurance Score on Garmin's level scale, with how far to the next level.
struct EnduranceSection: View {
    var endurance: FitnessWatch.Endurance

    private static let levels = ["intermediate", "trained", "well trained", "expert", "superior", "elite"]
    private static let colors: [Color] = [.gray, .blue, .teal, .green, .orange, .red, .purple]

    var body: some View {
        FloatingSection(title: "Endurance score", trailing: endurance.level.capitalized) {
            HStack(alignment: .firstTextBaseline) {
                Text(endurance.score.formatted())
                    .font(.system(size: 40, weight: .heavy, design: .rounded)).monospacedDigit()
                    .foregroundStyle(color(endurance.level))
                Spacer()
                if let next = endurance.nextLevel {
                    VStack(alignment: .trailing, spacing: 0) {
                        Text("\(Int(next.at) - endurance.score)").font(.system(size: 22, weight: .heavy, design: .rounded)).monospacedDigit()
                        Text("to \(next.name)").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            scale
            Text("How long you can hold an effort, from all your training. It moves slowly: weeks, not days.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func color(_ level: String) -> Color {
        let index = ["recreational"] + Self.levels
        return Self.colors[index.firstIndex(of: level) ?? 0]
    }

    /// Level bands between the watch's gauge limits, with a marker at the score.
    private var scale: some View {
        let low = endurance.gauge?.low ?? Double(endurance.score) * 0.6
        let high = endurance.gauge?.high ?? Double(endurance.score) * 1.6
        let stops = [low] + Self.levels.compactMap { endurance.bounds[$0] ?? nil } + [high]
        let share = max(0, min(1, (Double(endurance.score) - low) / (high - low)))
        return VStack(spacing: 6) {
            GeometryReader { geo in
                HStack(spacing: 2) {
                    ForEach(0..<(stops.count - 1), id: \.self) { i in
                        Rectangle().fill(Self.colors[min(i, Self.colors.count - 1)].opacity(0.8))
                            .frame(width: max(1, geo.size.width * (stops[i + 1] - stops[i]) / (high - low) - 2))
                    }
                }
                .frame(height: 10)
                .clipShape(Capsule())
                .overlay(alignment: .leading) {
                    Circle().fill(.white).frame(width: 18, height: 18).shadow(radius: 2)
                        .overlay(Circle().stroke(Color.black.opacity(0.15), lineWidth: 1))
                        .offset(x: geo.size.width * share - 9)
                }
            }
            .frame(height: 18)
            HStack {
                Text("Recreational").font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Text("Elite").font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}

/// The watch's race predictions, from VO2 max and recent training.
struct WatchRacesSection: View {
    var races: FitnessWatch.Races

    var body: some View {
        FloatingSection(title: "Race predictions", trailing: "From your watch") {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                ForEach([("5K", races.fiveK), ("10K", races.tenK), ("Half marathon", races.half), ("Marathon", races.marathon)], id: \.0) { race in
                    if let seconds = race.1 {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(race.0.uppercased()).font(.caption2.weight(.bold)).tracking(1).foregroundStyle(.secondary)
                            Text(WatchFormat.raceTime(seconds)).font(.system(size: 24, weight: .heavy, design: .rounded)).monospacedDigit()
                            Text(pace(seconds, race.0)).font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color.orange.opacity(0.1)))
                    }
                }
            }
        }
    }

    private func pace(_ seconds: Int, _ race: String) -> String {
        let distances: [String: Double] = ["5K": 5000, "10K": 10000, "Half marathon": 21097.5, "Marathon": 42195]
        let meters = distances[race] ?? 5000
        return FitnessFormat.pace(meters / Double(seconds)) ?? ""
    }
}

/// Four weeks of load in Garmin's three buckets, against the watch's targets.
struct LoadFocusSection: View {
    var focus: FitnessWatch.Focus

    var body: some View {
        FloatingSection(title: "Load focus", trailing: "4 weeks") {
            VStack(spacing: 14) {
                row("Anaerobic", focus.anaerobic, focus.targets.anaerobic, .purple)
                row("High aerobic", focus.high, focus.targets.high, .orange)
                row("Low aerobic", focus.low, focus.targets.low, .teal)
            }
            Text(focus.low + focus.high + focus.anaerobic < 1
                 ? "No training load in the last four weeks. The shaded bands are what your watch aims for."
                 : "Shaded bands are your watch's targets for your fitness. Aim to land each bar inside its band.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func row(_ name: String, _ value: Double, _ band: FitnessWatch.Focus.Band?, _ tint: Color) -> some View {
        let top = max(value, focus.targets.high?.max ?? 0, focus.targets.low?.max ?? 0, 100) * 1.1
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(name).font(.subheadline)
                Spacer()
                Text("\(Int(value.rounded()))").font(.subheadline.weight(.semibold)).monospacedDigit()
                if let band { Text("of \(Int(band.min))–\(Int(band.max))").font(.caption).foregroundStyle(.secondary) }
            }
            GeometryReader { geo in
                let x = { (v: Double) in geo.size.width * min(1, v / top) }
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.06))
                    if let band {
                        Rectangle().fill(tint.opacity(0.2)).frame(width: max(2, x(band.max) - x(band.min))).offset(x: x(band.min))
                    }
                    Capsule().fill(tint.gradient).frame(width: max(4, x(value)))
                }
                .clipShape(Capsule())
            }
            .frame(height: 12)
        }
    }
}

// MARK: Activity

/// An activity in the floating style: headline numbers, the watch's verdict,
/// heart rate with zones, then laps or sets.
struct ActivityPage: View {
    @Environment(AppSession.self) private var session
    let activity: FitnessActivity
    let store: FitnessStore
    @State private var loaded: FitnessActivityDetail?
    @State private var loading = true

    private var detail: FitnessActivityDetail? { loaded ?? store.cachedDetail(activity.id) }

    var body: some View {
        PageScaffold(title: activity.title) {
            header
            stats
            if let extras = detail?.extras { verdict(extras) }
            heartRate
            if let sets = detail?.extras?.sets, sets.contains(where: { $0.reps != nil }) { setsSection(sets) }
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
            TablerIcon(name: activity.symbol, size: 44).foregroundStyle(activity.color)
            if let start = activity.start {
                Text(start, format: .dateTime.weekday(.wide).month().day().hour().minute()).font(.subheadline).foregroundStyle(.secondary)
            }
            if let benefit = activity.primaryBenefit ?? detail?.extras?.primaryBenefit, benefit != "none" {
                Text(benefit == "vo2max" ? "VO2 max" : benefit.capitalized)
                    .font(.caption.weight(.bold))
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(Capsule().fill(WatchFormat.benefitColor(benefit).opacity(0.18)))
                    .foregroundStyle(WatchFormat.benefitColor(benefit))
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var stats: some View {
        var items: [(String, String)] = [("Time", FitnessFormat.duration(activity.duration))]
        if activity.hasDistance {
            items.append(("Distance", FitnessFormat.distance(activity.distanceMeters)))
            if let pace = FitnessFormat.pace(activity.avgSpeed) { items.append(("Avg pace", pace)) }
        }
        items.append(("Avg HR", activity.avgHr.map { "\($0)" } ?? "–"))
        items.append(("Max HR", activity.maxHr.map { "\($0)" } ?? "–"))
        items.append(("Calories", activity.calories.map { "\($0)" } ?? "–"))
        if let ascent = activity.ascentMeters, ascent > 0 {
            items.append(("Ascent", Measurement(value: ascent, unit: UnitLength.meters).formatted(.measurement(width: .abbreviated, usage: .asProvided))))
        }
        return LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 18) {
            ForEach(items, id: \.0) { item in
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.1).font(.system(size: 22, weight: .heavy, design: .rounded)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.6)
                    Text(item.0).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    /// Training Effect, load, recovery and Performance Condition, as the watch scored them.
    private func verdict(_ extras: ActivityExtras) -> some View {
        FloatingSection(title: "What it did", trailing: "From your watch") {
            HStack(alignment: .top, spacing: 0) {
                effect(activity.trainingEffect, "Aerobic", .green)
                effect(activity.anaerobicEffect, "Anaerobic", .purple)
                number(activity.watchLoad.map { "\(Int($0.rounded()))" }, "Load")
                number(detail?.recoveryHours.map { WatchFormat.hours($0) }, "Recovery")
            }
            if let condition = extras.performanceCondition, condition != 0 {
                Text("Performance Condition \(condition > 0 ? "+" : "")\(condition) at the end: \(condition > 0 ? "above" : "below") your usual fitness.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func effect(_ value: Double?, _ label: String, _ tint: Color) -> some View {
        VStack(spacing: 6) {
            ZStack {
                Circle().stroke(tint.opacity(0.15), lineWidth: 6)
                Circle().trim(from: 0, to: (value ?? 0) / 5).stroke(tint, style: StrokeStyle(lineWidth: 6, lineCap: .round)).rotationEffect(.degrees(-90))
                Text(value.map { String(format: "%.1f", $0) } ?? "–").font(.system(size: 15, weight: .heavy, design: .rounded)).monospacedDigit()
            }
            .frame(width: 52, height: 52)
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private func number(_ value: String?, _ label: String) -> some View {
        VStack(spacing: 6) {
            Text(value ?? "–").font(.system(size: 20, weight: .heavy, design: .rounded)).monospacedDigit().frame(height: 52)
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private var heartRate: some View {
        FloatingSection(title: "Heart rate", trailing: activity.avgHr.map { "avg \($0) bpm" }) {
            if let detail, !detail.points.isEmpty {
                let points = detail.points
                let floor = (points.map(\.1).min() ?? 0) - 10
                Chart {
                    ForEach(points.indices, id: \.self) { i in
                        AreaMark(x: .value("Minutes", points[i].0 / 60), yStart: .value("Floor", floor), yEnd: .value("BPM", points[i].1))
                            .foregroundStyle(.linearGradient(colors: [.red.opacity(0.3), .red.opacity(0)], startPoint: .top, endPoint: .bottom))
                            .interpolationMethod(.monotone)
                        LineMark(x: .value("Minutes", points[i].0 / 60), y: .value("BPM", points[i].1))
                            .foregroundStyle(.red).interpolationMethod(.monotone)
                            .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round))
                    }
                }
                .chartYScale(domain: .automatic(includesZero: false))
                .chartXAxisLabel("minutes")
                .frame(height: 180)
                zones(points.map(\.1))
            } else {
                Text(loading ? "Loading…" : "No heart rate recorded.").font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }

    /// Time in each zone, by share of max heart rate (the watch's max, else the session's).
    private func zones(_ bpm: [Double]) -> some View {
        let peak = Double(store.snapshot?.metrics?.profile?.maxHr ?? activity.maxHr ?? Int(bpm.max() ?? 190))
        let bounds = [0.5, 0.6, 0.7, 0.8, 0.9]
        let colors: [Color] = [.gray, .blue, .green, .orange, .red]
        let counts = (0..<5).map { zone in
            bpm.filter { value in
                let share = value / max(peak, 1)
                return share >= bounds[zone] && (zone == 4 || share < bounds[zone + 1])
            }.count
        }
        let total = max(counts.reduce(0, +), 1)
        return HStack(spacing: 3) {
            ForEach(0..<5, id: \.self) { zone in
                VStack(spacing: 4) {
                    GeometryReader { geo in
                        VStack {
                            Spacer(minLength: 0)
                            RoundedRectangle(cornerRadius: 4).fill(colors[zone].gradient)
                                .frame(height: max(3, geo.size.height * Double(counts[zone]) / Double(total)))
                        }
                    }
                    .frame(height: 54)
                    Text("Z\(zone + 1)").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                    Text("\(Int((Double(counts[zone]) / Double(total) * 100).rounded()))%").font(.caption2).monospacedDigit().foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    private func setsSection(_ sets: [ActivityExtras.StrengthSet]) -> some View {
        let working = sets.filter { $0.reps != nil }
        let volume = working.reduce(0.0) { $0 + Double($1.reps ?? 0) * ($1.weightKg ?? 0) }
        return FloatingSection(title: "Sets", trailing: volume > 0 ? "\(working.count) sets · \(WatchFormat.weight(volume)) moved" : "\(working.count) sets") {
            VStack(spacing: 0) {
                ForEach(Array(working.enumerated()), id: \.offset) { index, set in
                    HStack {
                        Text("\(index + 1)").font(.caption.weight(.bold)).foregroundStyle(.secondary).frame(width: 22, alignment: .leading)
                        Text(set.exercise.map(WatchFormat.name) ?? "Set").font(.subheadline)
                        Spacer()
                        Text(set.reps.map { "\($0) reps" } ?? "").font(.subheadline.weight(.semibold)).monospacedDigit()
                        Text(set.weightKg.flatMap { $0 > 0 ? WatchFormat.weight($0) : nil } ?? "body").font(.subheadline).monospacedDigit()
                            .foregroundStyle(.secondary).frame(width: 64, alignment: .trailing)
                    }
                    .padding(.vertical, 9)
                    if index < working.count - 1 { Divider() }
                }
            }
        }
    }

    private func lapsSection(_ laps: [ActivityExtras.Lap]) -> some View {
        let fastest = laps.compactMap(\.avgSpeed).max() ?? 1
        return FloatingSection(title: "Laps", trailing: "\(laps.count)") {
            VStack(spacing: 8) {
                ForEach(Array(laps.enumerated()), id: \.offset) { index, lap in
                    HStack(spacing: 10) {
                        Text("\(index + 1)").font(.caption.weight(.bold)).foregroundStyle(.secondary).frame(width: 22, alignment: .leading)
                        Text(activity.hasDistance ? (FitnessFormat.pace(lap.avgSpeed) ?? "–") : FitnessFormat.duration(lap.seconds))
                            .font(.subheadline.weight(.semibold)).monospacedDigit().frame(width: 92, alignment: .leading)
                        GeometryReader { geo in
                            Capsule().fill(activity.color.gradient).frame(width: max(4, geo.size.width * (lap.avgSpeed ?? 0) / fastest))
                        }
                        .frame(height: 8)
                        Text(lap.avgHr.map { "\($0)" } ?? "–").font(.caption).monospacedDigit().foregroundStyle(.red).frame(width: 30, alignment: .trailing)
                    }
                }
            }
            Text("Pace per lap, bar length by speed; heart rate on the right.").font(.caption).foregroundStyle(.secondary)
        }
    }

    private func effortsSection(_ efforts: [ActivityExtras.BestEffort]) -> some View {
        FloatingSection(title: "Best efforts", trailing: nil) {
            VStack(spacing: 8) {
                ForEach(efforts.sorted { $0.meters < $1.meters }) { effort in
                    HStack {
                        Text(FitnessFormat.distance(effort.meters)).font(.subheadline)
                        if effort.personalRecord {
                            Text("PR").font(.caption2.weight(.heavy)).padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Capsule().fill(Color.yellow.opacity(0.3)))
                        }
                        Spacer()
                        Text(WatchFormat.raceTime(Int(effort.seconds.rounded()))).font(.subheadline.weight(.semibold)).monospacedDigit()
                    }
                }
            }
        }
    }
}
