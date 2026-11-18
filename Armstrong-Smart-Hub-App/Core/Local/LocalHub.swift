import Foundation

/// The hub, inside the app. APIClient asks this first: each route moved off the
/// server answers here from the phone's own database (LocalDB), in exactly the
/// JSON the hub sent, so the screens don't change. A route that isn't here yet
/// (and everything for the lights and TV, which stay on the Pi) goes to the
/// network as before.
///
/// To move a route: add its handler in `routes` (or an action in `actions`),
/// porting the hub's lib code into a `Local*` file next to this one.
nonisolated enum LocalHub {
    struct Request: @unchecked Sendable {
        let method: String
        let path: String
        let query: [String: String]
        /// The decoded JSON body (dictionary, array or scalar), NSNull when there isn't one.
        let body: Any
        /// The body as sent, for uploads that aren't JSON (watch files).
        let raw: Data?
        /// The request as the app made it, for routes that pass part of the work on to the Pi.
        let original: URLRequest

        func param(_ name: String) -> String? { query[name] }
        var object: [String: Any] { body as? [String: Any] ?? [:] }
    }

    struct Reply: @unchecked Sendable {
        let status: Int
        let body: Any

        static func ok(_ body: Any) -> Reply { Reply(status: 200, body: body) }
        static func created(_ body: Any) -> Reply { Reply(status: 201, body: body) }
        static func error(_ message: String, _ status: Int = 400) -> Reply { Reply(status: status, body: ["error": message]) }
        static let done = Reply.ok(["ok": true])
        static let notFound = Reply.error("Not found.", 404)
    }

    typealias Handler = @Sendable (Request) -> Reply
    /// For routes that talk to another service first (SimpleFIN).
    typealias AsyncHandler = @Sendable (Request) async -> Reply
    /// For routes the phone answers only sometimes (Jarvis's tools): nil sends the request on to the Pi.
    typealias MaybeHandler = @Sendable (Request) async -> Reply?

    /// "METHOD /path" → handler.
    private static let routes: [String: Handler] = {
        var r: [String: Handler] = [:]
        LocalTodos.register(&r)
        LocalHabits.register(&r)
        LocalDrinks.register(&r)
        LocalWorkouts.register(&r)
        LocalFitness.register(&r)
        LocalFinance.register(&r)
        LocalContext.register(&r)
        return r
    }()

    private static let asyncRoutes: [String: AsyncHandler] = {
        var r: [String: AsyncHandler] = [:]
        LocalFinance.registerAsync(&r)
        LocalCalendar.registerAsync(&r)
        LocalWeather.registerAsync(&r)
        LocalContext.registerAsync(&r)
        return r
    }()

    private static let maybeRoutes: [String: MaybeHandler] = {
        var r: [String: MaybeHandler] = [:]
        LocalJarvis.registerMaybe(&r)
        LocalHome.registerMaybe(&r)
        return r
    }()

    /// Server Action name → handler taking the action's arguments, answering `{ ok, data }` or `{ ok: false, error }`.
    private static let actions: [String: @Sendable ([Any]) -> Any] = {
        var a: [String: @Sendable ([Any]) -> Any] = [:]
        LocalHabits.registerActions(&a)
        LocalFinance.registerActions(&a)
        LocalHome.registerActions(&a)
        return a
    }()

    /// Answers a request locally, or nil when it still belongs to a server.
    ///
    /// All of it runs off the main thread. A nonisolated async function runs on its caller's
    /// actor (approachable concurrency), and APIClient calls from the main actor, so reading the
    /// body and writing the answer as JSON (a fitness snapshot is hundreds of kilobytes) used to
    /// block scrolling while a page loaded.
    static func respond(_ req: URLRequest) async -> (Data, URLResponse)? {
        await Task.detached(priority: .userInitiated) { await answer(req) }.value
    }

    private static func answer(_ req: URLRequest) async -> (Data, URLResponse)? {
        guard let url = req.url else { return nil }
        let method = (req.httpMethod ?? "GET").uppercased()
        let path = url.path
        let isJSON = (req.value(forHTTPHeaderField: "Content-Type") ?? "application/json").contains("json")
        let body = isJSON ? req.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0, options: [.fragmentsAllowed]) } ?? NSNull() : NSNull()

        let reply: Reply
        if path == "/api/mobile/action", method == "POST" {
            let call = body as? [String: Any] ?? [:]
            guard let name = call["name"] as? String, let action = actions[name] else { return nil }
            let args = call["args"] as? [Any] ?? []
            reply = .ok(await run { action(args) })
        } else {
            let key = "\(method) \(path)"
            let handler = routes[key]
            let asyncHandler = asyncRoutes[key]
            let maybeHandler = maybeRoutes[key]
            guard handler != nil || asyncHandler != nil || maybeHandler != nil else { return nil }
            var query: [String: String] = [:]
            for item in URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [] {
                query[item.name] = item.value ?? ""
            }
            let request = Request(method: method, path: path, query: query, body: body, raw: req.httpBody, original: req)
            if let handler {
                reply = await run { handler(request) }
            } else if let asyncHandler {
                reply = await Task.detached(priority: .userInitiated) { await asyncHandler(request) }.value
            } else {
                guard let answer = await Task.detached(priority: .userInitiated, operation: { await maybeHandler!(request) }).value else { return nil }
                reply = answer
            }
        }

        let data = (try? JSONSerialization.data(withJSONObject: reply.body, options: [.fragmentsAllowed])) ?? Data("{}".utf8)
        let response = HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
        return (data, response)
    }

    /// Database work runs off the main thread.
    private static func run<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await Task.detached(priority: .userInitiated) { work() }.value
    }

    // MARK: Passing on to the Pi

    /// Sends a request to the hub the app is signed in to (the Pi), with the app's session,
    /// at `path` (the original path when nil) with a JSON `body` (the original body when nil).
    static func forward(_ original: URLRequest, path: String? = nil, method: String? = nil, body: Any? = nil,
                        timeout: TimeInterval = 60) async throws -> (Data, HTTPURLResponse) {
        guard let url = original.url, var c = URLComponents(url: url, resolvingAgainstBaseURL: false) else { throw URLError(.badURL) }
        if let path {
            let parts = path.split(separator: "?", maxSplits: 1).map(String.init)
            c.path = parts[0]
            c.percentEncodedQuery = parts.count > 1 ? parts[1] : nil
        }
        guard let target = c.url else { throw URLError(.badURL) }
        var request = URLRequest(url: target, timeoutInterval: timeout)
        request.httpMethod = method ?? original.httpMethod ?? "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let auth = original.value(forHTTPHeaderField: "Authorization") { request.setValue(auth, forHTTPHeaderField: "Authorization") }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        } else if path == nil {
            request.httpBody = original.httpBody
            if original.httpBody != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http)
    }

    /// A forwarded JSON answer, passed through as this route's reply.
    static func forwardJSON(_ original: URLRequest, path: String? = nil, method: String? = nil, body: Any? = nil,
                            timeout: TimeInterval = 60) async -> Reply {
        do {
            let (data, http) = try await forward(original, path: path, method: method, body: body, timeout: timeout)
            let value = (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) ?? ["error": "The Pi sent something unexpected."]
            return Reply(status: http.statusCode, body: value)
        } catch {
            return .error("Can't reach the Pi. Check that you're on the tailnet.", 502)
        }
    }

    // MARK: Helpers for handlers

    static var db: LocalDB { .shared }

    static func isUUID(_ s: String?) -> Bool {
        guard let s else { return false }
        return s.range(of: "^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$", options: .regularExpression) != nil
    }
    static func isDay(_ s: String?) -> Bool {
        guard let s else { return false }
        return s.range(of: "^[0-9]{4}-[0-9]{2}-[0-9]{2}$", options: .regularExpression) != nil
    }

    /// A JSON number as Double (JSONSerialization gives NSNumber; Bools are excluded).
    static func number(_ v: Any?) -> Double? {
        guard let n = v as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
        return n.doubleValue
    }
    static func int(_ v: Any?) -> Int? { number(v).map { Int($0) } }
    static func string(_ v: Any?) -> String? { v as? String }
    static func bool(_ v: Any?) -> Bool? {
        guard let n = v as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() else { return nil }
        return n.boolValue
    }

    /// Swift optionals as JSON null.
    static func orNull(_ v: Any?) -> Any { v ?? NSNull() }

    /// A row's value that's NSNull when missing (SQLite NULL already is).
    static func value(_ row: LocalDB.Row, _ key: String) -> Any { row[key] ?? NSNull() }

    static func actionOK(_ data: Any? = nil) -> [String: Any] {
        var out: [String: Any] = ["ok": true]
        if let data { out["data"] = data }
        return out
    }
    static func actionError(_ message: String) -> [String: Any] { ["ok": false, "error": message] }
}
