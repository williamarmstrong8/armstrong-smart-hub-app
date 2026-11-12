import SwiftUI
import ImageIO
import UIKit

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
            .foregroundStyle(HubDesign.secondary)
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var searchID = UUID()
    @Namespace private var glass
    @State private var query = ""
    @State private var results: [MediaResult]?
    @State private var recent: [MediaResult] = []
    @State private var error: String?
    @State private var searching = false
    @State private var showClose = false
    @FocusState private var focused: Bool

    private var typing: Bool { !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    /// Whatever was showing stays until the new results land, then they move into its slots.
    private var onShow: [MediaResult] { typing ? (results ?? recent) : recent }

    var body: some View {
        VStack(spacing: 16) {
            GlassEffectContainer(spacing: 12) {
                HStack(spacing: 12) {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass").foregroundStyle(HubDesign.secondary)
                        TextField("Search movies and shows", text: $query)
                            .focused($focused)
                            .autocorrectionDisabled()
                            .submitLabel(.search)
                        if searching { ProgressView().controlSize(.small) }
                        Button {
                            query = ""
                            results = nil
                            error = nil
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .frame(width: HubLayout.minHitTarget, height: HubLayout.minHitTarget)
                                .contentShape(.rect)
                        }
                        .accessibilityLabel("Clear search")
                        .foregroundStyle(HubDesign.secondary)
                        .buttonStyle(.plain)
                        // Reserve the target so typing does not resize the field or the grid.
                        .opacity(typing ? 1 : 0)
                        .disabled(!typing)
                        .accessibilityHidden(!typing)
                    }
                    .padding(.leading, 18).padding(.trailing, 4).padding(.vertical, 4)
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
                    if let error { Text(error).font(.footnote).foregroundStyle(HubDesign.danger) }
                    if typing, results?.isEmpty == true, !searching {
                        Text("Nothing found.").font(.subheadline).foregroundStyle(HubDesign.secondary)
                    } else {
                        grid(onShow)
                    }
                }
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .padding(.horizontal, HubLayout.gutter)
        .padding(.top, HubLayout.topInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .hubPageStyle()
        .task {
            withAnimation(HubMotion.animation(reduceMotion: reduceMotion)) { showClose = true }
            do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            guard !Task.isCancelled, !TitleCardPresenter.shared.isPresenting else { return }
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
            let id = UUID()
            searchID = id
            let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
            searching = !q.isEmpty
            error = nil
            defer { if searchID == id { searching = false } }
            guard !q.isEmpty else { results = nil; return }
            do {
                try await Task.sleep(for: .milliseconds(300))
                let found: [MediaResult] = try await session.api.run("searchMedia", [.string(q)]) ?? []
                guard !Task.isCancelled, searchID == id else { return }
                // Replacing a grid should not animate every poster and its scroll layout.
                results = found
            } catch {
                guard !Task.isCancelled, searchID == id else { return }
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
            }
        }
    }

    /// Popular movies released two months to a year ago, picked by the companion.
    private func loadRecent() async {
        do {
            let found: [MediaResult] = try await session.api.run("discoverMedia", []) ?? []
            guard !Task.isCancelled else { return }
            recent = found
        } catch {
            // Search still works without the suggestions.
        }
    }
}

/// Home's carousel: what's on its way, then what's ready. A title on its way is dimmed, and the
/// dark lifts from the bottom as it downloads until the whole poster shows.
struct MediaShelf: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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
                    .accessibilityLabel("\(r.title), \(r.stage.label)")
                    .accessibilityHidden(r.tmdbId != nil && r.tmdbId == hiding)
                }
            }
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
                TitleCardPresenter.shared.shelfSlot = CGRect(x: frame.minX, y: frame.minY, width: 150, height: 225)
            }
            .onDisappear { TitleCardPresenter.shared.shelfSlot = nil }
            .padding(.horizontal, HubLayout.gutter)
        }
        .padding(.horizontal, -HubLayout.gutter)
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
                            .animation(HubMotion.animation(reduceMotion: reduceMotion), value: fill)
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

