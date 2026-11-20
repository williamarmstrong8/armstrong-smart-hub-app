import Foundation
import Observation
import SwiftUI
import UIKit

/// The gym's key tag as a barcode on the phone: a card on Fitness, and the pass
/// full screen the first time the app comes to the front during a gym visit
/// (PlaceMonitor's geofence says when you're there).
///
/// The number is bundled from GymPass.txt, which is kept out of git because the
/// repo is public, or typed on the phone, which wins. Nothing leaves the phone.
@MainActor
@Observable
final class GymPass {
    static let shared = GymPass()

    /// The barcode's text, or nil before one is added.
    private(set) var code: String?
    /// The pass is on screen.
    private(set) var isShowing = false
    /// Open the pass by itself on arriving at the gym.
    var autoOpen: Bool {
        didSet { UserDefaults.standard.set(autoOpen, forKey: Self.autoOpenKey) }
    }

    @ObservationIgnored private let presenter = PassPresenter()
    /// "Pretend I got to the gym" (Test features): the next open shows the pass without being there.
    @ObservationIgnored private var testUntil: Date?

    private static let typedKey = "gymPass.code"
    private static let autoOpenKey = "gymPass.autoOpen"
    private static let shownVisitKey = "gymPass.shownVisit"
    /// An arrival older than this is likely a departure iOS never reported, so it doesn't open the pass.
    private static let freshFor: TimeInterval = 3 * 3600

    init() {
        autoOpen = UserDefaults.standard.object(forKey: Self.autoOpenKey) as? Bool ?? true
        code = Demo.isOn ? nil : UserDefaults.standard.string(forKey: Self.typedKey) ?? Self.bundled
    }

    /// The number this build came with (GymPass.txt), if any.
    static var bundled: String? {
        guard let url = Bundle.main.url(forResource: "GymPass", withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let code = text.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        return Code39.canEncode(code) ? code : nil
    }

    /// A number typed on the phone is in use, rather than the bundled one.
    var isTyped: Bool { UserDefaults.standard.string(forKey: Self.typedKey) != nil }

    /// Saves a typed number. Empty goes back to the bundled one.
    func set(_ text: String) {
        let typed = text.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if typed.isEmpty {
            UserDefaults.standard.removeObject(forKey: Self.typedKey)
            code = Self.bundled
        } else if Code39.canEncode(typed) {
            UserDefaults.standard.set(typed, forKey: Self.typedKey)
            code = typed
        }
    }

    // MARK: Showing

    /// Puts the pass up, over anything else open (a sheet, or the workout screen), with Fitness underneath.
    @discardableResult
    func show() -> Bool {
        guard code != nil else { return false }
        if isShowing { return true }
        guard presenter.show(onClosed: { [weak self] in self?.isShowing = false }) else { return false }
        isShowing = true
        AppRouter.shared.open(.fitness)
        return true
    }

    /// The first time the app is in front during a gym visit, the pass goes up.
    /// Later opens in the same visit leave the app as it was. Returns whether the pass is showing.
    @discardableResult
    func showIfJustArrived() -> Bool {
        if isShowing { return true }
        guard autoOpen, code != nil, UIApplication.shared.applicationState != .background else { return false }
        if let until = testUntil, until > .now {
            testUntil = nil
            return show()
        }
        guard let visit = PlaceMonitor.shared.openVisit(.gym),
              Date.now.timeIntervalSince(visit.arrived) < Self.freshFor,
              UserDefaults.standard.string(forKey: Self.shownVisitKey) != visit.id.uuidString,
              show() else { return false }
        UserDefaults.standard.set(visit.id.uuidString, forKey: Self.shownVisitKey)
        return true
    }

    /// Test features: the next time the app comes to the front (within 2 minutes), the pass opens as on arrival.
    func armTest() {
        testUntil = .now.addingTimeInterval(120)
    }
}

/// Shows the pass in a window of its own above the app's, so it covers whatever is open:
/// a SwiftUI sheet can't go up over another sheet or the workout screen.
@MainActor
private final class PassPresenter: NSObject, UIAdaptivePresentationControllerDelegate {
    private var window: UIWindow?
    private var onClosed: (() -> Void)?

    func show(onClosed: @escaping () -> Void) -> Bool {
        if window != nil { return true }
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let scene = scenes.first(where: { $0.activationState == .foregroundActive })
            ?? scenes.first(where: { $0.activationState == .foregroundInactive }) else { return false }
        let window = UIWindow(windowScene: scene)
        window.windowLevel = .normal + 1
        window.tintColor = UIColor(HubDesign.action)
        let root = UIViewController()
        root.view.backgroundColor = .clear
        window.rootViewController = root
        window.makeKeyAndVisible()
        self.window = window
        self.onClosed = onClosed

        let pass = UIHostingController(rootView: GymPassSheet(close: { [weak self] in self?.close() }))
        pass.presentationController?.delegate = self
        root.present(pass, animated: true)
        return true
    }

    func close() {
        guard let root = window?.rootViewController, root.presentedViewController != nil else {
            tearDown()
            return
        }
        root.dismiss(animated: true) { [weak self] in self?.tearDown() }
    }

    /// Swiped down.
    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        tearDown()
    }

    private func tearDown() {
        guard let window else { return }
        let scene = window.windowScene
        window.isHidden = true
        self.window = nil
        // Hand the keyboard and focus back to the app's own window.
        scene?.windows.first { $0.windowLevel == .normal && !$0.isHidden }?.makeKey()
        onClosed?()
        onClosed = nil
    }
}
