import SwiftUI

private let groups: [(title: String, kinds: Set<ControlKind>)] = [
    ("Lights", [.light]),
    ("Entertainment", [.remote, .mediaPlayer]),
    ("Climate", [.climate]),
    ("Locks", [.lock]),
    ("Switches", [.toggle]),
    ("Sensors", [.sensor]),
]

struct HomeView: View {
    @Environment(AppSession.self) private var session
    @Environment(\.scenePhase) private var scenePhase
    @State private var store = HomeStore()
    @State private var toast = Toast()
    @State private var light: HAEntity?
    @State private var remote: HAEntity?
    @State private var pick: MediaPick?
    @State private var managing = false
    @State private var display = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    content
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Home")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { AccountButton() }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button("Display mode", systemImage: "rectangle.on.rectangle") { display = true }
                    Button("Manage devices", systemImage: "slider.horizontal.3") { managing = true }
                        .disabled(store.entities.isEmpty)
                }
            }
            .refreshable { await store.refresh(api: session.api) }
            .task(id: scenePhase) {
                guard scenePhase == .active else { return }
                await store.poll(api: session.api)
            }
            .sheet(item: $light) { e in
                LightSheet(entityID: e.id, store: store, toast: toast)
                    .presentationDetents([.medium, .large])
            }
            .sheet(item: $remote) { e in
                RemoteSheet(entity: store.entity(e.id) ?? e)
                    .presentationDetents([.large])
            }
            .sheet(item: $pick) { p in
                MediaDetailSheet(pick: p) { Task { await store.refresh(api: session.api) } }
            }
            .sheet(isPresented: $managing) {
                ManageDevicesView(entities: store.entities, visible: store.state?.visible) {
                    Task { await store.refresh(api: session.api) }
                }
            }
            .fullScreenCover(isPresented: $display) {
                DisplayModeView(store: store)
            }
            .toast(toast)
        }
    }

    @ViewBuilder
    private var content: some View {
        if let state = store.state, !state.configured {
            MessageView(
                title: "Connect the Pi companion",
                systemImage: "network.slash",
                message: "Set HEARTHBOARD_URL and HEARTHBOARD_TOKEN on the hub, then pull to refresh."
            )
        } else {
            if let error = store.loadError ?? store.state?.errors.entities {
                ErrorBanner(message: store.entities.isEmpty ? error : "\(error) Showing the last known state.") {
                    Task { await store.refresh(api: session.api) }
                }
            }

            if store.state == nil {
                ProgressView().frame(maxWidth: .infinity, minHeight: 200)
            } else {
                DeviceGroups(store: store, large: false, onOpen: open, onToggle: toggle)
                if store.shownEntities.isEmpty, store.state?.errors.entities == nil {
                    Text("No devices. Add entity ids to ALLOWED_ENTITIES on the Pi.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            }

            if let payload = store.state?.automations, store.state?.errors.automations == nil {
                AutomationsSection(payload: payload, store: store, toast: toast)
            } else if let error = store.state?.errors.automations {
                SectionHeader(title: "Automations")
                Text("Unavailable: \(error)").font(.subheadline).foregroundStyle(.secondary)
            }

            if !store.activeDownloads.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    SectionHeader(title: "Downloads", meta: "\(store.activeDownloads.count) in progress")
                    RequestList(requests: store.activeDownloads) { pick = $0 }
                }
            }

            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(title: "Find something to watch", meta: "Overseerr")
                MediaSearchView { pick = $0 }
            }

            if !store.ready.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    SectionHeader(title: "Ready to watch", meta: "\(store.ready.count) in Jellyfin")
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 12) {
                            ForEach(store.ready) { r in
                                Button {
                                    if let tmdb = r.tmdbId {
                                        pick = MediaPick(id: tmdb, mediaType: r.mediaType, title: r.title, posterURL: r.posterURL)
                                    }
                                } label: {
                                    VStack(alignment: .leading, spacing: 6) {
                                        Poster(url: r.posterURL, width: 110)
                                        Text(r.title).font(.footnote.weight(.medium)).lineLimit(1).frame(width: 110, alignment: .leading)
                                    }
                                }
                                .buttonStyle(.plain)
                                .disabled(r.tmdbId == nil)
                            }
                        }
                    }
                }
            }
        }
    }

    private func open(_ entity: HAEntity) {
        if entity.isTV { remote = entity } else { light = entity }
    }

    private func toggle(_ entity: HAEntity) {
        Task { await store.toggle(entity, api: session.api, toast: toast) }
    }
}

/// Devices grouped by kind; sensors from the same device share a card.
struct DeviceGroups: View {
    let store: HomeStore
    let large: Bool
    /// The dashboard toggles a device when its tile is tapped.
    var tapToToggle = false
    let onOpen: (HAEntity) -> Void
    let onToggle: (HAEntity) -> Void