/// Fetches a poster through the shared URL cache, where the shelf's and search's posters already
/// sit, so a title's card can open with its image in place rather than loading it mid-slide.
enum PosterLoader {
    static func image(_ url: String?, waitingAtMost limit: Duration = .milliseconds(500)) async -> UIImage? {
        guard let url = url.flatMap(URL.init(string:)) else { return nil }
        return await withTaskGroup(of: UIImage?.self) { group in
            group.addTask {
                var req = URLRequest(url: url)
                req.cachePolicy = .returnCacheDataElseLoad
                guard let (data, response) = try? await URLSession.shared.data(for: req),
                      !Task.isCancelled,
                      (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true,
                      let source = CGImageSourceCreateWithData(data as CFData, nil),
                      let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceThumbnailMaxPixelSize: 1600,
                        kCGImageSourceCreateThumbnailWithTransform: true,
                        kCGImageSourceShouldCacheImmediately: true
                      ] as CFDictionary) else { return nil }
                // Decode and bound large artwork off the main actor, before the opening animation.
                return UIImage(cgImage: thumbnail)
            }
            group.addTask { try? await Task.sleep(for: limit); return nil }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    /// A card-sized TMDB image, rather than an unbounded original download.
    static func fullSize(_ url: String?) -> String? {
        guard let url else { return nil }
        guard let range = url.range(of: #"/t/p/(w\d+|original)/"#, options: .regularExpression) else { return url }
        return url.replacingCharacters(in: range, with: "/t/p/w780/")
    }
}

/// Presents above the tabs without changing Home's insets, and runs the send to the TV.
@MainActor
@Observable
final class TitleCardPresenter {
    static let shared = TitleCardPresenter()

    private(set) var pick: MediaPick?
    private(set) var poster: UIImage?
    private(set) var presentationID = UUID()
    @ObservationIgnored private var opening: Task<Void, Never>?
    var isPresenting: Bool { pick != nil || opening != nil }
    /// How far the card is up (0–1); controls the dim scrim only.
    var reveal: CGFloat = 0
    /// When the last title went to the TV, for the send haptic; nil shortly after.
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

    /// A short cache warm-up only: details refresh inside the card, never blocking its opening.
    func open(_ p: MediaPick, api: APIClient, onChanged: @escaping () -> Void) {
        guard pick == nil else { return }
        opening?.cancel()
        let id = UUID()
        presentationID = id
        landingID = nil
        self.onChanged = onChanged
        opening = Task {
            let image = await PosterLoader.image(p.posterURL, waitingAtMost: .milliseconds(120))
            guard !Task.isCancelled, presentationID == id else { return }
            poster = image
            withAnimation(HubMotion.animation(reduceMotion: UIAccessibility.isReduceMotionEnabled)) {
                pick = p
                reveal = 1
            }
            opening = nil
        }
    }

    func close() {
        opening?.cancel()
        opening = nil
        presentationID = UUID()
        landingID = nil
        withAnimation(HubMotion.animation(reduceMotion: UIAccessibility.isReduceMotionEnabled)) {
            pick = nil
            reveal = 0
        }
    }

    /// A request is about to fly to the shelf: close search so the shelf shows, and open an empty
    /// slot at the front for it, the posters already there sliding right.
    func requesting(_ p: MediaPick) {
        let queued = MediaRequest(id: -p.id, tmdbId: p.id, title: p.title, mediaType: p.mediaType,
                                  posterURL: p.posterURL, stage: .approved, progress: nil, etaSeconds: nil,
                                  updatedAt: nil, statusMessage: nil)
        // The shelf is scroll content: insert without animating its entire layout.
        var transaction = SwiftUI.Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            revealShelf()
            landingID = p.id
            justRequested.removeAll { $0.tmdbId == p.id && $0.mediaType == p.mediaType }
            justRequested.insert(queued, at: 0)
        }
    }

    /// The flight couldn't happen (the shelf is off screen): show the queued tile as it is.
    func cancelLanding() { landingID = nil }

    /// The poster has landed in its slot: swap the card for the queued tile beneath it, unseen.
    func landed() {
        var t = SwiftUI.Transaction(); t.disablesAnimations = true
        withTransaction(t) { pick = nil; landingID = nil; reveal = 0; presentationID = UUID() }
        onChanged()
    }

    /// The poster has gone into the island: remove it and release the scrim.
    func sent() {
        var t = SwiftUI.Transaction(); t.disablesAnimations = true
        withTransaction(t) { pick = nil; landingID = nil; presentationID = UUID() }
        let now = Date.now
        sentAt = now
        withAnimation(HubMotion.animation(reduceMotion: UIAccessibility.isReduceMotionEnabled)) { reveal = 0 }
        Task {
            try? await Task.sleep(for: .milliseconds(500))
            if sentAt == now { sentAt = nil }
        }
    }
}

/// All cache file access and JSON work stays on this actor, never on the UI executor.
private actor MediaDetailCacheFile {
    private let file = URL.cachesDirectory.appending(path: "media-details.json")
    private var latestRevision: UInt64 = 0

    func read() -> [String: MediaDetail] {
        (try? JSONDecoder().decode([String: MediaDetail].self, from: Data(contentsOf: file))) ?? [:]
    }

    func write(_ snapshot: [String: MediaDetail], revision: UInt64) {
        // Actor jobs need not arrive FIFO. A delayed older snapshot must never win.
        guard revision > latestRevision else { return }
        latestRevision = revision
        if let data = try? JSONEncoder().encode(snapshot) {
            try? data.write(to: file, options: .atomic)
        }
    }
}

/// Immediate in-memory lookups; disk restoration and persistence do not block scrolling.
@MainActor
enum MediaDetailCache {
    private static let storage = MediaDetailCacheFile()
    private static var details: [String: MediaDetail] = [:]
    private static var revisions: [String: UInt64] = [:]
    private static var nextRevision: UInt64 = 0
    private static var restored = false
    private static var restoration: Task<Void, Never>?

