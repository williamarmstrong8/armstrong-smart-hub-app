import SwiftUI
import WidgetKit

// The watch's day: Body Battery, steps, sleep and heart rate, as the app last
// saw them (from the watch live, or the hub). The app reloads these whenever
// its numbers change; there's nothing to fetch from here.

struct FitnessEntry: TimelineEntry {
    var date: Date
    var glance: FitnessGlance?
}

private struct FitnessProvider: TimelineProvider {
    func placeholder(in context: Context) -> FitnessEntry {
        FitnessEntry(date: .now, glance: FitnessGlance(
            day: SharedDay.string(), steps: 6420, stepGoal: 10000, bodyBattery: 68, stress: 24, restingHr: 52,
            heartRate: 64, heartRateAt: .now, sleepSeconds: 7 * 3600 + 25 * 60, sleepScore: 82, readiness: 74,
            readinessLevel: "High", intensityMinutes: 35, updatedAt: .now))
    }

    func getSnapshot(in context: Context, completion: @escaping (FitnessEntry) -> Void) {
        let glance = FitnessGlance.read()
        completion(context.isPreview && glance == nil ? placeholder(in: context) : FitnessEntry(date: .now, glance: glance))
    }

    /// Redraws at midnight, when yesterday's steps stop counting.
    func getTimeline(in context: Context, completion: @escaping (Timeline<FitnessEntry>) -> Void) {
        let glance = FitnessGlance.read()
        let midnight = Calendar.current.startOfDay(for: .now.addingTimeInterval(86400))
        completion(Timeline(entries: [FitnessEntry(date: .now, glance: glance), FitnessEntry(date: midnight, glance: glance)], policy: .never))
    }
}

/// Body Battery, steps, sleep and heart rate together.
struct FitnessWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetKind.fitness, provider: FitnessProvider()) { entry in
            FitnessWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
                .widgetURL(URL(string: "armstronghub://fitness"))
        }
        .configurationDisplayName("Watch")
        .description("Body Battery, steps, sleep and heart rate from your Garmin.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular, .accessoryInline])
    }
}

/// Just Body Battery, as a ring.
struct BodyBatteryWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetKind.fitness + ".bodyBattery", provider: FitnessProvider()) { entry in
            MetricRing(value: entry.glance?.bodyBattery, total: 100, symbol: "bolt.fill", color: WidgetColor.blue)
                .containerBackground(.fill.tertiary, for: .widget)
                .widgetURL(URL(string: "armstronghub://fitness"))
        }
        .configurationDisplayName("Body Battery")
        .description("Your Garmin's Body Battery right now.")
        .supportedFamilies([.accessoryCircular])
    }
}

/// Just today's steps, toward the goal.
struct StepsWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetKind.fitness + ".steps", provider: FitnessProvider()) { entry in
            let today = entry.glance?.day == SharedDay.string(entry.date) ? entry.glance : nil
            MetricRing(value: today?.steps ?? 0, total: today?.stepGoal ?? 10000, symbol: "figure.walk", color: WidgetColor.green, short: true)
                .containerBackground(.fill.tertiary, for: .widget)
                .widgetURL(URL(string: "armstronghub://fitness"))
        }
        .configurationDisplayName("Steps")
        .description("Today's steps toward your goal.")
        .supportedFamilies([.accessoryCircular])
    }
}

private struct MetricRing: View {
    var value: Int?
    var total: Int
    var symbol: String
    var color: Color
    var short = false

    var body: some View {
        Gauge(value: Double(min(value ?? 0, total)), in: 0...Double(max(total, 1))) {
            Image(systemName: symbol)
        } currentValueLabel: {
            Text(value.map { short && $0 >= 1000 ? String(format: "%.1fk", Double($0) / 1000) : "\($0)" } ?? "–")
                .monospacedDigit()
        }
        .gaugeStyle(.accessoryCircularCapacity)
        .tint(color)
    }
}

private struct FitnessWidgetView: View {
    @Environment(\.widgetFamily) private var family
    var entry: FitnessEntry

    /// Steps and intensity reset at midnight; Body Battery, sleep and resting heart rate carry on.
    private var glance: FitnessGlance? { entry.glance }
    private var stepsToday: Int? { glance?.day == SharedDay.string(entry.date) ? glance?.steps : nil }

    var body: some View {
        switch family {
        case .accessoryInline:
            Label("\(glance?.bodyBattery.map(String.init) ?? "–") · \(steps(stepsToday)) steps", systemImage: "bolt.fill")
        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 1) {
                Label("Body Battery \(glance?.bodyBattery.map(String.init) ?? "–")", systemImage: "bolt.fill")
                    .font(.headline).widgetAccentable()
                Text("\(steps(stepsToday)) steps")
                Text("Slept \(sleep(glance?.sleepSeconds))").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case .systemSmall:
            small
        default:
            medium
        }
    }

    private var small: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
                BatteryRing(level: glance?.bodyBattery).frame(width: 64, height: 64)
                Spacer()
                Image(systemName: "applewatch").font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            stat("figure.walk", steps(stepsToday), "steps", WidgetColor.green)
            stat("bed.double.fill", sleep(glance?.sleepSeconds), "sleep", .indigo)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private var medium: some View {
        HStack(spacing: 16) {
            VStack(spacing: 6) {
                BatteryRing(level: glance?.bodyBattery).frame(width: 92, height: 92)
                Text("Body Battery").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    stat("figure.walk", steps(stepsToday), glance?.stepGoal.map { "of \(steps($0))" } ?? "steps", WidgetColor.green)
                    ProgressView(value: stepsToday == nil ? 0 : glance?.stepFraction ?? 0).tint(WidgetColor.green)
                }
                stat("bed.double.fill", sleep(glance?.sleepSeconds), glance?.sleepScore.map { "score \($0)" } ?? "sleep", .indigo)
                stat("heart.fill", glance?.heartRate.map(String.init) ?? glance?.restingHr.map(String.init) ?? "–",
                     glance?.restingHr.map { "rest \($0)" } ?? "bpm", WidgetColor.heart)
                if let readiness = glance?.readiness {
                    stat("gauge.with.dots.needle.67percent", "\(readiness)", glance?.readinessLevel?.lowercased() ?? "readiness", .orange)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func stat(_ symbol: String, _ value: String, _ unit: String, _ color: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol).font(.caption).foregroundStyle(color).frame(width: 16)
            Text(value).font(.subheadline.weight(.semibold)).monospacedDigit()
            Text(unit).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
    }

    private func steps(_ n: Int?) -> String { n.map { $0.formatted(.number) } ?? "–" }

    private func sleep(_ seconds: Int?) -> String {
        guard let seconds, seconds > 0 else { return "–" }
        return "\(seconds / 3600)h \(seconds % 3600 / 60)m"
    }
}

/// Body Battery as a blue ring with the number in it.
private struct BatteryRing: View {
    var level: Int?

    var body: some View {
        ZStack {
            Circle().stroke(Color.primary.opacity(0.1), lineWidth: 8)
            Circle()
                .trim(from: 0, to: Double(level ?? 0) / 100)
                .stroke(WidgetColor.blue, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                .rotationEffect(.degrees(-90))
            VStack(spacing: -2) {
                Image(systemName: "bolt.fill").font(.caption2).foregroundStyle(WidgetColor.blue)
                Text(level.map(String.init) ?? "–").font(.title2.weight(.bold)).monospacedDigit()
            }
        }
    }
}
