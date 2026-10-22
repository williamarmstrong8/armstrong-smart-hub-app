import Foundation
import Security

// Shared by the app and the WorkoutWidgets extension: the hub sign-in as the
// widgets and controls see it, and a small client for them to call the hub
// with. The app writes the sign-in; the extension only reads it.

/// The server address lives in the app group's defaults; the session token in
/// the Keychain under the app group's access group, so the extension can read it.
nonisolated enum SharedHub {
    static let appGroup = WorkoutSnapshot.appGroup
    /// The app's own Keychain service (Keychain.swift), so there's one copy of the token.
    static let keychainService = "com.armstrong.hub.session"
    static let tokenAccount = "token"

    static var defaults: UserDefaults? { UserDefaults(suiteName: appGroup) }
    private static let serverKey = "hub.serverURL"

    static var serverURL: URL? { defaults?.string(forKey: serverKey).flatMap(URL.init(string:)) }

    static func setServerURL(_ url: URL?) {
        if let url { defaults?.set(url.absoluteString, forKey: serverKey) } else { defaults?.removeObject(forKey: serverKey) }
    }

    static var token: String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: tokenAccount,
            kSecAttrAccessGroup as String: appGroup,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// A file in the app group's container (the TV poster for the Live Activity).
    static func file(_ name: String) -> URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)?.appending(path: name)
    }
}

/// A Server Action argument, like the app's JSONValue.
nonisolated enum HubArg: Encodable, Sendable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case array([HubArg])
    case object([String: HubArg])

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let v): try c.encode(v)
        case .int(let v): try c.encode(v)
        case .double(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        }
    }
}

nonisolated struct HubCallError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Decodes and ignores any JSON value.
nonisolated struct HubNothing: Decodable, Sendable {
    init(from decoder: Decoder) throws {}
}

nonisolated private struct HubActionBody: Encodable {
    let name: String
    let args: [HubArg]
}

nonisolated private struct HubActionReply<T: Decodable>: Decodable {
    let ok: Bool
    let data: T?
    let error: String?
}

/// Talks to the hub from a widget or control with the shared sign-in.
nonisolated struct HubCall: Sendable {
    let baseURL: URL
    let token: String

    /// nil until the app has signed in (and shared the sign-in) once.
    static var current: HubCall? {
        guard let url = SharedHub.serverURL, let token = SharedHub.token else { return nil }
        return HubCall(baseURL: url, token: token)
    }

    func get<T: Decodable>(_ path: String, as: T.Type = T.self) async throws -> T {
        try decode(try await send(path, method: "GET", body: nil))
    }

    /// Calls a Server Action through /api/mobile/action and unwraps `{ ok, data, error }`.
    func run<T: Decodable>(_ name: String, _ args: [HubArg] = [], as: T.Type = T.self) async throws -> T? {
        let body = try JSONEncoder().encode(HubActionBody(name: name, args: args))
        let reply: HubActionReply<T> = try decode(try await send("/api/mobile/action", method: "POST", body: body))
        if !reply.ok { throw HubCallError(message: reply.error ?? "That didn't work.") }
        return reply.data
    }

    private func send(_ path: String, method: String, body: Data?) async throws -> Data {
        var req = URLRequest(url: URL(string: path, relativeTo: baseURL)!.absoluteURL)
        req.httpMethod = method
        // Widgets get a few seconds to answer; a hub off the tailnet must fail fast.
        req.timeoutInterval = 12
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = body
        }
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw HubCallError(message: "No response from the hub.") }
        if http.statusCode == 401 { throw HubCallError(message: "Sign in to the app again.") }
        guard (200..<300).contains(http.statusCode) else { throw HubCallError(message: "The hub returned \(http.statusCode).") }
        return data
    }

    private func decode<T: Decodable>(_ data: Data) throws -> T {
        do { return try JSONDecoder().decode(T.self, from: data) } catch { throw HubCallError(message: "The hub sent something unexpected.") }
    }
}
