import Foundation

/// The last thing each page loaded, kept on the phone so a cold launch paints
/// it straight away and the hub's answer replaces it when it comes in.
enum DiskCache {
    private static let folder = URL.applicationSupportDirectory.appending(path: "PageCache")

    private static func url(_ name: String) -> URL { folder.appending(path: "\(name).json") }

    /// What each page last decoded to, or the bytes last saved for it. The tabs' stores read
    /// their page as they're made, and the tab views (with their stores) are made again on
    /// every tab bar redraw; this keeps that from reading and decoding the file each time.
    private static var memory: [String: Any] = [:]

    static func read<T: Decodable>(_ name: String, as: T.Type = T.self) -> T? {
        // Demo mode never shows or keeps a saved page: each take starts from the same data.
        if Demo.isOn { return nil }
        if let value = memory[name] as? T { return value }
        guard let data = memory[name] as? Data ?? (try? Data(contentsOf: url(name))),
              let value = try? APIClient.decoder.decode(T.self, from: data) else { return nil }
        memory[name] = value
        return value
    }

    /// Saves a response body as the hub sent it.
    static func write(_ data: Data, _ name: String) {
        if Demo.isOn { return }
        // Read back from here until the file is written, so a read can't get the old file.
        memory[name] = data
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
        memory = [:]
        try? FileManager.default.removeItem(at: folder)
    }
}
