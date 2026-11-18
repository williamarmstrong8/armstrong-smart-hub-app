import Foundation
import Security

/// Google Calendar, from the phone (was lib/google-calendar.ts, lib/google-ios.ts
/// and /api/mobile/calendar, /api/mobile/google/link). GoogleSignIn's one-time
/// code is traded here with Google's iOS client (PKCE, no secret), the tokens
/// stay in the Keychain, and the agenda is read straight from Google.
///
/// Days are the phone's own time zone (the hub used America/New_York).
nonisolated enum LocalCalendar {
    static let clientID = "1054880549796-srql0pu9h4ku37t2delvuhuqkk82corj.apps.googleusercontent.com"
    static let readScope = "https://www.googleapis.com/auth/calendar.readonly"
    static let upcomingDays = 14

    static func registerAsync(_ r: inout [String: LocalHub.AsyncHandler]) {
        r["POST /api/mobile/google/link"] = { req in
            let o = req.object
            guard let code = o["code"] as? String, let verifier = o["codeVerifier"] as? String, let redirect = o["redirectUri"] as? String else {
                return .error("Not a valid request.")
            }
            do {
                try await link(code: code, verifier: verifier, redirect: redirect)
                cache.clear()
                return .done
            } catch {
                return .error((error as? Failure)?.message ?? "Couldn't connect Google.", 502)
            }
        }
        r["GET /api/mobile/calendar"] = { req in
            if req.param("refresh") != nil { cache.clear() }
            return .ok(await agenda())
        }
    }

    // MARK: Agenda (GET /api/mobile/calendar)

    static var timeZone: TimeZone { .current }

    static func day(_ date: Date) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        return LocalDB.day(date, calendar: cal)
    }

    static func agenda(now: Date = Date()) async -> [String: Any] {
        let base: [String: Any] = ["timeZone": timeZone.identifier, "upcomingDays": upcomingDays]
        let status = GoogleCredential.status()
        guard status == "connected" else { return base.merging(["status": status, "days": [Any]()]) { $1 } }
        let today = day(now)
        let events: [[String: Any]]
        do {
            events = try await upcoming(from: today).filter { notOver($0, now) }
        } catch let failure as Failure {
            if failure.status != "failed" { return base.merging(["status": "missing_scope", "days": [Any]()]) { $1 } }
            return base.merging(["status": status, "days": [Any](), "error": failure.message]) { $1 }
        } catch {
            return base.merging(["status": status, "days": [Any](), "error": "Couldn't load your calendar."]) { $1 }
        }
        let until = day(now.addingTimeInterval(Double(upcomingDays - 1) * 86_400))
        var byDay: [String: [[String: Any]]] = [:]
        for event in events {
            for d in eventDays(event) where d >= today && d <= until { byDay[d, default: []].append(event) }
        }
        let days = byDay.keys.sorted().map { d -> [String: Any] in
            // All-day first, otherwise in the order Google gave (soonest first).
            let list = byDay[d]!.enumerated().sorted { a, b in
                let (x, y) = ((a.element["allDay"] as? Bool) == true, (b.element["allDay"] as? Bool) == true)
                return x != y ? x : a.offset < b.offset
            }.map(\.element)
            return ["day": d, "events": list]
        }
        return base.merging(["status": status, "today": today, "days": days]) { $1 }
    }

    /// The local calendar days an event covers (an all-day event's end date is exclusive).
    static func eventDays(_ event: [String: Any]) -> [String] {
        let start = event["start"] as? String ?? ""
        guard (event["allDay"] as? Bool) == true else { return LocalDB.date(start).map { [day($0)] } ?? [] }
        let end = event["end"] as? String ?? ""
        var out: [String] = []
        var d = start
        for i in 0..<60 {
            if d >= end && i > 0 { break }
            out.append(d)
            d = LocalDB.addDays(d, 1)
        }
        return out
    }

    /// Timed events until they end, all-day ones through their last day.
    static func notOver(_ event: [String: Any], _ now: Date) -> Bool {
        let end = event["end"] as? String ?? ""
        if (event["allDay"] as? Bool) == true { return end > day(now) }
        return (LocalDB.date(end) ?? .distantPast) > now
    }

    /// The agenda from the day before `day` through the next two weeks, kept for a minute.
    static func upcoming(from day: String) async throws -> [[String: Any]] {
        if let hit = cache.get(day) { return hit }
        guard let start = LocalDB.date("\(day)T00:00:00Z") else { return [] }
        let events = try await listEvents(from: start.addingTimeInterval(-86_400), to: start.addingTimeInterval(Double(upcomingDays + 1) * 86_400))
        cache.put(day, events)
        return events
    }

    // MARK: Google

    struct Failure: Error {
        let message: String
        /// not_connected, missing_scope or failed, like the hub's CalendarError.
        let status: String
    }

    /// Events from every calendar ticked in Google Calendar (and Birthdays), soonest first.
    static func listEvents(from: Date, to: Date) async throws -> [[String: Any]] {
        let token = try await GoogleCredential.accessToken()
        let list = try await google(token, "users/me/calendarList", ["minAccessRole": "reader"])
        let calendars = (list["items"] as? [[String: Any]] ?? []).filter { c in
            (c["selected"] as? Bool) == true || (c["primary"] as? Bool) == true || isBirthdays(c)
        }
        let iso = { (d: Date) in LocalDB.iso(d) }
        let perCalendar = try await withThrowingTaskGroup(of: (Int, [[String: Any]]).self) { group in
            for (index, cal) in calendars.enumerated() {
                group.addTask {
                    let id = cal["id"] as? String ?? ""
                    let path = "calendars/\(id.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? id)/events"
                    let page = try await google(token, path, ["timeMin": iso(from), "timeMax": iso(to), "singleEvents": "true",
                                                              "orderBy": "startTime", "maxResults": "250"])
                    let events = (page["items"] as? [[String: Any]] ?? []).compactMap { e -> [String: Any]? in
                        if (e["status"] as? String) == "cancelled" { return nil }
                        let declined = (e["attendees"] as? [[String: Any]] ?? []).contains {
                            ($0["self"] as? Bool) == true && ($0["responseStatus"] as? String) == "declined"
                        }
                        if declined { return nil }
                        let start = e["start"] as? [String: Any] ?? [:], end = e["end"] as? [String: Any] ?? [:]
                        let title = (e["summary"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                        let location = (e["location"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                        return [
                            "id": "\(id):\(e["id"] as? String ?? "")",
                            "title": (title?.isEmpty ?? true) ? "(No title)" : title!,
                            "start": start["dateTime"] ?? start["date"] ?? "",
                            "end": end["dateTime"] ?? end["date"] ?? "",
                            "allDay": start["dateTime"] == nil,
                            "location": (location?.isEmpty ?? true) ? NSNull() : location!,
                            "calendar": cal["summaryOverride"] ?? cal["summary"] ?? "Calendar",
                            "color": cal["backgroundColor"] ?? "#4285F4",
                            "url": e["htmlLink"] ?? NSNull(),
                            "birthday": (e["eventType"] as? String) == "birthday" || isBirthdays(cal),
                        ]
                    }
                    return (index, events)
                }
            }
            var out: [(Int, [[String: Any]])] = []
            for try await result in group { out.append(result) }
            return out.sorted { $0.0 < $1.0 }.flatMap(\.1)
        }
        // All-day events sort as the start of their day (in UTC, like the hub's Date parse).
        func key(_ e: [String: Any]) -> Date {
            let start = e["start"] as? String ?? ""
            return LocalDB.date((e["allDay"] as? Bool) == true ? "\(start)T00:00:00Z" : start) ?? .distantPast
        }
        return perCalendar.enumerated().sorted { a, b in
            let (x, y) = (key(a.element), key(b.element))
            return x != y ? x < y : a.offset < b.offset
        }.map(\.element)
    }

    /// Google's Birthdays calendar, made from your contacts.
    static func isBirthdays(_ c: [String: Any]) -> Bool { (c["id"] as? String ?? "").contains("#contacts@") }

    static func google(_ token: String, _ path: String, _ params: [String: String]) async throws -> [String: Any] {
        var c = URLComponents(string: "https://www.googleapis.com/calendar/v3/\(path)")!
        c.queryItems = params.map { URLQueryItem(name: $0.key, value: $0.value) }
        var request = URLRequest(url: c.url!, timeoutInterval: 30)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 || status == 403 {
            throw Failure(message: "Google refused calendar access. Reconnect Google on the Calendar page.", status: "missing_scope")
        }
        guard (200..<300).contains(status) else { throw Failure(message: "Google Calendar returned \(status).", status: "failed") }
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    /// Trades the app's authorization code for tokens and keeps them.
    static func link(code: String, verifier: String, redirect: String) async throws {
        let t = try await GoogleCredential.tokenRequest(["grant_type": "authorization_code", "code": code,
                                                         "code_verifier": verifier, "redirect_uri": redirect])
        guard let access = t["access_token"] as? String else { throw Failure(message: "Google didn't return an access token.", status: "failed") }
        // Google only sends a refresh token on consent; keep the old one if this reply has none.
        guard let refresh = (t["refresh_token"] as? String) ?? GoogleCredential.read()?.refresh else {
            throw Failure(message: "Google didn't return a refresh token. Try connecting again.", status: "failed")
        }
        GoogleCredential.write(.init(refresh: refresh, access: access,
                                     expiresAt: Date().addingTimeInterval(LocalHub.number(t["expires_in"]) ?? 3600).timeIntervalSince1970,
                                     scope: t["scope"] as? String))
    }

    // MARK: Cache

    final class Cache: @unchecked Sendable {
        private let lock = NSLock()
        private var entry: (day: String, at: Date, events: [[String: Any]])?
        func get(_ day: String) -> [[String: Any]]? {
            lock.lock(); defer { lock.unlock() }
            guard let e = entry, e.day == day, Date().timeIntervalSince(e.at) < 60 else { return nil }
            return e.events
        }
        func put(_ day: String, _ events: [[String: Any]]) { lock.lock(); entry = (day, Date(), events); lock.unlock() }
        func clear() { lock.lock(); entry = nil; lock.unlock() }
    }

    static let cache = Cache()
}

/// The Google tokens from the app's own sign-in, in the Keychain only.
nonisolated enum GoogleCredential {
    struct Tokens: Codable {
        var refresh: String
        var access: String?
        /// Epoch seconds.
        var expiresAt: Double?
        var scope: String?
    }

    private static let service = "com.armstrong.hub.google"
    private static let account = "calendar"
    private static func base() -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    static func read() -> Tokens? {
        var query = base()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return try? JSONDecoder().decode(Tokens.self, from: data)
    }

    static func write(_ tokens: Tokens) {
        SecItemDelete(base() as CFDictionary)
        var query = base()
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        query[kSecValueData as String] = (try? JSONEncoder().encode(tokens)) ?? Data()
        SecItemAdd(query as CFDictionary, nil)
    }

    static func delete() { SecItemDelete(base() as CFDictionary) }

    /// connected, not_connected or missing_scope.
    static func status() -> String {
        guard let tokens = read() else { return "not_connected" }
        let scopes = (tokens.scope ?? "").split(whereSeparator: { $0 == " " || $0 == "," }).map(String.init)
        return scopes.contains(LocalCalendar.readScope) ? "connected" : "missing_scope"
    }

    /// A fresh access token, refreshed when it's within a minute of expiring.
    static func accessToken() async throws -> String {
        guard var tokens = read() else {
            throw LocalCalendar.Failure(message: "Google Calendar isn't connected yet. Connect it on the Calendar page.", status: "not_connected")
        }
        if let access = tokens.access, let exp = tokens.expiresAt, exp - Date().timeIntervalSince1970 > 60 { return access }
        do {
            let t = try await tokenRequest(["grant_type": "refresh_token", "refresh_token": tokens.refresh])
            guard let access = t["access_token"] as? String else { throw URLError(.badServerResponse) }
            tokens.access = access
            tokens.expiresAt = Date().addingTimeInterval(LocalHub.number(t["expires_in"]) ?? 3600).timeIntervalSince1970
            write(tokens)
            return access
        } catch {
            throw LocalCalendar.Failure(message: "Google sign-in expired. Reconnect Google on the Calendar page.", status: "missing_scope")
        }
    }

    static func tokenRequest(_ params: [String: String]) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        // Strict form encoding: only unreserved characters go through as they are.
        let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        let form = (["client_id": LocalCalendar.clientID].merging(params) { $1 })
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? "")" }
            .joined(separator: "&")
        request.httpBody = Data(form.utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        let body = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        guard ((response as? HTTPURLResponse)?.statusCode ?? 0) < 300 else {
            throw LocalCalendar.Failure(message: (body["error_description"] ?? body["error"]) as? String ?? "Google refused the sign-in.", status: "failed")
        }
        return body
    }
}
