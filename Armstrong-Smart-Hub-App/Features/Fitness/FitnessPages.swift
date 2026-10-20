import Charts
import SwiftUI

/// The Fitness tab as an overview of tiles, each opening its own page:
/// recovery, strain, sleep, heart, energy, training and health. The pages
/// reuse the sections in FitnessMetricsViews and FitnessInsightsViews under
/// a big visual at the top.
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
        case .training: "Training"
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

// MARK: Visual kit

/// A thick ring with a gradient fill, a big value in the middle and a label under it.
struct GaugeRing: View {
    var value: String
    var fraction: Double
    var tint: Color
    var label: String
    var caption: String?
    var size: CGFloat = 104
    var lineWidth: CGFloat = 12

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                Circle().stroke(tint.opacity(0.14), lineWidth: lineWidth)
                Circle().trim(from: 0, to: max(0.001, min(1, fraction)))
                    .stroke(AngularGradient(colors: [tint.opacity(0.55), tint], center: .center, startAngle: .degrees(0), endAngle: .degrees(360 * max(0.05, min(1, fraction)))),
                            style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .shadow(color: tint.opacity(0.35), radius: 6)
                Text(value)
                    .font(.system(size: size * 0.26, weight: .heavy, design: .rounded))
                    .monospacedDigit()
                    .minimumScaleFactor(0.5)
                    .lineLimit(1)
                    .padding(.horizontal, lineWidth + 4)
                    .contentTransition(.numericText())
            }
            .frame(width: size, height: size)
            .animation(.smooth(duration: 0.8), value: fraction)
            Text(label).font(.subheadline.weight(.semibold))
            if let caption {
                Text(caption).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center).lineLimit(2)
            }
        }
    }
}

/// A 270° gauge with colored bands and a marker at the value: strain, cardio fitness.
struct ArcGauge: View {
    var value: Double
    var range: ClosedRange<Double>
    /// Band upper bounds with their colors, in order.
    var bands: [(Double, Color)]
    var display: String
    var unit: String?
    var label: String?
    var size: CGFloat = 220

    var body: some View {
        let span = range.upperBound - range.lowerBound
        let share = { (v: Double) in max(0, min(1, (v - range.lowerBound) / span)) }
        ZStack {
            ForEach(Array(bands.enumerated()), id: \.offset) { index, band in
                let from = index == 0 ? 0 : share(bands[index - 1].0)
                Circle()
                    .trim(from: from * 0.75 + 0.004, to: share(band.0) * 0.75 - 0.004)
                    .stroke(band.1.opacity(0.85), style: StrokeStyle(lineWidth: 16, lineCap: .butt))
                    .rotationEffect(.degrees(135))
            }
            // The marker sits on the arc at the value.
            Circle()
                .fill(.white)
                .frame(width: 22, height: 22)
                .shadow(radius: 3)
                .overlay(Circle().stroke(Color.black.opacity(0.15), lineWidth: 1))
                .offset(y: -size / 2)
                .rotationEffect(.degrees(-135 + 270 * share(value)))
                .animation(.smooth(duration: 0.8), value: value)
            VStack(spacing: 0) {
                Text(display)
                    .font(.system(size: size * 0.24, weight: .heavy, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                if let unit { Text(unit).font(.subheadline).foregroundStyle(.secondary) }
                if let label { Text(label).font(.headline).padding(.top, 4) }
            }
        }
        .frame(width: size, height: size)
        .padding(.bottom, -size * 0.12)
    }
}

/// A small chart for a tile: a line with a soft fill, or bars.
struct Sparkline: View {
    var values: [Double]
    var tint: Color
    var bars = false
    var domain: ClosedRange<Double>?

    var body: some View {
        let points = Array(values.enumerated())
        Chart(points, id: \.offset) { point in
            if bars {
                BarMark(x: .value("i", point.offset), y: .value("v", point.element), width: .ratio(0.6))
                    .foregroundStyle(tint.gradient)
                    .cornerRadius(2)
            } else {
                AreaMark(x: .value("i", point.offset), y: .value("v", point.element))
                    .interpolationMethod(.monotone)
                    .foregroundStyle(LinearGradient(colors: [tint.opacity(0.35), tint.opacity(0)], startPoint: .top, endPoint: .bottom))
                LineMark(x: .value("i", point.offset), y: .value("v", point.element))
                    .interpolationMethod(.monotone)
                    .foregroundStyle(tint)
                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round))
            }
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartYScale(domain: domain ?? (values.min() ?? 0)...(max((values.max() ?? 1), (values.min() ?? 0) + 1)))
        .chartLegend(.hidden)
    }
}

/// An overview tile: icon and title, a big value, a caption, and a small chart.
struct FitnessTile<Chart: View>: View {
    var icon: String
    var title: String
    var value: String
    var unit: String?
    var caption: String?
    var tint: Color
    @ViewBuilder var chart: Chart

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                TablerIcon(name: icon, size: 16).foregroundStyle(tint)
                Text(title.uppercased()).font(.caption2.weight(.bold)).tracking(1).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                TablerIcon(name: "chevron-right", size: 12).foregroundStyle(.tertiary)
            }
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value)
                    .font(.system(size: 28, weight: .heavy, design: .rounded))
                    .monospacedDigit()
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
                if let unit { Text(unit).font(.caption.weight(.semibold)).foregroundStyle(.secondary) }
            }
            Text(caption ?? " ").font(.caption).foregroundStyle(.secondary).lineLimit(1)
            Spacer(minLength: 0)
            chart.frame(height: 38)
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 168, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(LinearGradient(colors: [tint.opacity(0.16), tint.opacity(0.04)], startPoint: .topLeading, endPoint: .bottomTrailing))
        )
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(tint.opacity(0.18), lineWidth: 1))
        .contentShape(.rect)
    }
}

