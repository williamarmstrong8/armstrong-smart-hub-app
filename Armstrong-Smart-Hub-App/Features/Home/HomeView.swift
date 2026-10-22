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
    @State private var fitness = FitnessStore()
    @State private var toast = Toast()
    @State private var light: HAEntity?
    @State private var remote: HAEntity?
    @State private var pick: MediaPick?
    /// How far the title card is up (0–1); the page behind blurs by it.
    @State private var reveal: CGFloat = 0
    @State private var poster: UIImage?
    @State private var editingHabit: HabitEditTarget?
    @State private var managing = false
    @State private var display = false
    @State private var showAutomations = false
    @State private var searching = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 40) {
                    topBar.padding(.bottom, -32)
                    content
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 48)
            }
            .background(BrickLook.page.ignoresSafeArea())
            .foregroundStyle(BrickLook.ink)
            .tint(BrickLook.ink)
            .toolbarBackground(BrickLook.page, for: .navigationBar)
            .overlay {
                if searching {
                    MediaSearchView(onPick: open) {
                        withAnimation(.smooth(duration: 0.3)) { searching = false }
                    }
                    .transition(.opacity)
                }
            }
            // The page behind a title's card blurs as it rises and clears as it goes, in step with it.
            .blur(radius: 14 * reveal)
            .overlay {
                if let p = pick {
                    MediaDetailCard(pick: p, poster: poster, toast: toast, reveal: $reveal,
                                    onChanged: { Task { await store.refresh(api: session.api) } },
                                    onClose: closeTitle,
                                    onFlewOff: {
                                        // Already off the top: remove it in place, without sliding back down.
                                        var t = SwiftUI.Transaction(); t.disablesAnimations = true
                                        withTransaction(t) { pick = nil; reveal = 0 }
                                    })
                        .id(p.id)
                        .transition(.move(edge: .bottom))
                }
            }
            .toolbarVisibility(pick == nil ? .visible : .hidden, for: .tabBar)
            .toolbar(.hidden, for: .navigationBar)
            .refreshable {
                async let a: Void = store.refresh(api: session.api)
                async let b: Void = habits.load(api: session.api)
                async let f: Void = fitness.load(api: session.api)
                _ = await (a, b, f)
            }
            .task(id: scenePhase) {
                guard scenePhase == .active else { return }
                habits.rollDay()
                await store.poll(api: session.api)
            }
            .task { if !habits.fetched { await habits.load(api: session.api) } }
            .task { await fitness.load(api: session.api) }
            .sheet(item: $light) { e in
                LightSheet(entityID: e.id, store: store, toast: toast)
                    .presentationDetents([.medium, .large])
            }
            .sheet(item: $remote) { e in
                RemoteSheet(entity: store.entity(e.id) ?? e)
                    .presentationDetents([.large])
            }
            .sheet(isPresented: $managing) {
                ManageDevicesView(entities: store.entities, visible: store.state?.visible) {
                    Task { await store.refresh(api: session.api) }
                }
            }
            .sheet(isPresented: $showAutomations) {
                NavigationStack {
                    ScrollView {
                        if let payload = store.state?.automations {
                            AutomationsSection(payload: payload, store: store, toast: toast).padding(16)
                        }
                    }
                    .navigationTitle("Automations")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showAutomations = false } } }
                }
                .presentationDetents([.medium, .large])
                .toast(toast)
            }
            .fullScreenCover(isPresented: $display) {
                DisplayModeView(store: store)
            }
            .habitEditor($editingHabit, store: habits)
            .toast(toast)
        }
    }

    /// Opens a title's card once its poster is in hand (it's normally cached, so this is instant),
    /// so the image slides in with the card instead of popping in partway.
    private func open(_ p: MediaPick) {
        Task {
            let image = await PosterLoader.image(p.posterURL)
            poster = image
            withAnimation(.smooth(duration: 0.4)) { pick = p; reveal = 1 }
        }
    }

    private func closeTitle() {
        withAnimation(.smooth(duration: 0.35)) { pick = nil; reveal = 0 }
    }

    private var topBar: some View {
        BrickTopBar {
            Menu("More", systemImage: "ellipsis") {
                Button("Display mode", systemImage: "rectangle.on.rectangle") { display = true }
                Button("Choose devices", systemImage: "slider.horizontal.3") { managing = true }
                    .disabled(store.entities.isEmpty)
                Button("Automations", systemImage: "bolt") { showAutomations = true }
                    .disabled(store.state?.automations == nil || store.state?.errors.automations != nil)
                Button("Add habit", systemImage: "plus.circle") { editingHabit = .new }
            }
            .labelStyle(.iconOnly)
        }
    }

    /// One word and one sentence on how you're doing, from the watch's readiness, sleep and Body Battery.
    private var status: (title: String, summary: String)? {
        let watch = fitness.snapshot?.watch
        let metrics = fitness.snapshot?.metrics
        let readiness = watch?.readiness?.score ?? metrics?.readiness.score
        let sleep = watch?.sleep?.overall ?? fitness.lastNight?.score
        let energy = fitness.currentBodyBattery ?? metrics?.bodyBattery?.current ?? fitness.snapshot?.insights?.stress.bodyBattery?.current
        guard readiness != nil || sleep != nil || energy != nil else { return nil }
        let drained = (energy ?? 100) < 30
        let slept = (sleep ?? 0) >= 75
        let ready = readiness ?? 0
        if drained || ready < 40 {
            return ("Run down", drained ? "Battery is low. Take it easy and get to bed early." : "Your body is asking for rest today.")
        }
        if ready >= 75 && (energy ?? 100) >= 60 {
            return ("Energized", slept ? "Slept well and ready to push. A good day to train." : "Ready to go, even on a short night.")
        }
        if slept { return ("Rested", "Slept well and recovered. Steady day ahead.") }
        return ("Steady", "A middling night. Fine for an easy day.")
    }

    /// How you're doing, from the watch, with the rest of the house under it.
    private var hero: some View {
        let shown = store.shownEntities
        let active = shown.filter { $0.isOn && $0.control != .light }.count
        let status = status
        return BrickHero(caption: Date.now.formatted(.dateTime.weekday(.wide).month(.wide).day()),
                         title: status?.title ?? "Home", subtitle: status?.summary) {
            if active > 0 { BrickPill(text: "\(active) active", icon: "bolt.fill") }
            if habits.loaded, !habits.habits.isEmpty { BrickPill(text: "\(habits.doneToday) of \(habits.habits.count) habits", icon: "checkmark.circle") }
            if store.isBusy { BrickPill(text: "Downloading", icon: "arrow.down.circle") }
        }
        .animation(.smooth, value: status?.title)
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

            if store.state != nil { hero }

            if store.state == nil {
                ProgressView().frame(maxWidth: .infinity, minHeight: 200)
            } else {
                DeviceGroups(store: store, large: false, onOpen: open, onToggle: toggle)
            }

            habitsSection

            if !searching {
                MediaSearchBar { withAnimation(.smooth(duration: 0.3)) { searching = true } }
            } else {
                Color.clear.frame(height: 50)
            }

            if let problem = store.state?.errors.requests {
                Text("Download status isn't updating: \(problem)")
                    .font(.footnote).foregroundStyle(BrickLook.soft)
            } else if !store.activeDownloads.isEmpty || !store.ready.isEmpty {
                MediaShelf(requests: store.activeDownloads + store.ready, onPick: open)
            }
        }
    }

    /// Today's habits as the dashboard's circles. Tap to fill; hold to edit.
    @ViewBuilder
    private var habitsSection: some View {
        if habits.loaded, !habits.habits.isEmpty {
            let today = habits.today
            VStack(alignment: .leading, spacing: 14) {
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
                    if large { SectionHeader(title: group.title) }
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
        VStack(spacing: 6) {
            Text(title).font(.system(size: 26, weight: .regular))
            if let meta { BrickCaps(text: meta).foregroundStyle(BrickLook.soft).monospacedDigit() }
        }
        .frame(maxWidth: .infinity)
    }
}
