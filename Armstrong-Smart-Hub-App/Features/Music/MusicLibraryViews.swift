import SwiftUI

// The rest of Spotify, inside the app: the library on the Music page, a page per
// playlist, album or show, saved episodes, search, the device picker and a mini
// player on every page under the Walkman. Tapping a row plays it here (on the
// chosen Spotify device); nothing opens the Spotify app.

/// Green for "this is the one playing", like Spotify's own.
let spotifyGreen = Fit.adaptive(0x16893F, 0x1ED760)

// MARK: Artwork

struct SpotifyArt: View {
    var url: String?
    var kind: String
    var size: CGFloat

    var body: some View {
        AsyncImage(url: url.flatMap(URL.init(string:))) { phase in
            if let image = phase.image {
                image.resizable().scaledToFill()
            } else {
                placeholder
            }
        }
        .frame(width: size, height: size)
        .clipShape(shape)
        .accessibilityHidden(true)
    }

    private var shape: some Shape {
        RoundedRectangle(cornerRadius: kind == "artist" ? size / 2 : kind == "show" || kind == "episode" ? size * 0.16 : size * 0.08,
                         style: .continuous)
    }

    @ViewBuilder private var placeholder: some View {
        if kind == "liked" {
            LinearGradient(colors: [Color(red: 0.27, green: 0.15, blue: 0.85), Color(red: 0.55, green: 0.78, blue: 0.9)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
                .overlay { Image(systemName: "heart.fill").font(.system(size: size * 0.36)).foregroundStyle(.white) }
        } else {
            BrickLook.pill.overlay {
                Image(systemName: Self.symbol(kind)).font(.system(size: size * 0.32)).foregroundStyle(BrickLook.soft)
            }
        }
    }

    static func symbol(_ kind: String) -> String {
        switch kind {
        case "episode", "show": "mic"
        case "playlist": "music.note.list"
        case "album": "square.stack"
        case "artist": "person"
        default: "music.note"
        }
    }
}

// MARK: Library on the Music page

/// Liked songs and saved episodes up top, then shelves of playlists, shows and albums.
struct LibrarySection: View {
    var library: SpotifyLibrary

    var body: some View {
        FitSection(title: "Your library") {
            VStack(spacing: 0) {
                NavigationLink(value: MusicRoute.collection(kind: "liked", id: "liked", title: "Liked Songs")) {
                    shortcut(kind: "liked", title: "Liked Songs", detail: "\(library.liked.total) songs")
                }
                if !library.episodes.isEmpty {
                    BrickDivider()
                    NavigationLink(value: MusicRoute.episodes) {
                        shortcut(kind: "episode", title: "Your Episodes",
                                 detail: "\(library.episodes.count) saved", image: library.episodes.first?.image)
                    }
                }
            }
            .buttonStyle(.plain)
            if !library.playlists.isEmpty { Shelf(title: "Playlists", items: library.playlists) }
            if !library.shows.isEmpty { Shelf(title: "Podcasts", items: library.shows) }
            if !library.albums.isEmpty { Shelf(title: "Albums", items: library.albums) }
        }
    }

    private func shortcut(kind: String, title: String, detail: String, image: String? = nil) -> some View {
        HStack(spacing: 12) {
            SpotifyArt(url: image, kind: kind, size: 52)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body)
                Text(detail).font(.subheadline).foregroundStyle(BrickLook.soft)
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.right").font(.system(size: 14, weight: .medium)).foregroundStyle(BrickLook.soft)
        }
        .foregroundStyle(BrickLook.ink)
        .padding(.vertical, 10)
        .contentShape(.rect)
    }
}

/// A horizontal row of covers that open their pages.
private struct Shelf: View {
    var title: String
    var items: [SpotifyItem]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 14) {
                    ForEach(items) { item in
                        if let route = item.route {
                            NavigationLink(value: route) { CoverCard(item: item) }.buttonStyle(.plain)
                        }
                    }
                }
                .scrollTargetLayout()
            }
            .scrollIndicators(.hidden)
            .scrollTargetBehavior(.viewAligned)
        }
    }
}

