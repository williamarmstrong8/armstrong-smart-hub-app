import Foundation

struct APIError: LocalizedError {
    let message: String
    var errorDescription: String? { message }

    static let unauthorized = APIError(message: "Your session ended. Sign in again.")
}

/// What every web Server Action returns: `{ ok, data }` or `{ ok: false, error }`.
struct ActionResult<T: Decodable>: Decodable {
    let ok: Bool
    let data: T?
    let error: String?
}

/// The finance tagging actions answer `{ status, message }` instead.
struct StatusResult: Decodable {
    let status: String
    let message: String?
}

/// Decodes and ignores any JSON value.
struct Empty: Decodable {
    init(from decoder: Decoder) throws {}
}

/// Talks to the hub's JSON API with the Keychain session as a bearer token.
/// The web app keeps every secret (Home Assistant, SimpleFIN, Google, the AI
/// Gateway); this only ever holds the hub's own session.
final class APIClient: @unchecked Sendable {
    let baseURL: URL
    let token: String?
    /// Called on any 401, so the app drops back to the login screen.
    var onUnauthorized: (@Sendable () -> Void)?

    static let decoder: JSONDecoder = JSONDecoder()
    static let encoder: JSONEncoder = JSONEncoder()

    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 60
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }()

    init(baseURL: URL, token: String?) {
        self.baseURL = baseURL
        self.token = token
    }

    func request(_ path: String, method: String = "GET", body: (any Encodable)? = nil, timeout: TimeInterval = 60) -> URLRequest {
        var req = URLRequest(url: URL(string: path, relativeTo: baseURL)!.absoluteURL)
        req.httpMethod = method
        req.timeoutInterval = timeout
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try? Self.encoder.encode(AnyEncodable(body))
        }
        return req
    }

    func get<T: Decodable>(_ path: String, as: T.Type = T.self) async throws -> T {
        try await send(request(path))
    }

    func post<T: Decodable>(_ path: String, body: (any Encodable)? = nil, as: T.Type = T.self) async throws -> T {
        try await send(request(path, method: "POST", body: body))
    }

    /// Calls one of the web app's Server Actions by name, through /api/mobile/action.
    func action<T: Decodable>(_ name: String, _ args: [JSONValue] = [], as: T.Type = T.self) async throws -> T {
        try await send(request("/api/mobile/action", method: "POST", body: ActionBody(name: name, args: args), timeout: 60))
    }

    /// Like `action`, but unwraps `{ ok, data, error }` and throws the error text.
    func run<T: Decodable>(_ name: String, _ args: [JSONValue] = [], as: T.Type = T.self) async throws -> T? {
        let result: ActionResult<T> = try await action(name, args)
        if !result.ok { throw APIError(message: result.error ?? "That didn't work.") }
        return result.data
    }

    func send<T: Decodable>(_ req: URLRequest) async throws -> T {
        let data = try await self.data(req)
        do {
            return try Self.decoder.decode(T.self, from: data)
        } catch {
            if let err = try? Self.decoder.decode(ErrorBody.self, from: data), let message = err.error {
                throw APIError(message: message)
            }
            #if DEBUG
            print("Decode failed for \(req.url?.path ?? "?"):", error)
            #endif
            throw APIError(message: "The hub sent something unexpected.")
        }
    }

    /// Network failures worth one more try: the tailnet waking up, Wi-Fi roaming, a dropped socket.
    private static let transient: Set<URLError.Code> = [
        .timedOut, .networkConnectionLost, .cannotConnectToHost, .cannotFindHost,
        .dnsLookupFailed, .notConnectedToInternet, .secureConnectionFailed,
    ]

    /// The response body, once the status and content type check out.
    func data(_ req: URLRequest) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await fetch(req)
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            HubLink.report(ok: false, error: error.localizedDescription)
            throw APIError(message: "Can't reach the hub. Check that you're on the tailnet.")
        }
        HubLink.report(ok: true)
        guard let http = response as? HTTPURLResponse else { throw APIError(message: "No response from the hub.") }
        if http.statusCode == 401 {
            onUnauthorized?()
            if let err = try? Self.decoder.decode(ErrorBody.self, from: data), let message = err.error, message != "unauthorized" {
                throw APIError(message: message)
            }
            throw APIError.unauthorized
        }
        // A redirect to /login means the proxy didn't see a session.
        if http.url?.path == "/login", token != nil {
            onUnauthorized?()
            throw APIError.unauthorized
        }
        // An HTML page where JSON was expected means this hub predates the
        // app's API (the route 404s or redirects to a web page).
        let type = http.value(forHTTPHeaderField: "Content-Type") ?? ""
        if !type.contains("json"), req.url?.path.hasPrefix("/api/") == true {
            let host = req.url?.host() ?? baseURL.absoluteString
            throw APIError(message: "\(host) doesn't have the app's API yet. Sign out and sign in to a hub that does (it needs /api/mobile), then try again.")
        }
        guard (200..<300).contains(http.statusCode) || http.statusCode == 404 || http.statusCode == 400 else {
            if let err = try? Self.decoder.decode(ErrorBody.self, from: data), let message = err.error {
                throw APIError(message: message)
            }
            throw APIError(message: "The hub returned \(http.statusCode).")
        }
        return data
    }

    /// Reads (GETs) that hit a transient network error get one more try after a short pause:
    /// a hiccup shouldn't show as an error, and changes are never sent twice.
    private func fetch(_ req: URLRequest) async throws -> (Data, URLResponse) {
        #if DEBUG
        if Demo.isOn { return await DemoHub.respond(req) }
        #endif
        do {
            return try await session.data(for: req)
        } catch let error as URLError where Self.transient.contains(error.code) && (req.httpMethod ?? "GET") == "GET" {
            try await Task.sleep(for: .seconds(1.5))
            return try await session.data(for: req)
        }
    }

    /// Streams a response line by line (the agent's server-sent events).
    func lines(_ req: URLRequest) async throws -> AsyncLineSequence<URLSession.AsyncBytes> {
        let (bytes, response) = try await session.bytes(for: req)
        guard let http = response as? HTTPURLResponse else { throw APIError(message: "No response from the hub.") }
        if http.statusCode == 401 {
            onUnauthorized?()
            throw APIError.unauthorized
        }
        guard (200..<300).contains(http.statusCode) else { throw APIError(message: "The agent returned \(http.statusCode).") }
        return bytes.lines
    }

    private struct ErrorBody: Decodable { let error: String? }
}

private struct ActionBody: Encodable {
    let name: String
    let args: [JSONValue]
}

private struct AnyEncodable: Encodable {
    let value: any Encodable
    init(_ value: any Encodable) { self.value = value }
    func encode(to encoder: Encoder) throws { try value.encode(to: encoder) }
}
