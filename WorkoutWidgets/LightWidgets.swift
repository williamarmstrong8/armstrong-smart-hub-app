import AppIntents
import SwiftUI
import WidgetKit

// The lights: a home screen widget of light buttons, a lock screen count, and a
// Control Center / Lock Screen control for one light. The buttons call the hub
// from here with the sign-in the app shares.

// MARK: Lights as the pickers see them

struct LightEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Light"
    static let defaultQuery = LightQuery()

    var id: String
    var name: String
    var room: String?

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: LocalizedStringResource(stringLiteral: name),
                              subtitle: room.map { LocalizedStringResource(stringLiteral: $0) })
    }
}

struct LightQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [LightEntity] {
        let all = await LightCatalog.load(fresh: false).lights
        return identifiers.compactMap { id in all.first { $0.id == id } }.map(LightEntity.init)
    }

    func suggestedEntities() async throws -> [LightEntity] {
        let snapshot = await LightCatalog.load(fresh: true)
        // Home's lights first, then the rest.
        let shown = Set(snapshot.shown)
        return (snapshot.shownLights + snapshot.lights.filter { !shown.contains($0.id) }).map(LightEntity.init)
    }
}

extension LightEntity {
    init(_ item: LightItem) { self.init(id: item.id, name: item.name, room: item.room) }
}

/// The lights from the hub when it answers (saved for next time), else the last copy.
enum LightCatalog {
    static func load(fresh: Bool) async -> LightsSnapshot {
        let saved = LightsSnapshot.read()
        // Right after a button press the hub can still report the old state.
        if fresh, !(saved?.recentlyTouched ?? false), let hub = HubCall.current,
           let payload: WidgetHomePayload = try? await hub.get("/api/home"), payload.entities != nil {
            let next = payload.snapshot
            next.write()
            return next
        }
        return saved ?? LightsSnapshot(lights: [], shown: [])
    }

    static func set(_ id: String, on: Bool) async throws {
        guard let hub = HubCall.current else { throw HubCallError(message: "Open the app and sign in first.") }
        let _: HubNothing? = try await hub.run("setLight", [.string(id), .object(["on": .bool(on)])])
        var snapshot = LightsSnapshot.read() ?? LightsSnapshot(lights: [], shown: [])
        snapshot.set(id, on: on)
        snapshot.write()
        WidgetCenter.shared.reloadTimelines(ofKind: WidgetKind.lights)
        ControlCenter.shared.reloadControls(ofKind: WidgetKind.lightControl)
    }
}

// MARK: Intents

struct ToggleLightIntent: AppIntent {
    static let title: LocalizedStringResource = "Toggle light"
    static let isDiscoverable = false

    @Parameter(title: "Light") var lightId: String
    @Parameter(title: "On") var on: Bool

    init() {}
    init(id: String, on: Bool) {
        lightId = id
        self.on = on
    }

    func perform() async throws -> some IntentResult {
        try await LightCatalog.set(lightId, on: on)
        return .result()
    }
}

/// The control's toggle: the system hands it the new value.
struct SetLightIntent: SetValueIntent {
    static let title: LocalizedStringResource = "Turn a light on or off"
    static let isDiscoverable = false

    @Parameter(title: "Light") var lightId: String
    @Parameter(title: "On") var value: Bool

    init() {}
    init(id: String) { lightId = id }

    func perform() async throws -> some IntentResult {
        try await LightCatalog.set(lightId, on: value)
        return .result()
    }
}

struct SelectLightsIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Lights"
    static let description = IntentDescription("Pick the lights to show, or leave it empty for the lights on Home.")

    @Parameter(title: "Lights") var lights: [LightEntity]?

    init() {}
}

struct SelectLightControlIntent: ControlConfigurationIntent {
    static let title: LocalizedStringResource = "Light"

    @Parameter(title: "Light") var light: LightEntity?

    init() {}
}

// MARK: Home screen and lock screen widget

struct LightsEntry: TimelineEntry {
    var date: Date
    var lights: [LightItem]
    var signedIn: Bool
}

struct LightsWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: WidgetKind.lights, intent: SelectLightsIntent.self, provider: LightsProvider()) { entry in
            LightsWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
                .widgetURL(URL(string: "armstronghub://home"))
        }
        .configurationDisplayName("Lights")
        .description("Turn lights on and off.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}

private struct LightsProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> LightsEntry {
        LightsEntry(date: .now, lights: [
            LightItem(id: "light.a", name: "Lamp", room: nil, state: "on", brightness: 200),
            LightItem(id: "light.b", name: "Ceiling", room: nil, state: "off", brightness: nil),
            LightItem(id: "light.c", name: "Desk", room: nil, state: "on", brightness: 120),
            LightItem(id: "light.d", name: "Hall", room: nil, state: "off", brightness: nil),
        ], signedIn: true)
    }

    func snapshot(for configuration: SelectLightsIntent, in context: Context) async -> LightsEntry {
        if context.isPreview && LightsSnapshot.read() == nil { return placeholder(in: context) }
        return await entry(configuration, fresh: false)
    }

    /// The app reloads this on every change it sees; otherwise it checks the hub every 15 minutes.
    func timeline(for configuration: SelectLightsIntent, in context: Context) async -> Timeline<LightsEntry> {
        Timeline(entries: [await entry(configuration, fresh: true)], policy: .after(.now.addingTimeInterval(15 * 60)))
    }

    private func entry(_ configuration: SelectLightsIntent, fresh: Bool) async -> LightsEntry {
        let snapshot = await LightCatalog.load(fresh: fresh)
        let picked = configuration.lights ?? []
        let lights = picked.isEmpty
            ? snapshot.shownLights
            : picked.map { p in snapshot.lights.first { $0.id == p.id } ?? LightItem(id: p.id, name: p.name, room: p.room, state: "unknown", brightness: nil) }
        return LightsEntry(date: .now, lights: lights, signedIn: HubCall.current != nil)
    }
}

