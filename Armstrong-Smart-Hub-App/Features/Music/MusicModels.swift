import Foundation

/// The hub's `/api/mobile/spotify` answer (lib/spotify.ts on the hub).
struct MusicSummary: Decodable, Equatable {
    /// "connected", "not_connected" or "unconfigured" (no Spotify app keys on the hub).
    var status: String
    /// The Spotify app's client ID, for App Remote (SpotifyRemote.swift).
    var clientId: String?
    var account: String?
    var nowPlaying: SpotifyTrack?

    var isConnected: Bool { status == "connected" || status == "needs_reconnect" }
    /// Linked before the hub asked to read the library: playback works, the library doesn't.
    var needsReconnect: Bool { status == "needs_reconnect" }
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
    var deviceId: String?
    var deviceType: String?
    /// 0...100, nil when the device has no volume control.
    var volume: Int?
    /// "off", "context" or "track".
    var `repeat`: String?
    var uri: String?
    var contextUri: String?
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

// MARK: Library and browsing

/// A row: a song or episode to play, or a playlist, album, show, artist or the liked songs to open.
struct SpotifyItem: Decodable, Equatable, Hashable, Identifiable {
    /// "track", "episode", "playlist", "album", "show", "artist" or "liked".
    var kind: String
    var id: String
    var uri: String
    var title: String
    var subtitle: String
    var image: String?
    var durationMs: Int?
    var explicit: Bool
    /// Episodes: "YYYY-MM-DD".
    var date: String?
    var resumeMs: Int?
    var played: Bool

    var isPlayable: Bool { kind == "track" || kind == "episode" }
    var opens: Bool { !isPlayable }

    var releaseDate: Date? {
        guard let date else { return nil }
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.dateFormat = "yyyy-MM-dd"
        return f.date(from: date)
    }
}

struct SpotifyLibrary: Decodable, Equatable {
    struct Liked: Decodable, Equatable { var total: Int; var items: [SpotifyItem] }
    var playlists: [SpotifyItem]
    var albums: [SpotifyItem]
    var shows: [SpotifyItem]
    var episodes: [SpotifyItem]
    var liked: Liked
}

/// Episodes to listen to, and podcasts and playlists picked from the listening history.
struct SpotifyDiscover: Decodable, Equatable {
    var episodes: [SpotifyItem]
    var recommendedPodcasts: [SpotifyItem]
    var recommendedPlaylists: [SpotifyItem]
}

struct SpotifyCollection: Decodable, Equatable {
    var header: SpotifyItem
    /// What a row plays from; nil plays the row alone (podcast episodes).
    var contextUri: String?
    var items: [SpotifyItem]
    var total: Int
    var next: Int?
    var note: String?
}

struct SpotifySearchResults: Decodable, Equatable {
    var tracks: [SpotifyItem]
    var artists: [SpotifyItem]
    var albums: [SpotifyItem]
    var playlists: [SpotifyItem]
    var shows: [SpotifyItem]
    var episodes: [SpotifyItem]

    var isEmpty: Bool { tracks.isEmpty && artists.isEmpty && albums.isEmpty && playlists.isEmpty && shows.isEmpty && episodes.isEmpty }
}

struct SpotifyDevice: Decodable, Equatable, Identifiable {
    var id: String
    var name: String
    /// "Smartphone", "Computer", "Speaker", "TV", "CastAudio", ...
    var type: String
    var isActive: Bool
    var volume: Int?
    var restricted: Bool

    var symbol: String { SpotifyDevice.symbol(for: type) }

    static func symbol(for type: String?) -> String {
        switch type?.lowercased() {
        case "smartphone": "iphone"
        case "computer": "laptopcomputer"
        case "tablet": "ipad"
        case "tv", "stb": "tv"
        case "speaker", "castaudio", "castvideo", "avr": "hifispeaker"
        case "automobile": "car"
        case "gameconsole": "gamecontroller"
        default: "hifispeaker"
        }
    }
}

struct SpotifyDevicesResponse: Decodable { var devices: [SpotifyDevice] }

/// A list to open from the Music page.
enum MusicRoute: Hashable {
    case collection(kind: String, id: String, title: String)
    case search
}

extension SpotifyItem {
    var route: MusicRoute? {
        switch kind {
        case "playlist", "album", "show", "liked": .collection(kind: kind, id: id, title: title)
        default: nil
        }
    }
}
