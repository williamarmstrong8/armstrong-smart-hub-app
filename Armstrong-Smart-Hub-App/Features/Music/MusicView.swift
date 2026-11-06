import Charts
import SwiftUI

/// Spotify, like the Fitness tab: a hero sheet with the Walkman floating on it and
/// what's playing in its cassette window, then the recent plays and the week's
/// podcast-versus-music mix.
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

    private static let pullToShuffle: CGFloat = 110
    private static let swipeToSkip: CGFloat = 80

    var body: some View {
        NavigationStack {
            ScrollView(.vertical) {
                VStack(spacing: HubLayout.sectionGap) {
                    sheet
                    LazyVStack(spacing: HubLayout.sectionGap) {
                        if let error = store.error, !store.loaded {
                            ErrorBanner(message: error) { Task { await store.load(api: session.api) } }
                        }
                        if let summary = store.summary, summary.isConnected {
                            if let mix = summary.mix { MixSection(mix: mix) }
                            RecentSection(plays: summary.recent)
                            if let account = summary.account { accountFooter(account) }
                        }
                    }
                    .environment(\.fitnessCards, true)
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
            .task {
                #if DEBUG
                if Demo.isOn { store.demoSeed(); return }
                #endif
                await store.load(api: session.api)
            }
            // While the page is open, keep what's playing fresh.
            .task(id: scenePhase) {
                guard scenePhase == .active, !Demo.isOn else { return }
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
                if let url = store.nowPlaying?.url.flatMap(URL.init(string:)) {
                    Link(destination: url) {
                        Image(systemName: "arrow.up.right.square")
                            .frame(width: HubLayout.minHitTarget, height: HubLayout.minHitTarget)
                            .contentShape(.rect)
                    }
                    .accessibilityLabel("Open in Spotify")
                }
            }
            .frame(minHeight: HubLayout.minHitTarget)
            .padding(.top, HubLayout.topInset)

            pullHint.padding(.top, 4)

            walkman
                .padding(.horizontal, 8)
                .padding(.top, 8)

            heroText.padding(.top, 18)

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
        .frame(maxWidth: 360)
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

    @ViewBuilder
    private var heroText: some View {
        let playing = store.nowPlaying
        VStack(spacing: 8) {
            BrickCaps(text: caption).foregroundStyle(BrickLook.soft)
                .multilineTextAlignment(.center)
            Text(title)
                .font(.largeTitle.weight(.light))
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            if let subtitle {
                Text(subtitle).font(.body).foregroundStyle(BrickLook.soft).multilineTextAlignment(.center)
            }
            if let playing {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) { pills(playing) }
                    VStack(spacing: 8) { pills(playing) }
                }
                .padding(.top, 8)
            }
        }
        .frame(maxWidth: .infinity)
        .animation(reduceMotion ? nil : HubMotion.standard, value: playing?.id)
    }

    @ViewBuilder
    private func pills(_ playing: NowPlaying) -> some View {
        BrickPill(text: playing.isEpisode ? "Podcast" : "Music", icon: playing.isEpisode ? "mic" : "music.note")
        if playing.shuffle { BrickPill(text: "Shuffle", icon: "shuffle") }
        if let device = playing.device { BrickPill(text: device, icon: "hifispeaker") }
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
        case "not_connected": return "Link your account and the Walkman shows what's playing, your recent plays and the week's mix."
        default:
            guard let playing = summary.nowPlaying else { return "Open Spotify on a device, then pull the page down." }
            return [playing.subtitle, playing.detail].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        }
    }

    // MARK: Controls

    private var transport: some View {
        let playing = store.nowPlaying?.isPlaying == true
        return HStack(spacing: 12) {
            transportButton("backward.fill", label: "Previous", key: .rew)
            transportButton(playing ? "pause.fill" : "play.fill", label: playing ? "Pause" : "Play", key: .stop, large: true)
            transportButton("forward.fill", label: "Next", key: .ff)
            transportButton("shuffle", label: "Shuffle play", key: .play)
        }
        .disabled(store.busyKey != nil)
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

// MARK: Mix

/// Podcasts against music over the last seven days, with a word for the week.
private struct MixSection: View {
    var mix: ListeningMix

    static let music = Fit.adaptive(0x16893F, 0x1ED760)
    static let talk = Fit.sleep

    private struct Bar: Identifiable {
        var date: Date
        var kind: String
        var minutes: Int
        var id: String { "\(date.timeIntervalSince1970)|\(kind)" }
    }

    private var bars: [Bar] {
        mix.days.flatMap { day in
            [Bar(date: day.date, kind: "Music", minutes: day.musicMinutes),
             Bar(date: day.date, kind: "Podcasts", minutes: day.podcastMinutes)]
        }
    }

    var body: some View {
        FitSection(title: "Podcasts vs music", trailing: "Last 7 days") {
            VStack(alignment: .leading, spacing: 6) {
                Text(mix.mood).font(.system(.title, design: .default).weight(.light))
                Text(mix.line).font(.subheadline).foregroundStyle(BrickLook.soft)
                    .fixedSize(horizontal: false, vertical: true)
            }
            shareBar
            Chart(bars) { bar in
                BarMark(x: .value("Day", bar.date, unit: .day), y: .value("Minutes", bar.minutes))
                    .foregroundStyle(by: .value("Kind", bar.kind))
                    .cornerRadius(3)
            }
            .chartForegroundStyleScale(["Music": Self.music, "Podcasts": Self.talk])
            .chartLegend(.hidden)
            .chartXAxis {
                AxisMarks(values: .stride(by: .day)) { _ in
                    AxisValueLabel(format: .dateTime.weekday(.narrow)).font(Fit.axis)
                }
            }
            .chartYAxis {
                AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { value in
                    AxisGridLine().foregroundStyle(Fit.hairline)
                    AxisValueLabel { if let m = value.as(Int.self) { Text("\(m)m").font(Fit.axis) } }
                }
            }
            .frame(height: 150)
            .accessibilityLabel("Minutes of music and podcasts each day")
            HStack(spacing: 16) {
                LegendDot(color: Self.music, text: "Music \(hours(mix.musicMinutes))")
                LegendDot(color: Self.talk, text: "Podcasts \(hours(mix.podcastMinutes))")
            }
            if mix.topArtist != nil || mix.topShow != nil {
                VStack(spacing: 0) {
                    if let artist = mix.topArtist { DetailRow(label: "Most played artist", value: artist, last: mix.topShow == nil) }
                    if let show = mix.topShow { DetailRow(label: "Most played show", value: show, last: true) }
                }
            }
        }
    }

    /// The week's split as one bar: music from the left, talk from the right.
    private var shareBar: some View {
        let total = mix.musicMinutes + mix.podcastMinutes
        let talk = total > 0 ? mix.podcastShare : 0
        return GeometryReader { geo in
            HStack(spacing: 3) {
                Capsule().fill(total > 0 ? Self.music : Fit.track)
                    .frame(width: max(6, geo.size.width * (1 - talk) - 1.5))
                if talk > 0.005 {
                    Capsule().fill(Self.talk).frame(maxWidth: .infinity)
                }
            }
        }
        .frame(height: 12)
        .accessibilityElement()
        .accessibilityLabel("\(Int((talk * 100).rounded())) percent podcasts")
    }

    private func hours(_ minutes: Int) -> String {
        minutes >= 60 ? String(format: "%.1f h", Double(minutes) / 60) : "\(minutes) min"
    }
}

// MARK: Recent

private struct RecentSection: View {
    var plays: [RecentPlay]

    var body: some View {
        FitSection(title: "Recently played", trailing: plays.isEmpty ? nil : "\(plays.count) plays") {
            if plays.isEmpty {
                Text("Plays show up here as you listen. Podcasts count once the app has seen them playing.")
                    .font(.subheadline).foregroundStyle(BrickLook.soft)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(plays.enumerated()), id: \.element.rowID) { index, play in
                        if index > 0 { BrickDivider() }
                        RecentRow(play: play)
                    }
                }
            }
        }
    }
}

