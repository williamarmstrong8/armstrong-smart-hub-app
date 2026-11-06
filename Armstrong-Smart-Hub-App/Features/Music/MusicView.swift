import SwiftUI

/// Spotify, like the Fitness tab: a hero sheet with the Walkman floating on it and
/// what's playing in its cassette window, then the library, episodes to listen to
/// and picks from the listening history, all floating on the page with no cards.
///
/// The Walkman is played by hand: pull the page down and let go to press PLAY
/// (shuffle play), swipe it left or right for FF and REW, tap the window to
/// play or pause, or tap a key. The transport row under it does the same.
struct MusicView: View {
    @Environment(AppSession.self) private var session
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var store = MusicStore.shared

    /// How far the page is pulled past its top, in points.
    @State private var pull: CGFloat = 0
    @State private var dragging = false
    /// Pulled far enough: letting go presses PLAY.
    @State private var armed = false
    /// Horizontal drag on the Walkman.
    @State private var swipe: CGFloat = 0
    /// A key tapped a moment ago, held down briefly even if the hub answers fast.
    @State private var tapped: WalkmanKey?
    @State private var flash: WalkmanKey?
    @State private var path = NavigationPath()
    @State private var pickingDevice = false
    /// The scrubber while a finger is on it, 0...1.
    @State private var scrub: Double?