    private static func key(_ p: MediaPick) -> String { "\(p.mediaType.rawValue)-\(p.id)" }

    static func get(_ p: MediaPick) -> MediaDetail? { details[key(p)] }
    static func revision(for p: MediaPick) -> UInt64 { revisions[key(p)] ?? 0 }

    static func restore() async {
        guard !restored else { return }
        if let restoration { await restoration.value; return }
        let task = Task {
            let saved = await storage.read()
            // Include tombstones: an invalidation during the read must not be resurrected.
            for (key, value) in saved where revisions[key] == nil { details[key] = value }
            restored = true
        }
        restoration = task
        await task.value
        restoration = nil
    }

    static func set(_ d: MediaDetail?, for p: MediaPick) {
        details[key(p)] = d
        nextRevision += 1
        revisions[key(p)] = nextRevision
        Task {
            // Merge untouched saved entries before taking a complete snapshot.
            await restore()
            let snapshot = details
            let revision = nextRevision
            await storage.write(snapshot, revision: revision)
        }
    }

    /// Fetches what isn't stored yet, so even the first open of a shelf title is instant.
    static func prefetch(_ picks: [MediaPick], api: APIClient) async {
        await restore()
        for p in picks where get(p) == nil {
            guard !Task.isCancelled else { return }
            let version = revision(for: p)
            if let d: MediaDetail = try? await api.run("mediaDetail", [.string(p.mediaType.rawValue), .int(p.id)]) {
                guard !Task.isCancelled else { return }
                guard revision(for: p) == version else { continue }
                set(d, for: p)
            }
        }
    }
}

/// A cinematic title card above a dim scrim, without changing the tab view's layout.
/// The poster fills it from the top and fades into black under the words.
/// Drag it down or tap above it to close. On a title that can play, swiping up shrinks the card to
/// its poster as it rises, stopping just under the Dynamic Island; let go and it goes in and plays.
struct MediaDetailCard: View {
    let pick: MediaPick
    let presentationID: UUID
    /// The poster, already loaded, so it arrives with the card; nil falls back to loading it here.
    let poster: UIImage?
    let toast: Toast
    /// 1 while fully up, falling toward 0 as it's dragged down; dims the backdrop.
    @Binding var reveal: CGFloat
    let onChanged: () -> Void
    let onClose: () -> Void
    /// Called once the poster has gone into the Dynamic Island, for Home to remove the card in place
    /// and play the send burst.
    let onSent: () -> Void

