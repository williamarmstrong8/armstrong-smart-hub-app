import SwiftUI
import WidgetKit

// Whether the phone is bricked, which mode, and for how long. Bricking needs
// the tag, so tapping it opens the Brick tab rather than doing it from here.

struct BrickEntry: TimelineEntry {
    var date: Date
    var glance: BrickGlance?
}

private struct BrickProvider: TimelineProvider {
    func placeholder(in context: Context) -> BrickEntry {
        BrickEntry(date: .now, glance: BrickGlance(
            isBlocking: true, profileName: "Focus", startedAt: .now.addingTimeInterval(-42 * 60), endsAt: nil,
            strict: true, finishedTodaySeconds: 3600, day: SharedDay.string(), hasTag: true))
    }

    func getSnapshot(in context: Context, completion: @escaping (BrickEntry) -> Void) {
        let glance = BrickGlance.read()
        completion(context.isPreview && glance == nil ? placeholder(in: context) : BrickEntry(date: .now, glance: glance))
    }

    /// When a timer runs out the widget says so then, even before the app has unbricked.
    func getTimeline(in context: Context, completion: @escaping (Timeline<BrickEntry>) -> Void) {
        let glance = BrickGlance.read()
        var entries = [BrickEntry(date: .now, glance: glance)]
        if var ended = glance, ended.isBlocking, let end = ended.endsAt, end > .now {
            ended.finishedTodaySeconds = ended.todaySeconds(at: end)
            ended.isBlocking = false
            ended.startedAt = nil
            ended.endsAt = nil
            entries.append(BrickEntry(date: end, glance: ended))
        }
        // Today's total is drawn as of each entry, so redraw it every 15 minutes while bricked.
        let policy: TimelineReloadPolicy = glance?.isBlocking == true ? .after(.now.addingTimeInterval(15 * 60)) : .never
        completion(Timeline(entries: entries, policy: policy))
    }
}

struct BrickWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetKind.brick, provider: BrickProvider()) { entry in
            BrickWidgetView(entry: entry)
                .containerBackground(for: .widget) {
                    entry.glance?.isBlocking == true ? Color.black : Color(.secondarySystemBackground)
                }
                .widgetURL(URL(string: "armstronghub://brick"))
        }
        .configurationDisplayName("Brick")
        .description("Whether you're bricked, and for how long.")
        .supportedFamilies([.systemSmall, .accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}

private struct BrickWidgetView: View {
    @Environment(\.widgetFamily) private var family
    var entry: BrickEntry

    private var blocking: Bool { entry.glance?.isBlocking == true }

    var body: some View {
        switch family {
        case .accessoryInline:
            if blocking, let end = entry.glance?.endsAt {
                Label { Text("Bricked · \(Text(end, style: .timer))") } icon: { Image(systemName: "iphone.slash") }
            } else {
                Label(blocking ? "Bricked" : "Not bricked", systemImage: blocking ? "iphone.slash" : "iphone")
            }
        case .accessoryCircular:
            ZStack {
                AccessoryWidgetBackground()
                VStack(spacing: 1) {
                    Image(systemName: blocking ? "iphone.slash" : "iphone").font(.title3)
                    if blocking, let start = entry.glance?.startedAt {
                        Text(start, style: .timer).font(.caption2).monospacedDigit().multilineTextAlignment(.center)
                            .frame(maxWidth: 44)
                    }
                }
            }
            .widgetAccentable()
        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 1) {
                Label(blocking ? "Bricked" : "Not bricked", systemImage: blocking ? "iphone.slash" : "iphone")
                    .font(.headline).widgetAccentable()
                if blocking { Text(entry.glance?.profileName ?? "Brick") }
                timeLine.foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        default:
            small
        }
    }

    /// "12:30 left", "for 0:42", or today's total when not bricked.
    @ViewBuilder private var timeLine: some View {
        if blocking, let end = entry.glance?.endsAt {
            Text("\(Text(end, style: .timer)) left")
        } else if blocking, let start = entry.glance?.startedAt {
            Text("for \(Text(start, style: .timer))")
        } else {
            Text("\(duration(entry.glance?.todaySeconds(at: entry.date) ?? 0)) today")
        }
    }

    private var small: some View {
        VStack(alignment: .leading, spacing: 4) {
            Image(systemName: blocking ? "iphone.slash" : "iphone")
                .font(.title2.weight(.semibold))
                .foregroundStyle(blocking ? .white : .primary)
            Spacer(minLength: 0)
            Text(blocking ? "Bricked" : "Not bricked").font(.headline)
            if blocking {
                Text(entry.glance?.profileName ?? "Brick").font(.subheadline).foregroundStyle(.white.opacity(0.7))
                timeLine.font(.caption.weight(.semibold)).monospacedDigit().foregroundStyle(.white.opacity(0.7))
            } else {
                Text(entry.glance?.hasTag == false ? "Register your tag" : "Tap your Brick to start")
                    .font(.caption).foregroundStyle(.secondary)
                Text("\(duration(entry.glance?.todaySeconds(at: entry.date) ?? 0)) today")
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            }
        }
        .foregroundStyle(blocking ? .white : .primary)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private func duration(_ seconds: TimeInterval) -> String {
        let m = Int(seconds / 60)
        return m >= 60 ? "\(m / 60)h \(m % 60)m" : "\(m)m"
    }
}