enum Bands {
    /// Whoop's strain bands: light, moderate, strenuous, all out.
    static let strain: [(Double, Color)] = [(10, .teal), (14, .blue), (18, .indigo), (21, .purple)]
    /// Percentile bands for cardio fitness: low, below average, above average, high.
    static let fitness: [(Double, Color)] = [(10, .red), (50, .orange), (85, .yellow), (100, .green)]

    static func recovery(_ zone: String?) -> Color {
        switch zone { case "green": .green; case "yellow": .yellow; case "red": .red; default: .gray }
    }
}

// MARK: Overview

/// The three dials under the readiness hero: energy, sleep, strain.
struct FitnessDials: View {
    var store: FitnessStore

    var body: some View {
        let insights = store.snapshot?.insights
        let watch = store.snapshot?.watch
        HStack(alignment: .top, spacing: 4) {
            NavigationLink(value: FitnessPage.energy) {
                let battery = store.snapshot?.metrics?.bodyBattery?.current ?? insights?.stress.bodyBattery?.current
                GaugeRing(value: battery.map(String.init) ?? "–", fraction: Double(battery ?? 0) / 100, tint: .teal,
                          label: "Energy", caption: insights?.stress.now.map { "Stress \($0)" } ?? "Body Battery", size: 96)
            }
            .buttonStyle(.plain).frame(maxWidth: .infinity)
            NavigationLink(value: FitnessPage.sleep) {
                let night = store.lastNight
                let score = watch?.sleep?.overall ?? night?.score
                GaugeRing(value: score.map(String.init) ?? "–", fraction: Double(score ?? 0) / 100, tint: .indigo,
                          label: "Sleep", caption: night.map { FitnessFormat.duration(Double($0.asleepSeconds)) }, size: 96)
            }
            .buttonStyle(.plain).frame(maxWidth: .infinity)
            NavigationLink(value: FitnessPage.strain) {
                let strain = insights?.strain?.today
                GaugeRing(value: strain.map { String(format: "%.1f", $0) } ?? "–", fraction: (strain ?? 0) / 21, tint: .blue,
                          label: "Strain", caption: insights?.strain?.level?.capitalized ?? "today", size: 96)
            }
            .buttonStyle(.plain).frame(maxWidth: .infinity)
        }
    }
}

/// The grid of tiles under the dials.
struct FitnessTileGrid: View {
    var store: FitnessStore
    var liveBpm: Int?
    var steps: Int
    var stepGoal: Int?

