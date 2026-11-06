import AuthenticationServices
import Foundation
import Observation
import UIKit

/// The Music page's data from the hub, which holds the Spotify link and talks to
/// the Web API. The phone only ever sees what's playing, never a Spotify token.
@MainActor
@Observable
final class MusicStore {
    static let shared = MusicStore()

    private(set) var summary: MusicSummary?
    private(set) var error: String?
    private(set) var connecting = false
    /// The key being held down by a request in flight; the Walkman shows it pressed.
    private(set) var busyKey: WalkmanKey?
    /// Bumped on every finished key press, for haptics and the LCD flash.
    private(set) var pressedAt: Date?
    private(set) var lastPressed: WalkmanKey?
    let toast = Toast()

    var nowPlaying: NowPlaying? { summary?.nowPlaying }
    var loaded: Bool { summary != nil }

    private static let cacheURL = URL.applicationSupportDirectory.appending(path: "Music/summary.json")

    init() {
        if !Demo.isOn, let data = try? Data(contentsOf: Self.cacheURL),
           let cached = try? APIClient.decoder.decode(MusicSummary.self, from: data) {
            summary = cached
        }
    }

    func load(api: APIClient) async {
        do {
            let data = try await api.data(api.request("/api/mobile/spotify"))
            summary = try APIClient.decoder.decode(MusicSummary.self, from: data)
            error = nil
            guard !Demo.isOn else { return }
            try? FileManager.default.createDirectory(at: Self.cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: Self.cacheURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch is CancellationError {
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Just what's playing; cheap enough to poll while the page is open.
    func poll(api: APIClient) async {
        guard summary?.isConnected == true, busyKey == nil else { return }
        do {
            let r: NowPlayingResponse = try await api.get("/api/mobile/spotify/now")
            let changed = r.nowPlaying?.id != summary?.nowPlaying?.id
            summary?.nowPlaying = r.nowPlaying
            // A new song means the last one joined the recent plays.
            if changed { await load(api: api) }
        } catch {}
    }

    /// Presses a key: the Walkman holds it down until Spotify answers.
    func press(_ key: WalkmanKey, api: APIClient) async {
        guard busyKey == nil else { return }
        guard summary?.isConnected == true else {
            toast.show("Connect Spotify first.", error: true)
            return
        }
        busyKey = key
        defer {
            busyKey = nil
            lastPressed = key
            pressedAt = .now
        }
        // Answer right away on the LCD; the hub's reading replaces it.
        if key == .stop, var now = summary?.nowPlaying {
            now.progressMs = Int(now.elapsed() * 1000)
            now.isPlaying.toggle()
            now.at = NowPlaying.iso.string(from: .now)
            summary?.nowPlaying = now
        }
        do {
            let r: NowPlayingResponse = try await api.post("/api/mobile/spotify/control", body: ["action": key.action])
            summary?.nowPlaying = r.nowPlaying
            if key == .play { toast.show("Shuffling") }
        } catch {
            toast.error(error)
            await poll(api: api)
        }
    }

    // MARK: Linking

    /// Opens Spotify's sign-in in a browser sheet. The hub's callback lands on armstronghub://spotify.
    func connect(api: APIClient) async {
        connecting = true
        defer { connecting = false }
        do {
            let r: SpotifyConnectResponse = try await api.post("/api/mobile/spotify/connect")
            guard let url = URL(string: r.url) else { return }
            let callback = try await SpotifySignIn().start(url)
            let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
            if let failure = items.first(where: { $0.name == "error" })?.value {
                if failure != "access_denied" && failure != "cancelled" { toast.show(failure, error: true) }
                return
            }
            await load(api: api)
            toast.show("Spotify connected")
        } catch let error as ASWebAuthenticationSessionError where error.code == .canceledLogin {
        } catch {
            toast.error(error)
        }
    }

    func disconnect(api: APIClient) async {
        do {
            _ = try await api.send(api.request("/api/mobile/spotify/connect", method: "DELETE")) as Empty
            await load(api: api)
        } catch {
            toast.error(error)
        }
    }

    #if DEBUG
    func demoSeed() {
        let now = NowPlaying.iso.string(from: .now)
        summary = MusicSummary(
            status: "connected", account: "Will",
            nowPlaying: NowPlaying(kind: "track", id: "demo", title: "Dreams", subtitle: "Fleetwood Mac", detail: "Rumours",
                                   image: nil, url: nil, durationMs: 257_000, progressMs: 92_000, isPlaying: true,
                                   shuffle: true, device: "iPhone", at: now),
            recent: [
                RecentPlay(kind: "track", id: "a", title: "Everywhere", subtitle: "Fleetwood Mac", image: nil, url: nil, playedAt: NowPlaying.iso.string(from: .now.addingTimeInterval(-600)), minutes: 4),
                RecentPlay(kind: "episode", id: "b", title: "The future of batteries", subtitle: "Acquired", image: nil, url: nil, playedAt: NowPlaying.iso.string(from: .now.addingTimeInterval(-7200)), minutes: 38),
                RecentPlay(kind: "track", id: "c", title: "Heroes", subtitle: "David Bowie", image: nil, url: nil, playedAt: NowPlaying.iso.string(from: .now.addingTimeInterval(-9000)), minutes: 6),
            ],
            mix: ListeningMix(
                days: (0..<7).map { i in
                    let d = Calendar.current.date(byAdding: .day, value: i - 6, to: .now)!
                    let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
                    return .init(day: f.string(from: d), musicMinutes: [42, 65, 30, 88, 54, 120, 70][i], podcastMinutes: [35, 20, 60, 15, 40, 0, 25][i])
                },
                musicMinutes: 469, podcastMinutes: 195, podcastShare: 0.29, mood: "Mostly music",
                line: "Music first, with 29% talk mixed in.", topArtist: "Fleetwood Mac", topShow: "Acquired"))
    }
    #endif
}

/// One run of ASWebAuthenticationSession, presented over the key window.
@MainActor
private final class SpotifySignIn: NSObject, ASWebAuthenticationPresentationContextProviding {
    private var session: ASWebAuthenticationSession?

    func start(_ url: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(url: url, callback: .customScheme("armstronghub")) { callback, error in
                if let callback { continuation.resume(returning: callback) }
                else { continuation.resume(throwing: error ?? ASWebAuthenticationSessionError(.canceledLogin)) }
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false
            self.session = session
            session.start()
        }
    }

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .flatMap(\.windows)
                .first(where: \.isKeyWindow) ?? ASPresentationAnchor()
        }
    }
}
