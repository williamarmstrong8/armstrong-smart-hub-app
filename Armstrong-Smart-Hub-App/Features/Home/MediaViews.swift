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
                            Button("Clear", systemImage: "xmark.circle.fill") { query = ""; results = nil }
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
                    if typing {
                        if let results {
                            if results.isEmpty, !searching {
                                Text("Nothing found.").font(.subheadline).foregroundStyle(BrickLook.soft)
                            } else {
                                grid(results)
                            }
                        }
                    } else {
                        grid(recent)
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
        .task(id: query) {
            let q = query.trimmingCharacters(in: .whitespaces)
            guard !q.isEmpty else { return }
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            searching = true
            defer { searching = false }
            do {
                results = try await session.api.run("searchMedia", [.string(q)]) ?? []
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
                    onPick(MediaPick(id: r.id, mediaType: r.mediaType, title: r.title, posterURL: r.posterURL))
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Poster(url: r.posterURL)
                        Text(r.title).font(.footnote.weight(.medium)).lineLimit(2)
                        Text([r.year, r.mediaType == .tv ? "Series" : "Movie"].compactMap { $0 }.joined(separator: " · "))
                            .font(.caption2).foregroundStyle(BrickLook.soft)
                    }
                }
                .buttonStyle(.plain)
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
                    .disabled(r.tmdbId == nil)
                }
            }
            .padding(.horizontal, 16)
            .animation(.smooth, value: requests.map(\.id))
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

/// A title's card, drawn over Home rather than as a sheet so the page behind can blur in step with
/// it: as tall as the poster, which fills it from the top and fades into black under the words.
/// Drag it down or tap above it to close.
struct MediaDetailCard: View {
    let pick: MediaPick
    let toast: Toast
    /// 1 while the card is fully up, falling toward 0 as it's dragged down; Home blurs by it.
    @Binding var reveal: CGFloat
    let onChanged: () -> Void
    let onClose: () -> Void

    @Environment(AppSession.self) private var session
    @State private var detail: MediaDetail?
    @State private var error: String?
    @State private var working = false
    @State private var requested = false
    @State private var confirmRemove = false
    @State private var drag: CGFloat = 0

    private var available: Bool { detail?.available ?? (pick.known == .available) }
    private var isRequested: Bool { requested || (detail?.alreadyRequested ?? (pick.known == .requested)) }

    var body: some View {
        GeometryReader { geo in
            let height = min(geo.size.width * 1.5, geo.size.height - 60)
            ZStack(alignment: .bottom) {
                Color.clear.contentShape(.rect).onTapGesture(perform: onClose)
                card
                    .frame(width: geo.size.width, height: height)
                    .offset(y: drag)
                    .gesture(
                        DragGesture(minimumDistance: 8)
                            .onChanged { v in
                                drag = v.translation.height > 0 ? v.translation.height : v.translation.height / 6
                                reveal = 1 - min(max(drag / height, 0), 1)
                            }
                            .onEnded { v in
                                if v.translation.height > 120 || v.predictedEndTranslation.height > 320 {
                                    onClose()
                                } else {
                                    withAnimation(.smooth(duration: 0.3)) { drag = 0; reveal = 1 }
                                }
                            }
                    )
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        }
        .ignoresSafeArea(edges: .bottom)
        .preferredColorScheme(.dark)
        .task { await load() }
        .confirmationDialog(available ? "Delete \(pick.title)?" : "Cancel the request for \(pick.title)?",
                            isPresented: $confirmRemove, titleVisibility: .visible) {
            Button(available ? "Delete movie and files" : "Cancel request", role: .destructive) { Task { await remove() } }
        } message: {
            Text("This stops any download and removes it, and its files, from the library.")
        }
    }

    private var card: some View {
        // Every row keeps its place while the details load, so nothing moves when they arrive.
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
            Button(available ? "Delete from library" : "Cancel request") { confirmRemove = true }
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.white.opacity(0.6))
                .frame(maxWidth: .infinity)
                .opacity(available || isRequested ? 1 : 0)
                .disabled(working || !(available || isRequested))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 24)
        .padding(.bottom, 44)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .background {
            AsyncImage(url: (detail?.posterURL ?? pick.posterURL).flatMap(URL.init(string:))) { phase in
                if let image = phase.image { image.resizable().scaledToFill() } else { Color.white.opacity(0.06) }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .clipped()
            .overlay {
                LinearGradient(stops: [
                    .init(color: .clear, location: 0.3),
                    .init(color: .black.opacity(0.55), location: 0.6),
                    .init(color: .black.opacity(0.92), location: 0.85),
                    .init(color: .black, location: 1),
                ], startPoint: .top, endPoint: .bottom)
            }
        }
        .background(.black)
        .clipShape(UnevenRoundedRectangle(topLeadingRadius: 36, topTrailingRadius: 36))
        .overlay(alignment: .topTrailing) {
            Button(action: onClose) {
                Image(systemName: "xmark").font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(.black.opacity(0.4), in: .circle)
            }
            .padding(16)
            .accessibilityLabel("Close")
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
            detail = try await session.api.run("mediaDetail", [.string(pick.mediaType.rawValue), .int(pick.id)])
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
            toast.show("Requested \(pick.title)")
            onChanged()
        } catch {
            toast.error(error)
        }
    }

    private func remove() async {
        working = true
        defer { working = false }
        do {
            let _: Empty? = try await session.api.run("removeMedia", [.string(pick.mediaType.rawValue), .int(pick.id)])
            onChanged()
            onClose()
        } catch {
            toast.error(error)
        }
    }

    private func play() async {
        working = true
        defer { working = false }
        do {
            let _: Empty? = try await session.api.run("playMedia", [.string(pick.mediaType.rawValue), .int(pick.id)])
            toast.show("Playing on the TV")
        } catch {
            toast.error(error)
        }
    }
}
