import Foundation

/// The last thing each page loaded, kept on the phone so a cold launch paints
/// it straight away and the hub's answer replaces it when it comes in.
enum DiskCache {
    private static let folder = URL.applicationSupportDirectory.appending(path: "PageCache")

    private static func url(_ name: String) -> URL { folder.appending(path: "\(name).json") }

    static func read<T: Decodable>(_ name: String, as: T.Type = T.self) -> T? {
        // Demo mode never shows or keeps a saved page: each take starts from the same data.
        if Demo.isOn { return nil }
        guard let data = try? Data(contentsOf: url(name)) else { return nil }
        return try? APIClient.decoder.decode(T.self, from: data)
    }

    /// Saves a response body as the hub sent it.
    static func write(_ data: Data, _ name: String) {
        if Demo.isOn { return }
        let target = url(name)
        Task.detached(priority: .utility) {
            try? FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: target, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
    }

    static func write<T: Encodable>(_ value: T, _ name: String) {
        guard let data = try? APIClient.encoder.encode(value) else { return }
        write(data, name)
    }

    /// Forgets every page, on sign-out.
    static func clear() {
        try? FileManager.default.removeItem(at: folder)
    }
}
