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
import SwiftUI

/// Film cues: the recording scripts write "<name> [args…] <stamp>" into the app's Documents/demo-cue
/// (see demo-video/scripts/cue.sh) and the screen on show acts on it within ~40 ms, so every
/// take runs the same actions at the same moments, with no injected touches to miss.
/// The screen registered last for a name handles it (a pushed page takes over from its parent).
@MainActor
enum DemoCue {
    private static var handlers: [String: (String) -> Void] = [:]
    private static var polling = false
    private static let file = URL.documentsDirectory.appending(path: "demo-cue")

    /// Registers what a cue does; a later registration for the same cue replaces it.
    static func on(_ name: String, _ action: @escaping () -> Void) { on(name, arg: { _ in action() }) }

    /// A cue with arguments: everything between the name and the stamp, space-separated.
    static func on(_ name: String, arg action: @escaping (String) -> Void) {
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
                    var words = text.split(whereSeparator: \.isWhitespace).map(String.init)
                    if words.count > 1 { words.removeLast() } // the stamp
                    if let name = words.first {
                        handlers[name]?(words.dropFirst().joined(separator: " "))
                    }
                }
                try? await Task.sleep(for: .milliseconds(40))
            }
        }
    }
}

/// Lets the film scroll a page: cue `scroll <y> [seconds]` glides to y points from the top
/// (`scroll top` goes back). Whichever page appeared last owns the cue.
struct DemoScroll: ViewModifier {
    @State private var position = ScrollPosition(edge: .top)

    func body(content: Content) -> some View {
        content
            .scrollPosition($position)
            .onAppear {
                DemoCue.on("scroll", arg: { arg in
                    let parts = arg.split(separator: " ")
                    let seconds = parts.count > 1 ? Double(parts[1]) ?? 1.2 : 1.2
                    withAnimation(.easeInOut(duration: seconds)) {
                        if parts.first == "top" { position.scrollTo(edge: .top) }
                        else if parts.first == "bottom" { position.scrollTo(edge: .bottom) }
                        else { position.scrollTo(y: CGFloat(Double(parts.first ?? "0") ?? 0)) }
                    }
                })
            }
    }
}
#endif

extension View {
    /// Film scroll cues in demo mode; nothing otherwise.
    @ViewBuilder func demoScroll() -> some View {
        #if DEBUG
        if Demo.isOn { modifier(DemoScroll()) } else { self }
        #else
        self
        #endif
    }
}
