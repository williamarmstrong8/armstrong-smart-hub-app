import Foundation
import SQLite3

/// Jarvis's chat (was app/api/mobile/agent and lib/agent/sql.ts): the tool loop runs on
/// the phone, against the phone's own data. Each model step goes through the Pi's
/// /api/mobile/llm relay (the Pi keeps the AI Gateway key and reads no data); the
/// device tools (lights, automations, TV, media, skills) run on the Pi through
/// /api/mobile/agent/tool. Everything else runs here.
///
/// `stream` yields the same newline-delimited JSON events the hub's agent route sent,
/// so AgentStore reads it the same way.
nonisolated enum LocalAgent {
    static let maxSteps = 16

    /// One turn. `template` is any request built by the app's APIClient (it carries the Pi's address and session).
    static func stream(history: [[String: String]], model: String, template: URLRequest) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task.detached(priority: .userInitiated) {
                func send(_ event: [String: Any]) {
                    if let data = try? JSONSerialization.data(withJSONObject: event), let line = String(data: data, encoding: .utf8) {
                        continuation.yield(line)
                    }
                }
                do {
                    try await turn(history: history, model: model, template: template, send: send)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    static func turn(history: [[String: String]], model: String, template: URLRequest, send: ([String: Any]) -> Void) async throws {
        var messages: [[String: Any]] = history.map { ["role": $0["role"] ?? "user", "content": $0["content"] ?? ""] }
        let device = await deviceTools(template)
        var tools = localTools
        for (name, def) in device.tools { tools[name] = def }
        let system = instructions(skills: device.skills)

        for _ in 0..<maxSteps {
            try Task.checkCancellation()
            var request = try relayRequest(template, body: [
                "model": model, "system": system, "messages": messages, "tools": tools, "tags": ["agent", "iphone"],
            ])
            request.setValue("application/x-ndjson", forHTTPHeaderField: "Accept")
            let (bytes, response) = try await URLSession.shared.bytes(for: request)
            guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
            guard http.statusCode == 200 else {
                var raw = ""
                for try await line in bytes.lines { raw += line }
                let message = (try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any])?["error"] as? String
                send(["t": "error", "m": message ?? "The Pi couldn't reach the model (\(http.statusCode))."])
                break
            }
            var text = ""
            var calls: [(id: String, name: String, input: Any)] = []
            var failed = false
            for try await line in bytes.lines {
                guard let event = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any], let kind = event["t"] as? String else { continue }
                switch kind {
                case "text":
                    if let d = event["d"] as? String { text += d; send(event) }
                case "call":
                    calls.append((event["id"] as? String ?? UUID().uuidString, event["name"] as? String ?? "", event["input"] ?? [String: Any]()))
                case "cost": send(event)
                case "error": send(event); failed = true
                default: break
                }
            }
            if failed || calls.isEmpty { break }

            var content: [[String: Any]] = []
            if !text.isEmpty { content.append(["type": "text", "text": text]) }
            for c in calls { content.append(["type": "tool-call", "toolCallId": c.id, "toolName": c.name, "input": c.input]) }
            messages.append(["role": "assistant", "content": content])
            var results: [[String: Any]] = []
            for c in calls {
                send(["t": "tool", "id": c.id, "name": c.name, "label": (c.input as? [String: Any])?["purpose"] ?? NSNull()])
                let output = device.tools[c.name] != nil
                    ? await runDevice(c.name, c.input, template)
                    : await runLocal(c.name, c.input as? [String: Any] ?? [:])
                send(["t": "toolDone", "id": c.id])
                results.append(["type": "tool-result", "toolCallId": c.id, "toolName": c.name, "output": ["type": "json", "value": output]])
            }
            messages.append(["role": "tool", "content": results])
        }
        send(["t": "answered"])
        send(["t": "done"])
    }

    static func relayRequest(_ template: URLRequest, body: [String: Any]) throws -> URLRequest {
        guard let url = template.url, var c = URLComponents(url: url, resolvingAgainstBaseURL: false) else { throw URLError(.badURL) }
        c.path = "/api/mobile/llm"
        c.query = nil
        var request = URLRequest(url: c.url!, timeoutInterval: 300)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let auth = template.value(forHTTPHeaderField: "Authorization") { request.setValue(auth, forHTTPHeaderField: "Authorization") }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    // MARK: Device tools (on the Pi)

    final class DeviceCache: @unchecked Sendable {
        private let lock = NSLock()
        private var value: (tools: [String: Any], skills: String)?
        func get() -> (tools: [String: Any], skills: String)? { lock.lock(); defer { lock.unlock() }; return value }
        func put(_ v: (tools: [String: Any], skills: String)) { lock.lock(); value = v; lock.unlock() }
    }
    static let deviceCache = DeviceCache()

    /// The Pi's device tool definitions and skills index; without the Pi, chat still answers from the phone's data.
    static func deviceTools(_ template: URLRequest) async -> (tools: [String: Any], skills: String) {
        if let hit = deviceCache.get() { return hit }
        guard let (data, http) = try? await LocalHub.forward(template, path: "/api/mobile/agent/tool", method: "GET", timeout: 15),
              http.statusCode == 200, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return ([:], "") }
        let value = (json["tools"] as? [String: Any] ?? [:], json["skills"] as? String ?? "")
        deviceCache.put(value)
        return value
    }

    static func runDevice(_ name: String, _ input: Any, _ template: URLRequest) async -> Any {
        guard let (data, _) = try? await LocalHub.forward(template, path: "/api/mobile/agent/tool", method: "POST",
                                                          body: ["name": name, "input": input], timeout: 60),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return ["error": "Can't reach the Pi for that."]
        }
        return json["output"] ?? json
    }

    // MARK: Local tools

    static let localTools: [String: Any] = [
        "describeSchema": [
            "description": "List every table the phone's database has that you may query, with columns, types and row counts. Call this first before writing SQL, and again if a query fails on a missing column.",
            "parameters": ["type": "object", "properties": [String: Any]()],
        ],
        "queryDatabase": [
            "description": "Run one read-only SQL SELECT (SQLite) against the phone's database and get rows back (at most \(ReadOnly.maxRows)). Use it for anything about stored data: spending, transactions, fitness, sleep, HRV, workouts, habits, check-ins, drinks, todos. Do the math in SQL (aggregate, group, window functions, strftime, date) rather than pulling rows to add up yourself. Select only the columns you need. On an error, read the message, fix the query and try again.",
            "parameters": [
                "type": "object", "required": ["sql"],
                "properties": [
                    "sql": ["type": "string", "description": "One SQLite SELECT or WITH ... SELECT statement."],
                    "purpose": ["type": "string", "description": "Five words on what this answers, shown to the user."],
                ],
            ],
        ],
        "getFinanceSummary": [
            "description": "Net worth, assets, debts, 30-day income/spending, every account balance and the top spending categories. Amounts are in the account currency.",
            "parameters": ["type": "object", "properties": [String: Any]()],
        ],
        "searchTransactions": [
            "description": "Search recent transactions by text and/or category. Negative amounts are money out.",
            "parameters": [
                "type": "object",
                "properties": [
                    "text": ["type": "string", "description": "Matches description, payee or account name, case-insensitive"],
                    "category": ["type": "string"],
                    "days": ["type": "integer", "minimum": 1, "maximum": 365, "default": 30],
                    "limit": ["type": "integer", "minimum": 1, "maximum": 100, "default": 25],
                ],
            ],
        ],
        "getCalendarEvents": [
            "description": "Events from the user's Google Calendar (all calendars they show), soonest first, in the phone's time zone. Use for \"what's on today\", \"am I free Thursday\", \"when is my next…\".",
            "parameters": [
                "type": "object",
                "properties": [
                    "daysAhead": ["type": "integer", "minimum": 1, "maximum": 60, "default": 7, "description": "How many days from now to include"],
                    "daysBack": ["type": "integer", "minimum": 0, "maximum": 30, "default": 0, "description": "Also include this many past days"],
                    "text": ["type": "string", "description": "Only events whose title or location contains this, case-insensitive"],
                ],
            ],
        ],
    ]

    static func runLocal(_ name: String, _ input: [String: Any]) async -> Any {
        switch name {
        case "describeSchema": return ["tables": ReadOnly.schema()]
        case "queryDatabase": return ReadOnly.query(input["sql"] as? String ?? "")
        case "getFinanceSummary":
            guard SimpleFinCredential.read() != nil else { return ["error": "SimpleFIN isn't configured."] }
            return HubJS.finance.call("financeSummary", ["rows": LocalFinance.dashboardInput()]) ?? ["error": "Couldn't load finances."]
        case "searchTransactions":
            guard SimpleFinCredential.read() != nil else { return ["error": "SimpleFIN isn't configured."] }
            var args = input
            args["rows"] = LocalFinance.dashboardInput()
            return HubJS.finance.call("searchTransactions", args) ?? ["error": "Couldn't load transactions."]
        case "getCalendarEvents":
            let ahead = Double(min(max(LocalHub.int(input["daysAhead"]) ?? 7, 1), 60)), back = Double(min(max(LocalHub.int(input["daysBack"]) ?? 0, 0), 30))
            do {
                let events = try await LocalCalendar.listEvents(from: Date().addingTimeInterval(-back * 86_400), to: Date().addingTimeInterval(ahead * 86_400))
                let needle = (input["text"] as? String)?.lowercased()
                let f = DateFormatter()
                f.locale = Locale(identifier: "en_US")
                f.timeZone = LocalCalendar.timeZone
                f.dateFormat = "EEE, MMM d, h:mm a"
                let local = { (s: Any?) in LocalDB.date(s as? String).map(f.string) ?? "" }
                return ["events": events.filter { e in
                    guard let needle else { return true }
                    return "\(e["title"] ?? "") \(e["location"] as? String ?? "")".lowercased().contains(needle)
                }.prefix(100).map { e -> [String: Any] in
                    var out: [String: Any] = ["title": e["title"] ?? "", "calendar": e["calendar"] ?? ""]
                    if (e["allDay"] as? Bool) == true {
                        out["allDay"] = true; out["date"] = e["start"]; out["endDateExclusive"] = e["end"]
                    } else {
                        out["start"] = local(e["start"]); out["end"] = local(e["end"])
                    }
                    if let location = e["location"] as? String { out["location"] = location }
                    return out
                }]
            } catch let failure as LocalCalendar.Failure {
                return ["error": failure.message]
            } catch {
                return ["error": "Couldn't load the calendar."]
            }
        default:
            return ["error": "Unknown tool \(name)."]
        }
    }

    // MARK: Instructions

    static func instructions(skills: String) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US")
        f.timeZone = LocalCalendar.timeZone
        f.dateStyle = .full
        f.timeStyle = .short
        let tz = LocalCalendar.timeZone.identifier
        return """
        You are Jarvis, the data analyst inside William's personal hub, answering on his iPhone. It is \(f.string(from: Date())) (\(tz)).

        The phone stores his money, fitness (Garmin watch), workouts, sleep, habits, check-ins, drinks, diet and todos in a SQLite database. You can query it with queryDatabase, and you can also use the other tools (finance summary, transactions, calendar, smart home, media).

        Database tables you may use:
        \(ReadOnly.schema())

        How to work:
        - Answer questions about his data and trends by querying it. Think about what to measure, write the SQL, check the result, and explain what it means in plain words. Run several queries when the question needs it (a trend, a comparison, a correlation).
        - This is SQLite, not Postgres: no date_trunc, generate_series, percentile_cont or corr. Use strftime, date(), julianday(), window functions (lag, avg over), recursive CTEs for date series, and compute correlations from sums when needed.
        - Times: columns ending _time, _at, at (text), posted, day and night are ISO-8601 text. Timestamps are UTC ("2026-11-17T14:03:00.000Z"); group by local day with date(x, 'localtime'). day and night columns are already local "YYYY-MM-DD".
        - fitness_heart_rate, fitness_vitals and fitness_watch_metrics store at as epoch milliseconds: use datetime(at / 1000, 'unixepoch', 'localtime'). fitness_activities and fitness_sleep also have start_ms / end_ms.
        - JSON columns (metrics, levels, hr_series, data, tags, rejected, exercises, place) are text: read them with json_extract and json_each.
        - Money: transactions.amount and accounts.balance are decimal strings; use cast(amount as real). A negative amount is money out. "Rent" and transfers distort spending, so mention it when you exclude them. Manual categories are in category_overrides (transaction_id → category); the rest come from the hub's rules, so say when a category total is inferred (getFinanceSummary and searchTransactions have the categories applied).
        - Drinks: fitness_drinks has one row per kind per round (count is standard drinks; time_of_day morning/afternoon/evening/lateNight/allDay). Its night is the local evening the drinking started, so date(night, '+1 day') is the morning its sleep, HRV, resting HR and check-in land on. fitness_dry_nights are nights answered "No drinks" (a known zero); fitness_drank_nights are "Drank, not sure how much" (leave them out of per-drink math); a night in none of these is unknown, not zero.
        - Diet (he's on a low-FODMAP diet): diet_meals (slot breakfast/lunch/dinner/snack, at, day) with their foods in diet_meal_foods (fodmap low/moderate/high/unknown as rated when logged; groups is comma text of fructans, gos, lactose, fructose, sorbitol, mannitol). diet_checks are how he felt, usually after a meal (meal_id); its symptoms are in diet_symptoms (symptom gutPain/gas/bloating/nausea/cramps/diarrhea/constipation/reflux/urgency/fatigue, severity 1 mild to 3 severe). A check with no symptom rows means he felt fine; a meal with no check is unknown, not fine. The current phase (elimination/reintroduction/personalization) is in settings under diet.phase and diet.phase_since.
        - Use only columns that exist in the schema above. If a query errors, read the message and fix it. If data is missing or thin, say so rather than guessing.
        - Say which period and how many data points a conclusion rests on. Separate what the data shows from a guess about why. With only a few points, don't claim a trend.
        - Be concise: lead with the answer, then the supporting numbers. The phone renders only inline markdown (bold, italics, code), so use short lines and "- " bullets, never tables or # headings. Don't paste SQL unless asked.
        - You can do things too (lights, TV), but for those act on clear requests only. You are read-only on the database.
        \(skills.isEmpty ? "" : "\nSkills (call loadSkill to read one before the task it covers):\n\(skills)")
        """
    }
}