    var body: some View {
        let insights = store.snapshot?.insights
        let metrics = store.snapshot?.metrics
        let watch = store.snapshot?.watch
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
            NavigationLink(value: FitnessPage.heart) {
                let points = (store.snapshot?.heartRate ?? []).map { Double($0.bpm) }
                FitnessTile(icon: "heart", title: "Heart", value: (liveBpm ?? store.snapshot?.heartRate.last?.bpm).map(String.init) ?? "–",
                            unit: "bpm", caption: store.restingHr.map { "Resting \($0)" }, tint: .red) {
                    Sparkline(values: points, tint: .red)
                }
            }
            NavigationLink(value: FitnessPage.training) {
                let vo2 = metrics?.vo2max?.value ?? watch?.vo2max?.value
                let history = watch?.vo2max?.history.map(\.value) ?? metrics?.vo2max?.runs.suffix(12).map(\.value) ?? []
                FitnessTile(icon: "run", title: "VO2 max", value: vo2.map { String(format: "%.0f", $0) } ?? "–",
                            unit: nil, caption: insights?.age?.cardioFitness.map { "\($0.level.capitalized)" } ?? metrics?.load.status, tint: .orange) {
                    Sparkline(values: Array(history.suffix(12)), tint: .orange)
                }
            }
            NavigationLink(value: FitnessPage.training) {
                let endurance = watch?.endurance
                FitnessTile(icon: "mountain", title: "Endurance", value: endurance.map { $0.score.formatted() } ?? "–",
                            unit: nil, caption: endurance?.level.capitalized ?? "Needs a few weeks", tint: .green) {
                    Sparkline(values: endurance?.history.map(\.value) ?? [], tint: .green)
                }
            }
            NavigationLink(value: FitnessPage.training) {
                let races = watch?.races
                FitnessTile(icon: "clock-hour-4", title: "5K", value: races?.fiveK.map(WatchFormat.raceTime) ?? "–", unit: nil,
                            caption: races?.half.map { "Half \(WatchFormat.raceTime($0))" } ?? "Race prediction", tint: .yellow) {
                    Sparkline(values: races?.history.map { -$0.value } ?? [], tint: .yellow)
                }
            }
            NavigationLink { ActivitiesView(activities: store.activities) } label: {
                FitnessTile(icon: "activity", title: "Activities", value: "\(store.thisWeek.count)", unit: "this week",
                            caption: store.activities.first.map { "Last: \($0.title)" }, tint: .pink) {
                    Sparkline(values: weekMinutes(store.activities), tint: .pink, bars: true)
                }
            }
            .disabled(store.activities.isEmpty)
            NavigationLink(value: FitnessPage.health) {
                let hub = insights?.age?.hubAge
                FitnessTile(icon: "target", title: "Health", value: hub.map { String(format: "%.0f", $0.age) } ?? "–",
                            unit: hub == nil ? nil : "yrs", caption: healthCaption(insights), tint: .purple) {
                    if let parts = hub?.parts, !parts.isEmpty {
                        Sparkline(values: parts.map { max(0.2, 2 - $0.years) }, tint: .purple, bars: true, domain: 0...4)
                    } else {
                        Color.clear
                    }
                }
            }
            NavigationLink { TrendsView(store: store) } label: {
                FitnessTile(icon: "walk", title: "Steps", value: steps.formatted(), unit: nil,
                            caption: stepGoal.map { "Goal \($0.formatted())" }, tint: .mint) {
                    Sparkline(values: store.days.prefix(7).reversed().map { Double($0.steps ?? 0) }, tint: .mint, bars: true)
                }
            }
            NavigationLink(value: FitnessPage.recovery) {
                let r = insights?.recovery
                FitnessTile(icon: "lungs", title: "Recovery", value: r?.score.map { "\($0)%" } ?? "–", unit: nil,
                            caption: r?.status == "ready" ? r?.zone.map { "\($0.capitalized) zone" } : "Calibrating", tint: Bands.recovery(r?.zone)) {
                    Sparkline(values: (store.snapshot?.hrv ?? []).compactMap(\.lastNightAverage).reversed(), tint: .teal)
                }
            }
        }
        .buttonStyle(.plain)
    }

    private func healthCaption(_ insights: FitnessInsights?) -> String? {
        if let vitals = insights?.vitals, !vitals.calibrating {
            return vitals.outliers == 0 ? "Vitals typical" : "\(vitals.outliers) vitals off"
        }
        return insights?.age?.hubAge.map { $0.difference <= 0 ? "Hub age" : String(format: "+%.1f vs your age", $0.difference) }
    }

    /// Workout minutes for each of the last 7 days, oldest first.
    private func weekMinutes(_ activities: [FitnessActivity]) -> [Double] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        return (0..<7).reversed().map { back in
            guard let day = calendar.date(byAdding: .day, value: -back, to: today) else { return 0 }
            return activities.filter { $0.start.map { calendar.isDate($0, inSameDayAs: day) } == true }
                .reduce(0) { $0 + ($1.duration ?? 0) / 60 }
        }
    }
}

