import Foundation

/// The hub's `/api/mobile/spotify` answer (lib/spotify.ts on the hub).
struct MusicSummary: Decodable, Equatable {
    /// "connected", "not_connected" or "unconfigured" (no Spotify app keys on the hub).
    var status: String
    var account: String?
    var nowPlaying: SpotifyTrack?
    var recent: [SpotifyRecentPlay]
    var mix: ListeningMix?

    var isConnected: Bool { status == "connected" }
}

struct SpotifyTrack: Decodable, Equatable {
    /// "track" or "episode".
    var kind: String
    var id: String
    var title: String
    var subtitle: String
    var detail: String?
    var image: String?
    var url: String?
    var durationMs: Int
    var progressMs: Int
    var isPlaying: Bool
    var shuffle: Bool
    var device: String?
    /// When the hub read `progressMs`.
    var at: String

    var isEpisode: Bool { kind == "episode" }
    var readAt: Date { Self.iso.date(from: at) ?? Self.isoPlain.date(from: at) ?? .now }

    /// Progress now, running the clock on from the hub's last reading.
    func progress(at now: Date = .now) -> Double {
        guard durationMs > 0 else { return 0 }
        let ms = Double(progressMs) + (isPlaying ? now.timeIntervalSince(readAt) * 1000 : 0)
        return min(max(ms / Double(durationMs), 0), 1)
    }

    func elapsed(at now: Date = .now) -> TimeInterval { progress(at: now) * Double(durationMs) / 1000 }

    static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    static let isoPlain = ISO8601DateFormatter()
}

struct SpotifyRecentPlay: Decodable, Equatable, Identifiable {
    var kind: String
    var id: String
    var title: String
    var subtitle: String
    var image: String?
    var url: String?
    var playedAt: String
    var minutes: Int

    var isEpisode: Bool { kind == "episode" }
    var date: Date { SpotifyTrack.iso.date(from: playedAt) ?? SpotifyTrack.isoPlain.date(from: playedAt) ?? .now }
    /// Unique per play: the same song twice is two rows.
    var rowID: String { "\(id)|\(playedAt)" }
}

struct ListeningMix: Decodable, Equatable {
    struct Day: Decodable, Equatable, Identifiable {
        var day: String
        var musicMinutes: Int
        var podcastMinutes: Int
        var id: String { day }
        var date: Date {
            let f = DateFormatter()
            f.calendar = Calendar(identifier: .gregorian)
            f.dateFormat = "yyyy-MM-dd"
            return f.date(from: day) ?? .now
        }
    }

    var days: [Day]
    var musicMinutes: Int
    var podcastMinutes: Int
    var podcastShare: Double
    var mood: String
    var line: String
    var topArtist: String?
    var topShow: String?
}

struct SpotifyNowResponse: Decodable { var nowPlaying: SpotifyTrack? }
struct SpotifyConnectResponse: Decodable { var url: String }

/// A Walkman key, as the hub's control route names them.
enum WalkmanKey: String, CaseIterable, Encodable {
    case rew, ff, stop, play

    /// What pressing it asks Spotify to do.
    var action: String {
        switch self {
        case .rew: "previous"
        case .ff: "next"
        case .stop: "toggle"
        case .play: "shuffle"
        }
    }

    var label: String {
        switch self {
        case .rew: "Previous"
        case .ff: "Next"
        case .stop: "Play or pause"
        case .play: "Shuffle play"
        }
    }
}
