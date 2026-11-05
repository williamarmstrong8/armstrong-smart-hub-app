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