// MARK: Pages

/// The scroll view every page shares: a hero visual, then sections.
struct PageScaffold<Content: View>: View {
    var title: String
    @ViewBuilder var content: Content

    @Environment(\.fitnessRenderFlat) private var flat

    var body: some View {
        let stack = VStack(spacing: 36) { content }
            .padding(.horizontal, 20)
            .padding(.vertical, 20)
            .padding(.bottom, 24)
        Group {
            if flat { stack } else { ScrollView { stack } }
        }
        .background(Color(.systemBackground))
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct Placeholder: View {
    var text: String
    var body: some View {
        Text(text).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: .infinity).padding(.vertical, 24)
    }
}

struct RecoveryPage: View {
    var store: FitnessStore

    var body: some View {
        let insights = store.snapshot?.insights
        PageScaffold(title: "Recovery") {
            if let r = insights?.recovery, r.status == "ready", let score = r.score {
                GaugeRing(value: "\(score)%", fraction: Double(score) / 100, tint: Bands.recovery(r.zone),
                          label: "\(r.zone?.capitalized ?? "") recovery", caption: "Last night against your own 30-night baseline", size: 190, lineWidth: 20)
                if let parts = r.parts, !parts.isEmpty { contributors(parts) }
            } else {
                let have = insights?.recovery?.have ?? 0, need = insights?.recovery?.need ?? 4
                GaugeRing(value: "\(have)/\(need)", fraction: Double(have) / Double(max(need, 1)), tint: .gray,
                          label: "Learning your baseline", caption: "Recovery compares each night's HRV, resting heart rate, breathing and sleep with your own. It needs \(need) nights with HRV; it has \(have).", size: 190, lineWidth: 20)
            }
            if let metrics = store.snapshot?.metrics { ReadinessSection(readiness: metrics.readiness) }
            HrvTrend(nights: store.snapshot?.hrv ?? [])
        }
    }

    /// Each input as a bar left (hurt) or right (helped) of center.
    private func contributors(_ parts: [FitnessInsights.Recovery.Part]) -> some View {
        FloatingSection(title: "What moved it", trailing: nil) {
            VStack(spacing: 12) {
                ForEach(parts) { part in
                    HStack(spacing: 10) {
                        Text(name(part.key)).font(.subheadline).frame(width: 110, alignment: .leading)
                        GeometryReader { geo in
                            let half = geo.size.width / 2
                            let width = min(half, half * abs(part.z) / 3)
                            ZStack(alignment: .leading) {
                                Capsule().fill(Color.primary.opacity(0.06))
                                Rectangle().fill(Color.primary.opacity(0.2)).frame(width: 1).offset(x: half)
                                Capsule().fill(part.z >= 0 ? Color.green : Color.red)
                                    .frame(width: max(4, width))
                                    .offset(x: part.z >= 0 ? half : half - width)
                            }
                        }
                        .frame(height: 10)
                        Text(String(format: "%+.1f", part.z)).font(.caption).monospacedDigit().foregroundStyle(.secondary).frame(width: 34, alignment: .trailing)
                    }
                }
            }
            Text("Standard deviations from your usual, signed so right helps. HRV carries half the weight.").font(.caption).foregroundStyle(.secondary)
        }
    }

    private func name(_ key: String) -> String {
        switch key {
        case "hrv": "HRV"
        case "restingHr": "Resting HR"
        case "sleep": "Sleep"
        case "respiration": "Breathing"
        case "spo2": "SpO2"
        default: key
        }
    }
}

struct StrainPage: View {
    var store: FitnessStore

