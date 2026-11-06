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
            // Nothing awake: link Spotify on this phone, then press again.
            switch await linkPhone(api: api) {
            case .device, .remote:
                if key == .stop { SpotifyRemote.shared.play("") }
                else if let r: SpotifyNowResponse = try? await api.post("/api/mobile/spotify/control", body: ["action": key.action]) {
                    summary?.nowPlaying = r.nowPlaying
                }
                try? await Task.sleep(for: .milliseconds(600))
                await poll(api: api, force: true)
            case .asleep:
                openSpotify(then: .key(key))
            case .unavailable:
                toast.show("Open Spotify on a device, or pick one from the speaker button.", error: true)
            }
        } catch {
            toast.error(error)
            await poll(api: api)
        }
    }

    // MARK: Playing anything, anywhere

    /// The library: playlists, liked songs, albums, shows and saved episodes.
    private(set) var library: SpotifyLibrary?
    /// Episodes to listen to and the picks from the listening history.
    private(set) var discover: SpotifyDiscover?
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

    func loadDiscover(api: APIClient) async {
        guard summary?.isConnected == true else { return }
        if let found: SpotifyDiscover = try? await api.get("/api/mobile/spotify/discover") { discover = found }
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
            switch await linkPhone(api: api) {
            case .device(let phone):
                body.deviceId = phone
            case .remote:
                // Spotify on the phone is running but not on the device list until it plays:
                // start it through the link, then (for a song inside a list, or an episode
                // part-way) let the hub start it exactly, on the phone.
                SpotifyRemote.shared.play(body.contextUri ?? body.uri ?? "")
                guard body.contextUri != nil && body.uri != nil || body.positionMs != nil else {
                    try? await Task.sleep(for: .milliseconds(700))
                    await poll(api: api, force: true)
                    return
                }
                try? await Task.sleep(for: .milliseconds(900))
                body.deviceId = await phoneDeviceID(api: api)
            case .asleep:
                openSpotify(then: .play(body))
                return
            case .unavailable:
                break // plays wherever Spotify is active, if anywhere
            }
        }
        do {
            let r: SpotifyNowResponse = try await api.post("/api/mobile/spotify/play", body: body)
            if let now = r.nowPlaying { summary?.nowPlaying = now }
        } catch where Self.isNoDevice(error) {
            toast.show("Open Spotify on a device, or pick one from the speaker button.", error: true)
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

    private enum PhoneLink { case device(String), remote, asleep, unavailable }

    /// Linking Spotify on this phone, for the device picker's spinner.
    private(set) var linking = false

    /// Gets Spotify on this phone ready to play: already on the device list, or linked
    /// through App Remote with the hub's token while it's running. Asleep means it has
    /// to be opened first.
    private func linkPhone(api: APIClient) async -> PhoneLink {
        if let phone = await phoneDeviceID(api: api) { return .device(phone) }
        let remote = SpotifyRemote.shared
        guard remote.isConfigured else { return .unavailable }
        if remote.isConnected { return .remote }
        linking = true
        defer { linking = false }
        struct Token: Decodable { var accessToken: String }
        guard let token: Token = try? await api.get("/api/mobile/spotify/remote-token") else { return .unavailable }
        return await remote.connect(token: token.accessToken) ? .remote : .asleep
    }

    /// What to do once Spotify, opened to wake it up, hands back to the app.
    private enum Pending { case play(PlayBody), key(WalkmanKey), wake }
    private var pending: Pending?

    private func openSpotify(then next: Pending) {
        guard SpotifyRemote.shared.openSpotify() else {
            toast.show(SpotifyRemote.shared.lastError ?? "Spotify isn't installed on this phone.", error: true)
            return
        }
        pending = next
        toast.show("Spotify was asleep. Tap ◀ Hub at the top left and it plays here.")
    }

    /// Back in the app: finish what opening Spotify was for, now it's awake.
    func resumePending(api: APIClient) async {
        guard let next = pending else { return }
        pending = nil
        // Spotify needs a moment after coming to the foreground before it answers App Remote.
        try? await Task.sleep(for: .milliseconds(500))
        switch next {
        case .play(let body):
            switch await linkPhone(api: api) {
            case .asleep, .unavailable:
                toast.show("Spotify on this phone still isn't answering. \(SpotifyRemote.shared.lastError ?? "")", error: true)
            default:
                await start(body, id: body.uri ?? body.contextUri ?? "", api: api)
            }
        case .key(let key):
            _ = await linkPhone(api: api)
            await press(key, api: api)
        case .wake:
            _ = await linkPhone(api: api)
            await loadDevices(api: api)
            await poll(api: api, force: true)
        }
    }

    /// The device picker's "This iPhone": link it, opening Spotify if it's asleep.
    func wakeThisPhone(api: APIClient) async {
        preferPhone = true
        switch await linkPhone(api: api) {
        case .device(let id):
            if let device = devices.first(where: { $0.id == id }) { await transfer(to: device, api: api) }
        case .remote:
            SpotifyRemote.shared.play("")
            try? await Task.sleep(for: .milliseconds(700))
            await poll(api: api, force: true)
            await loadDevices(api: api)
        case .asleep:
            openSpotify(then: .wake)
        case .unavailable:
            toast.show("Couldn't reach Spotify on this phone.", error: true)
        }
    }

    /// The hub's answer when Spotify has no awake device to play on.
    static func isNoDevice(_ error: any Error) -> Bool {
        let message = error.localizedDescription
        return message.contains("No Spotify device") || message.contains("Nothing's playing on a device")
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
                                   shuffle: true, device: "iPhone", at: now))
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
