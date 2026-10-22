import SwiftUI

/// The closed search bar on Home: a Liquid Glass capsule that opens the search page.
struct MediaSearchBar: View {
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                Text("Search movies and shows")
                Spacer()
            }
            .foregroundStyle(BrickLook.soft)
            .padding(.horizontal, 18).padding(.vertical, 16)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .capsule)
    }
}

/// Overseerr search with a 300ms debounce, on its own page. With nothing typed it shows recent releases.
struct MediaSearchView: View {
    let onPick: (MediaPick) -> Void
    let onClose: () -> Void

    @Environment(AppSession.self) private var session
    @Namespace private var glass
    @State private var query = ""
    @State private var results: [MediaResult]?
    @State private var recent: [MediaResult] = []
    @State private var error: String?
    @State private var searching = false
    @State private var showClose = false
    @FocusState private var focused: Bool

    private var typing: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }
    /// Whatever was showing stays until the new results land, then they move into its slots.
    private var onShow: [MediaResult] { typing ? (results ?? recent) : recent }

    var body: some View {
        VStack(spacing: 16) {
            GlassEffectContainer(spacing: 12) {
                HStack(spacing: 12) {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass").foregroundStyle(BrickLook.soft)
                        TextField("Search movies and shows", text: $query)
                            .focused($focused)
                            .autocorrectionDisabled()
                            .submitLabel(.search)
                        if searching { ProgressView().controlSize(.small) }
                        if typing {
                            Button("Clear", systemImage: "xmark.circle.fill") {
                                query = ""
                                withAnimation(.smooth(duration: 0.4)) { results = nil }
                            }
                                .labelStyle(.iconOnly).foregroundStyle(BrickLook.soft).buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 18).padding(.vertical, 16)
                    .glassEffect(.regular.interactive(), in: .capsule)
                    .glassEffectID("field", in: glass)

                    if showClose {
                        Button { focused = false; onClose() } label: {
                            Image(systemName: "xmark").font(.system(size: 17, weight: .semibold))
                                .frame(width: 52, height: 52)
                        }
                        .buttonStyle(.plain)
                        .glassEffect(.regular.interactive(), in: .circle)
                        .glassEffectID("close", in: glass)
                        .accessibilityLabel("Close search")
                    }
                }
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let error { Text(error).font(.footnote).foregroundStyle(.red) }
                    if typing, results?.isEmpty == true, !searching {
                        Text("Nothing found.").font(.subheadline).foregroundStyle(BrickLook.soft)
                    } else {
                        grid(onShow)
                    }
                }
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(BrickLook.page.ignoresSafeArea())
        .foregroundStyle(BrickLook.ink)
        .tint(BrickLook.ink)
        .task {
            withAnimation(.smooth(duration: 0.4)) { showClose = true }
            try? await Task.sleep(for: .milliseconds(350))
            focused = true
        }
        .task { await loadRecent() }
        // The titles on show get their details fetched ahead, so a card opens with its button and
        // details in place. Starts over (and stops the last batch) whenever the grid changes.
        .task(id: onShow.map(\.id)) {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            await MediaDetailCache.prefetch(onShow.prefix(9).map(\.pick), api: session.api)
        }
        .task(id: query) {
            let q = query.trimmingCharacters(in: .whitespaces)
            guard !q.isEmpty else { return }
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            searching = true
            defer { searching = false }
            do {
                let found: [MediaResult] = try await session.api.run("searchMedia", [.string(q)]) ?? []
                guard !Task.isCancelled else { return }
                withAnimation(.smooth(duration: 0.4)) { results = found }
                error = nil
            } catch is CancellationError {
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func grid(_ items: [MediaResult]) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 12)], spacing: 16) {
            ForEach(items) { r in
                Button {
                    focused = false
                    onPick(r.pick)
                } label: {
                    Poster(url: r.posterURL)
                }
                .buttonStyle(.plain)
                .accessibilityLabel([r.title, r.year].compactMap { $0 }.joined(separator: ", "))
                .transition(.opacity.combined(with: .scale(scale: 0.92)))
            }
        }
    }

    /// Popular movies released two months to a year ago, picked by the companion.
    private func loadRecent() async {
        do {
            recent = try await session.api.run("discoverMedia", []) ?? []
        } catch {
            // Search still works without the suggestions.
        }
    }
}