private struct CoverCard: View {
    var item: SpotifyItem
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SpotifyArt(url: item.image, kind: item.kind, size: 124)
            Text(item.title).font(.subheadline).lineLimit(2).foregroundStyle(BrickLook.ink)
            Text(item.subtitle).font(.caption).lineLimit(1).foregroundStyle(BrickLook.soft)
        }
        .frame(width: 124, alignment: .leading)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
    }
}

// MARK: Rows

/// A song or episode: tap to play it here, from its list when it has one. Lists open their page.
struct ItemRow: View {
    var item: SpotifyItem
    /// What it plays from: the playlist, album or liked songs it's in.
    var contextUri: String?
    var showArt = true
    @Environment(AppSession.self) private var session
    @State private var store = MusicStore.shared

    var body: some View {
        if let route = item.route {
            NavigationLink(value: route) { content(chevron: true) }.buttonStyle(.plain)
        } else {
            Button {
                Task { await store.play(item, in: contextUri, api: session.api) }
            } label: { content(chevron: false) }
            .buttonStyle(.plain)
            .contextMenu {
                if item.isPlayable {
                    Button { Task { await store.play(item, in: contextUri, api: session.api) } } label: {
                        Label("Play", systemImage: "play.fill")
                    }
                    Button { Task { await store.queue(item, api: session.api) } } label: {
                        Label("Add to queue", systemImage: "text.badge.plus")
                    }
                }
            }
            .accessibilityHint(item.isPlayable ? "Plays it" : "Plays all of it")
        }
    }

    private var isCurrent: Bool { store.nowPlaying?.id == item.id }

    private func content(chevron: Bool) -> some View {
        HStack(spacing: 12) {
            if showArt { SpotifyArt(url: item.image, kind: item.kind, size: 48) }
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).font(.body).lineLimit(2)
                    .foregroundStyle(isCurrent ? spotifyGreen : BrickLook.ink)
                HStack(spacing: 4) {
                    if item.explicit { Image(systemName: "e.square.fill").font(.caption2) }
                    Text(detail).lineLimit(1)
                }
                .font(.subheadline).foregroundStyle(BrickLook.soft)
                if item.kind == "episode", let progress = episodeProgress {
                    ProgressView(value: progress).tint(spotifyGreen).frame(maxWidth: 120)
                }
            }
            Spacer(minLength: 8)
            if store.starting == item.uri {
                ProgressView()
            } else if isCurrent, store.nowPlaying?.isPlaying == true {
                Image(systemName: "waveform").foregroundStyle(spotifyGreen)
                    .symbolEffect(.variableColor.iterative, options: .repeating)
                    .accessibilityLabel("Playing")
            } else if chevron {
                Image(systemName: "chevron.right").font(.system(size: 14, weight: .medium)).foregroundStyle(BrickLook.soft)
            }
        }
        .padding(.vertical, 8)
        .contentShape(.rect)
    }

    private var detail: String {
        switch item.kind {
        case "episode":
            var parts: [String] = []
            if let date = item.releaseDate { parts.append(date.formatted(.dateTime.month(.abbreviated).day())) }
            if let ms = item.durationMs { parts.append(Self.minutes(ms)) }
            if item.played { parts.append("Played") }
            return parts.isEmpty ? item.subtitle : parts.joined(separator: " · ")
        case "track":
            return item.durationMs.map { "\(item.subtitle) · \(Self.clock($0))" } ?? item.subtitle
        default:
            return item.subtitle
        }
    }

    private var episodeProgress: Double? {
        guard let resume = item.resumeMs, let total = item.durationMs, total > 0, resume > 0, !item.played else { return nil }
        return min(1, Double(resume) / Double(total))
    }

    static func clock(_ ms: Int) -> String { String(format: "%d:%02d", ms / 60000, ms / 1000 % 60) }
    static func minutes(_ ms: Int) -> String {
        let m = ms / 60000
        return m >= 60 ? "\(m / 60) hr \(m % 60) min" : "\(m) min"
    }
}

// MARK: A playlist, album, show or the liked songs

struct CollectionPage: View {
    var kind: String
    var id: String
    var title: String
    @Environment(AppSession.self) private var session
    @State private var store = MusicStore.shared
    @State private var page: SpotifyCollection?
    @State private var error: String?
    @State private var loadingMore = false

