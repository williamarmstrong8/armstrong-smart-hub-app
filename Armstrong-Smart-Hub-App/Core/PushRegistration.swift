import Foundation
import UIKit
import UserNotifications

/// Registers the iPhone for push so Jarvis's app-build updates ("build is
/// ready", "it's on your phone") arrive as notifications instead of texts.
/// The device token goes to the hub at /api/mobile/push.
@MainActor
final class PushRegistration {
    static let shared = PushRegistration()

    var api: APIClient? {
        didSet { if api != nil { register() } }
    }

    private var token: String?

    /// Asks for alerts (a no-op once answered) and for a device token.
    func register() {
        guard UIDevice.current.userInterfaceIdiom == .phone, !Demo.isOn else { return }
        Task {
            _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
            UIApplication.shared.registerForRemoteNotifications()
        }
    }

    func didRegister(_ deviceToken: Data) {
        token = deviceToken.map { String(format: "%02x", $0) }.joined()
        upload()
    }

    private func upload() {
        guard let api, let token else { return }
        let body = Body(token: token, env: Self.environment, device: "phone")
        Task { let _: Empty? = try? await api.post("/api/mobile/push", body: body) }
    }

    private struct Body: Encodable {
        let token: String
        let env: String
        let device: String
    }

    /// Development-signed builds (everything Xcode and the Mac runner install)
    /// use the APNs sandbox; App Store and TestFlight builds use production.
    private static let environment: String = {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .isoLatin1)
        else { return "production" }
        return text.range(of: "<key>aps-environment</key>\\s*<string>development</string>", options: .regularExpression) != nil
            ? "sandbox" : "production"
    }()
}

/// Hands the APNs device token from UIKit to PushRegistration.
final class HubAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        MainActor.assumeIsolated { PushRegistration.shared.didRegister(deviceToken) }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        print("Push registration failed: \(error.localizedDescription)")
    }
}
