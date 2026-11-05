import Foundation

/// Demo mode for the launch film: launch with `-DemoMode YES` (Debug builds only).
/// Every hub request is answered in-process from `DemoData.swift`, the watch and
/// the focus tag are simulated, and nothing reaches the network, Bluetooth, NFC or Screen Time.
/// Release builds compile this to a constant `false`.
enum Demo {
    #if DEBUG
    /// `-DemoMode YES` lands in the arguments domain of UserDefaults.
    static let isOn: Bool = UserDefaults.standard.bool(forKey: "DemoMode")
    #else
    static let isOn = false
    #endif

    /// The tab the app opens on: `-DemoTab fitness|home|focus`.
    static var startTab: String? { isOn ? UserDefaults.standard.string(forKey: "DemoTab") : nil }

    /// Focus is the film's name for Brick: the word never appears in demo footage.
    static func copy(_ real: String, _ demo: String) -> String { isOn ? demo : real }
}

#if DEBUG
/// Film cues: the recording scripts write "<name> <stamp>" into the app's Documents/demo-cue
/// (see demo-video/scripts/cue.sh) and the screen on show acts on it within ~40 ms, so every
/// take runs the same actions at the same moments, with no injected touches to miss.
@MainActor
enum DemoCue {
    private static var handlers: [String: () -> Void] = [:]
    private static var polling = false
    private static let file = URL.documentsDirectory.appending(path: "demo-cue")

    /// Registers what a cue does; a later registration for the same cue replaces it.
    static func on(_ name: String, _ action: @escaping () -> Void) {
        guard Demo.isOn else { return }
        handlers[name] = action
        guard !polling else { return }
        polling = true
        try? FileManager.default.removeItem(at: file)
        Task { @MainActor in
            var last = ""
            while true {
                if let text = try? String(contentsOf: file, encoding: .utf8), text != last {
                    last = text
                    let name = String(text.split(separator: " ").first ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    handlers[name]?()
                }
                try? await Task.sleep(for: .milliseconds(40))
            }
        }
    }
}
#endif