    var body: some View {
        BrickPage(title: title) {
            if let page {
                header(page)
                if let note = page.note {
                    Text(note).font(.subheadline).foregroundStyle(BrickLook.soft).multilineTextAlignment(.center)
                }
                if !page.items.isEmpty {
                    BrickCard(padding: 16) {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(page.items.enumerated()), id: \.offset) { index, item in
                                if index > 0 { BrickDivider() }
                                ItemRow(item: item, contextUri: page.contextUri, showArt: kind != "album")
                                    .onAppear { if index == page.items.count - 5 { Task { await more() } } }
                            }
                            if loadingMore { ProgressView().padding() }
                        }
                    }
                }
            } else if let error {
                MessageView(title: "Couldn't open it", systemImage: "exclamationmark.triangle", message: error,
                            actionTitle: "Try again") { Task { await load() } }
            } else {
                ProgressView().frame(maxWidth: .infinity).padding(.top, 80)
            }
        }
        .safeAreaInset(edge: .bottom) { MusicMiniBar() }
        .task { await load() }
        .refreshable { await load() }
        .toast(store.toast)
    }

    private func header(_ page: SpotifyCollection) -> some View {
        VStack(spacing: 14) {
            SpotifyArt(url: page.header.image, kind: page.header.kind, size: 200)
                .shadow(color: .black.opacity(0.18), radius: 14, y: 8)
            VStack(spacing: 4) {
                Text(page.header.title).font(.title2.weight(.regular)).multilineTextAlignment(.center)
                Text(page.header.subtitle).font(.subheadline).foregroundStyle(BrickLook.soft).multilineTextAlignment(.center)
                if page.total > 0 {
                    BrickCaps(text: kind == "show" ? "\(page.total) episodes" : "\(page.total) items")
                        .foregroundStyle(BrickLook.soft).padding(.top, 4)
                }
            }
            if let context = page.contextUri {
                HStack(spacing: 12) {
                    Button { Task { await store.playAll(context, shuffle: false, api: session.api) } } label: {
                        Label("Play", systemImage: "play.fill").frame(maxWidth: .infinity, minHeight: HubLayout.minHitTarget)
                    }
                    .buttonStyle(.borderedProminent).tint(spotifyGreen)
                    Button { Task { await store.playAll(context, shuffle: true, api: session.api) } } label: {
                        Label("Shuffle", systemImage: "shuffle").frame(maxWidth: .infinity, minHeight: HubLayout.minHitTarget)
                    }
                    .buttonStyle(.bordered)
                }
                .disabled(store.starting != nil)
            } else if let first = page.items.first {
                Button { Task { await store.play(first, api: session.api) } } label: {
                    Label("Play latest", systemImage: "play.fill").frame(maxWidth: .infinity, minHeight: HubLayout.minHitTarget)
                }
                .buttonStyle(.borderedProminent).tint(spotifyGreen)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func path(offset: Int) -> String {
        var c = URLComponents()
        c.path = "/api/mobile/spotify/collection"
        c.queryItems = [.init(name: "kind", value: kind), .init(name: "id", value: id), .init(name: "offset", value: String(offset))]
        return c.string ?? c.path
    }

    private func load() async {
        do {
            page = try await session.api.get(path(offset: 0))
            error = nil
        } catch is CancellationError {
        } catch {
            if page == nil { self.error = error.localizedDescription }
        }
    }

    private func more() async {
        guard let current = page, let next = current.next, !loadingMore else { return }
        loadingMore = true
        defer { loadingMore = false }
        if let more: SpotifyCollection = try? await session.api.get(path(offset: next)) {
            page?.items += more.items
            page?.next = more.next
        }
    }
}

// MARK: Saved episodes

struct EpisodesPage: View {
    @State private var store = MusicStore.shared

    var body: some View {
        BrickPage(title: "Your Episodes") {
            let episodes = store.library?.episodes ?? []
            if episodes.isEmpty {
                MessageView(title: "No saved episodes", systemImage: "mic",
                            message: "Episodes you save in Spotify show up here.")
            } else {
                BrickCard(padding: 16) {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(episodes.enumerated()), id: \.element.id) { index, item in
                            if index > 0 { BrickDivider() }
                            ItemRow(item: item)
                        }
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom) { MusicMiniBar() }
        .toast(store.toast)
    }
}

// MARK: Search

struct MusicSearchPage: View {
    @Environment(AppSession.self) private var session
    @State private var store = MusicStore.shared
    @State private var query = ""
    @State private var results: SpotifySearchResults?
    @State private var searching = false
    @State private var error: String?

    var body: some View {
        BrickPage(title: "Search") {
            if let results, !query.isEmpty {
                if results.isEmpty {
                    MessageView(title: "Nothing found", systemImage: "magnifyingglass", message: "Try other words.")
                } else {
                    group("Songs", results.tracks)
                    group("Episodes", results.episodes)
                    group("Artists", results.artists)
                    group("Albums", results.albums)
                    group("Playlists", results.playlists)
                    group("Podcasts", results.shows)
                }
            } else if let error {
                ErrorBanner(message: error)
            } else if searching {
                ProgressView().frame(maxWidth: .infinity).padding(.top, 60)
            } else {
                Text("Songs, artists, albums, playlists, podcasts and episodes.")
                    .font(.subheadline).foregroundStyle(BrickLook.soft)
                    .multilineTextAlignment(.center).padding(.top, 40)
            }
        }
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "What do you want to play?")
        .task(id: query) {
            let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !q.isEmpty else { results = nil; error = nil; return }
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            searching = true
            defer { searching = false }
            var c = URLComponents()
            c.path = "/api/mobile/spotify/search"
            c.queryItems = [.init(name: "q", value: q)]
            do {
                let r: SpotifySearchResults = try await session.api.get(c.string ?? "")
                guard !Task.isCancelled, q == query.trimmingCharacters(in: .whitespacesAndNewlines) else { return }
                results = r
                error = nil
            } catch is CancellationError {
            } catch {
                self.error = error.localizedDescription
            }
        }
        .safeAreaInset(edge: .bottom) { MusicMiniBar() }
        .toast(store.toast)
    }

    @ViewBuilder
    private func group(_ title: String, _ items: [SpotifyItem]) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text(title).font(.headline)
                BrickCard(padding: 16) {
                    VStack(spacing: 0) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                            if index > 0 { BrickDivider() }
                            if item.kind == "artist" {
                                // Artist pages are gone for development apps; tapping plays the artist.
                                ArtistRow(item: item)
                            } else {
                                ItemRow(item: item)
                            }
                        }
                    }
                }
            }
        }
    }
}

