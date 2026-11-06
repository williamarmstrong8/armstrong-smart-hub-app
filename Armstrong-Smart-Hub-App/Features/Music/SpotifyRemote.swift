import Foundation
import Observation
import SpotifyiOS
import UIKit

/// The link to the Spotify app on this phone (Spotify's iOS SDK, App Remote), the way
/// workout apps and games play Spotify. The hub does everything else over the Web API,
/// but the Web API can only play on a device that's awake, and iOS puts the Spotify app
/// to sleep in the background, so the phone drops off Spotify's device list.
///
/// `wake(playing:)` opens Spotify for a moment with the song (or where it left off),
/// Spotify starts it and comes straight back here with a token, and from then on the
/// phone is an active device the hub can play anything on.
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
    @ObservationIgnored private var clientID: String?
    @ObservationIgnored private var waiters: [CheckedContinuation<Bool, Never>] = []
    @ObservationIgnored private var attempt = 0
    /// Connecting with a token Spotify just handed back, so a failure ends the sign-in too.
    @ObservationIgnored private var connectingWithNewToken = false

    /// App Remote's token from the Spotify app; it only lets this phone talk to Spotify on this phone.
    @ObservationIgnored private var token: String? {
        get { UserDefaults.standard.string(forKey: "spotify.remoteToken") }
        set { UserDefaults.standard.set(newValue, forKey: "spotify.remoteToken") }
    }

    var isConfigured: Bool { appRemote != nil }

    /// The hub sends the Spotify app's client ID (it's public); App Remote needs it.
    func configure(clientID: String) {
        guard clientID != self.clientID else { return }
        self.clientID = clientID
        let remote = SPTAppRemote(configuration: SPTConfiguration(clientID: clientID, redirectURL: Self.redirectURL), logLevel: .error)
        remote.delegate = self
        remote.connectionParameters.accessToken = token
        appRemote = remote
    }

    /// Opens Spotify on this phone playing `uri` ("" picks up where it left off), and
    /// waits for it to come back and connect. False when Spotify isn't installed, the
    /// person said no, or it didn't come back in time.
    func wake(playing uri: String) async -> Bool {
        guard let remote = appRemote else { return false }
        lastError = nil
        if !remote.isConnected, remote.connectionParameters.accessToken != nil {
            // Spotify may still be running: try the link without leaving the app.
            if await connect(remote, within: .seconds(3)) == false { remote.disconnect() }
        }
        if !remote.isConnected {
            // Sign in with no song: asking App Remote to play a URI while authorizing is a
            // known cause of Spotify showing an X and bouncing back. The song plays after.
            guard await authorize(remote) else { return false }
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

    private func authorize(_ remote: SPTAppRemote) async -> Bool {
        lastError = nil
        connectingWithNewToken = false
        waking = true
        defer { waking = false }
        attempt += 1
        let this = attempt
        return await withCheckedContinuation { continuation in
            waiters.append(continuation)
            remote.authorizeAndPlayURI("") { installed in
                guard !installed else { return }
                Task { @MainActor in
                    self.lastError = "Spotify isn't installed on this phone."
                    self.finish(false)
                }
            }
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(25))
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
        guard let remote = appRemote else { return false }
        guard let params = remote.authorizationParameters(from: url) else {
            lastError = "Spotify came back without a token (\(url.query ?? url.absoluteString))."
            finish(false)
            return true
        }
        if let token = params[SPTAppRemoteAccessTokenKey] {
            self.token = token
            remote.connectionParameters.accessToken = token
            connectingWithNewToken = true
            remote.connect()
        } else {
            lastError = "Spotify said: \(params[SPTAppRemoteErrorDescriptionKey] ?? "no").".replacingOccurrences(of: "..", with: ".")
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
}

extension SpotifyRemote: SPTAppRemoteDelegate {
    nonisolated func appRemoteDidEstablishConnection(_ appRemote: SPTAppRemote) {
        Task { @MainActor in
            self.isConnected = true
            self.lastError = nil
            self.finish(true)
        }
    }

    nonisolated func appRemote(_ appRemote: SPTAppRemote, didFailConnectionAttemptWithError error: (any Error)?) {
        let message = error?.localizedDescription
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
