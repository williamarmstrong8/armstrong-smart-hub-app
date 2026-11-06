import Foundation
import Observation
import SpotifyiOS
import UIKit

/// The link to the Spotify app on this phone (Spotify's iOS SDK, App Remote), the way
/// workout apps and games play Spotify. The hub does everything else over the Web API,
/// but the Web API can only play on a device that's awake, and iOS puts the Spotify app
/// to sleep in the background, so the phone drops off Spotify's device list.
///
/// `wake(playing:)` opens Spotify for a moment (it starts playing, which wakes it), the
/// Spotify app hands back a one-time code, the SDK trades it for a token through the
/// hub's token swap (`/api/spotify/swap`, which holds the client secret), and App Remote
/// connects. From then on the phone is an awake device the hub can play anything on.
@MainActor
@Observable
final class SpotifyRemote: NSObject {
    static let shared = SpotifyRemote()
    /// Also a Redirect URI on the Spotify app in the developer dashboard.
    static let redirectURL = URL(string: "armstronghub://spotify-remote")!

    private(set) var isConnected = false
    private(set) var lastError: String?
    /// Opening Spotify and waiting for it to come back.
    private(set) var waking = false

    @ObservationIgnored private var appRemote: SPTAppRemote?
    @ObservationIgnored private var sessionManager: SPTSessionManager?
    @ObservationIgnored private var configuredFor: String?
    @ObservationIgnored private var waiters: [CheckedContinuation<Bool, Never>] = []
    @ObservationIgnored private var attempt = 0
    /// Connecting with a token that just came back, so a failure ends the sign-in too.
    @ObservationIgnored private var connectingWithNewToken = false

    private static let sessionKey = "spotify.remoteSession"

    var isConfigured: Bool { appRemote != nil }

    /// The hub sends the Spotify app's client ID (it's public); the SDK trades codes
    /// for tokens through the hub, so it needs the hub's address too.
    func configure(clientID: String, hub: URL) {
        let key = "\(clientID)|\(hub.absoluteString)"
        guard key != configuredFor else { return }
        configuredFor = key
        let configuration = SPTConfiguration(clientID: clientID, redirectURL: Self.redirectURL)
        configuration.tokenSwapURL = hub.appending(path: "api/spotify/swap")
        configuration.tokenRefreshURL = hub.appending(path: "api/spotify/refresh")
        // Starting playback during sign-in is what wakes Spotify; "" resumes where it was.
        configuration.playURI = ""
        let manager = SPTSessionManager(configuration: configuration, delegate: self)
        let remote = SPTAppRemote(configuration: configuration, logLevel: .error)
        remote.delegate = self
        if let session = Self.savedSession() {
            manager.session = session
            remote.connectionParameters.accessToken = session.accessToken
        }
        sessionManager = manager
        appRemote = remote
    }

    /// Opens Spotify on this phone if it has to, and plays `uri` ("" picks up where it left
    /// off). False when Spotify isn't installed, the person said no, or it didn't come back.
    func wake(playing uri: String) async -> Bool {
        guard let remote = appRemote else { return false }
        lastError = nil
        if !remote.isConnected, let session = sessionManager?.session, !session.isExpired {
            // Spotify may still be running: try the link without leaving the app.
            if await connect(remote, within: .seconds(3)) == false { remote.disconnect() }
        }
        if !remote.isConnected {
            guard await signIn() else { return false }
        }
        if !uri.isEmpty { remote.playerAPI?.play(uri, callback: nil) }
        else { remote.playerAPI?.resume(nil) }
        return true
    }

    private func connect(_ remote: SPTAppRemote, within limit: Duration) async -> Bool {
        attempt += 1
        let this = attempt
        return await withCheckedContinuation { continuation in
            waiters.append(continuation)
            remote.connect()
            Task { @MainActor in
                try? await Task.sleep(for: limit)
                if self.attempt == this { self.finish(false) }
            }
        }
    }

