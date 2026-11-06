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
        if remote.isConnected {
            if !uri.isEmpty { remote.playerAPI?.play(uri, callback: nil) }
            return true
        }
        waking = true
        defer { waking = false }
        attempt += 1
        let this = attempt
        return await withCheckedContinuation { continuation in
            waiters.append(continuation)
            remote.authorizeAndPlayURI(uri) { installed in
                guard !installed else { return }
                Task { @MainActor in
                    self.lastError = "Spotify isn't installed on this phone."
                    self.finish(false)
                }
            }
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(25))
                if self.attempt == this { self.finish(false) }
            }
        }
    }

    /// armstronghub://spotify-remote, on the way back from Spotify.
    @discardableResult
    func handle(_ url: URL) -> Bool {
        guard let remote = appRemote, let params = remote.authorizationParameters(from: url) else { return false }
        if let token = params[SPTAppRemoteAccessTokenKey] {
            self.token = token
            remote.connectionParameters.accessToken = token
            remote.connect()
        } else {
            lastError = params[SPTAppRemoteErrorDescriptionKey] ?? "Spotify didn't connect."
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
            self.lastError = message
            self.finish(false)
        }
    }

    nonisolated func appRemote(_ appRemote: SPTAppRemote, didDisconnectWithError error: (any Error)?) {
        Task { @MainActor in self.isConnected = false }
    }
}
