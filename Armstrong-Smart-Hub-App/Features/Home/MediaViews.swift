import SwiftUI

/// Overseerr search with a 300ms debounce.
struct MediaSearchView: View {
    let onPick: (MediaPick) -> Void

    @Environment(AppSession.self) private var session
    @State private var query = ""
    @State private var results: [MediaResult]?
    @State private var error: String?
    @State private var searching = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search movies and shows", text: $query)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                if searching { ProgressView().controlSize(.small) }
                if !query.isEmpty {
                    Button("Clear", systemImage: "xmark.circle.fill") { query = ""; results = nil }
                        .labelStyle(.iconOnly).foregroundStyle(.secondary).buttonStyle(.plain)
                }
            }
            .padding(12)
            .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 12))

            if let error { Text(error).font(.footnote).foregroundStyle(.red) }

            if let results, !query.trimmingCharacters(in: .whitespaces).isEmpty {
                if results.isEmpty, !searching {
                    Text("Nothing found.").font(.subheadline).foregroundStyle(.secondary)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 12)], spacing: 16) {
                        ForEach(results) { r in
                            Button {
                                onPick(MediaPick(id: r.id, mediaType: r.mediaType, title: r.title, posterURL: r.posterURL))
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Poster(url: r.posterURL)
                                    Text(r.title).font(.footnote.weight(.medium)).lineLimit(2)
                                    Text([r.year, r.mediaType == .tv ? "Series" : "Movie"].compactMap { $0 }.joined(separator: " · "))
                                        .font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
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
}

struct RequestList: View {
    let requests: [MediaRequest]
    let onPick: (MediaPick) -> Void

    var body: some View {
        VStack(spacing: 10) {
            ForEach(requests) { r in
                Button {
                    if let tmdb = r.tmdbId { onPick(MediaPick(id: tmdb, mediaType: r.mediaType, title: r.title, posterURL: r.posterURL)) }
                } label: {
                    HStack(spacing: 12) {
                        Poster(url: r.posterURL, width: 44)
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
                    .padding(12)
                    .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 14))
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// A title's details, with Request or Play on TV.
struct MediaDetailSheet: View {
    let pick: MediaPick
    let onChanged: () -> Void

    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var detail: MediaDetail?
    @State private var error: String?
    @State private var working = false
    @State private var requested = false
    @State private var toast = Toast()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(alignment: .top, spacing: 16) {
                        Poster(url: detail?.posterURL ?? pick.posterURL, width: 120)
                        VStack(alignment: .leading, spacing: 6) {
                            Text(pick.title).font(.title2.bold())
                            if let d = detail {
                                Text(meta(d)).font(.subheadline).foregroundStyle(.secondary)
                                if !d.genres.isEmpty {
                                    Text(d.genres.prefix(3).joined(separator: ", ")).font(.footnote).foregroundStyle(.secondary)
                                }
                                if let ep = d.episodeLabel { Text(ep).font(.footnote) }
                            }
                        }
                    }

                    if let d = detail {
                        actions(d)
                        if d.available && !d.canPlay {
                            Text("The TV is off and can't be woken from here. Turn it on, then try again.")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                        if let overview = d.overview, !overview.isEmpty {
                            Text(overview).font(.body)
                        }
                    } else if let error {
                        ErrorBanner(message: error) { Task { await load() } }
                    } else {
                        ProgressView().frame(maxWidth: .infinity)
                    }
                }
                .padding(20)
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
            }
            .task { await load() }
            .toast(toast)
        }
        .presentationDetents([.medium, .large])
    }

    @ViewBuilder
    private func actions(_ d: MediaDetail) -> some View {
        Group {
            if d.available {
                Button {
                    Task { await play() }
                } label: {
                    Label(d.resumeSeconds != nil ? "Resume on TV" : "Play on TV", systemImage: "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!d.canPlay || working)
            } else if requested || d.alreadyRequested {
                Label("Requested", systemImage: "checkmark").frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(Color(.secondarySystemBackground), in: .capsule)
            } else {
                Button {
                    Task { await request() }
                } label: {
                    Label("Request", systemImage: "plus").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(working)
            }
        }
        .controlSize(.large)
        .overlay { if working { ProgressView() } }
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