/// Home's carousel: what's on its way, then what's ready. A title on its way is dimmed, and the
/// dark lifts from the bottom as it downloads until the whole poster shows.
struct MediaShelf: View {
    let requests: [MediaRequest]
    /// A tile a request's poster is flying to, hidden until it lands.
    var hiding: Int? = nil
    let onPick: (MediaPick) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(requests) { r in
                    Button {
                        if let tmdb = r.tmdbId { onPick(MediaPick(id: tmdb, mediaType: r.mediaType, title: r.title, posterURL: r.posterURL,
                                                    known: r.stage == .available ? .available : .requested)) }
                    } label: { tile(r) }
                    .buttonStyle(.plain)
                    .opacity(r.tmdbId != nil && r.tmdbId == hiding ? 0 : 1)
                    .disabled(r.tmdbId == nil)
                }
            }
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
                TitleCardPresenter.shared.shelfSlot = CGRect(x: frame.minX, y: frame.minY, width: 150, height: 225)
            }
            .onDisappear { TitleCardPresenter.shared.shelfSlot = nil }
            .padding(.horizontal, 16)
            .animation(.smooth(duration: 0.45), value: requests.map(\.id))
        }
        .padding(.horizontal, -16)
        .scrollClipDisabled()
    }

    private func tile(_ r: MediaRequest) -> some View {
        let waiting = r.stage != .available
        let fill = r.stage == .available ? 1 : r.stage == .processing ? 0.98 : min(max(r.progress ?? 0, 0), 1)
        return Poster(url: r.posterURL, width: 150)
            .overlay(alignment: .top) {
                if waiting {
                    // The dark part is whatever hasn't downloaded yet; it shrinks upward from the bottom.
                    GeometryReader { geo in
                        Rectangle().fill(.black.opacity(0.72))
                            .frame(height: geo.size.height * (1 - fill))
                            .animation(.smooth(duration: 0.8), value: fill)
                    }
                }
            }
            .overlay {
                if waiting {
                    VStack(spacing: 4) {
                        if r.stage == .downloading, let p = r.progress {
                            Text("\(Int(p * 100))%").font(.system(size: 28, weight: .light).monospacedDigit())
                                .contentTransition(.numericText())
                        } else {
                            Text(r.stage.label).font(.footnote.weight(.medium))
                        }
                        if r.stage == .downloading, let eta = r.etaSeconds, eta > 0 {
                            Text(r.etaText).font(.caption2).opacity(0.8)
                        }
                    }
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.5), radius: 6)
                    .padding(8)
                }
            }
            .clipShape(.rect(cornerRadius: 18))
            .shadow(color: .black.opacity(0.14), radius: 10, y: 6)
    }
}

struct RequestList: View {
    let requests: [MediaRequest]
    let onPick: (MediaPick) -> Void

