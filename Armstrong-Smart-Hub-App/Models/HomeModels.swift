import Foundation

/// Mirrors lib/home-types.ts in the web app.
enum ControlKind: String, Codable, Sendable {
    case toggle, light, lock, climate, sensor, remote, mediaPlayer
    case unknown

    init(from decoder: Decoder) throws {
        self = ControlKind(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown
    }
}

struct HAEntity: Codable, Identifiable, Equatable, Sendable {
    let id: String
    var name: String
    var state: String
    var icon: String?
    var room: String?
    var control: ControlKind
    var brightness: Double?
    var unit: String?
    var device: String?
    var remoteEntityId: String?
    var mediaPlayerEntityId: String?
    var colorModes: [String]?
    var rgbColor: [Int]?
    var colorTempKelvin: Int?
    var minKelvin: Int?
    var maxKelvin: Int?

    var isOn: Bool {
        let s = state.lowercased()
        switch control {
        case .climate: return !["off", "unavailable", "unknown"].contains(s)
        case .mediaPlayer: return !["off", "standby", "unavailable", "unknown"].contains(s)
        default: return ["on", "open", "unlocked", "home"].contains(s)
        }
    }

    var isUnavailable: Bool { ["unavailable", "unknown"].contains(state.lowercased()) }
    var isTV: Bool { control == .remote || control == .mediaPlayer }

    private static let colorModeNames: Set<String> = ["hs", "xy", "rgb", "rgbw", "rgbww"]
    var supportsColor: Bool { (colorModes ?? []).contains { Self.colorModeNames.contains($0) } }
    var supportsColorTemp: Bool { (colorModes ?? []).contains("color_temp") }
    var supportsBrightness: Bool { control == .light && (colorModes ?? []).contains { $0 != "onoff" } }
    var hasLightControls: Bool { supportsBrightness || supportsColor || supportsColorTemp }

    /// 1 to 100 while on, 0 when off. HA reports brightness on a 0 to 255 scale.
    var brightnessPct: Int {
        guard isOn else { return 0 }
        guard let brightness else { return 100 }
        return max(1, Int((brightness / 255 * 100).rounded()))
    }

    var stateLabel: String {
        if isUnavailable { return "Unavailable" }
        switch control {
        case .sensor: return state + (unit.map { " \($0)" } ?? "")
        case .lock: return isOn ? "Unlocked" : "Locked"
        case .light where isOn && brightness != nil: return "On · \(brightnessPct)%"
        case .remote, .mediaPlayer: return state.prefix(1).uppercased() + state.dropFirst()
        default: return isOn ? "On" : "Off"
        }
    }

    var symbol: String {
        switch control {
        case .light: return isOn ? "lightbulb.fill" : "lightbulb"
        case .lock: return isOn ? "lock.open.fill" : "lock.fill"
        case .climate: return "thermometer.medium"
        case .sensor: return "gauge.with.dots.needle.50percent"
        case .remote, .mediaPlayer: return "tv"
        default: return "power"
        }
    }

    /// A TV is a `remote.*` for the D-pad plus a `media_player.*` for playback;
    /// pick whichever of the pair understands this command.
    func remoteTarget(_ command: RemoteCommand) -> String? {
        let nav = control == .remote ? id : remoteEntityId
        let media = control == .mediaPlayer ? id : mediaPlayerEntityId
        return command.isNavigation ? nav : (media ?? nav)
    }
}

enum RemoteCommand: String, CaseIterable, Sendable {
    case up, down, left, right, select, back, home, power
    case playPause = "play_pause"
    case volumeUp = "volume_up"
    case volumeDown = "volume_down"
    case mute
    case openJellyfin = "open_jellyfin"

    var isNavigation: Bool { [.up, .down, .left, .right, .select, .back, .home].contains(self) }
    /// Power and Open Jellyfin wait for the TV's real answer; the rest are fire-and-forget.
    var waits: Bool { self == .power || self == .openJellyfin }
}

enum RequestStage: String, Codable, Sendable {
    case pendingApproval, approved, searching, found, downloading, processing, available, declined, unknown

    init(from decoder: Decoder) throws {
        self = RequestStage(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown
    }

    var label: String {
        switch self {
        case .pendingApproval: return "Pending approval"
        case .approved: return "Queued"
        case .searching: return "Searching"
        case .found: return "Found"
        case .downloading: return "Downloading"
        case .processing: return "Processing"
        case .available: return "Available"
        case .declined: return "Declined"
        case .unknown: return "Unknown"
        }
    }

    var isActive: Bool { [.approved, .searching, .found, .downloading, .processing].contains(self) }
}

enum MediaType: String, Codable, Sendable { case movie, tv }

struct MediaRequest: Codable, Identifiable, Equatable, Sendable {
    let id: Int
    let tmdbId: Int?
    let title: String
    let mediaType: MediaType
    let posterURL: String?
    let stage: RequestStage
    let progress: Double?
    let etaSeconds: Double?
    let updatedAt: String?
    let statusMessage: String?

    /// Never invent an ETA the download client didn't supply.
    var etaText: String {
        if stage == .available { return "Available now" }
        if stage == .processing { return "Processing" }
        if let progress, progress >= 0.99 { return "Finishing up" }
        guard let eta = etaSeconds, eta > 0 else { return stage.label }
        let min = max(1, Int((eta / 60).rounded()))
        return min >= 60 ? "About \(min / 60)h \(min % 60)m" : "About \(min) min"
    }
}

struct MediaResult: Codable, Identifiable, Hashable, Sendable {
    let id: Int
    let title: String
    let overview: String?
    let mediaType: MediaType
    let year: String?
    let posterURL: String?
}

struct MediaDetail: Codable, Sendable {
    let id: Int
    let title: String
    let overview: String?
    let mediaType: MediaType
    let year: String?
    let posterURL: String?
    let backdropURL: String?
    let runtimeMinutes: Int?
    let genres: [String]
    let voteAverage: Double?
    let seasons: Int?
    let alreadyRequested: Bool
    let available: Bool
    let jellyfinItemId: String?
    let playerOnline: Bool
    let canLaunchPlayer: Bool
    let resumeSeconds: Double?
    let runtimeSeconds: Double?
    let episodeLabel: String?

    var canPlay: Bool { jellyfinItemId != nil && (playerOnline || canLaunchPlayer) }
}

/// What the Home tab opens in its title card: a title from search, downloads or the shelf.
struct MediaPick: Identifiable, Hashable, Sendable {
    /// What's already known before the details load, so the card's button is there from the start.
    enum Known: Hashable, Sendable { case available, requested }

    let id: Int
    let mediaType: MediaType
    let title: String
    let posterURL: String?
    var known: Known? = nil
}

struct HAAutomation: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    var state: String
    let lastTriggered: String?
    let hubMade: Bool
    let configId: String?
}

struct HAScene: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let state: String
    let lastTriggered: String?
}

struct AutomationsPayload: Codable, Equatable, Sendable {
    var automations: [HAAutomation]
    var scenes: [HAScene]
    var scripts: [HAScene]
}

/// GET /api/home.
struct HomeState: Codable, Sendable {
    struct Errors: Codable, Sendable {
        var entities: String?
        var requests: String?
        var automations: String?
    }

    let configured: Bool
    var entities: [HAEntity]?
    var requests: [MediaRequest]?
    var automations: AutomationsPayload?
    var visible: [String]?
    var errors: Errors
    var fetchedAt: Double?
}
