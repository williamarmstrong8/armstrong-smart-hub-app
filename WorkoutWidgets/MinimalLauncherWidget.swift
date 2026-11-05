import SwiftUI
import WidgetKit

private struct MinimalLauncherEntry: TimelineEntry {
    var date: Date
    var settings: MinimalLauncherSettings
}

private struct MinimalLauncherProvider: TimelineProvider {
    func placeholder(in context: Context) -> MinimalLauncherEntry {
        MinimalLauncherEntry(date: .now, settings: MinimalLauncherSettings(items: [
            LauncherItem(name: "Messages", destination: "sms:", usesShortcut: false),
            LauncherItem(name: "Maps", destination: "maps://", usesShortcut: false)
        ]))
    }
    func getSnapshot(in context: Context, completion: @escaping (MinimalLauncherEntry) -> Void) {
        completion(context.isPreview ? placeholder(in: context) : MinimalLauncherEntry(date: .now, settings: .read()))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<MinimalLauncherEntry>) -> Void) {
        completion(Timeline(entries: [MinimalLauncherEntry(date: .now, settings: .read())], policy: .never))
    }
}

struct MinimalLauncherWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: MinimalLauncherSettings.widgetKind, provider: MinimalLauncherProvider()) { entry in
            MinimalLauncherWidgetView(settings: entry.settings)
                .containerBackground(for: .widget) { entry.settings.dark ? Color.black : Color.white }
        }
        .configurationDisplayName("Minimal Launcher")
        .description("Your essential apps, as a simple list. Set it up inside Brick.")
        .supportedFamilies([.systemLarge])
        .contentMarginsDisabled()
    }
}

private struct MinimalLauncherWidgetView: View {
    var settings: MinimalLauncherSettings
    private let configure = URL(string: "armstronghub://brick/launcher")!

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if settings.items.isEmpty {
                Link(destination: configure) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Your essentials").font(.title2)
                        Text("Set up Minimal Launcher in Brick")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                }
            } else {
                ForEach(Array(settings.items.prefix(MinimalLauncherSettings.maximumItems))) { item in
                    Link(destination: item.widgetURL) {
                        Text(item.name)
                            .font(.system(size: settings.largeText ? 30 : 25, weight: .regular))
                            .lineLimit(1).minimumScaleFactor(0.7)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .accessibilityHint("Open \(item.name)")
                }
            }
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 24).padding(.vertical, 12)
        .foregroundStyle(settings.dark ? Color.white : Color.black)
        .widgetURL(configure)
    }
}
