import Foundation
import Observation
import SpotifyiOS
import UIKit

/// The link to the Spotify app on this phone (Spotify's iOS SDK, App Remote), the way
/// workout apps and games play Spotify. The hub does everything else over the Web API,
/// but the Web API can only play on a device that's awake, and iOS puts the Spotify app
/// to sleep in the background, so the phone drops off Spotify's device list.
///
/// App Remote connects with the hub's own Spotify token (it has app-remote-control):
/// Spotify's app-switch sign-in for the SDK answers `unknown_error` for new apps, even
/// with Spotify's own demo app. Connecting works while Spotify is running on the phone.
/// When it's asleep, nothing on iOS can wake it without opening it, so `openSpotify()`
/// does that and the play waits until the person comes back.
@MainActor
@Observable
final class SpotifyRemote: NSObject {
    static let shared = SpotifyRemote()
    /// The SDK insists on one; nothing is ever redirected to it now.
    static let redirectURL = URL(string: "armstronghub://spotify-remote")!

    private(set) var isConnected = false
    private(set) var lastError: String?

    @ObservationIgnored private var appRemote: SPTAppRemote?
    @ObservationIgnored private var clientID: String?
    @ObservationIgnored private var waiters: [CheckedContinuation<Bool, Never>] = []
    @ObservationIgnored private var attempt = 0

    var isConfigured: Bool { appRemote != nil }

    /// The hub sends the Spotify app's client ID (it's public); App Remote needs it.
    func configure(clientID: String) {
        guard clientID != self.clientID else { return }
        self.clientID = clientID
        let remote = SPTAppRemote(configuration: SPTConfiguration(clientID: clientID, redirectURL: Self.redirectURL), logLevel: .error)
        remote.delegate = self
        appRemote = remote
    }

    /// Links to Spotify on this phone with the hub's token. False when Spotify isn't
    /// running (or won't take the token); `lastError` says which.
    func connect(token: String) async -> Bool {
        guard let remote = appRemote else { return false }
        if remote.isConnected { return true }
        lastError = nil
        remote.connectionParameters.accessToken = token
        attempt += 1
        let this = attempt
        return await withCheckedContinuation { continuation in
            waiters.append(continuation)
            remote.connect()
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(4))
                if self.attempt == this {
                    if self.lastError == nil { self.lastError = "Spotify on this phone didn't answer." }
                    self.finish(false)
                }
            }
        }
    }

    /// Plays on this phone through the link: one song, episode or list from the top.
    func play(_ uri: String) {
        guard let player = appRemote?.playerAPI else { return }
        if uri.isEmpty { player.resume(nil) } else { player.play(uri, callback: nil) }
    }

    /// Brings Spotify up so it's awake; the person comes back with the "◀ Hub" link at the top.
    @discardableResult
    func openSpotify() -> Bool {
        guard let url = URL(string: "spotify:"), UIApplication.shared.canOpenURL(url) else {
            lastError = "Spotify isn't installed on this phone."
            return false
        }
        UIApplication.shared.open(url)
        return true
    }

    func disconnect() {
        appRemote?.disconnect()
    }

    private func finish(_ ok: Bool) {
        let pending = waiters
        waiters = []
        pending.forEach { $0.resume(returning: ok) }
    }

    nonisolated private static func describe(_ error: any Error) -> String {
        let ns = error as NSError
        var parts = [ns.localizedDescription]
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError { parts.append(underlying.localizedDescription) }
        return parts.joined(separator: " · ")
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
        let message = error.map { Self.describe($0) }
        Task { @MainActor in
            self.isConnected = false
            if let message { self.lastError = "Spotify said: \(message)" }
            self.finish(false)
        }
    }

    nonisolated func appRemote(_ appRemote: SPTAppRemote, didDisconnectWithError error: (any Error)?) {
        Task { @MainActor in self.isConnected = false }
    }
}
