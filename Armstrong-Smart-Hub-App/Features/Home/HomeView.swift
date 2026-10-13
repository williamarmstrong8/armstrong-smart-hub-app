import SwiftUI

private let groups: [(title: String, kinds: Set<ControlKind>)] = [
    ("Lights", [.light]),
    ("Entertainment", [.remote, .mediaPlayer]),
    ("Climate", [.climate]),
    ("Locks", [.lock]),
    ("Switches", [.toggle]),
]

/// Home on the iPhone: devices as cards you tap, automations, today's habits,
/// and what's downloading or ready to watch.
struct HomeView: View {
    @Environment(AppSession.self) private var session
    @Environment(\.scenePhase) private var scenePhase
    @State private var store = HomeStore()
    @State private var habits = HabitsStore()
    @State private var toast = Toast()
    @State private var light: HAEntity?
    @State private var remote: HAEntity?
    @State private var pick: MediaPick?
    @State private var editingHabit: HabitEditTarget?
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
                ToolbarItem(placement: .topBarTrailing) {
                    Menu("More", systemImage: "ellipsis") {
                        Button("Display mode", systemImage: "rectangle.on.rectangle") { display = true }
                        Button("Choose devices", systemImage: "slider.horizontal.3") { managing = true }
                            .disabled(store.entities.isEmpty)
                        Button("Add habit", systemImage: "plus.circle") { editingHabit = .new }
                    }
                }
            }
            .refreshable {
                async let a: Void = store.refresh(api: session.api)
                async let b: Void = habits.load(api: session.api)
                _ = await (a, b)
            }
            .task(id: scenePhase) {
                guard scenePhase == .active else { return }
                habits.rollDay()
                await store.poll(api: session.api)
            }
            .task { if !habits.loaded { await habits.load(api: session.api) } }
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
            .habitEditor($editingHabit, store: habits)
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
            }

            habitsSection

            if let payload = store.state?.automations, store.state?.errors.automations == nil {
                AutomationsSection(payload: payload, store: store, toast: toast)
            }

            if !store.activeDownloads.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    SectionHeader(title: "Downloading")
                    RequestList(requests: store.activeDownloads) { pick = $0 }
                }
            }

            if !store.ready.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    SectionHeader(title: "Ready to watch")
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 12) {
                            ForEach(store.ready) { r in
                                Button {
                                    if let tmdb = r.tmdbId {
                                        pick = MediaPick(id: tmdb, mediaType: r.mediaType, title: r.title, posterURL: r.posterURL)
                                    }
                                } label: {
                                    Poster(url: r.posterURL, width: 110)
                                }
                                .buttonStyle(.plain)
                                .disabled(r.tmdbId == nil)
                            }
                        }
                    }
                }
            }

            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(title: "Find something to watch")
                MediaSearchView { pick = $0 }
            }
        }
    }

    /// Today's habits as the dashboard's circles. Tap to fill; hold to edit.
    @ViewBuilder
    private var habitsSection: some View {
        if habits.loaded, !habits.habits.isEmpty {
            let today = habits.today
            VStack(alignment: .leading, spacing: 14) {
                SectionHeader(title: "Habits")
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 12)], spacing: 18) {
                    ForEach(habits.habits) { habit in
                        HabitButton(habit: habit, done: habits.isDone(habit.id, today), saving: habits.isSaving(habit.id, today), size: 84) {
                            Task { await habits.toggle(habit, today, api: session.api, toast: toast) }
                        }
                        .contextMenu { Button("Edit", systemImage: "pencil") { editingHabit = .habit(habit) } }
                    }
                }
                .animation(.spring(duration: 0.4, bounce: 0.2), value: habits.done)
                .sensoryFeedback(.success, trigger: habits.doneToday) { old, new in new > old }
            }
        }
    }

    private func open(_ entity: HAEntity) {
        if entity.isTV { remote = entity } else if entity.hasLightControls { light = entity }
    }

    private func toggle(_ entity: HAEntity) {
        if entity.isTV { remote = entity; return }
        Task { await store.toggle(entity, api: session.api, toast: toast) }
    }
}

/// Devices grouped by kind, each a card that is itself the switch.
struct DeviceGroups: View {
    let store: HomeStore
    let large: Bool
    /// Kept for callers; every card toggles on tap now.
    var tapToToggle = true
    let onOpen: (HAEntity) -> Void
    let onToggle: (HAEntity) -> Void

    var body: some View {
        let shown = store.shownEntities
        ForEach(groups, id: \.title) { group in
            let items = shown.filter { group.kinds.contains($0.control) }
            if !items.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    SectionHeader(title: group.title)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: large ? 200 : 150), spacing: 10)], spacing: 10) {
                        ForEach(items) { e in
                            DeviceButton(entity: e, pending: store.pending.contains(e.id), compact: !large) {
                                onToggle(e)
                            } onAdjust: {
                                onOpen(e)
                            }
                        }
                    }
                }
            }
        }
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