    /// The Spotify app's sign-in: it opens, starts playing, and comes back with a code.
    private func signIn() async -> Bool {
        guard let manager = sessionManager else { return false }
        guard manager.isSpotifyAppInstalled else {
            lastError = "Spotify isn't installed on this phone."
            return false
        }
        lastError = nil
        connectingWithNewToken = false
        waking = true
        defer { waking = false }
        attempt += 1
        let this = attempt
        return await withCheckedContinuation { continuation in
            waiters.append(continuation)
            manager.initiateSession(with: [.appRemoteControl, .streaming], options: .clientOnly, campaign: nil)
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(30))
                if self.attempt == this {
                    if self.lastError == nil { self.lastError = "Spotify didn't come back." }
                    self.finish(false)
                }
            }
        }
    }

    /// armstronghub://spotify-remote, on the way back from Spotify.
    @discardableResult
    func handle(_ url: URL) -> Bool {
        guard let manager = sessionManager else { return false }
        let handled = manager.application(UIApplication.shared, open: url, options: [:])
        if !handled {
            lastError = "Spotify came back with something unexpected (\(url.query ?? url.absoluteString))."
            finish(false)
        }
        return true
    }

    /// Back in the app: pick the link up again if Spotify is still running.
    func reconnect() {
        guard let remote = appRemote, !remote.isConnected, remote.connectionParameters.accessToken != nil else { return }
        remote.connect()
    }

    private func finish(_ ok: Bool) {
        let pending = waiters
        waiters = []
        pending.forEach { $0.resume(returning: ok) }
    }

    private func use(_ session: SPTSession) {
        if let data = try? NSKeyedArchiver.archivedData(withRootObject: session, requiringSecureCoding: true) {
            UserDefaults.standard.set(data, forKey: Self.sessionKey)
        }
        appRemote?.connectionParameters.accessToken = session.accessToken
    }

    private static func savedSession() -> SPTSession? {
        guard let data = UserDefaults.standard.data(forKey: sessionKey) else { return nil }
        return try? NSKeyedUnarchiver.unarchivedObject(ofClass: SPTSession.self, from: data)
    }

    /// Spotify's errors nest the useful part (the swap's answer) under the top one.
    nonisolated private static func describe(_ error: any Error) -> String {
        let ns = error as NSError
        var parts = [ns.localizedDescription]
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError {
            parts.append(underlying.localizedDescription)
        }
        for key in ["error_description", "error", NSLocalizedFailureReasonErrorKey] {
            if let value = ns.userInfo[key] as? String, !parts.contains(value) { parts.append(value) }
        }
        return parts.joined(separator: " · ")
    }
}

extension SpotifyRemote: SPTSessionManagerDelegate {
    nonisolated func sessionManager(manager: SPTSessionManager, didInitiate session: SPTSession) {
        Task { @MainActor in
            self.use(session)
            self.connectingWithNewToken = true
            self.appRemote?.connect()
        }
    }

    nonisolated func sessionManager(manager: SPTSessionManager, didFailWith error: any Error) {
        let message = Self.describe(error)
        Task { @MainActor in
            self.lastError = "Spotify said: \(message)"
            self.finish(false)
        }
    }

    nonisolated func sessionManager(manager: SPTSessionManager, didRenew session: SPTSession) {
        Task { @MainActor in self.use(session) }
    }
}

extension SpotifyRemote: SPTAppRemoteDelegate {
    nonisolated func appRemoteDidEstablishConnection(_ appRemote: SPTAppRemote) {
        Task { @MainActor in
            self.isConnected = true
            self.lastError = nil
            self.connectingWithNewToken = false
            self.finish(true)
        }
    }

    nonisolated func appRemote(_ appRemote: SPTAppRemote, didFailConnectionAttemptWithError error: (any Error)?) {
        let message = error.map { Self.describe($0) }
        Task { @MainActor in
            self.isConnected = false
            // An old token failing while the sign-in is open isn't the sign-in failing.
            guard !self.waking || self.connectingWithNewToken else { return }
            if let message { self.lastError = "Spotify said: \(message)" }
            self.finish(false)
        }
    }

    nonisolated func appRemote(_ appRemote: SPTAppRemote, didDisconnectWithError error: (any Error)?) {
        Task { @MainActor in self.isConnected = false }
    }
}
