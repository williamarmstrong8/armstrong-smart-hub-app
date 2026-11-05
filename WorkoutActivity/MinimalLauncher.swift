import Foundation

/// Local-only launcher preferences, shared with the existing widget extension.
/// Widget URLs contain only an entry ID, never an arbitrary destination supplied by a link.
nonisolated struct LauncherItem: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var name: String
    var destination: String
    var usesShortcut: Bool

    var url: URL? {
        if usesShortcut {
            var parts = URLComponents()
            parts.scheme = "shortcuts"
            parts.host = "run-shortcut"
            parts.queryItems = [URLQueryItem(name: "name", value: destination)]
            return parts.url
        }
        guard !destination.contains(where: { $0.isWhitespace }),
              let result = URL(string: destination), let scheme = result.scheme?.lowercased(),
              !["armstronghub", "file", "javascript", "data"].contains(scheme) else { return nil }
        return result
    }

    var widgetURL: URL {
        var parts = URLComponents()
        parts.scheme = "armstronghub"
        parts.host = "launch"
        parts.queryItems = [URLQueryItem(name: "id", value: id.uuidString)]
        return parts.url!
    }
}

nonisolated struct MinimalLauncherSettings: Codable, Equatable, Sendable {
    static let key = "brick.minimalLauncher.v1"
    static let widgetKind = "MinimalLauncherWidget"
    static let maximumItems = 6
    var items: [LauncherItem] = []
    var dark = true
    var largeText = false

    static func read() -> Self { SharedStore.read(Self.self, key) ?? Self() }
    func save() { SharedStore.write(self, Self.key) }

    func item(for url: URL) -> LauncherItem? {
        guard url.scheme == "armstronghub", url.host == "launch",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let value = components.queryItems?.first(where: { $0.name == "id" })?.value,
              let id = UUID(uuidString: value) else { return nil }
        return items.first { $0.id == id }
    }
}