private struct RecentRow: View {
    var play: RecentPlay

    var body: some View {
        if let url = play.url.flatMap(URL.init(string:)) {
            Link(destination: url) { row }.buttonStyle(.plain)
        } else {
            row
        }
    }

    private var row: some View {
        HStack(spacing: 12) {
            AsyncImage(url: play.image.flatMap(URL.init(string:))) { phase in
                if let image = phase.image {
                    image.resizable().scaledToFill()
                } else {
                    Image(systemName: play.isEpisode ? "mic" : "music.note")
                        .foregroundStyle(BrickLook.soft)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(BrickLook.pill)
                }
            }
            .frame(width: 48, height: 48)
            .clipShape(.rect(cornerRadius: play.isEpisode ? 10 : 6, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(play.title).font(.body).lineLimit(1)
                HStack(spacing: 4) {
                    if play.isEpisode { Image(systemName: "mic.fill").font(.caption2) }
                    Text(play.isEpisode ? "\(play.subtitle) · \(play.minutes) min" : play.subtitle).lineLimit(1)
                }
                .font(.subheadline).foregroundStyle(BrickLook.soft)
            }
            Spacer(minLength: 8)
            Text(play.date, format: .relative(presentation: .numeric, unitsStyle: .abbreviated))
                .font(.caption).foregroundStyle(BrickLook.soft).monospacedDigit()
        }
        .padding(.vertical, 10)
        .foregroundStyle(BrickLook.ink)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
    }
}
