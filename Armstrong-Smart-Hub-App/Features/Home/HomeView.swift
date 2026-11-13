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
    @State private var pi = PiStore()
    @State private var toast = Toast()
    @State private var light: HAEntity?
    @State private var remote: HAEntity?
    @State private var editingHabit: HabitEditTarget?
    @State private var managing = false
    @State private var display = false
    @State private var showAutomations = false
    @State private var searching = false
    @State private var showBackground = false

    var body: some View {
        NavigationStack {
            HubTabPage(topBar: { topBar }, hero: {
                if store.state != nil, store.state?.configured != false { hero }
            }, content: {
                content
            }, mountains: true)
            // The search page's keyboard mustn't resize Home underneath it: that scrolled the page
            // when search closed.
            .ignoresSafeArea(.keyboard)
            .toolbarBackground(HubDesign.page, for: .navigationBar)
            .allowsHitTesting(!searching)
            .accessibilityHidden(searching)
            .overlay {
                ZStack {
                    if searching {
                        MediaSearchView(onPick: open) { searching = false }
                            .transition(.opacity)
                    }
                }
                .hubAnimation(value: searching)
            }
            // A title requested from search flies to the shelf, so the search page gets out of its way.
            .onAppear {
                TitleCardPresenter.shared.revealShelf = { searching = false }
            }
            // An open title card follows its download from the same polls.
            .onChange(of: store.state?.requests ?? [], initial: true) { _, requests in
                TitleCardPresenter.shared.requests = requests
            }
            // Shelf titles' details are fetched ahead, so their cards open complete.
            .task(id: shelf.map(\.id)) { await MediaDetailCache.prefetch(shelf, api: session.api) }
            .toolbar(.hidden, for: .navigationBar)
            .refreshable {
                async let a: Void = store.refresh(api: session.api)
                async let b: Void = habits.load(api: session.api)
                async let c: Void = pi.load(api: session.api)
                _ = await (a, b, c)
            }
            .task(id: scenePhase) {
                guard scenePhase == .active else { return }
                habits.rollDay()
                await store.poll(api: session.api)
            }
            // The Pi card refreshes every minute while Home is open.
            .task(id: scenePhase) {
                guard scenePhase == .active else { return }
                while !Task.isCancelled {
                    await pi.load(api: session.api)
                    try? await Task.sleep(for: .seconds(60))
                }
            }
            .task { if !habits.fetched { await habits.load(api: session.api) } }
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
                    .hubPageStyle()
                    .toolbarBackground(.hidden, for: .navigationBar)
                    .navigationTitle("Automations")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showAutomations = false } } }
                }
                .presentationDetents([.medium, .large])
                .presentationBackground { AmbientBackdrop() }
                .toast(toast)
            }
            .sheet(isPresented: $showBackground) { BackgroundSettingsView() }
            .fullScreenCover(isPresented: $display) {
                DisplayModeView(store: store)
            }
            .habitEditor($editingHabit, store: habits)
            #if DEBUG
            .onAppear {
                DemoCue.on("light.toggle") { if let e = store.entity("light.living_room") { toggle(e) } }
                DemoCue.on("light.sheet") { light = store.entity("light.living_room") }
                DemoCue.on("light.close") { light = nil }
                DemoCue.on("lock") { if let e = store.entity("lock.front_door") { toggle(e) } }
            }
            #endif
            .toast(toast)
        }
    }

    /// What's on its way, then what's ready; a title just requested from its card goes first until
    /// the hub lists it.
    private var shelfRequests: [MediaRequest] {
        let real = store.activeDownloads + store.ready
        let pending = TitleCardPresenter.shared.justRequested.filter { p in !real.contains { $0.tmdbId == p.tmdbId } }
        return pending + real
    }

    /// Shelf titles as the card opens them.
    private var shelf: [MediaPick] {
        (store.activeDownloads + store.ready).compactMap { r in
            r.tmdbId.map { MediaPick(id: $0, mediaType: r.mediaType, title: r.title, posterURL: r.posterURL,
                                     known: r.stage == .available ? .available : .requested) }
        }
    }

    private func open(_ p: MediaPick) {
        TitleCardPresenter.shared.open(p, api: session.api) { Task { await store.refresh(api: session.api) } }
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
                Button("Background", systemImage: "photo") { showBackground = true }
            }
            .labelStyle(.iconOnly)
        }
    }

    /// A centred greeting and one line on the house, quick buttons for the lights, and a Docker check.
    private var hero: some View {
        let hour = Calendar.current.component(.hour, from: .now)
        let greeting = hour < 5 ? "Still up" : hour < 12 ? "Good morning" : hour < 18 ? "Good afternoon" : "Good evening"
        let lights = store.entities.filter { $0.control == .light && !$0.isTV && !$0.name.localizedCaseInsensitiveContains("remote") }
        let on = lights.filter(\.isOn).count
        let unlocked = store.entities.filter { $0.control == .lock && $0.isOn }
        let summary: String = {
            if let door = unlocked.first { return unlocked.count == 1 ? "\(door.name) is unlocked" : "\(unlocked.count) doors are unlocked" }
            if on > 0 { return on == 1 ? "One light is on" : "\(on) lights are on" }
            return "The house is quiet"
        }()
        return VStack(spacing: 0) {
            Spacer(minLength: 0)
            VStack(spacing: 8) {
                Text(greeting)
                    .font(.system(size: 48, weight: .light))
                    .multilineTextAlignment(.center)
                    .accessibilityAddTraits(.isHeader)
                Text(summary).font(.title3).foregroundStyle(BrickLook.soft)
            }
            Spacer(minLength: 0)
            if let status = pi.status, status.available, let containers = status.containers, !containers.isEmpty {
                NavigationLink { PiDetailView(pi: pi) } label: { dockerCheck(status, containers) }
                    .buttonStyle(.plain)
                    .padding(.top, 18)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: HubLayout.heroHeight)
    }

    /// "Pi healthy", or a red dot and what's wrong.
    private func dockerCheck(_ status: PiStatus, _ containers: [PiContainer]) -> some View {
        let bad = status.troubled
        let down = (status.services ?? []).filter { !$0.up }
        let problem: String? = {
            if let s = down.first { return down.count == 1 ? "\(s.name) is down" : "\(down.count) services down" }
            if !bad.isEmpty { return bad.count == 1 ? "\(bad[0].name) is down" : "\(bad.count) containers down" }
            return nil
        }()
        return HStack(spacing: 8) {
            if problem != nil { Circle().fill(HubDesign.danger).frame(width: 8, height: 8) }
            Text(problem ?? "Pi healthy").font(.footnote).foregroundStyle(BrickLook.soft)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .glassGlare(.regular, in: .capsule)
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
                // Together, so no birthday today leaves no gap.
                VStack(alignment: .leading, spacing: 0) {
                    BirthdayCards()
                    VStack(alignment: .leading, spacing: HubLayout.sectionGap) {
                        DeviceGroups(store: store, large: false, onOpen: open, onToggle: toggle, onBrightness: setBrightness)
                    }
                }
            }

            habitsSection

            if let status = pi.status, status.available {
                NavigationLink { PiDetailView(pi: pi) } label: { PiStatusCard(status: status) }
                    .buttonStyle(.plain)
            }

            // Keep the actual control mounted: a fixed-height placeholder jumps at larger text sizes.
            MediaSearchBar { searching = true }
                .opacity(searching ? 0 : 1)
                .accessibilityHidden(searching)

            if let problem = store.state?.errors.requests {
                Text("Download status isn't updating: \(problem)")
                    .font(.footnote).foregroundStyle(BrickLook.soft)
            } else if !shelfRequests.isEmpty {
                MediaShelf(requests: shelfRequests, hiding: TitleCardPresenter.shared.landingID, onPick: open)
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
                .sensoryFeedback(.success, trigger: habits.doneToday) { old, new in new > old }
            }
        }
    }

    private func open(_ entity: HAEntity) {
        if entity.isTV { remote = entity } else if entity.hasLightControls { light = entity }
    }

    private func setBrightness(_ entity: HAEntity, _ pct: Int) {
        Task { await store.setLight(entity, .init(on: true, brightnessPct: pct), api: session.api, toast: toast) }
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
    var onBrightness: (HAEntity, Int) -> Void = { _, _ in }

    var body: some View {
        let shown = store.shownEntities
        ForEach(groups, id: \.title) { group in
            let items = shown.filter { group.kinds.contains($0.control) }
            if !items.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    if large { SectionHeader(title: group.title) }
                    if group.kinds.contains(.light) {
                        VStack(spacing: 12) {
                            ForEach(items) { e in
                                LightSwitch(entity: e, pending: store.pending.contains(e.id), large: large) {
                                    onToggle(e)
                                } onAdjust: {
                                    onOpen(e)
                                } onBrightness: { pct in
                                    onBrightness(e, pct)
                                }
                            }
                        }
                    } else {
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
}

struct SectionHeader: View {
    let title: String
    var meta: String?

    var body: some View {
        VStack(spacing: 6) {
            Text(title).font(.title2)
            if let meta { BrickCaps(text: meta).foregroundStyle(HubDesign.secondary).monospacedDigit() }
        }
        .frame(maxWidth: .infinity)
    }
}