/// The agent's window onto the database: a separate read-only connection, one SELECT at a time,
/// capped rows and a time limit. Credentials and settings tables are left out.
nonisolated enum ReadOnly {
    static let maxRows = 200
    static let maxChars = 40_000
    static let hidden: Set<String> = ["app_settings", "sync_runs", "fitness_files", "sqlite_master", "sqlite_schema", "sqlite_sequence"]

    /// Tables and columns, with row counts, in one compact block.
    static func schema() -> String {
        let db = LocalDB.shared
        return db.query("select name from sqlite_master where type = 'table' and name not like 'sqlite_%' order by name")
            .compactMap { $0["name"] as? String }
            .filter { !hidden.contains($0) }
            .map { table in
                let cols = db.query("select name, type from pragma_table_info(?)", [table])
                    .compactMap { c -> String? in
                        guard let name = c["name"] as? String, name != "raw" else { return nil }
                        return "\(name) \((c["type"] as? String ?? "").lowercased())"
                    }
                let count = db.one("select count(*) as n from \"\(table)\"")?["n"] as? Int ?? 0
                return "\(table) (\(count) rows): \(cols.joined(separator: ", "))"
            }
            .joined(separator: "\n")
    }

    /// An error message if the query isn't a single plain read of allowed tables.
    static func refuse(_ sql: String) -> String? {
        var text = sql.replacingOccurrences(of: "/\\*[\\s\\S]*?\\*/", with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: "--[^\\n]*", with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: "'(?:[^']|'')*'", with: "''", options: .regularExpression)
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ";+\\s*$", with: "", options: .regularExpression)
        if body.contains(";") { return "Run one statement at a time." }
        guard body.range(of: "^(select|with|\\()", options: [.regularExpression, .caseInsensitive]) != nil else {
            return "Only SELECT queries (or WITH ... SELECT) are allowed."
        }
        let words = body.lowercased().components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_")).inverted)
        for word in words where !word.isEmpty {
            if hidden.contains(word) || word == "raw" { return "\"\(word)\" isn't available to the agent." }
            if ["attach", "detach", "pragma", "load_extension", "readfile", "writefile", "into"].contains(word) { return "\"\(word)\" isn't allowed." }
        }
        return nil
    }

    static func query(_ sql: String) -> [String: Any] {
        if let why = refuse(sql) { return ["error": why] }
        let body = sql.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ";+\\s*$", with: "", options: .regularExpression)
        var handle: OpaquePointer?
        guard sqlite3_open_v2(LocalDB.fileURL.path, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
            return ["error": "Couldn't open the database."]
        }
        defer { sqlite3_close_v2(handle) }
        // A runaway query stops after about 8 seconds.
        let deadline = Date().addingTimeInterval(8)
        let box = Unmanaged.passRetained(DeadlineBox(deadline))
        defer { box.release() }
        sqlite3_progress_handler(handle, 10_000, { context in
            guard let context else { return 0 }
            return Unmanaged<DeadlineBox>.fromOpaque(context).takeUnretainedValue().deadline < Date() ? 1 : 0
        }, box.toOpaque())

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, "select * from (\n\(body)\n) limit \(maxRows + 1)", -1, &stmt, nil) == SQLITE_OK else {
            return ["error": String(String(cString: sqlite3_errmsg(handle)).prefix(400))]
        }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_stmt_readonly(stmt) != 0 else { return ["error": "Only reads are allowed."] }
        var rows: [[String: Any]] = []
        while true {
            let step = sqlite3_step(stmt)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else {
                let message = step == SQLITE_INTERRUPT ? "The query took too long. Narrow it down." : String(cString: sqlite3_errmsg(handle))
                return ["error": String(message.prefix(400))]
            }
            var row: [String: Any] = [:]
            for i in 0..<sqlite3_column_count(stmt) {
                let name = String(cString: sqlite3_column_name(stmt, i))
                switch sqlite3_column_type(stmt, i) {
                case SQLITE_INTEGER: row[name] = Int(sqlite3_column_int64(stmt, i))
                case SQLITE_FLOAT: row[name] = sqlite3_column_double(stmt, i)
                case SQLITE_TEXT: row[name] = String(cString: sqlite3_column_text(stmt, i))
                case SQLITE_BLOB: row[name] = "(binary)"
                default: row[name] = NSNull()
                }
            }
            rows.append(row)
        }
        let truncated = rows.count > maxRows
        var out = Array(rows.prefix(maxRows))
        while out.count > 1, ((try? JSONSerialization.data(withJSONObject: out))?.count ?? 0) > maxChars { out = Array(out.prefix(Int((Double(out.count) / 2).rounded(.up)))) }
        return ["rowCount": out.count, "truncated": truncated || out.count < rows.count, "rows": out]
    }

    final class DeadlineBox { let deadline: Date; init(_ d: Date) { deadline = d } }
}