private struct ArtistRow: View {
    var item: SpotifyItem
    @Environment(AppSession.self) private var session
    @State private var store = MusicStore.shared

    var body: some View {
        Button { Task { await store.play(item, api: session.api) } } label: {
            HStack(spacing: 12) {
                SpotifyArt(url: item.image, kind: "artist", size: 48)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title).font(.body)
                    Text("Artist").font(.subheadline).foregroundStyle(BrickLook.soft)
                }
                Spacer(minLength: 8)
                if store.starting == item.uri { ProgressView() } else {
                    Image(systemName: "play.circle").font(.title2).foregroundStyle(spotifyGreen)
                }
            }
            .foregroundStyle(BrickLook.ink)
            .padding(.vertical, 8)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityHint("Plays the artist")
    }
}

// MARK: Mini player

/// What's playing, on every page under the Music tab: play/pause and next, and the device.
struct MusicMiniBar: View {
    @Environment(AppSession.self) private var session
    @State private var store = MusicStore.shared
    @State private var picking = false

    var body: some View {
        if let now = store.nowPlaying {
            HStack(spacing: 12) {
                SpotifyArt(url: now.image, kind: now.kind, size: 42)
                VStack(alignment: .leading, spacing: 1) {
                    Text(now.title).font(.subheadline.weight(.medium)).lineLimit(1)
                    Button { picking = true } label: {
                        HStack(spacing: 4) {
                            Image(systemName: SpotifyDevice.symbol(for: now.deviceType)).font(.caption2)
                            Text(now.device ?? now.subtitle).lineLimit(1)
                        }
                        .font(.caption).foregroundStyle(spotifyGreen)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Playing on \(now.device ?? "a device"). Change device")
                }
                Spacer(minLength: 8)
                Button { Task { await store.press(.stop, api: session.api) } } label: {
                    Image(systemName: now.isPlaying ? "pause.fill" : "play.fill").font(.title3)
                        .frame(width: HubLayout.minHitTarget, height: HubLayout.minHitTarget).contentShape(.rect)
                }
                .accessibilityLabel(now.isPlaying ? "Pause" : "Play")
                Button { Task { await store.press(.ff, api: session.api) } } label: {
                    Image(systemName: "forward.fill").font(.title3)
                        .frame(width: HubLayout.minHitTarget, height: HubLayout.minHitTarget).contentShape(.rect)
                }
                .accessibilityLabel("Next")
            }
            .buttonStyle(.plain)
            .foregroundStyle(BrickLook.ink)
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(HubDesign.raised, in: .rect(cornerRadius: HubLayout.controlRadius, style: .continuous))
            .overlay(alignment: .bottom) {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    GeometryReader { geo in
                        Capsule().fill(spotifyGreen)
                            .frame(width: geo.size.width * now.progress(at: context.date), height: 2)
                    }
                    .frame(height: 2)
                }
                .padding(.horizontal, 12)
            }
            .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
            .padding(.horizontal, HubLayout.gutter)
            .padding(.bottom, 6)
            .sheet(isPresented: $picking) { DevicePicker() }
        }
    }
}