    var body: some View {
        let insights = store.snapshot?.insights
        PageScaffold(title: "Strain") {
            let today = insights?.strain?.today
            ArcGauge(value: today ?? 0, range: 0...21, bands: Bands.strain, display: today.map { String(format: "%.1f", $0) } ?? "–",
                     unit: "of 21", label: insights?.strain?.level?.capitalized ?? "No strain yet today")
            HStack(spacing: 14) {
                ForEach([("Light", Color.teal), ("Moderate", .blue), ("Strenuous", .indigo), ("All out", .purple)], id: \.0) { band in
                    Label(band.0, systemImage: "circle.fill").labelStyle(TintedDot(color: band.1))
                }
            }
            .font(.caption).foregroundStyle(.secondary)
            if let week = insights?.strain?.week, week.contains(where: { $0.strain != nil }) {
                FloatingSection(title: "This week", trailing: nil) {
                    let days = week.compactMap { day -> (Date, Double)? in
                        guard let strain = day.strain, let date = DateOnly.parse(day.day) else { return nil }
                        return (date, strain)
                    }
                    Chart(days, id: \.0) { day in
                        BarMark(x: .value("Day", day.0, unit: .day), y: .value("Strain", day.1), width: .ratio(0.55))
                            .foregroundStyle(Bands.strain.first { day.1 < $0.0 }?.1 ?? .purple)
                            .cornerRadius(6)
                            .annotation(position: .top) { Text(String(format: "%.1f", day.1)).font(.caption2).monospacedDigit() }
                    }
                    .chartYScale(domain: 0...21)
                    .chartYAxis { AxisMarks(values: [10, 14, 18]) { _ in AxisGridLine(stroke: StrokeStyle(dash: [3, 3])) } }
                    .chartXAxis { AxisMarks(values: .stride(by: .day)) { _ in AxisValueLabel(format: .dateTime.weekday(.abbreviated)) } }
                    .frame(height: 170)
                }
            }
            if let workout = insights?.training.lastWorkout { WorkoutEffectSection(workout: workout) }
            if let load = insights?.training.effortLoad, load.month > 0 || load.week > 0 {
                FloatingSection(title: "Training load", trailing: load.trend?.capitalized) {
                    let rows = [("Last 7 days", load.week, Color.pink), ("Last 28 days", load.month, Color.pink.opacity(0.45))]
                    Chart(rows, id: \.0) { row in
                        BarMark(x: .value("Load", row.1), y: .value("Window", row.0))
                            .foregroundStyle(row.2)
                            .cornerRadius(6)
                            .annotation(position: .trailing) { Text("\(row.1)").font(.caption).monospacedDigit() }
                    }
                    .chartXAxis(.hidden)
                    .frame(height: 90)
                    Text("Effort × minutes a day, Apple's way: the last week against the last four.").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}

struct SleepPage: View {
    var store: FitnessStore

    var body: some View {
        let insights = store.snapshot?.insights
        PageScaffold(title: "Sleep") {
            if let night = store.lastNight {
                // Against the watch's sleep need when it gives one, else the hub's.
                let needed = store.snapshot?.watch?.sleepNeed?.hours ?? insights?.sleep.lastNight?.needed
                let performance = needed.map { min(100, Int((Double(night.asleepSeconds) / 3600 / $0 * 100).rounded())) } ?? insights?.sleep.lastNight?.performance
                HStack(spacing: 24) {
                    GaugeRing(value: performance.map { "\($0)%" } ?? "–", fraction: Double(performance ?? 0) / 100, tint: .indigo,
                              label: "Performance", caption: needed.map { "of \(WatchFormat.hours($0)) needed" }, size: 130, lineWidth: 16)
                    let score = store.snapshot?.watch?.sleep?.overall ?? night.score
                    GaugeRing(value: score.map(String.init) ?? "–", fraction: Double(score ?? 0) / 100, tint: .purple,
                              label: "Sleep score", caption: FitnessFormat.duration(Double(night.asleepSeconds)) + " asleep", size: 130, lineWidth: 16)
                }
                if night.watchScore != nil || store.snapshot?.watch?.sleep != nil { SourceBadge(watch: true) }
                FloatingSection(title: "Last night", trailing: night.startDate.map { $0.formatted(.dateTime.weekday(.wide)) }) {
                    Hypnogram(night: night).frame(height: 150)
                    StageBar(night: night).frame(height: 12)
                    HStack(alignment: .top) {
                        ForEach(SleepNight.Stage.allCases) { stage in
                            VStack(spacing: 2) {
                                Text(FitnessFormat.duration(Double(night.seconds(stage)))).font(.subheadline.weight(.bold)).monospacedDigit()
                                Label(stage.name, systemImage: "circle.fill").labelStyle(TintedDot(color: stage.color))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity)
                        }
                    }
                }
            } else {
                Placeholder(text: "Sleep shows up after a night with the watch on, once it hands over the sleep file.")
            }
            if let sleep = store.snapshot?.watch?.sleep { WatchSleepSection(sleep: sleep, need: store.snapshot?.watch?.sleepNeed) }
            if let sleep = insights?.sleep { SleepCoachSection(sleep: sleep, watchNeed: store.snapshot?.watch?.sleepNeed != nil) }
            if store.nights.count > 1 {
                NavigationLink { SleepView(nights: store.nights) } label: {
                    HStack {
                        Text("All nights").font(.subheadline.weight(.semibold))
                        Spacer()
                        TablerIcon(name: "chevron-right", size: 14).foregroundStyle(.tertiary)
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

struct HeartPage: View {
    var store: FitnessStore
    @Environment(WatchLink.self) private var watch

    var body: some View {
        let points = (store.snapshot?.heartRate ?? []).compactMap { p in p.date.map { ($0, p.bpm) } }
        PageScaffold(title: "Heart") {
            HStack(spacing: 24) {
                GaugeRing(value: (watch.heartRate?.bpm ?? points.last?.1).map(String.init) ?? "–",
                          fraction: Double(watch.heartRate?.bpm ?? points.last?.1 ?? 0) / 200, tint: .red,
                          label: watch.heartRate == nil ? "Latest" : "Now", caption: "bpm", size: 130, lineWidth: 16)
                GaugeRing(value: store.restingHr.map(String.init) ?? "–", fraction: Double(store.restingHr ?? 0) / 100, tint: .pink,
                          label: "Resting", caption: "bpm today", size: 130, lineWidth: 16)
            }
            FloatingSection(title: "Today", trailing: points.isEmpty ? nil : "\(points.map(\.1).min() ?? 0)–\(points.map(\.1).max() ?? 0) bpm") {
                if points.isEmpty {
                    Placeholder(text: "All-day heart rate appears once the watch hands over a monitoring file.")
                } else {
                    let low = points.map(\.1).min() ?? 0
                    Chart(points, id: \.0) { point in
                        AreaMark(x: .value("Time", point.0), yStart: .value("Floor", max(low - 10, 0)), yEnd: .value("BPM", point.1))
                            .interpolationMethod(.monotone)
                            .foregroundStyle(LinearGradient(colors: [.red.opacity(0.3), .red.opacity(0)], startPoint: .top, endPoint: .bottom))
                        LineMark(x: .value("Time", point.0), y: .value("BPM", point.1))
                            .interpolationMethod(.monotone)
                            .foregroundStyle(.red)
                            .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round))
                    }
                    .chartYScale(domain: .automatic(includesZero: false))
                    .chartXAxis { AxisMarks(values: .stride(by: .hour, count: 6)) { _ in AxisValueLabel(format: .dateTime.hour()) } }
                    .frame(height: 180)
                }
            }
            let resting = store.days.compactMap { day in day.date.flatMap { d in day.restingHr.map { (d, $0) } } }
            if resting.count > 1 {
                FloatingSection(title: "Resting heart rate", trailing: "\(resting.count) days") {
                    Chart(resting, id: \.0) { day in
                        LineMark(x: .value("Day", day.0, unit: .day), y: .value("Resting", day.1))
                            .interpolationMethod(.monotone).foregroundStyle(.pink)
                        PointMark(x: .value("Day", day.0, unit: .day), y: .value("Resting", day.1)).foregroundStyle(.pink).symbolSize(20)
                    }
                    .chartYScale(domain: .automatic(includesZero: false))
                    .frame(height: 120)
                }
            }
            HrvTrend(nights: store.snapshot?.hrv ?? [])
        }
    }
}

struct EnergyPage: View {
    var store: FitnessStore

    var body: some View {
        let insights = store.snapshot?.insights
        let metrics = store.snapshot?.metrics
        PageScaffold(title: "Energy & stress") {
            let battery = insights?.stress.bodyBattery?.current ?? metrics?.bodyBattery?.current
            HStack(spacing: 24) {
                GaugeRing(value: battery.map(String.init) ?? "–", fraction: Double(battery ?? 0) / 100, tint: .teal,
                          label: "Body Battery", caption: insights?.stress.bodyBattery.map { "High \($0.high) · low \($0.low)" }, size: 130, lineWidth: 16)
                let stress = insights?.stress.now ?? metrics?.stress?.average
                GaugeRing(value: stress.map(String.init) ?? "–", fraction: Double(stress ?? 0) / 100,
                          tint: stress.map { MetricColor.stress($0) } ?? .gray,
                          label: "Stress", caption: insights?.stress.now == nil ? "today's average" : "now", size: 130, lineWidth: 16)
            }
            if let insights { BalanceSection(stress: insights.stress) }
            if let metrics, metrics.stress != nil { EnergySection(battery: insights?.stress.bodyBattery == nil ? metrics.bodyBattery : nil, stress: metrics.stress) }
        }
    }
}

struct TrainingPage: View {
    var store: FitnessStore

    var body: some View {
        let insights = store.snapshot?.insights
        let metrics = store.snapshot?.metrics
        let watch = store.snapshot?.watch
        PageScaffold(title: "Training") {
            if let vo2 = metrics?.vo2max {
                let fitness = insights?.age?.cardioFitness
                ArcGauge(value: Double(fitness?.percentile ?? 50), range: 0...100, bands: Bands.fitness,
                         display: String(format: "%.1f", vo2.value), unit: "VO2 max",
                         label: fitness.map { "\($0.level.capitalized) · \($0.percentile)th percentile" })
                SourceBadge(watch: metrics?.fromWatch("vo2max") == true)
            } else {
                Placeholder(text: "VO2 max comes from outdoor runs with steady pace and heart rate.")
            }
            if let endurance = watch?.endurance { EnduranceSection(endurance: endurance) }
            if let races = watch?.races { WatchRacesSection(races: races) } else if let races = insights?.training.races { raceCards(races) }
            if let focus = watch?.focus { LoadFocusSection(focus: focus) }
            if let threshold = watch?.lactateThreshold { thresholdSection(threshold) }
            if let metrics { PerformanceSection(metrics: metrics) }
            if let insights { TrainingInsightsSection(training: insights.training, watchCovers: watch?.endurance != nil || watch?.races != nil) }
        }
    }

    private func thresholdSection(_ threshold: FitnessWatch.Threshold) -> some View {
        FloatingSection(title: "Lactate threshold", trailing: "From your watch") {
            HStack(alignment: .firstTextBaseline, spacing: 24) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(Int(threshold.hr))").font(.system(size: 34, weight: .heavy, design: .rounded)).monospacedDigit().foregroundStyle(.orange)
                    Text("bpm").font(.caption).foregroundStyle(.secondary)
                }
                if let pace = FitnessFormat.pace(threshold.speed) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(pace).font(.system(size: 34, weight: .heavy, design: .rounded)).monospacedDigit()
                        Text("pace").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Text("The hardest effort you can hold for about an hour. Tempo and threshold work sits just under it.").font(.caption).foregroundStyle(.secondary)
        }
    }

    private func raceCards(_ races: FitnessInsights.Training.Races) -> some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
            ForEach([("5K", races.fiveK), ("10K", races.tenK), ("Half marathon", races.half), ("Marathon", races.marathon)], id: \.0) { race in
                VStack(alignment: .leading, spacing: 4) {
                    Text(race.0.uppercased()).font(.caption2.weight(.bold)).tracking(1).foregroundStyle(.secondary)
                    Text(race.1 >= 3600 ? String(format: "%d:%02d:%02d", race.1 / 3600, race.1 % 3600 / 60, race.1 % 60)
                                        : String(format: "%d:%02d", race.1 / 60, race.1 % 60))
                        .font(.system(size: 24, weight: .heavy, design: .rounded)).monospacedDigit()
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color.orange.opacity(0.1)))
            }
        }
    }
}

struct HealthPage: View {
    var store: FitnessStore

    var body: some View {
        let insights = store.snapshot?.insights
        PageScaffold(title: "Health") {
            if let age = insights?.age, let hub = age.hubAge {
                ageComparison(age: age, hub: hub)
            } else {
                Placeholder(text: "Hub age needs your VO2 max (from outdoor runs) and your age from the watch profile.")
            }
            HealthInsightsSection(age: insights?.age, vitals: insights?.vitals)
        }
    }

    /// Your age, fitness age and Hub age on one line, so the gap is visible at a glance.
    private func ageComparison(age: FitnessInsights.Age, hub: FitnessInsights.Age.HubAge) -> some View {
        let marks: [(String, Double, Color)] = [("Your age", Double(age.age), .secondary), ("Fitness age", Double(hub.fitnessAge), .orange),
                                                ("Hub age", hub.age, hub.difference <= 0 ? .green : .purple)]
        let low = (marks.map(\.1).min() ?? 20) - 5, high = (marks.map(\.1).max() ?? 40) + 5
        return VStack(spacing: 18) {
            VStack(spacing: 2) {
                Text(String(format: "%.1f", hub.age)).font(.system(size: 64, weight: .heavy, design: .rounded)).monospacedDigit()
                    .foregroundStyle(hub.difference <= 0 ? .green : .purple)
                Text("Hub age").font(.headline)
                Text(hub.difference <= 0 ? String(format: "%.1f years younger than you are", -hub.difference)
                                         : String(format: "%.1f years older than you are", hub.difference))
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(LinearGradient(colors: [.green.opacity(0.35), .yellow.opacity(0.35), .purple.opacity(0.35)], startPoint: .leading, endPoint: .trailing))
                        .frame(height: 8)
                    ForEach(marks, id: \.0) { mark in
                        let x = geo.size.width * (mark.1 - low) / (high - low)
                        VStack(spacing: 4) {
                            Circle().fill(mark.2).frame(width: 16, height: 16).overlay(Circle().stroke(.background, lineWidth: 2))
                            Text(mark.0).font(.caption2).foregroundStyle(.secondary).fixedSize()
                        }
                        .position(x: x, y: 18)
                    }
                }
            }
            .frame(height: 44)
        }
    }
}

/// Overnight HRV across the nights the hub has, with the watch's balanced band.
struct HrvTrend: View {
    var nights: [FitnessHrv]

    var body: some View {
        let usable = nights.filter { $0.lastNightAverage != nil && $0.date != nil }
        if let last = usable.first, let value = last.lastNightAverage {
            FloatingSection(title: "HRV", trailing: last.status?.capitalized) {
                HStack(alignment: .firstTextBaseline) {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text("\(Int(value.rounded()))").font(.system(size: 40, weight: .heavy, design: .rounded)).foregroundStyle(.teal).monospacedDigit()
                        Text("ms last night").font(.subheadline).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let weekly = last.weeklyAverage {
                        VStack(alignment: .trailing, spacing: 0) {
                            Text("\(Int(weekly.rounded()))").font(.system(size: 28, weight: .heavy, design: .rounded)).monospacedDigit()
                            Text("7-day avg").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                if usable.count > 1 {
                    Chart {
                        if let low = last.baselineBalancedLower, let high = last.baselineBalancedUpper, let first = usable.last?.date {
                            RectangleMark(xStart: .value("From", first), xEnd: .value("To", last.date ?? first), yStart: .value("Low", low), yEnd: .value("High", high))
                                .foregroundStyle(Color.teal.opacity(0.12))
                        }
                        ForEach(usable.reversed()) { night in
                            if let date = night.date, let average = night.lastNightAverage {
                                LineMark(x: .value("Night", date), y: .value("HRV", average)).interpolationMethod(.monotone).foregroundStyle(.teal)
                                PointMark(x: .value("Night", date), y: .value("HRV", average)).foregroundStyle(.teal).symbolSize(18)
                            }
                        }
                    }
                    .chartYScale(domain: .automatic(includesZero: false))
                    .chartYAxis(.hidden)
                    .frame(height: 120)
                } else if let low = last.baselineBalancedLower, let high = last.baselineBalancedUpper {
                    Text("Balanced range \(Int(low))–\(Int(high)) ms. The trend line fills in night by night.").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}

extension EnvironmentValues {
    /// TEMPORARY (FitnessRenderDebug): lay pages out without their scroll view so a renderer captures the full height.
    @Entry var fitnessRenderFlat = false
}
