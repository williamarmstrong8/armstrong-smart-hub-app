import ActivityKit
import Foundation
import UIKit

/// What the hub says the TV's Jellyfin is playing (nowPlaying).
struct NowPlaying: Decodable, Equatable {
    var playing: Bool
    var title: String?
    var episodeLabel: String?
    var itemId: String?
    var positionSeconds: Double?
    var runtimeSeconds: Double?
    var isPaused: Bool?
    var posterURL: String?
    var player: String?
}

/// Shows what's playing on the TV as a Live Activity with the TV's controls.
///
/// It starts when Play goes through, or when the app finds something already
/// playing while it's open. The times tick on their own between updates; the
/// buttons run here (even with the app in the background) and update it from
/// the hub's answer. It ends when the TV stops, or is marked stale when the
/// title should have finished.
@MainActor
final class TVActivityController {
    static let shared = TVActivityController()

    /// Set while signed in.
    var api: APIClient?
    /// The TV for the volume buttons, from Home's last poll.
    var tv: HAEntity?

    private var activity: Activity<TVActivityAttributes>? { Activity<TVActivityAttributes>.activities.first }
    private var state: TVActivityState? { activity?.content.state }
    private var watching: Task<Void, Never>?
    private var lastPoster: String?

    private init() {}

    /// A lock screen button can wake the app in the background before its window (and the
    /// session) exists, so fall back to the saved sign-in.
    private var client: APIClient? {
        if let api { return api }
        guard let url = SharedHub.serverURL, let token = Keychain.read("token") else { return nil }
        let made = APIClient(baseURL: url, token: token)
        api = made
        return made
    }

    // MARK: Finding what's playing

    /// Play went through: the TV can take a while to open Jellyfin and start, so keep looking.
    func played() {
        watch(every: 3, for: 90)
    }

    /// While the app is open, check now and then, so a title started on the TV shows up too.
    func appBecameActive() {
        watch(every: 20, for: nil)
    }

    func appWentToBackground() {
        watching?.cancel()
        watching = nil
    }

    private func watch(every seconds: Double, for limit: TimeInterval?) {
        watching?.cancel()
        let stopAt = limit.map { Date.now.addingTimeInterval($0) }
        watching = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let found = await self.refresh()
                // After Play, a quick hunt that settles into the slower check once it's found.
                if found, stopAt != nil { self.watch(every: 20, for: nil); return }
                if let stopAt, Date.now > stopAt { self.watch(every: 20, for: nil); return }
                try? await Task.sleep(for: .seconds(seconds))
            }
        }
    }

    /// Asks the hub and brings the activity in line. True when something is playing.
    @discardableResult
    func refresh() async -> Bool {
        guard let api = client else { return false }
        guard let now: NowPlaying = try? await api.run("nowPlaying") else { return activity != nil }
        await apply(now)
        return now.playing
    }

    private func apply(_ now: NowPlaying) async {
        guard now.playing, let title = now.title else {
            await endAll()
            return
        }
        let poster = await posterFile(for: now)
        let next = TVActivityState(
            title: title, episodeLabel: now.episodeLabel, isPaused: now.isPaused ?? false,
            position: now.positionSeconds ?? 0, runtime: now.runtimeSeconds, asOf: .now, posterFile: poster)
        await show(next)
    }

    private func show(_ next: TVActivityState) async {
        let content = ActivityContent(state: next, staleDate: next.isPaused ? nil : next.endsAt?.addingTimeInterval(60))
        if let activity {
            // Same title, same play state, and within a few seconds of where it should be: leave it be.
            if let old = state, old.title == next.title, old.episodeLabel == next.episodeLabel, old.isPaused == next.isPaused,
               old.posterFile == next.posterFile, abs(old.position(at: .now) - next.position) < 5 { return }
            await activity.update(content)
        } else {
            guard ActivityAuthorizationInfo().areActivitiesEnabled,
                  UIApplication.shared.applicationState == .active else { return }
            let name = tv?.name ?? "TV"
            _ = try? Activity.request(attributes: TVActivityAttributes(tvName: name), content: content)
        }
    }

    func endAll() async {
        for a in Activity<TVActivityAttributes>.activities {
            await a.end(nil, dismissalPolicy: .immediate)
        }
    }

    // MARK: Buttons

    func handle(_ command: TVCommand) async {
        guard let api = client else { return }
        // Which way play/pause goes, from what the lock screen showed when it was pressed.
        let pause = !(state?.isPaused ?? false)
        // The buttons change what's on the lock screen straight away; the hub's answer corrects it.
        if var s = state {
            let at = s.position(at: .now)
            switch command {
            case .playPause:
                s.isPaused.toggle()
                s.position = at
                s.asOf = .now
            case .back, .forward:
                s.position = max(0, at + (command == .back ? -TVCommand.backSeconds : TVCommand.forwardSeconds))
                s.asOf = .now
            default:
                break
            }
            if s != state { await show(s) }
        }
        do {
            switch command {
            case .playPause:
                let _: Empty? = try await api.run("nowPlayingControl", [.string(pause ? "pause" : "unpause")])
            case .back:
                let _: Empty? = try await api.run("nowPlayingControl", [.string("seek"), .number(-TVCommand.backSeconds)])
            case .forward:
                let _: Empty? = try await api.run("nowPlayingControl", [.string("seek"), .number(TVCommand.forwardSeconds)])
            case .stop:
                let _: Empty? = try await api.run("nowPlayingControl", [.string("stop")])
                await endAll()
                return
            case .volumeDown, .volumeUp, .mute:
                let remote: RemoteCommand = command == .volumeDown ? .volumeDown : command == .volumeUp ? .volumeUp : .mute
                // Woken in the background, Home hasn't polled yet: use its last copy.
                let tv = tv ?? DiskCache.read("home", as: HomeState.self)?.entities?.first { $0.isTV && !$0.isUnavailable }
                guard let target = tv?.remoteTarget(remote) else { return }
                let _: Empty? = try await api.run("remote", [.string(target), .string(remote.rawValue)])
                return
            }
        } catch {
            // The next look at the hub puts it right.
        }
        // Jellyfin takes a moment to report the new position.
        try? await Task.sleep(for: .seconds(1.5))
        await refresh()
    }

    // MARK: Poster

    /// A small copy of the poster in the app group, where the lock screen can read it.
    private func posterFile(for now: NowPlaying) async -> String? {
        guard let item = now.itemId, let raw = now.posterURL, let url = URL(string: raw) else { return nil }
        // A new name per title, so the activity redraws with the new poster.
        let name = "tv-poster-\(item.filter { $0.isLetter || $0.isNumber }).jpg"
        if let file = SharedHub.file(name), FileManager.default.fileExists(atPath: file.path) { return name }
        guard let file = SharedHub.file(name),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let image = UIImage(data: data) else { return nil }
        // Live Activity images have to be small.
        let size = CGSize(width: 120, height: 180)
        let small = UIGraphicsImageRenderer(size: size).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
        guard let jpeg = small.jpegData(compressionQuality: 0.8), (try? jpeg.write(to: file, options: .atomic)) != nil else { return nil }
        // Only the one playing is kept.
        if let old = lastPoster, old != name, let oldFile = SharedHub.file(old) { try? FileManager.default.removeItem(at: oldFile) }
        lastPoster = name
        return name
    }
}