// MARK: Devices

/// Where Spotify plays: every device it knows, the active one's volume, and a tap to move there.
struct DevicePicker: View {
    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var store = MusicStore.shared
    @State private var volume: Double = 50
    @State private var dragging = false

    var body: some View {
        NavigationStack {
            List {
                if let active = store.devices.first(where: \.isActive) ?? currentDevice {
                    Section("Playing on") {
                        Label(active.name, systemImage: active.symbol).foregroundStyle(spotifyGreen)
                        if active.volume != nil || store.nowPlaying?.volume != nil {
                            HStack(spacing: 12) {
                                Image(systemName: "speaker.fill").foregroundStyle(.secondary)
                                Slider(value: $volume, in: 0...100) { editing in
                                    dragging = editing
                                    if !editing { Task { await store.setVolume(Int(volume), api: session.api) } }
                                }
                                .tint(spotifyGreen)
                                .accessibilityLabel("Volume")
                                Image(systemName: "speaker.wave.3.fill").foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                Section {
                    // Spotify on this phone drops off the list while it sleeps; App Remote wakes it.
                    if SpotifyRemote.shared.isConfigured, !store.devices.contains(where: { $0.type.lowercased() == "smartphone" }) {
                        Button {
                            Task {
                                await store.wakeThisPhone(api: session.api)
                                dismiss()
                            }
                        } label: {
                            HStack {
                                Label("This iPhone", systemImage: "iphone")
                                Spacer()
                                if SpotifyRemote.shared.waking { ProgressView() } else {
                                    Text("Wake Spotify").font(.subheadline).foregroundStyle(.secondary)
                                }
                            }
                        }
                        .disabled(SpotifyRemote.shared.waking)
                    }
                    ForEach(store.devices.filter { !$0.isActive }) { device in
                        Button {
                            Task {
                                await store.transfer(to: device, api: session.api)
                                dismiss()
                            }
                        } label: {
                            HStack {
                                Label(device.name, systemImage: device.symbol)
                                Spacer()
                                if store.starting == device.id { ProgressView() }
                            }
                        }
                        .disabled(device.restricted || store.starting != nil)
                    }
                } header: {
                    Text("Devices")
                } footer: {
                    Text("A device shows up here while Spotify is open on it: this phone, a speaker, your computer or a TV. The app sends what to play; the sound comes from that device.")
                }
            }
            .hubListStyle()
            .overlay { if store.devices.isEmpty && store.loadingDevices { ProgressView() } }
            .navigationTitle("Play on")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .refreshable { await store.loadDevices(api: session.api) }
            .task { await store.loadDevices(api: session.api) }
            .onChange(of: store.devices.first(where: \.isActive)?.volume ?? store.nowPlaying?.volume, initial: true) { _, v in
                if !dragging, let v { volume = Double(v) }
            }
        }
        .presentationDetents([.medium, .large])
        .toast(store.toast)
    }

    /// The device from now playing, until the list loads.
    private var currentDevice: SpotifyDevice? {
        guard let now = store.nowPlaying, let id = now.deviceId, let name = now.device else { return nil }
        return SpotifyDevice(id: id, name: name, type: now.deviceType ?? "", isActive: true, volume: now.volume, restricted: false)
    }
}