    var body: some View {
        let shown = store.shownEntities
        ForEach(groups, id: \.title) { group in
            let items = shown.filter { group.kinds.contains($0.control) }
            if !items.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    SectionHeader(title: group.title, meta: summary(items))
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: large ? 300 : 280), spacing: 10)], spacing: 10) {
                        ForEach(sensorCards(items), id: \.key) { card in
                            if let device = card.device {
                                DeviceCard(device: device, sensors: card.items, large: large)
                            } else {
                                EntityTile(
                                    entity: card.items[0],
                                    pending: store.pending.contains(card.items[0].id),
                                    large: large,
                                    tapToToggle: tapToToggle,
                                    onToggle: onToggle,
                                    onOpen: onOpen
                                )
                            }
                        }
                    }
                }
            }
        }
    }

    private struct SensorCard { let key: String; let device: String?; var items: [HAEntity] }

    private func sensorCards(_ items: [HAEntity]) -> [SensorCard] {
        var out: [SensorCard] = []
        var index: [String: Int] = [:]
        for e in items {
            guard e.control == .sensor, let device = e.device else {
                out.append(SensorCard(key: e.id, device: nil, items: [e]))
                continue
            }
            if let i = index[device] {
                out[i].items.append(e)
            } else {
                index[device] = out.count
                out.append(SensorCard(key: "device:\(device)", device: device, items: [e]))
            }
        }
        return out.map { $0.device != nil && $0.items.count == 1 ? SensorCard(key: $0.items[0].id, device: nil, items: $0.items) : $0 }
    }

    private func summary(_ items: [HAEntity]) -> String {
        let toggles = items.filter { $0.control != .sensor }
        guard !toggles.isEmpty else { return "\(items.count)" }
        let on = toggles.filter(\.isOn).count
        if items[0].control == .lock { return on > 0 ? "\(on) unlocked" : "All locked" }
        return on > 0 ? "\(on) of \(toggles.count) on" : "All off"
    }
}

struct SectionHeader: View {
    let title: String
    var meta: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.title3.weight(.semibold))
            Spacer()
            if let meta { Text(meta).font(.subheadline).foregroundStyle(.secondary).monospacedDigit() }
        }
    }
}

struct EntityTile: View {
    let entity: HAEntity
    let pending: Bool
    var large = false
    var tapToToggle = false
    let onToggle: (HAEntity) -> Void
    let onOpen: (HAEntity) -> Void

    var body: some View {
        let on = entity.isOn
        let readOnly = entity.control == .sensor
        HStack(spacing: 12) {
            Image(systemName: entity.symbol)
                .font(large ? .title3 : .body)
                .frame(width: large ? 46 : 38, height: large ? 46 : 38)
                .foregroundStyle(on && !readOnly ? Color(.systemBackground) : .secondary)
                .background(on && !readOnly ? lightTint : Color(.tertiarySystemFill), in: .rect(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 2) {
                Text(entity.name).font(large ? .headline : .subheadline.weight(.medium)).lineLimit(1)
                Text(entity.stateLabel).font(.footnote).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
            }
            Spacer(minLength: 4)
            if entity.isTV {
                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
            } else {
                if entity.hasLightControls {
                    Button("Adjust \(entity.name)", systemImage: "slider.horizontal.3") { onOpen(entity) }
                        .labelStyle(.iconOnly)
                        .foregroundStyle(.secondary)
                        .buttonStyle(.borderless)
                        .disabled(entity.isUnavailable)
                }
                if !readOnly {
                    Toggle(entity.name, isOn: Binding(get: { on }, set: { _ in onToggle(entity) }))
                        .labelsHidden()
                        .disabled(entity.isUnavailable || pending)
                }
            }
        }
        .padding(large ? 16 : 12)
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 14))
        .opacity(entity.isUnavailable ? 0.6 : 1)
        .contentShape(.rect(cornerRadius: 14))
        .onTapGesture {
            if entity.isTV {
                onOpen(entity)
            } else if tapToToggle, entity.control != .sensor, !entity.isUnavailable, !pending {
                onToggle(entity)
            } else if entity.hasLightControls {
                onOpen(entity)
            }
        }
        .onLongPressGesture { if entity.hasLightControls || entity.isTV { onOpen(entity) } }
        .sensoryFeedback(.selection, trigger: entity.state)
        .accessibilityElement(children: .combine)
    }

    /// Lights glow in their own color when they have one.
    private var lightTint: Color {
        if entity.control == .light, let rgb = entity.rgbColor { return Color(rgb: rgb) }
        if entity.control == .light { return .yellow }
        if entity.control == .lock { return .orange }
        return .accentColor
    }
}

struct DeviceCard: View {
    let device: String
    let sensors: [HAEntity]
    var large = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(device, systemImage: "iphone.gen3").font(large ? .headline : .subheadline.weight(.medium))
            ForEach(sensors) { s in
                HStack {
                    Text(shortName(s)).foregroundStyle(.secondary)
                    Spacer()
                    Text(s.stateLabel).monospacedDigit()
                }
                .font(.footnote)
            }
        }
        .padding(large ? 16 : 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 14))
    }

    /// "William's iPhone Battery level" reads as "Battery level" inside the card.
    private func shortName(_ s: HAEntity) -> String {
        s.name.hasPrefix(device) ? s.name.dropFirst(device.count).trimmingCharacters(in: .whitespaces) : s.name
    }
}