    init(pick: MediaPick, presentationID: UUID, poster: UIImage?, toast: Toast, reveal: Binding<CGFloat>,
         onChanged: @escaping () -> Void, onClose: @escaping () -> Void, onSent: @escaping () -> Void) {
        self.pick = pick
        self.presentationID = presentationID
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AccessibilityFocusState private var closeFocused: Bool
    @State private var detail: MediaDetail?
    @State private var detailLoadID = UUID()
    @State private var sharp: UIImage?
    @State private var error: String?
    @State private var working = false
    @State private var requested = false
    @State private var confirmRemove = false
    @State private var drag: CGFloat = 0
    /// A swipe up has passed the point where letting go plays it.
    @State private var armed = false
    /// Set once let go on a play swipe: the poster's flight into the island, taking over from the drag.
    @State private var sending = false
    @State private var sendPending = false
    @State private var sendX: CGFloat = 0
    @State private var sendY: CGFloat = 0
    /// This view's origin on screen, to place a request's flight to the shelf.
    @State private var origin: CGPoint = .zero
    @State private var viewport: CGRect = .zero
    /// The card's size and resting centre, as laid out.
    @State private var cardSize: CGSize = .zero
    @State private var restY: CGFloat = 0
    /// Set on a request's flight: the card takes on the queued tile's look as it shrinks into it.
    @State private var landing = false
    @State private var sendScale: CGFloat = 1
    @State private var sendOpacity: Double = 1

    /// This title's request as Home last polled it, for a live download bar.
    private var isCurrent: Bool { TitleCardPresenter.shared.presentationID == presentationID }
    private var live: MediaRequest? {
        TitleCardPresenter.shared.requests.first { $0.tmdbId == pick.id && $0.mediaType == pick.mediaType }
    }
    private var available: Bool { live?.stage == .available || (detail?.available ?? (pick.known == .available)) }
    private var canPlay: Bool { available && (detail?.canPlay ?? true) }
    private var isRequested: Bool {
        requested || live != nil || (detail?.alreadyRequested ?? (pick.known == .requested))
    }

    var body: some View {
        GeometryReader { geo in
            // Floats a little in from the screen's edges so its corners can be round all the way.
            let width = max(1, geo.size.width - 2 * Self.inset)
            let height = max(1, min(width * 1.5, geo.size.height - 16))
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
                Color.clear.contentShape(.rect)
                    .onTapGesture { if !sending { onClose() } }
                    .accessibilityHidden(true)
                card(shrink: reduceMotion ? 0 : sending ? 1 : shrink)
                    .frame(width: width, height: height)
                    .simultaneousGesture(
                        DragGesture(minimumDistance: 12, coordinateSpace: .global)
                            .onChanged { v in
                                guard !working, !sending, isCurrent,
                                      abs(v.translation.height) > abs(v.translation.width) else { return }
                                let dy = v.translation.height
                                drag = dy
                                if !reduceMotion { reveal = 1 - min(max(dy / height, 0), 1) }
                                armed = canPlay && dy < -100
                            }
                            .onEnded { v in
                                guard isCurrent else { return }
                                let dy = v.translation.height
                                let vertical = abs(dy) > abs(v.translation.width)
                                if !working, !sending, vertical, canPlay,
                                   dy < -100 || v.predictedEndTranslation.height < -240 {
                                    send(toward: island - rest, posterHeight: height)
                                } else if !working, !sending, vertical,
                                          dy > 120 || v.predictedEndTranslation.height > 320 {
                                    onClose()
                                } else {
                                    armed = false
                                    withAnimation(HubMotion.animation(reduceMotion: reduceMotion)) { drag = 0; reveal = 1 }
                                }
                            }
                    )
                    .padding(.bottom, Self.inset)
                    .scaleEffect(reduceMotion ? 1 : sending ? sendScale : 1 - (1 - Self.smallest) * shrink)
                    .offset(x: reduceMotion ? 0 : sending ? sendX : 0,
                            y: reduceMotion ? 0 : sending ? sendY : y)
                    .opacity(sendOpacity)
                    .allowsHitTesting(!sending && !sendPending)
                    .sensoryFeedback(.impact(weight: .medium), trigger: armed) { _, now in now }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .onChange(of: CGSize(width: width, height: height), initial: true) { _, size in
                cardSize = size
                restY = rest
            }
            .onChange(of: rest) { _, value in restY = value }
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: {
                origin = $0.origin
                viewport = $0
            }
        }
        .ignoresSafeArea(edges: .bottom)
        .environment(\.colorScheme, .dark)
        .accessibilityAddTraits(.isModal)
        .accessibilityAction(.escape) { if !sending { onClose() } }
        .onAppear { closeFocused = true }
        // SwiftUI cancels obsolete refreshes when the live state changes or the card closes.
        .task(id: live?.stage) { await load() }
        .task(id: pick.posterURL ?? detail?.posterURL) {
            let image = await PosterLoader.image(PosterLoader.fullSize(pick.posterURL ?? detail?.posterURL),
                                                 waitingAtMost: .seconds(20))
            guard !Task.isCancelled, isCurrent else { return }
            // Avoid a transaction that also animates text, controls and layout.
            sharp = image
        }
        .confirmationDialog(available ? "Delete \(pick.title)?" : "Cancel the request for \(pick.title)?",
                            isPresented: $confirmRemove, titleVisibility: .visible) {
            Button(available ? "Delete movie and files" : "Cancel request", role: .destructive) { Task { await remove() } }
        } message: {
            Text("This stops any download and removes it, and its files, from the library.")
        }
    }

    private func card(shrink: CGFloat) -> some View {
        // Keep controls reachable in short windows and with larger text.
        // On a play swipe the words, fade and close button dissolve, leaving just the poster.
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(pick.title).font(.title2.weight(.semibold)).lineLimit(3)
                Text(detail.map(meta) ?? "2026 · Movie · 120 min")
                    .font(.subheadline).foregroundStyle(.white.opacity(0.65))
                    .redacted(reason: detail == nil ? .placeholder : [])
                if let error, detail == nil {
                    ErrorBanner(message: error) { Task { await load() } }
                } else {
                    primary.padding(.top, 8)
                }
                // Only titles in the library or on their way have this row.
                if available || isRequested {
                    Button(available ? "Delete from library" : "Cancel request") { confirmRemove = true }
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.white.opacity(0.6))
                        .frame(maxWidth: .infinity, minHeight: HubLayout.minHitTarget)
                        .disabled(working)
                }
            }
            .foregroundStyle(.white)
            .opacity(1 - min(shrink * 2.2, 1))
            .padding(.horizontal, HubLayout.cardPadding)
            .padding(.top, 60)
            .padding(.bottom, HubLayout.bottomInset)
        }
        .defaultScrollAnchor(.bottom)
        .defaultScrollAnchor(.bottom, for: .alignment)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .background {
            // Keep the small poster underneath; bound artwork to the card's actual geometry.
            GeometryReader { geometry in
                ZStack {
                    if let poster {
                        Image(uiImage: poster).resizable().scaledToFill()
                    } else {
                        AsyncImage(url: (pick.posterURL ?? detail?.posterURL).flatMap(URL.init(string:))) { phase in
                            if let image = phase.image { image.resizable().scaledToFill() } else { Color.white.opacity(0.06) }
                        }
                    }
                    if let sharp {
                        Image(uiImage: sharp).resizable().scaledToFill()
                    }
                }
                .frame(width: geometry.size.width, height: geometry.size.height, alignment: .top)
                .clipped()
            }
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
                    .frame(width: HubLayout.minHitTarget, height: HubLayout.minHitTarget)
                    .background(.black.opacity(0.4), in: .circle)
            }
            .padding(12)
            .accessibilityLabel("Close \(pick.title)")
            .accessibilityFocused($closeFocused)
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
        .animation(HubMotion.animation(reduceMotion: reduceMotion), value: fill)
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
        guard isCurrent else { return false }
        presenter.requesting(pick)
        if reduceMotion {
            presenter.landed()
            return true
        }
        // A beat for the shelf to lay out (it may have only just appeared) and report its slot.
        try? await Task.sleep(for: .milliseconds(60))
        guard isCurrent else { return false }
        guard !Task.isCancelled, let slot = presenter.shelfSlot, cardSize.width > 0, slot.width > 0,
              viewport.contains(slot) else {
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
            guard isCurrent else { return }
            presenter.landed()
        }
        return true
    }

    /// Plays the title and carries on from the swipe in one motion: the poster shrinks to the
    /// island's size as it travels up into it, fading only at the very end. There's no toast
    /// unless it fails.
    private func send(toward island: CGFloat, posterHeight: CGFloat) {
        guard !working, !sending, !sendPending, isCurrent else { return }
        sendPending = true
        Task {
            defer { sendPending = false }
            let succeeded = await play(announce: false)
            guard isCurrent else { return }
            guard succeeded else {
                armed = false
                withAnimation(HubMotion.animation(reduceMotion: reduceMotion)) { drag = 0; reveal = 1 }
                return
            }
            guard !reduceMotion else {
                toast.show("Playing on the TV")
                onSent()
                return
            }
            // Only celebrate once the server has accepted playback.
            withAnimation(.easeIn(duration: 0.34)) {
                sending = true
                sendY = island
                sendScale = 37 / max(posterHeight, 1)
            } completion: {
                guard isCurrent else { return }
                onSent()
            }
            withAnimation(.easeIn(duration: 0.1).delay(0.26)) { sendOpacity = 0 }
        }
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
        guard !Task.isCancelled, isCurrent else { return }
        let id = UUID()
        detailLoadID = id
        await MediaDetailCache.restore()
        guard !Task.isCancelled, isCurrent, detailLoadID == id else { return }
        if detail == nil { detail = MediaDetailCache.get(pick) }
        let version = MediaDetailCache.revision(for: pick)
        do {
            let fresh: MediaDetail? = try await session.api.run("mediaDetail", [.string(pick.mediaType.rawValue), .int(pick.id)])
            guard !Task.isCancelled, isCurrent, detailLoadID == id else { return }
            guard MediaDetailCache.revision(for: pick) == version else {
                adoptCachedDetail()
                return
            }
            detail = fresh
            MediaDetailCache.set(fresh, for: pick)
            error = nil
        } catch {
            guard !Task.isCancelled, isCurrent, detailLoadID == id else { return }
            guard MediaDetailCache.revision(for: pick) == version else {
                adoptCachedDetail()
                return
            }
            self.error = error.localizedDescription
        }
    }

    private func adoptCachedDetail() {
        // A concurrent prefetch may have won. Use its value instead of leaving a placeholder;
        // nil means invalidated, so never restore the older network response in that case.
        if let cached = MediaDetailCache.get(pick) {
            detail = cached
            error = nil
        }
    }

    private func request() async {
        guard !working, isCurrent else { return }
        working = true
        defer { working = false }
        do {
            let _: Empty? = try await session.api.run("requestMedia", [.string(pick.mediaType.rawValue), .int(pick.id)])
            MediaDetailCache.set(nil, for: pick)
            // The server mutation still needs a refresh after dismissal, but must not
            // animate or replace feedback belonging to a subsequently opened card.
            guard isCurrent else { onChanged(); return }
            requested = true
            if !(await flyToShelf()) {
                if isCurrent { toast.show("Requested \(pick.title)") }
                onChanged()
            }
        } catch {
            if isCurrent { toast.error(error) }
        }
    }

    private func remove() async {
        guard !working, isCurrent else { return }
        working = true
        defer { working = false }
        do {
            let _: Empty? = try await session.api.run("removeMedia", [.string(pick.mediaType.rawValue), .int(pick.id)])
            MediaDetailCache.set(nil, for: pick)
            onChanged()
            if isCurrent { onClose() }
        } catch {
            if isCurrent { toast.error(error) }
        }
    }

    @discardableResult
    private func play(announce: Bool = true) async -> Bool {
        guard !working, isCurrent else { return false }
        working = true
        defer { working = false }
        do {
            let _: Empty? = try await session.api.run("playMedia", [.string(pick.mediaType.rawValue), .int(pick.id)])
            if announce, isCurrent { toast.show("Playing on the TV") }
            TVActivityController.shared.played()
            return true
        } catch {
            if isCurrent { toast.error(error) }
            return false
        }
    }
}