private struct LightsWidgetView: View {
    @Environment(\.widgetFamily) private var family
    var entry: LightsEntry

    private var onCount: Int { entry.lights.filter(\.isOn).count }

    var body: some View {
        switch family {
        case .accessoryInline:
            Label("\(onCount) of \(entry.lights.count) lights on", systemImage: "lightbulb.fill")
        case .accessoryCircular:
            ZStack {
                AccessoryWidgetBackground()
                VStack(spacing: 0) {
                    Image(systemName: onCount > 0 ? "lightbulb.fill" : "lightbulb").font(.title3)
                    Text("\(onCount)").font(.headline).monospacedDigit()
                }
            }
        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 1) {
                Label("Lights", systemImage: "lightbulb.fill").font(.headline).widgetAccentable()
                Text(onCount == 0 ? "All off" : "\(onCount) of \(entry.lights.count) on")
                Text(entry.lights.filter(\.isOn).map(\.name).joined(separator: ", "))
                    .foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        default:
            grid
        }
    }

    private var columns: Int { family == .systemSmall ? 2 : 3 }
    private var limit: Int {
        switch family {
        case .systemSmall: return 4
        case .systemMedium: return 6
        default: return 12
        }
    }

    @ViewBuilder private var grid: some View {
        if !entry.signedIn {
            WidgetMessage(symbol: "lightbulb", title: "Lights", detail: "Open the app to sign in")
        } else if entry.lights.isEmpty {
            WidgetMessage(symbol: "lightbulb", title: "No lights", detail: "Pick devices on Home")
        } else {
            let shown = Array(entry.lights.prefix(limit))
            let rows = stride(from: 0, to: shown.count, by: columns).map { Array(shown[$0..<min($0 + columns, shown.count)]) }
            VStack(spacing: 8) {
                ForEach(rows.indices, id: \.self) { r in
                    HStack(spacing: 8) {
                        ForEach(rows[r]) { LightTile(light: $0) }
                        // Keeps a short last row's tiles the same width as the rest.
                        ForEach(0..<(columns - rows[r].count), id: \.self) { _ in Color.clear }
                    }
                }
                if family == .systemLarge { Spacer(minLength: 0) }
            }
        }
    }
}

private struct LightTile: View {
    var light: LightItem

    var body: some View {
        Button(intent: ToggleLightIntent(id: light.id, on: !light.isOn)) {
            VStack(alignment: .leading, spacing: 2) {
                Image(systemName: light.isOn ? "lightbulb.fill" : "lightbulb")
                    .font(.title3)
                    .foregroundStyle(light.isOn ? Color.orange : .secondary)
                Spacer(minLength: 0)
                Text(light.name).font(.caption.weight(.semibold)).lineLimit(2).minimumScaleFactor(0.8)
                Text(light.isUnavailable ? "Unavailable" : light.isOn ? (light.brightnessPct.map { "\($0)%" } ?? "On") : "Off")
                    .font(.caption2).foregroundStyle(.secondary).monospacedDigit()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .padding(8)
            .background(light.isOn ? Color.yellow.opacity(0.28) : Color.primary.opacity(0.06), in: .rect(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .disabled(light.isUnavailable)
        .invalidatableContent()
    }
}

// MARK: Control Center and Lock Screen

struct LightControlValue: Sendable {
    var id: String?
    var name: String
    var isOn: Bool
}

private struct LightControlProvider: AppIntentControlValueProvider {
    func previewValue(configuration: SelectLightControlIntent) -> LightControlValue {
        LightControlValue(id: configuration.light?.id, name: configuration.light?.name ?? "Light", isOn: false)
    }

    func currentValue(configuration: SelectLightControlIntent) async throws -> LightControlValue {
        guard let light = configuration.light else { return previewValue(configuration: configuration) }
        let snapshot = await LightCatalog.load(fresh: true)
        return LightControlValue(id: light.id, name: light.name, isOn: snapshot.lights.first { $0.id == light.id }?.isOn ?? false)
    }
}

struct LightControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        AppIntentControlConfiguration(kind: WidgetKind.lightControl, provider: LightControlProvider()) { value in
            ControlWidgetToggle(value.name, isOn: value.isOn, action: SetLightIntent(id: value.id ?? "")) { isOn in
                Label(isOn ? "On" : "Off", systemImage: isOn ? "lightbulb.fill" : "lightbulb")
            }
            .tint(.yellow)
        }
        .displayName("Light")
        .description("Turn a light on or off.")
        .promptsForUserConfiguration()
    }
}

// MARK: Shared pieces

/// An icon, a title and a line under it, for a widget with nothing to show yet.
struct WidgetMessage: View {
    var symbol: String
    var title: String
    var detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Image(systemName: symbol).font(.title2).foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Text(title).font(.headline)
            Text(detail).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}