    var body: some View {
        VStack(spacing: 10) {
            ForEach(requests) { r in
                Button {
                    if let tmdb = r.tmdbId { onPick(MediaPick(id: tmdb, mediaType: r.mediaType, title: r.title, posterURL: r.posterURL,
                                                    known: r.stage == .available ? .available : .requested)) }
                } label: {
                    HStack(spacing: 12) {
                        Poster(url: r.posterURL, width: 60)
                        VStack(alignment: .leading, spacing: 6) {
                            Text(r.title).font(.subheadline.weight(.medium)).lineLimit(1)
                            if let p = r.progress, r.stage == .downloading {
                                ProgressView(value: p).tint(.accentColor)
                            }
                            HStack {
                                Text(r.etaText)
                                Spacer()
                                if let p = r.progress { Text("\(Int(p * 100))%").monospacedDigit() }
                            }
                            .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// The burst when a title goes to the TV: light pours out of the Dynamic Island and ripples down
/// the screen, like two phones meeting for AirDrop.
struct SendGlow: View {
    let start: Date
    static let duration: Double = 1.4

    private let blue = Color(red: 0.36, green: 0.64, blue: 1)
    private let violet = Color(red: 0.62, green: 0.48, blue: 1)

    var body: some View {
        TimelineView(.animation) { timeline in
            let t = min(timeline.date.timeIntervalSince(start) / Self.duration, 1)
            Canvas { ctx, size in
                let origin = CGPoint(x: size.width / 2, y: 29.5)
                let reach = hypot(size.width, size.height)
                func circle(_ r: CGFloat) -> Path {
                    Path(ellipseIn: CGRect(x: origin.x - r, y: origin.y - r, width: r * 2, height: r * 2))
                }

                // A glow that swells out of the island and fades as it spreads.
                let spread = 1 - pow(1 - t, 3)
                let glowR = 40 + spread * reach * 0.85
                let glow = sin(.pi * min(t * 1.3, 1)) * 0.5
                ctx.fill(circle(glowR), with: .radialGradient(
                    Gradient(colors: [.white.opacity(glow), blue.opacity(glow * 0.8), violet.opacity(glow * 0.35), .clear]),
                    center: origin, startRadius: 0, endRadius: glowR))

                // Three soft rings rippling down behind it.
                for i in 0..<3 {
                    let ti = (t - Double(i) * 0.14) / 0.75
                    guard ti > 0, ti < 1 else { continue }
                    let r = 16 + (1 - pow(1 - ti, 2.2)) * reach
                    var ring = ctx
                    ring.addFilter(.blur(radius: 4 + 10 * ti))
                    ring.stroke(circle(r), with: .color((i == 1 ? violet : blue).opacity((1 - ti) * 0.85)),
                                lineWidth: 2 + 12 * (1 - ti))
                }
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

/// Fetches a poster through the shared URL cache, where the shelf's and search's posters already
/// sit, so a title's card can open with its image in place rather than loading it mid-slide.
enum PosterLoader {
    static func image(_ url: String?, waitingAtMost limit: Duration = .milliseconds(500)) async -> UIImage? {
        guard let url = url.flatMap(URL.init(string:)) else { return nil }
        return await withTaskGroup(of: UIImage?.self) { group in
            group.addTask {
                var req = URLRequest(url: url)
                req.cachePolicy = .returnCacheDataElseLoad
                guard let (data, _) = try? await URLSession.shared.data(for: req) else { return nil }
                return UIImage(data: data)
            }
            group.addTask { try? await Task.sleep(for: limit); return nil }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }
}

/// Shows a title's card above the whole tab view, so the tab bar blurs with the page rather than
/// hiding (hiding it changed Home's insets and nudged its scroll), and runs the send to the TV.
@MainActor
@Observable
final class TitleCardPresenter {
    static let shared = TitleCardPresenter()

    private(set) var pick: MediaPick?
    private(set) var poster: UIImage?
    /// How far the card is up (0–1); the screen behind blurs by it.
    var reveal: CGFloat = 0
    /// When the last title went to the TV, for the send burst; nil once it's over.
    private(set) var sentAt: Date?
    let toast = Toast()
    @ObservationIgnored private(set) var onChanged: () -> Void = {}
    /// Titles just requested from a card, shown first on the shelf as queued until the hub lists them.
    private(set) var justRequested: [MediaRequest] = []
    /// The shelf tile a request's poster is flying to, kept invisible until the poster lands on it.
    private(set) var landingID: Int?
    /// The hub's requests as Home last polled them, so an open card follows its download live.
    var requests: [MediaRequest] = []
    /// Where a new title lands on Home's shelf (its first slot, on screen), for a request's flight.
    @ObservationIgnored var shelfSlot: CGRect?
    /// Home's hook to get its shelf in view for a request's flight (it closes the search page).
    @ObservationIgnored var revealShelf: () -> Void = {}

    /// Opens once the poster is in hand (normally cached, so at once), so it slides in with the
    /// card; details not stored yet are fetched in the same short wait, so the card opens complete.
    func open(_ p: MediaPick, api: APIClient, onChanged: @escaping () -> Void) {
        self.onChanged = onChanged
        Task {
            async let image = PosterLoader.image(p.posterURL)
            if MediaDetailCache.get(p) == nil {
                await MediaDetailCache.fetch(p, api: api, waitingAtMost: .milliseconds(600))
            }
            poster = await image
            withAnimation(.smooth(duration: 0.4)) { pick = p; reveal = 1 }
        }
    }

    /// A plain ease-in, so the card drops straight out rather than lingering along the bottom edge.
    func close() {
        withAnimation(.easeIn(duration: 0.3)) { pick = nil; reveal = 0 }
    }

    /// A request is about to fly to the shelf: close search so the shelf shows, and open an empty
    /// slot at the front for it, the posters already there sliding right.
    func requesting(_ p: MediaPick) {
        let queued = MediaRequest(id: -p.id, tmdbId: p.id, title: p.title, mediaType: p.mediaType,
                                  posterURL: p.posterURL, stage: .approved, progress: nil, etaSeconds: nil,
                                  updatedAt: nil, statusMessage: nil)
        revealShelf()
        landingID = p.id
        withAnimation(.smooth(duration: 0.55)) {
            justRequested.removeAll { $0.tmdbId == p.id }
            justRequested.insert(queued, at: 0)
        }
    }

    /// The flight couldn't happen (the shelf is off screen): show the queued tile as it is.
    func cancelLanding() { landingID = nil }

    /// The poster has landed in its slot: swap the card for the queued tile beneath it, unseen.
    func landed() {
        var t = SwiftUI.Transaction(); t.disablesAnimations = true
        withTransaction(t) { pick = nil; landingID = nil }
        onChanged()
    }

    /// The poster has gone into the island: drop the card where it is (it's already invisible) and
    /// play the burst while the screen unblurs.
    func sent() {
        var t = SwiftUI.Transaction(); t.disablesAnimations = true
        withTransaction(t) { pick = nil }
        let now = Date.now
        sentAt = now
        withAnimation(.smooth(duration: 0.7)) { reveal = 0 }
        Task {
            try? await Task.sleep(for: .seconds(SendGlow.duration + 0.1))
            if sentAt == now { sentAt = nil }
        }
    }
}

/// Title details kept between opens and launches, so a card shows them at once and only refreshes
/// them quietly behind.
@MainActor
enum MediaDetailCache {
    private static let file = URL.cachesDirectory.appending(path: "media-details.json")
    private static var details: [String: MediaDetail] =
        (try? JSONDecoder().decode([String: MediaDetail].self, from: Data(contentsOf: file))) ?? [:]

    private static func key(_ p: MediaPick) -> String { "\(p.mediaType.rawValue)-\(p.id)" }

    static func get(_ p: MediaPick) -> MediaDetail? { details[key(p)] }

    static func set(_ d: MediaDetail?, for p: MediaPick) {
        details[key(p)] = d
        if let data = try? JSONEncoder().encode(details) { try? data.write(to: file, options: .atomic) }
    }

    /// Fetches and stores one title's details, giving up on the wait (not the fetch) after `limit`.
    static func fetch(_ p: MediaPick, api: APIClient, waitingAtMost limit: Duration) async {
        let fetch = Task {
            if let d: MediaDetail = try? await api.run("mediaDetail", [.string(p.mediaType.rawValue), .int(p.id)]) {
                set(d, for: p)
            }
        }
        let timeout = Task { try? await Task.sleep(for: limit) }
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await fetch.value }
            group.addTask { await timeout.value }
            _ = await group.next()
            timeout.cancel()
        }
    }

    /// Fetches what isn't stored yet, so even the first open of a shelf title is instant.
    static func prefetch(_ picks: [MediaPick], api: APIClient) async {
        for p in picks where get(p) == nil {
            guard !Task.isCancelled else { return }
            if let d: MediaDetail = try? await api.run("mediaDetail", [.string(p.mediaType.rawValue), .int(p.id)]) {
                set(d, for: p)
            }
        }
    }
}

/// A title's card, drawn over the tab view rather than as a sheet so the page behind can blur in step with
/// it: as tall as the poster, which fills it from the top and fades into black under the words.
/// Drag it down or tap above it to close. On a title that can play, swiping up shrinks the card to
/// its poster as it rises, stopping just under the Dynamic Island; let go and it goes in and plays.
struct MediaDetailCard: View {
    let pick: MediaPick
    /// The poster, already loaded, so it arrives with the card; nil falls back to loading it here.
    let poster: UIImage?
    let toast: Toast
    /// 1 while the card is fully up, falling toward 0 as it's dragged down; Home blurs by it.
    @Binding var reveal: CGFloat
    let onChanged: () -> Void
    let onClose: () -> Void
    /// Called once the poster has gone into the Dynamic Island, for Home to remove the card in place
    /// and play the send burst.
    let onSent: () -> Void

    init(pick: MediaPick, poster: UIImage?, toast: Toast, reveal: Binding<CGFloat>,
         onChanged: @escaping () -> Void, onClose: @escaping () -> Void, onSent: @escaping () -> Void) {
        self.pick = pick
        self.poster = poster
        self.toast = toast
        _reveal = reveal
        self.onChanged = onChanged
        self.onClose = onClose
        self.onSent = onSent
        _detail = State(initialValue: MediaDetailCache.get(pick))
    }

    /// The screen's own corner radius, so the card's corners run parallel to the display's.
    private static let screenRadius: CGFloat = {
        let screen = UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.screen }.first
        return (screen?.value(forKey: "_displayCornerRadius") as? CGFloat).flatMap { $0 > 0 ? $0 : nil } ?? 55
    }()
    /// How far the card floats in from the screen's edges.
    private static let inset: CGFloat = 8
    /// How small a play swipe shrinks the card before it goes into the island.
    private static let smallest: CGFloat = 0.3

    @Environment(AppSession.self) private var session
    @State private var detail: MediaDetail?
    @State private var error: String?
    @State private var working = false
    @State private var requested = false
    @State private var confirmRemove = false
    @State private var drag: CGFloat = 0
    /// A swipe up has passed the point where letting go plays it.
    @State private var armed = false
    /// Set once let go on a play swipe: the poster's flight into the island, taking over from the drag.
    @State private var sending = false
    @State private var sendX: CGFloat = 0
    @State private var sendY: CGFloat = 0
    /// This view's origin on screen, to place a request's flight to the shelf.
    @State private var origin: CGPoint = .zero
    /// The card's size and resting centre, as laid out.
    @State private var cardSize: CGSize = .zero
    @State private var restY: CGFloat = 0
    /// Set on a request's flight: the card takes on the queued tile's look as it shrinks into it.
    @State private var landing = false
    @State private var sendScale: CGFloat = 1
    @State private var sendOpacity: Double = 1

    /// This title's request as Home last polled it, for a live download bar.
    private var live: MediaRequest? { TitleCardPresenter.shared.requests.first { $0.tmdbId == pick.id } }
    private var available: Bool { live?.stage == .available || (detail?.available ?? (pick.known == .available)) }
    private var canPlay: Bool { available && (detail?.canPlay ?? true) }
    private var isRequested: Bool {
        requested || live != nil || (detail?.alreadyRequested ?? (pick.known == .requested))
    }

    var body: some View {
        GeometryReader { geo in
            // Floats a little in from the screen's edges so its corners can be round all the way.
            let width = geo.size.width - 2 * Self.inset
            let height = min(width * 1.5, geo.size.height - 60)
            // Where the card's centre sits at rest and the island's centre, in this view's space
            // (it starts below the status bar).
            let rest = geo.size.height - Self.inset - height / 2
            let island = 29.5 - geo.safeAreaInsets.top
            // A play swipe can lift the card until, at its smallest, its top is just under the island.
            let maxLift = max(rest - (island + 18.5 + 14 + Self.smallest * height / 2), 1)
            let lift = canPlay ? max(-drag, 0) : 0
            // 0 as the full card, 1 once a play swipe has shrunk it down to its smallest.
            let shrink = min(lift / maxLift, 1)
            // Past the stop it barely moves, as if on a short leash.
            let shown = lift <= maxLift ? lift : maxLift + (lift - maxLift) / 10
            let y = drag > 0 ? drag : canPlay ? -shown : drag / 6
            ZStack(alignment: .bottom) {
                Color.clear.contentShape(.rect).onTapGesture(perform: onClose)
                card(shrink: sending ? 1 : shrink)
                    .frame(width: width, height: height)
                    .padding(.bottom, Self.inset)
                    .scaleEffect(sending ? sendScale : 1 - (1 - Self.smallest) * shrink)
                    .offset(x: sending ? sendX : 0, y: sending ? sendY : y)
                    .opacity(sendOpacity)
                    .allowsHitTesting(!sending)
                    .gesture(
                        DragGesture(minimumDistance: 8)
                            .onChanged { v in
                                let dy = v.translation.height
                                drag = dy
                                reveal = 1 - min(max(dy / height, 0), 1)
                                armed = canPlay && dy < -100
                            }
                            .onEnded { v in
                                let dy = v.translation.height
                                if canPlay && (dy < -100 || v.predictedEndTranslation.height < -240) {
                                    send(toward: island - rest, posterHeight: height)
                                } else if dy > 120 || v.predictedEndTranslation.height > 320 {
                                    onClose()
                                } else {
                                    armed = false
                                    withAnimation(.smooth(duration: 0.3)) { drag = 0; reveal = 1 }
                                }
                            }
                    )
                    .sensoryFeedback(.impact(weight: .medium), trigger: armed) { _, now in now }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .onAppear { cardSize = CGSize(width: width, height: height); restY = rest }
            .onChange(of: rest) { _, r in cardSize = CGSize(width: width, height: height); restY = r }
            .onGeometryChange(for: CGPoint.self) { $0.frame(in: .global).origin } action: { origin = $0 }
        }
        .ignoresSafeArea(edges: .bottom)
        .preferredColorScheme(.dark)
        .task { await load() }
        // Finished downloading while open: fetch the details again for Play.
        .onChange(of: live?.stage) { _, stage in
            if stage == .available { Task { await load() } }
        }
        .confirmationDialog(available ? "Delete \(pick.title)?" : "Cancel the request for \(pick.title)?",
                            isPresented: $confirmRemove, titleVisibility: .visible) {
            Button(available ? "Delete movie and files" : "Cancel request", role: .destructive) { Task { await remove() } }
        } message: {
            Text("This stops any download and removes it, and its files, from the library.")
        }
    }

    private func card(shrink: CGFloat) -> some View {
        // Every row keeps its place while the details load, so nothing moves when they arrive.
        // On a play swipe the words, fade and close button dissolve, leaving just the poster.
        VStack(alignment: .leading, spacing: 12) {
            Text(pick.title).font(.system(size: 28, weight: .semibold)).lineLimit(2)
            Text(detail.map(meta) ?? "2026 · Movie · 120 min")
                .font(.system(size: 15)).foregroundStyle(.white.opacity(0.65))
                .redacted(reason: detail == nil ? .placeholder : [])
            if let error, detail == nil {
                ErrorBanner(message: error) { Task { await load() } }
            } else {
                primary.padding(.top, 8)
            }
            // Only titles in the library or on their way have this row; without it, Request sits
            // lower, by the bottom of the card.
            if available || isRequested {
                Button(available ? "Delete from library" : "Cancel request") { confirmRemove = true }
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.white.opacity(0.6))
                    .frame(maxWidth: .infinity)
                    .disabled(working)
            }
        }
        .foregroundStyle(.white)
        .opacity(1 - min(shrink * 2.2, 1))
        .padding(.horizontal, 24)
        .padding(.bottom, 44)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .background {
            // One image for the card's whole life: swapping to the details' poster URL reloaded it,
            // which is what flashed.
            Group {
                if let poster {
                    Image(uiImage: poster).resizable().scaledToFill()
                } else {
                    AsyncImage(url: (pick.posterURL ?? detail?.posterURL).flatMap(URL.init(string:))) { phase in
                        if let image = phase.image { image.resizable().scaledToFill() } else { Color.white.opacity(0.06) }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .clipped()
            .overlay {
                LinearGradient(stops: [
                    .init(color: .clear, location: 0.3),
                    .init(color: .black.opacity(0.55), location: 0.58),
                    .init(color: .black.opacity(0.92), location: 0.8),
                    // Fully black before the bottom, so the corners' curve has no poster left in it.
                    .init(color: .black, location: 0.9),
                ], startPoint: .top, endPoint: .bottom)
                .opacity(1 - shrink)
            }
        }
        .background(.black)
        .overlay {
            // The queued tile's dimming and label, sized up so they read right once shrunk.
            if landing {
                ZStack {
                    Color.black.opacity(0.72)
                    Text(RequestStage.approved.label)
                        .font(.system(size: 13 / max(sendScale, 0.1), weight: .medium))
                        .foregroundStyle(.white)
                }
                .transition(.opacity)
            }
        }
        // Flattened first so the corners are cut once: clipping the poster and the gradient as
        // separate layers left a faint sliver of poster along the curve.
        .compositingGroup()
        .clipShape(.rect(cornerRadius: Self.screenRadius - Self.inset, style: .continuous))
        .overlay(alignment: .topTrailing) {
            Button(action: onClose) {
                Image(systemName: "xmark").font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(.black.opacity(0.4), in: .circle)
            }
            .padding(16)
            .accessibilityLabel("Close")
            .opacity(1 - shrink)
        }
        .shadow(color: .black.opacity(0.3), radius: 24, y: -4)
    }

    /// Play, Requested or Request, from what the card already knows. Only a title from search,
    /// whose state isn't known until the details load, shows a placeholder of the same size.
    @ViewBuilder
    private var primary: some View {
        if available {
            let canPlay = detail?.canPlay ?? true
            pill(detail?.resumeSeconds != nil ? "Resume on TV" : "Play on TV", systemImage: "play.fill") {
                Task { await play() }
            }
            .opacity(canPlay ? 1 : 0.45)
            .disabled(!canPlay || working)
        } else if let live, live.stage.isActive || live.stage == .pendingApproval {
            progress(live)
        } else if isRequested {
            Label("Requested", systemImage: "checkmark").font(.system(size: 17, weight: .semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(.white.opacity(0.18), in: .capsule)
        } else if detail != nil {
            pill("Request", systemImage: "plus") { Task { await request() } }
                .disabled(working)
        } else {
            pill("Request", systemImage: "plus") {}
                .redacted(reason: .placeholder)
                .opacity(0.35)
                .disabled(true)
        }
    }

    /// Requested, as a bar that fills as the title downloads, with how far along it is.
    private func progress(_ r: MediaRequest) -> some View {
        let fill = r.stage == .downloading ? min(max(r.progress ?? 0, 0), 1) : r.stage == .processing ? 1 : 0
        return HStack(spacing: 6) {
            Text(r.stage == .downloading ? "Downloading" : r.stage.label)
            if r.stage == .downloading, r.progress != nil {
                Text("\(Int(fill * 100))%").monospacedDigit().contentTransition(.numericText())
            }
        }
        .font(.system(size: 17, weight: .semibold))
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
        .background {
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Rectangle().fill(.white.opacity(0.18))
                    Rectangle().fill(.white.opacity(0.32)).frame(width: g.size.width * fill)
                }
            }
        }
        .clipShape(.capsule)
        .animation(.smooth(duration: 0.8), value: fill)
        .accessibilityElement(children: .combine)
    }

    private func pill(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 17, weight: .semibold)).foregroundStyle(.black)
                .frame(maxWidth: .infinity).padding(.vertical, 16)
                .background(.white, in: .capsule)
                .overlay { if working { ProgressView().tint(.black) } }
        }
        .buttonStyle(.plain)
    }

    /// Search closes and the shelf opens an empty slot at its front, then the card shrinks into a
    /// poster and flies up into it, taking on the queued tile's look as it lands. False when the
    /// shelf isn't on screen to land in.
    private func flyToShelf() async -> Bool {
        let presenter = TitleCardPresenter.shared
        presenter.requesting(pick)
        // A beat for the shelf to lay out (it may have only just appeared) and report its slot.
        try? await Task.sleep(for: .milliseconds(60))
        guard let slot = presenter.shelfSlot, cardSize.width > 0,
              let screen = UIApplication.shared.connectedScenes.compactMap({ ($0 as? UIWindowScene)?.screen }).first,
              slot.maxY > 0, slot.minY < screen.bounds.height else {
            presenter.cancelLanding()
            return false
        }
        withAnimation(.smooth(duration: 0.75)) {
            sending = true
            landing = true
            sendX = slot.midX - origin.x - cardSize.width / 2 - Self.inset
            sendY = slot.midY - origin.y - restY
            sendScale = slot.width / cardSize.width
            reveal = 0
        } completion: {
            presenter.landed()
        }
        return true
    }

    /// Plays the title and carries on from the swipe in one motion: the poster shrinks to the
    /// island's size as it travels up into it, fading only at the very end. The burst says it went,
    /// so there's no toast unless it fails.
    private func send(toward island: CGFloat, posterHeight: CGFloat) {
        Task { await play(announce: false) }
        withAnimation(.easeIn(duration: 0.34)) {
            sending = true
            sendY = island
            sendScale = 37 / posterHeight
        } completion: {
            onSent()
        }
        withAnimation(.easeIn(duration: 0.1).delay(0.26)) { sendOpacity = 0 }
    }

    private func meta(_ d: MediaDetail) -> String {
        var parts: [String] = []
        if let y = d.year { parts.append(y) }
        parts.append(d.mediaType == .tv ? (d.seasons.map { "\($0) season\($0 == 1 ? "" : "s")" } ?? "Series") : "Movie")
        if let r = d.runtimeMinutes, r > 0 { parts.append("\(r) min") }
        if let v = d.voteAverage, v > 0 { parts.append(String(format: "★ %.1f", v)) }
        return parts.joined(separator: " · ")
    }

    private func load() async {
        do {
            let fresh: MediaDetail? = try await session.api.run("mediaDetail", [.string(pick.mediaType.rawValue), .int(pick.id)])
            detail = fresh
            MediaDetailCache.set(fresh, for: pick)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func request() async {
        working = true
        defer { working = false }
        do {
            let _: Empty? = try await session.api.run("requestMedia", [.string(pick.mediaType.rawValue), .int(pick.id)])
            requested = true
            MediaDetailCache.set(nil, for: pick)
            if !(await flyToShelf()) {
                toast.show("Requested \(pick.title)")
                onChanged()
            }
        } catch {
            toast.error(error)
        }
    }

    private func remove() async {
        working = true
        defer { working = false }
        do {
            let _: Empty? = try await session.api.run("removeMedia", [.string(pick.mediaType.rawValue), .int(pick.id)])
            MediaDetailCache.set(nil, for: pick)
            onChanged()
            onClose()
        } catch {
            toast.error(error)
        }
    }

    private func play(announce: Bool = true) async {
        working = true
        defer { working = false }
        do {
            let _: Empty? = try await session.api.run("playMedia", [.string(pick.mediaType.rawValue), .int(pick.id)])
            if announce { toast.show("Playing on the TV") }
            TVActivityController.shared.played()
        } catch {
            toast.error(error)
        }
    }
}