    private static let pullToShuffle: CGFloat = 110
    private static let swipeToSkip: CGFloat = 80

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView(.vertical) {
                VStack(spacing: HubLayout.sectionGap) {
                    sheet
                    LazyVStack(spacing: HubLayout.sectionGap) {
                        if let error = store.error, !store.loaded {
                            ErrorBanner(message: error) { Task { await store.load(api: session.api) } }
                        }
                        if let summary = store.summary, summary.isConnected {
                            if summary.needsReconnect { reconnectCard }
                            else if let library = store.library { LibrarySection(library: library, discover: store.discover) }
                            if let account = summary.account { accountFooter(account) }
                        }
                    }
                    .padding(.horizontal, HubLayout.gutter)
                }
                .padding(.bottom, HubLayout.bottomInset)
                .containerRelativeFrame(.horizontal)
            }
            .scrollBounceBehavior(.always, axes: .vertical)
            .onScrollGeometryChange(for: CGFloat.self) { geo in
                -(geo.contentOffset.y + geo.contentInsets.top)
            } action: { _, overscroll in
                pull = max(0, overscroll)
                guard dragging, store.summary?.isConnected == true else { return }
                if !armed, pull >= Self.pullToShuffle { armed = true }
                else if armed, pull < Self.pullToShuffle * 0.7 { armed = false }
            }
            .onScrollPhaseChange { _, phase in
                if phase == .interacting {
                    dragging = true
                } else if dragging {
                    dragging = false
                    if armed {
                        armed = false
                        press(.play)
                    }
                }
            }
            .demoScroll()
            .hubPageStyle()
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: MusicRoute.self) { route in
                switch route {
                case .collection(let kind, let id, let title): CollectionPage(kind: kind, id: id, title: title)
                case .search: MusicSearchPage()
                }
            }
            .sheet(isPresented: $pickingDevice) { DevicePicker() }
            .task {
                #if DEBUG
                if Demo.isOn { store.demoSeed(); return }
                #endif
                await store.load(api: session.api)
                await store.loadLibrary(api: session.api)
                await store.loadDiscover(api: session.api)
            }
            // While the page is open, keep what's playing fresh.
            .task(id: scenePhase) {
                guard scenePhase == .active, !Demo.isOn else { return }
                await store.resumePending(api: session.api)
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(5))
                    guard !Task.isCancelled else { return }
                    await store.poll(api: session.api)
                }
            }
            .onChange(of: store.pressedAt) {
                flash = store.lastPressed
            }
            .task(id: flash) {
                guard flash != nil else { return }
                try? await Task.sleep(for: .seconds(1.1))
                if !Task.isCancelled { flash = nil }
            }
            .sensoryFeedback(.impact(weight: .light), trigger: armed) { _, now in now }
            .sensoryFeedback(.impact(flexibility: .rigid, intensity: 0.9), trigger: store.busyKey) { _, key in key != nil }
            .sensoryFeedback(.success, trigger: store.pressedAt) { _, _ in store.lastPressed == .play }
            .toast(store.toast)
        }
    }

    // MARK: Hero

    private var sheet: some View {
        VStack(spacing: 0) {
            BrickTopBar {
                if store.summary?.isConnected == true {
                    NavigationLink(value: MusicRoute.search) {
                        Image(systemName: "magnifyingglass")
                            .frame(width: HubLayout.minHitTarget, height: HubLayout.minHitTarget)
                            .contentShape(.rect)
                    }
                    .accessibilityLabel("Search")
                    Button { pickingDevice = true } label: {
                        Image(systemName: SpotifyDevice.symbol(for: store.nowPlaying?.deviceType))
                            .frame(width: HubLayout.minHitTarget, height: HubLayout.minHitTarget)
                            .contentShape(.rect)
                    }
                    .accessibilityLabel("Choose where it plays")
                }
            }
            .frame(minHeight: HubLayout.minHitTarget)
            .padding(.top, HubLayout.topInset)

            pullHint.padding(.top, 4)

            walkman
                .padding(.horizontal, 8)
                .padding(.top, 4)

            heroText.padding(.top, 12)

            if store.summary?.isConnected == true {
                transport.padding(.top, HubLayout.sectionGap)
            } else if store.loaded {
                connect.padding(.top, HubLayout.sectionGap)
            }
        }
        .padding(.horizontal, HubLayout.gutter)
        .padding(.bottom, HubLayout.sectionGap)
        .frame(maxWidth: .infinity)
        .background {
            UnevenRoundedRectangle(bottomLeadingRadius: BrickLook.sheetRadius, bottomTrailingRadius: BrickLook.sheetRadius, style: .continuous)
                .fill(BrickLook.sheet)
                // Reaches up under the status bar and past the top when pulled down, like Fitness.
                .padding(.top, -600)
        }
    }

    /// Only while pulling: how far to go, then that letting go will shuffle.
    private var pullHint: some View {
        let shown = pull > 12 && store.summary?.isConnected == true
        return BrickCaps(text: armed ? "Release to shuffle" : "Pull to shuffle")
            .foregroundStyle(armed ? HubDesign.action : BrickLook.soft)
            .opacity(shown ? min(1, Double(pull - 12) / 40) : 0)
            .frame(height: 16)
            .accessibilityHidden(true)
    }

    private var walkman: some View {
        let depth = keyDepth
        let pressed = depth.values.max() ?? 0
        return WalkmanHero(playing: store.nowPlaying, depth: depth, flash: flash, winding: winding) { key in
            press(key)
        }
        .frame(maxWidth: 250)
        // A little give in the whole body when a key goes down, and a turn toward a swipe.
        .offset(x: swipe * 0.25, y: pressed * 2)
        .rotation3DEffect(.degrees(reduceMotion ? 0 : Double(swipe) / 9), axis: (x: 0, y: 1, z: 0), perspective: 0.6)
        .simultaneousGesture(swipeGesture)
        .animation(reduceMotion ? nil : .spring(response: 0.22, dampingFraction: 0.6), value: store.busyKey)
        .animation(reduceMotion ? nil : .spring(response: 0.22, dampingFraction: 0.6), value: tapped)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Walkman")
    }

    /// How far down each key is: PLAY follows the pull, FF and REW follow a swipe,
    /// and whichever key the hub is working on stays all the way down.
    private var keyDepth: [WalkmanKey: Double] {
        var depth: [WalkmanKey: Double] = [:]
        if store.summary?.isConnected == true {
            depth[.play] = min(1, Double(pull / Self.pullToShuffle))
        }
        if swipe < 0 { depth[.ff] = min(1, Double(-swipe / Self.swipeToSkip)) }
        if swipe > 0 { depth[.rew] = min(1, Double(swipe / Self.swipeToSkip)) }
        for key in [store.busyKey, tapped].compactMap({ $0 }) { depth[key] = 1 }
        return depth
    }

    private var winding: WalkmanKey? {
        guard let key = store.busyKey, key != .stop else { return nil }
        return key
    }

    private var swipeGesture: some Gesture {
        DragGesture(minimumDistance: 16)
            .onChanged { value in
                let t = value.translation
                guard abs(t.width) > abs(t.height) * 1.4, store.summary?.isConnected == true else { return }
                swipe = max(-140, min(140, t.width))
            }
            .onEnded { _ in
                let key: WalkmanKey? = swipe <= -Self.swipeToSkip ? .ff : swipe >= Self.swipeToSkip ? .rew : nil
                withAnimation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.55)) { swipe = 0 }
                if let key { press(key) }
            }
    }

    private func press(_ key: WalkmanKey) {
        tapped = key
        Task {
            let started = Date.now
            await store.press(key, api: session.api)
            // Hold the key down long enough to see, even when the hub answers fast.
            let left = 0.18 - Date.now.timeIntervalSince(started)
            if left > 0 { try? await Task.sleep(for: .seconds(left)) }
            if tapped == key { tapped = nil }
        }
    }

    /// Just the title and who it's by; the device, mode and album live in the controls.
    private var heroText: some View {
        VStack(spacing: 6) {
            if store.nowPlaying == nil {
                BrickCaps(text: caption).foregroundStyle(BrickLook.soft)
                    .multilineTextAlignment(.center)
            }
            Text(title)
                .font(store.nowPlaying == nil ? .largeTitle.weight(.light) : .title2.weight(.regular))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            if let subtitle {
                Text(subtitle).font(.subheadline).foregroundStyle(BrickLook.soft).multilineTextAlignment(.center).lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity)
        .animation(reduceMotion ? nil : HubMotion.standard, value: store.nowPlaying?.id)
    }

    private var caption: String {
        guard let summary = store.summary else { return "Spotify" }
        if !summary.isConnected { return "Spotify" }
        guard let playing = summary.nowPlaying else { return "Nothing playing" }
        return playing.isPlaying ? (playing.isEpisode ? "Now listening" : "Now playing") : "Paused"
    }

    private var title: String {
        guard let summary = store.summary else { return "Music" }
        if !summary.isConnected { return "Connect Spotify" }
        return summary.nowPlaying?.title ?? "Pull down to shuffle"
    }

    private var subtitle: String? {
        guard let summary = store.summary else { return nil }
        switch summary.status {
        case "unconfigured": return "The hub needs a Spotify app first: add SPOTIFY_CLIENT_ID and SPOTIFY_CLIENT_SECRET to its environment."
        case "not_connected": return "Link your account and the Walkman shows what's playing, with your library and picks for what to hear next."
        default:
            guard let playing = summary.nowPlaying else { return "Open Spotify on a device, then pull the page down." }
            return playing.subtitle
        }
    }

    // MARK: Controls

    private var transport: some View {
        let now = store.nowPlaying
        let playing = now?.isPlaying == true
        return VStack(spacing: 18) {
            if let now { scrubber(now) }
            HStack(spacing: 10) {
                toggleButton(store.smartShuffle ? "sparkles" : "shuffle", on: now?.shuffle == true,
                             label: store.smartShuffle ? "Smart shuffle" : "Shuffle") {
                    Task { await store.cycleShuffle(api: session.api) }
                }
                transportButton("backward.fill", label: "Previous", key: .rew)
                transportButton(playing ? "pause.fill" : "play.fill", label: playing ? "Pause" : "Play", key: .stop, large: true)
                transportButton("forward.fill", label: "Next", key: .ff)
                toggleButton(now?.repeat == "track" ? "repeat.1" : "repeat", on: (now?.repeat ?? "off") != "off",
                             label: now?.repeat == "track" ? "Repeat one" : now?.repeat == "context" ? "Repeat all" : "Repeat off") {
                    Task { await store.cycleRepeat(api: session.api) }
                }
            }
            .disabled(store.busyKey != nil)
            Button { pickingDevice = true } label: {
                HStack(spacing: 6) {
                    Image(systemName: SpotifyDevice.symbol(for: now?.deviceType))
                    Text(now?.device.map { "Playing on \($0)" } ?? "Choose a device")
                    Image(systemName: "chevron.down").font(.caption2.weight(.semibold))
                }
                .font(.subheadline.weight(.medium))
                .foregroundStyle(now?.device == nil ? BrickLook.soft : spotifyGreen)
                .frame(minHeight: HubLayout.minHitTarget)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityHint("Choose where it plays")
        }
    }

    /// Drag to seek; the clock runs between the hub's readings.
    private func scrubber(_ now: SpotifyTrack) -> some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: now.isPlaying == false || scrub != nil)) { context in
            let live = now.progress(at: context.date)
            let shown = scrub ?? live
            VStack(spacing: 4) {
                Slider(value: Binding(get: { shown }, set: { scrub = $0 }), in: 0...1) { editing in
                    if !editing, let value = scrub {
                        Task {
                            await store.seek(to: value, api: session.api)
                            scrub = nil
                        }
                    }
                }
                .tint(spotifyGreen)
                .accessibilityLabel("Position")
                .accessibilityValue(Self.clock(shown * Double(now.durationMs) / 1000))
                HStack {
                    Text(Self.clock(shown * Double(now.durationMs) / 1000))
                    Spacer()
                    Text("-" + Self.clock((1 - shown) * Double(now.durationMs) / 1000))
                }
                .font(.caption).monospacedDigit().foregroundStyle(BrickLook.soft)
            }
        }
    }

    private static func clock(_ seconds: Double) -> String {
        let s = max(0, Int(seconds.rounded(.down)))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }

    private func toggleButton(_ icon: String, on: Bool, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(on ? spotifyGreen : BrickLook.soft)
                .frame(width: 44, height: 44)
                .overlay(alignment: .bottom) {
                    if on { Circle().fill(spotifyGreen).frame(width: 4, height: 4).offset(y: -4) }
                }
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private func transportButton(_ icon: String, label: String, key: WalkmanKey, large: Bool = false) -> some View {
        Button { press(key) } label: {
            Image(systemName: icon)
                .font(.system(size: large ? 22 : 17, weight: .medium))
                .foregroundStyle(BrickLook.ink)
                .frame(width: large ? 64 : 52, height: large ? 64 : 52)
                .background(BrickLook.pill, in: .circle)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    @ViewBuilder
    private var connect: some View {
        if store.summary?.status == "not_connected" {
            Button {
                Task { await store.connect(api: session.api) }
            } label: {
                HStack(spacing: 8) {
                    if store.connecting { ProgressView() } else { Image(systemName: "link") }
                    Text("Connect Spotify")
                }
                .frame(minHeight: HubLayout.minHitTarget)
            }
            .buttonStyle(.borderedProminent)
            .disabled(store.connecting)
        }
    }

    /// Linked before the hub asked to read the library: one more pass through Spotify's sign-in.
    private var reconnectCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Reconnect Spotify").font(.headline)
            Text("Spotify needs one more yes so the hub can show your liked songs, playlists and podcast episodes.")
                .font(.subheadline).foregroundStyle(BrickLook.soft)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                Task {
                    await store.connect(api: session.api)
                    await store.loadLibrary(api: session.api)
                    await store.loadDiscover(api: session.api)
                }
            } label: {
                HStack(spacing: 8) {
                    if store.connecting { ProgressView() } else { Image(systemName: "arrow.triangle.2.circlepath") }
                    Text("Reconnect")
                }
                .frame(minHeight: HubLayout.minHitTarget)
            }
            .buttonStyle(.borderedProminent)
            .tint(spotifyGreen)
            .disabled(store.connecting)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func accountFooter(_ account: String) -> some View {
        Menu {
            Button("Disconnect Spotify", role: .destructive) {
                Task { await store.disconnect(api: session.api) }
            }
        } label: {
            Text("Spotify · \(account)")
                .font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: HubLayout.minHitTarget)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityHint("Shows the option to disconnect")
    }
}
