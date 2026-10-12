import Foundation
import Observation

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

    var isSignedIn: Bool { token != nil && serverURL != nil }

    private static let serverKey = "hub.serverURL"
    private static let userKey = "hub.user"

    init() {
        let url = UserDefaults.standard.string(forKey: Self.serverKey).flatMap(URL.init(string:))
        let token = Keychain.read("token")
        serverURL = url
        self.token = token
        user = UserDefaults.standard.data(forKey: Self.userKey).flatMap { try? JSONDecoder().decode(HubUser.self, from: $0) }
        api = APIClient(baseURL: url ?? URL(string: "https://localhost")!, token: token)
        wire()
    }

    private func wire() {
        api.onUnauthorized = { [weak self] in
            Task { @MainActor in self?.signOutLocally() }
        }
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

    func signIn(server: String, email: String, password: String) async throws {
        guard let url = Self.normalize(server) else { throw APIError(message: "Enter the hub's address.") }
        struct Body: Encodable { let email: String; let password: String }
        struct Reply: Decodable { let token: String?; let user: HubUser?; let error: String? }

        let client = APIClient(baseURL: url, token: nil)
        let reply: Reply = try await client.post("/api/mobile/login", body: Body(email: email, password: password))
        guard let token = reply.token, let user = reply.user else {
            throw APIError(message: reply.error ?? "That email and password didn't match.")
        }

        UserDefaults.standard.set(url.absoluteString, forKey: Self.serverKey)
        UserDefaults.standard.set(try? JSONEncoder().encode(user), forKey: Self.userKey)
        Keychain.write(token, for: "token")
        serverURL = url
        self.token = token
        self.user = user
        api = APIClient(baseURL: url, token: token)
        wire()
    }

    func updateUser(_ user: HubUser) {
        self.user = user
        UserDefaults.standard.set(try? JSONEncoder().encode(user), forKey: Self.userKey)
    }

    /// Revokes the session on the hub, then forgets it here.
    func signOut() async {
        let _: Empty? = try? await api.post("/api/mobile/logout")
        signOutLocally()
    }

    func signOutLocally() {
        Keychain.delete("token")
        token = nil
        api = APIClient(baseURL: serverURL ?? URL(string: "https://localhost")!, token: nil)
    }

    /// The hub's own web page, for things that need a browser (connecting Google).
    func webURL(_ path: String) -> URL? {
        serverURL.flatMap { URL(string: path, relativeTo: $0)?.absoluteURL }
    }
}
