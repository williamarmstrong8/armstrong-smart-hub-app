import Foundation
import Observation
import Security
import UIKit

struct HubUser: Codable, Equatable, Sendable {
    let id: String
    let email: String
    let name: String

    var firstName: String { name.split(separator: " ").first.map(String.init) ?? "" }
}

/// Who is signed in, to which hub. The server URL lives in UserDefaults; the
/// session token lives in the Keychain.
@MainActor
@Observable
final class AppSession {
    private(set) var serverURL: URL?
    private(set) var token: String?
    private(set) var user: HubUser?
    private(set) var api: APIClient

    var isSignedIn: Bool { Demo.isOn || (token != nil && serverURL != nil) }

    private static let serverKey = "hub.serverURL"
    private static let userKey = "hub.user"

    init() {
        let url = UserDefaults.standard.string(forKey: Self.serverKey).flatMap(URL.init(string:))
        let token = Keychain.read("token")
        serverURL = url
        self.token = token
        user = UserDefaults.standard.data(forKey: Self.userKey).flatMap { try? JSONDecoder().decode(HubUser.self, from: $0) }
        if Demo.isOn { user = HubUser(id: "demo", email: "alex@riverahome.net", name: "Alex Rivera") }
        api = APIClient(baseURL: url ?? URL(string: "https://localhost")!, token: token)
        wire()
        shareWithWidgets()
        importHistory()
    }

    /// The widgets and controls call the hub with the same sign-in. A token saved before they
    /// existed sits outside the shared Keychain group, so it's saved again once to move it there.
    private func shareWithWidgets() {
        SharedHub.setServerURL(token == nil ? nil : serverURL)
        if let token, SharedHub.token != token { Keychain.write(token, for: "token") }
    }

    /// The old database's history, once it's been exported to the Pi (LocalImport).
    private func importHistory() {
        guard !Demo.isOn, token != nil, serverURL != nil else { return }
        let template = api.request("/api/mobile/import")
        Task.detached(priority: .utility) { await LocalImport.runIfNeeded(template: template) }
    }

    private func wire() {
        api.onUnauthorized = { [weak self] in
            Task { @MainActor in await self?.confirmSignedOut() }
        }
    }

    private var confirming = false

    /// A 401 signs out only once the hub says so twice, a few seconds apart. A hub that's
    /// restarting or briefly can't reach its database mustn't drop the wall iPad (or the
    /// phone) back to the login screen; a session that really ended still does.
    private func confirmSignedOut() async {
        guard !confirming, let url = serverURL, let token else { return }
        confirming = true
        defer { confirming = false }
        try? await Task.sleep(for: .seconds(3))
        // A client without the sign-out hook, so the check can't set off another check.
        let check = APIClient(baseURL: url, token: token)
        var status: Int?
        if let result = try? await URLSession.shared.data(for: check.request("/api/mobile/me", timeout: 15)) {
            let http = result.1 as? HTTPURLResponse
            // Sent to the login page counts as signed out too.
            status = http?.url?.path == "/login" ? 401 : http?.statusCode
        }
        guard status == 401, self.token == token else { return }
        signOutLocally()
    }

    /// Accepts "hub.tail1234.ts.net", "https://…" or "http://localhost:3000".
    static func normalize(_ raw: String) -> URL? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasSuffix("/") { text.removeLast() }
        guard !text.isEmpty else { return nil }
        if !text.contains("://") {
            let local = text.hasPrefix("localhost") || text.hasPrefix("127.") || text.hasPrefix("192.168.")
            text = (local ? "http://" : "https://") + text
        }
        guard let url = URL(string: text), url.host() != nil else { return nil }
        return url
    }

    /// Pairs this device with the hub: a long random key made here, kept in the Keychain and
    /// sent as the bearer token from then on. Pairing again (after signing out) makes a new one.
    func signIn(server: String) async throws {
        guard let url = Self.normalize(server) else { throw APIError(message: "Enter the hub's address.") }
        struct Body: Encodable { let key: String; let device: String }
        struct Reply: Decodable { let token: String?; let user: HubUser?; let error: String? }

        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw APIError(message: "Couldn't make a key for this device.")
        }
        let key = Data(bytes).base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        let client = APIClient(baseURL: url, token: nil)
        let reply: Reply = try await client.post("/api/mobile/login", body: Body(key: key, device: UIDevice.current.name))
        guard let token = reply.token, let user = reply.user else {
            throw APIError(message: reply.error ?? "The hub didn't pair this device.")
        }

        UserDefaults.standard.set(url.absoluteString, forKey: Self.serverKey)
        UserDefaults.standard.set(try? JSONEncoder().encode(user), forKey: Self.userKey)
        Keychain.write(token, for: "token")
        serverURL = url
        self.token = token
        self.user = user
        api = APIClient(baseURL: url, token: token)
        wire()
        shareWithWidgets()
        WidgetSync.reloadAll()
        importHistory()
    }

    func updateUser(_ user: HubUser) {
        self.user = user
        UserDefaults.standard.set(try? JSONEncoder().encode(user), forKey: Self.userKey)
    }

    /// Unpairs this device on the hub, then forgets its key here.
    func signOut() async {
        let _: Empty? = try? await api.post("/api/mobile/logout")
        signOutLocally()
    }

    func signOutLocally() {
        Keychain.delete("token")
        DiskCache.clear()
        token = nil
        api = APIClient(baseURL: serverURL ?? URL(string: "https://localhost")!, token: nil)
        shareWithWidgets()
        WidgetSync.signedOut()
    }

    /// The hub's own web page, for things that need a browser (connecting Google).
    func webURL(_ path: String) -> URL? {
        serverURL.flatMap { URL(string: path, relativeTo: $0)?.absoluteURL }
    }
}
