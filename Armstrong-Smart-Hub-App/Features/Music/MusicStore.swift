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

    var nowPlaying: SpotifyTrack? { summary?.nowPlaying }
    var loaded: Bool { summary != nil }

    private static let cacheURL = URL.applicationSupportDirectory.appending(path: "Music/summary.json")

    init() {
        if !Demo.isOn, let data = try? Data(contentsOf: Self.cacheURL),
           let cached = try? APIClient.decoder.decode(MusicSummary.self, from: data) {
            summary = cached
            if let id = cached.clientId { SpotifyRemote.shared.configure(clientID: id) }
        }
    }

    func load(api: APIClient) async {
        do {
            let data = try await api.data(api.request("/api/mobile/spotify"))
            summary = try APIClient.decoder.decode(MusicSummary.self, from: data)
            if let id = summary?.clientId { SpotifyRemote.shared.configure(clientID: id) }
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
    func poll(api: APIClient, force: Bool = false) async {
        guard summary?.isConnected == true, force || (busyKey == nil && starting == nil) else { return }
        do {
            let r: SpotifyNowResponse = try await api.get("/api/mobile/spotify/now")
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
            now.at = SpotifyTrack.iso.string(from: .now)
            summary?.nowPlaying = now
        }
        do {
            let r: SpotifyNowResponse = try await api.post("/api/mobile/spotify/control", body: ["action": key.action])
            summary?.nowPlaying = r.nowPlaying
            if key == .play { toast.show("Shuffling") }
        } catch where Self.isNoDevice(error) {
            // Spotify on this phone is asleep: wake it where it left off, then press again.
            guard await wakePhone(playing: "") else { return }
            if key != .stop, let r: SpotifyNowResponse = try? await api.post("/api/mobile/spotify/control", body: ["action": key.action]) {
                summary?.nowPlaying = r.nowPlaying
            } else {
                await poll(api: api)
            }
        } catch {
            toast.error(error)
            await poll(api: api)
        }
    }

    // MARK: Playing anything, anywhere

    /// The library: playlists, liked songs, albums, shows and saved episodes.
    private(set) var library: SpotifyLibrary?
    /// Everywhere Spotify can play right now.
    private(set) var devices: [SpotifyDevice] = []
    private(set) var loadingDevices = false
    /// The row being started, so it can show a spinner until Spotify answers.
    private(set) var starting: String?

    func loadLibrary(api: APIClient) async {
        guard summary?.isConnected == true else { return }
        do { library = try await api.get("/api/mobile/spotify/library") }
        catch is CancellationError {}
        catch { if library == nil { toast.error(error) } }
    }

    func loadDevices(api: APIClient, quiet: Bool = false) async {
        loadingDevices = true
        defer { loadingDevices = false }
        do {
            let r: SpotifyDevicesResponse = try await api.get("/api/mobile/spotify/devices")
            devices = r.devices
        } catch is CancellationError {
        } catch { if !quiet { toast.error(error) } }
    }

    private struct PlayBody: Encodable {
        var contextUri: String?
        var uri: String?
        var positionMs: Int?
        var deviceId: String?
    }

    /// Plays a row: a song from its list (so the list carries on after it), an episode
    /// from where it was left, or a whole playlist, album, artist or show.
    func play(_ item: SpotifyItem, in contextUri: String? = nil, api: APIClient) async {
        let body: PlayBody = item.isPlayable
            ? PlayBody(contextUri: contextUri, uri: item.uri,
                       positionMs: item.kind == "episode" && !item.played ? item.resumeMs : nil)
            : PlayBody(contextUri: item.uri)
        await start(body, id: item.uri, api: api)
    }

    /// Plays a list from the top, shuffled or not.
    func playAll(_ contextUri: String, shuffle: Bool, api: APIClient) async {
        if summary?.nowPlaying?.shuffle != shuffle {
            _ = try? await api.post("/api/mobile/spotify/adjust", body: ["action": JSONValue.string("shuffle"), "state": .bool(shuffle)]) as SpotifyNowResponse
        }
        await start(PlayBody(contextUri: contextUri), id: contextUri, api: api)
    }

    /// Plays go to this iPhone unless another device was picked in the device list.
    private(set) var preferPhone: Bool = UserDefaults.standard.object(forKey: "spotify.preferPhone") as? Bool ?? true {
        didSet { UserDefaults.standard.set(preferPhone, forKey: "spotify.preferPhone") }
    }

    private func start(_ body: PlayBody, id: String, api: APIClient) async {
        guard starting == nil else { return }
        starting = id
        defer { starting = nil }
        var body = body
        if body.deviceId == nil, preferPhone {
            if let phone = await phoneDeviceID(api: api) {
                body.deviceId = phone
            } else if await wakePhone(playing: body.contextUri ?? body.uri ?? "", quiet: true) {
                // Spotify on the phone is up and playing the list (or the song) from the top;
                // the hub then starts it at the row tapped, on the phone.
                try? await Task.sleep(for: .milliseconds(800))
                body.deviceId = await phoneDeviceID(api: api)
                if body.deviceId == nil || (body.contextUri == nil && body.positionMs == nil) {
                    await poll(api: api, force: true)
                    return
                }
            }
            // Otherwise it plays wherever Spotify is active, and says so below if nowhere is.
        }
        do {
            let r: SpotifyNowResponse = try await api.post("/api/mobile/spotify/play", body: body)
            if let now = r.nowPlaying { summary?.nowPlaying = now }
            // Wanted the phone but it wouldn't wake: say where it went instead, and why.
            if preferPhone, body.deviceId == nil, let why = SpotifyRemote.shared.lastError {
                toast.show("Playing on \(r.nowPlaying?.device ?? "another device"). This phone: \(why)", error: true)
            }
        } catch where Self.isNoDevice(error) {
            toast.show(SpotifyRemote.shared.lastError.map { "Couldn't start Spotify on this phone. \($0)" }
                       ?? "Open Spotify on a device, or pick one from the speaker button.", error: true)
        } catch {
            toast.error(error)
        }
    }

    /// This phone's entry in Spotify's device list, while Spotify on it is awake.
    private func phoneDeviceID(api: APIClient) async -> String? {
        await loadDevices(api: api, quiet: true)
        let phones = devices.filter { $0.type.lowercased() == "smartphone" && !$0.restricted }
        return (phones.first(where: \.isActive) ?? phones.first)?.id
    }

    /// Starts Spotify on this phone where it left off, so it joins the device list.
    func wakeThisPhone(api: APIClient) async {
        preferPhone = true
        guard await wakePhone(playing: "") else { return }
        try? await Task.sleep(for: .milliseconds(600))
        await poll(api: api, force: true)
        await loadDevices(api: api)
    }

    /// The hub's answer when Spotify has no awake device to play on.
    static func isNoDevice(_ error: any Error) -> Bool {
        let message = error.localizedDescription
        return message.contains("No Spotify device") || message.contains("Nothing's playing on a device")
    }

    /// Opens Spotify on this phone for a moment (it comes straight back) so it can play.
    private func wakePhone(playing uri: String, quiet: Bool = false) async -> Bool {
        let remote = SpotifyRemote.shared
        guard remote.isConfigured else {
            if !quiet { toast.show("Open Spotify on a device first.", error: true) }
            return false
        }
        if await remote.wake(playing: uri) { return true }
        if !quiet { toast.show("Couldn't start Spotify on this phone. \(remote.lastError ?? "Spotify didn't come back.")", error: true) }
        return false
    }

    /// Moves playback to a device (and keeps it playing).
    func transfer(to device: SpotifyDevice, api: APIClient) async {
        preferPhone = device.type.lowercased() == "smartphone"
        starting = device.id
        defer { starting = nil }
        do {
            let r: SpotifyNowResponse = try await api.post("/api/mobile/spotify/transfer", body: ["deviceId": JSONValue.string(device.id), "play": .bool(true)])
            summary?.nowPlaying = r.nowPlaying
            await loadDevices(api: api)
            toast.show("Playing on \(device.name)")
        } catch {
            toast.error(error)
        }
    }

    func seek(to fraction: Double, api: APIClient) async {
        guard var now = summary?.nowPlaying else { return }
        let ms = Int(Double(now.durationMs) * min(max(fraction, 0), 1))
        now.progressMs = ms
        now.at = SpotifyTrack.iso.string(from: .now)
        summary?.nowPlaying = now
        await adjust(["action": .string("seek"), "positionMs": .int(ms)], api: api)
    }

    func setVolume(_ percent: Int, api: APIClient) async {
        summary?.nowPlaying?.volume = percent
        if let i = devices.firstIndex(where: \.isActive) { devices[i].volume = percent }
        await adjust(["action": .string("volume"), "percent": .int(percent)], api: api)
    }

    /// Off, then the whole list, then this one song.
    func cycleRepeat(api: APIClient) async {
        let next = switch summary?.nowPlaying?.repeat ?? "off" {
        case "off": "context"
        case "context": "track"
        default: "off"
        }
        summary?.nowPlaying?.repeat = next
        await adjust(["action": .string("repeat"), "state": .string(next)], api: api)
    }

    func toggleShuffle(api: APIClient) async {
        let next = !(summary?.nowPlaying?.shuffle ?? false)
        summary?.nowPlaying?.shuffle = next
        await adjust(["action": .string("shuffle"), "state": .bool(next)], api: api)
    }

    func queue(_ item: SpotifyItem, api: APIClient) async {
        await adjust(["action": .string("queue"), "uri": .string(item.uri)], api: api)
        toast.show("Added to the queue")
    }

    private func adjust(_ body: [String: JSONValue], api: APIClient) async {
        do {
            let r: SpotifyNowResponse = try await api.post("/api/mobile/spotify/adjust", body: body)
            if let now = r.nowPlaying { summary?.nowPlaying = now }
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
        let now = SpotifyTrack.iso.string(from: .now)
        summary = MusicSummary(
            status: "connected", account: "Will",
            nowPlaying: SpotifyTrack(kind: "track", id: "demo", title: "Dreams", subtitle: "Fleetwood Mac", detail: "Rumours",
                                   image: nil, url: nil, durationMs: 257_000, progressMs: 92_000, isPlaying: true,
                                   shuffle: true, device: "iPhone", at: now),
            recent: [
                SpotifyRecentPlay(kind: "track", id: "a", title: "Everywhere", subtitle: "Fleetwood Mac", image: nil, url: nil, playedAt: SpotifyTrack.iso.string(from: .now.addingTimeInterval(-600)), minutes: 4),
                SpotifyRecentPlay(kind: "episode", id: "b", title: "The future of batteries", subtitle: "Acquired", image: nil, url: nil, playedAt: SpotifyTrack.iso.string(from: .now.addingTimeInterval(-7200)), minutes: 38),
                SpotifyRecentPlay(kind: "track", id: "c", title: "Heroes", subtitle: "David Bowie", image: nil, url: nil, playedAt: SpotifyTrack.iso.string(from: .now.addingTimeInterval(-9000)), minutes: 6),
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
