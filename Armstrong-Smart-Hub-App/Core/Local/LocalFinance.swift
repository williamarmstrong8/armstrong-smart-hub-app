import Foundation
import Security

/// Money, on the phone (was lib/store.ts, lib/sync.ts, lib/holdings.ts, the
/// finance Server Actions and /api/mobile/finance). The phone talks to
/// SimpleFIN itself with the access URL in its Keychain, keeps accounts and
/// transactions in its database, and runs the hub's own finance code
/// (HubJS.finance) to build the page, so the numbers match.
///
/// Syncing only happens when asked (pull to refresh): SimpleFIN allows 24
/// requests a day.
nonisolated enum LocalFinance {
    /// Days of history the dashboard renders (store.ts DASHBOARD_DAYS).
    static let historyDays = 90
    /// SimpleFIN caps one request at 90 days and rejects exactly 90.
    static let maxWindowDays = 89
    /// Transactions post late and pending ones are rewritten, so each run re-reads the recent past.
    static let overlapDays = 7

    static var db: LocalDB { .shared }

    static func register(_ r: inout [String: LocalHub.Handler]) {
        r["GET /api/mobile/finance"] = { _ in
            guard SimpleFinCredential.read() != nil else { return .ok(["configured": false]) }
            return HubJS.finance.call("dashboard", dashboardInput()).map(LocalHub.Reply.ok)
                ?? .error("Couldn't work out the finance page.", 500)
        }
        r["GET /api/mobile/finance/holdings"] = { _ in
            guard SimpleFinCredential.read() != nil else { return .ok(["configured": false]) }
            return HubJS.finance.call("holdings", holdingsInput()).map(LocalHub.Reply.ok)
                ?? .error("Couldn't work out the investments.", 500)
        }
        r["DELETE /api/mobile/finance/connect"] = { _ in
            SimpleFinCredential.delete()
            return .done
        }
    }

    static func registerAsync(_ r: inout [String: LocalHub.AsyncHandler]) {
        r["POST /api/mobile/finance"] = { _ in await sync(mode: "incremental", trigger: "manual") }
        // Connects with a setup token (claimed here) or an access URL, then pulls the full window.
        r["POST /api/mobile/finance/connect"] = { req in
            let input = (req.object["token"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !input.isEmpty else { return .ok(["ok": false, "error": "Paste a SimpleFIN setup token or access URL."]) }
            do {
                let access = try await SimpleFin.accessURL(from: input)
                SimpleFinCredential.write(access)
            } catch {
                return .ok(["ok": false, "error": (error as? SimpleFin.Failure)?.message ?? "Couldn't connect to SimpleFIN."])
            }
            return await sync(mode: "full", trigger: "connect")
        }
    }

    static func registerActions(_ a: inout [String: @Sendable ([Any]) -> Any]) {
        a["retagTransaction"] = { args in
            guard args.count >= 2, let id = args[0] as? String, let raw = args[1] as? String,
                  let category = normalized(raw) else { return ["status": "error", "message": "Not a valid category."] }
            db.transaction { setCategory(id, category) }
            return ["status": "success"]
        }
        a["confirmCategories"] = { args in
            var items: [(String, (name: String, builtIn: Bool))] = []
            for case let item as [String: Any] in (args.first as? [Any] ?? []).prefix(200) {
                guard let id = item["transactionId"] as? String, let raw = item["category"] as? String, let category = normalized(raw) else {
                    return ["status": "error", "message": "Not a valid category."]
                }
                items.append((id, category))
            }
            db.transaction { for (id, category) in items { setCategory(id, category) } }
            return ["status": "success"]
        }
        a["saveGoal"] = { args in
            let goal = args.first as? [String: Any] ?? [:]
            guard let target = LocalHub.number(goal["target"]), let ret = LocalHub.number(goal["annualReturnPct"]) else {
                return LocalHub.actionError("That goal isn't valid.")
            }
            if target < 1_000 { return LocalHub.actionError("Set a goal of at least $1,000.") }
            if target > 1_000_000_000 { return LocalHub.actionError("That goal isn't valid.") }
            if !(0...30).contains(ret) { return LocalHub.actionError("Keep the return between 0% and 30%.") }
            let monthly = LocalHub.number(goal["monthlyContribution"])
            if goal["monthlyContribution"] != nil, !(goal["monthlyContribution"] is NSNull), !(monthly.map { (0...10_000_000).contains($0) } ?? false) {
                return LocalHub.actionError("That goal isn't valid.")
            }
            let value: [String: Any] = ["target": target, "monthlyContribution": LocalHub.orNull(monthly), "annualReturnPct": ret]
            db.run("insert into app_settings (key, value) values ('net_worth_goal', ?) on conflict (key) do update set value = excluded.value",
                   [LocalDB.json(value)])
            return LocalHub.actionOK()
        }
        a["ignoreRecurring"] = { args in
            guard let id = args.first as? String, !id.isEmpty, id.count <= 200 else { return LocalHub.actionError("Not a valid charge.") }
            db.run("insert or ignore into recurring_ignored (id) values (?)", [id])
            return LocalHub.actionOK()
        }
    }

    // MARK: Categories

    /// A category as the hub stores it (categories.ts normalizeCategory), and whether it's built in.
    static func normalized(_ raw: String) -> (name: String, builtIn: Bool)? {
        guard let out = HubJS.finance.call("category", raw) as? [String: Any], let name = out["category"] as? String else { return nil }
        return (name, out["builtIn"] as? Bool ?? false)
    }

    static func setCategory(_ id: String, _ category: (name: String, builtIn: Bool)) {
        db.run(
            """
            insert into category_overrides (transaction_id, category, updated_at) values (?, ?, ?)
            on conflict (transaction_id) do update set category = excluded.category, updated_at = excluded.updated_at
            """, [id, category.name, LocalDB.iso(Date())])
        if !category.builtIn { db.run("insert or ignore into custom_categories (name) values (?)", [category.name]) }
    }

    // MARK: Reading

    /// The UTC day, which is what the hub's daily snapshots were keyed by.
    static func utcDay(_ date: Date = Date()) -> String { String(LocalDB.iso(date).prefix(10)) }

    static func dashboardInput() -> [String: Any] {
        let since = LocalDB.iso(Date().addingTimeInterval(-Double(historyDays) * 86_400))
        return [
            "now": Int(Date().timeIntervalSince1970 * 1000),
            "historyDays": historyDays,
            "accounts": db.query("select id, name, institution, currency, balance, available_balance, balance_date from accounts order by name"),
            "transactions": db.query(
                "select id, account_id, posted, amount, description, payee, memo, pending from transactions where posted >= ? order by posted desc",
                [since]),
            "sync": syncStatus(),
            "overrides": db.query("select transaction_id, category from category_overrides"),
            "custom": db.query("select name from custom_categories order by name"),
            "queue": db.query(
                """
                select t.id from transactions t
                 where t.created_at >= (select value from app_settings where key = 'review_since')
                   and not exists (select 1 from category_overrides o where o.transaction_id = t.id)
                """).compactMap { $0["id"] },
            "ignored": db.query("select id from recurring_ignored").compactMap { $0["id"] },
            "goal": LocalHub.orNull(db.one("select value from app_settings where key = 'net_worth_goal'")?["value"]),
            "snapshots": db.query("select day as date, value from net_worth_snapshots order by day"),
        ]
    }

    static func syncStatus() -> [String: Any] {
        let success = db.one(
            "select finished_at, notices from sync_runs where status = 'success' and finished_at is not null order by finished_at desc limit 1")
        let latest = db.one(
            "select status, error from sync_runs where status in ('success', 'error') order by coalesce(finished_at, started_at) desc limit 1")
        let lastSuccessAt = (success?["finished_at"] as? String).flatMap(LocalDB.date).map { Int($0.timeIntervalSince1970 * 1000) }
        return [
            "lastSuccessAt": LocalHub.orNull(lastSuccessAt),
            // Only a failure after the last good run.
            "failureReason": (latest?["status"] as? String) == "error" ? LocalHub.value(latest ?? [:], "error") : NSNull(),
            "notices": LocalDB.parse(success?["notices"]) as? [String] ?? [],
        ]
    }

    static func holdingsInput() -> [String: Any] {
        let since = utcDay(Date().addingTimeInterval(-365 * 86_400))
        return [
            "accountRows": db.query(
                """
                select id, name, institution, balance, balance_date, raw from accounts
                 where json_type(raw, '$.holdings') = 'array' and json_array_length(raw, '$.holdings') > 0
                 order by cast(balance as real) desc
                """).map { row -> [String: Any] in
                    var out = row
                    out["raw"] = LocalDB.parse(row["raw"])
                    return out
                },
            "snapshotRows": db.query(
                "select day as date, account_id, symbol, shares, market_value from holding_snapshots where day >= ? order by day", [since]),
            "today": utcDay(),
        ]
    }

    // MARK: Sync

    /// Pulls SimpleFIN into the database (sync.ts runSync). Idempotent: rows are upserted by id.
    static func sync(mode: String, trigger: String) async -> LocalHub.Reply {
        guard let access = SimpleFinCredential.read() else { return .ok(["ok": false, "error": "Not connected to SimpleFIN yet."]) }
        let lastSuccess = (db.one("select max(finished_at) as at from sync_runs where status = 'success'")?["at"] as? String).flatMap(LocalDB.date)
        var windowDays = maxWindowDays
        if mode != "full", let lastSuccess {
            let elapsed = Int((Date().timeIntervalSince(lastSuccess) / 86_400).rounded(.up))
            windowDays = min(max(elapsed + overlapDays, overlapDays), maxWindowDays)
        }
        let effectiveMode = windowDays >= maxWindowDays ? "full" : mode
        let windowStart = Date().addingTimeInterval(-Double(windowDays) * 86_400)
        let now = LocalDB.iso(Date())
        let runId = db.one("insert into sync_runs (trigger, mode, window_start, status, started_at) values (?, ?, ?, 'running', ?) returning id",
                           [trigger, effectiveMode, LocalDB.iso(windowStart), now])?["id"] as? Int ?? 0

        do {
            let set = try await SimpleFin.accounts(access, start: Int(windowStart.timeIntervalSince1970))
            let (accountCount, upserted) = try record(set, runId: runId)
            return .ok(["ok": true, "message": "Synced \(upserted) transactions across \(accountCount) accounts."])
        } catch {
            let message = (error as? SimpleFin.Failure)?.message ?? "Couldn't refresh from SimpleFIN."
            db.run("update sync_runs set status = 'error', finished_at = ?, error = ? where id = ?", [LocalDB.iso(Date()), message, runId])
            return .ok(["ok": false, "error": message])
        }
    }

    /// Writes one SimpleFIN account set and closes the sync run: accounts, transactions (dropping
    /// pending ones the bank stopped reporting), today's holdings and net worth.
    static func record(_ set: Any, runId: Int) throws -> (accounts: Int, upserted: Int) {
        let now = LocalDB.iso(Date())
        do {
            guard let rows = HubJS.finance.call("syncRows", set) as? [String: Any] else { throw SimpleFin.Failure("Couldn't read SimpleFIN's answer.") }
            let accounts = rows["accounts"] as? [[String: Any]] ?? []
            var upserted = 0
            db.transaction {
                for account in accounts {
                    guard let id = account["id"] as? String else { continue }
                    db.run(
                        """
                        insert into accounts (id, name, institution, currency, balance, available_balance, balance_date, raw, updated_at)
                        values (?, ?, ?, ?, ?, ?, ?, ?, ?)
                        on conflict (id) do update set name = excluded.name, institution = excluded.institution,
                          currency = excluded.currency, balance = excluded.balance, available_balance = excluded.available_balance,
                          balance_date = excluded.balance_date, raw = excluded.raw, updated_at = excluded.updated_at
                        """,
                        [id, account["name"], account["institution"], account["currency"], account["balance"],
                         account["available_balance"], account["balance_date"], account["raw"], now])
                    if let transactions = account["transactions"] as? [[String: Any]] {
                        for t in transactions {
                            db.run(
                                """
                                insert into transactions (id, account_id, posted, amount, description, payee, memo, pending, raw, created_at, updated_at)
                                values (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                                on conflict (id) do update set account_id = excluded.account_id, posted = excluded.posted,
                                  amount = excluded.amount, description = excluded.description, payee = excluded.payee,
                                  memo = excluded.memo, pending = excluded.pending, raw = excluded.raw, updated_at = excluded.updated_at
                                """,
                                [t["id"], id, t["posted"], t["amount"], t["description"], t["payee"], t["memo"],
                                 LocalHub.bool(t["pending"]) ?? false, t["raw"], now, now])
                        }
                        upserted += transactions.count
                        // A pending charge the bank stopped reporting settled under a new id or vanished.
                        db.run("delete from transactions where account_id = ? and pending and id not in (select value from json_each(?))",
                               [id, LocalDB.json(transactions.compactMap { $0["id"] }) ?? "[]"])
                    }
                    // Today's reading for every position (holdings.ts recordHoldings).
                    let holdings = account["holdings"] as? [[String: Any]] ?? []
                    if !holdings.isEmpty {
                        let today = utcDay()
                        db.run("delete from holding_snapshots where day = ? and account_id = ? and symbol not in (select value from json_each(?))",
                               [today, id, LocalDB.json(holdings.compactMap { $0["symbol"] }) ?? "[]"])
                        for h in holdings {
                            db.run(
                                """
                                insert into holding_snapshots (day, account_id, symbol, shares, market_value, cost_basis, updated_at)
                                values (?, ?, ?, ?, ?, ?, ?)
                                on conflict (day, account_id, symbol) do update set shares = excluded.shares,
                                  market_value = excluded.market_value, cost_basis = excluded.cost_basis, updated_at = excluded.updated_at
                                """, [today, id, h["symbol"], h["shares"], h["market_value"], h["cost_basis"], now])
                        }
                    }
                }
                // Balances are fresh, so this is the day's net worth reading.
                if let netWorth = rows["netWorth"] as? String {
                    db.run(
                        "insert into net_worth_snapshots (day, value, updated_at) values (?, ?, ?) on conflict (day) do update set value = excluded.value, updated_at = excluded.updated_at",
                        [utcDay(), netWorth, now])
                }
                db.run(
                    "update sync_runs set status = 'success', finished_at = ?, accounts_synced = ?, transactions_upserted = ?, notices = ? where id = ?",
                    [LocalDB.iso(Date()), accounts.count, upserted, LocalDB.json(rows["notices"] ?? []) ?? "[]", runId])
            }
            return (accounts.count, upserted)
        }
    }
}

// MARK: SimpleFIN

/// SimpleFIN Bridge (lib/simplefin.ts). A setup token is a base64 claim URL; POSTing to it once
/// returns an access URL `https://user:pass@host/path`, used for `GET {access}/accounts`.
nonisolated enum SimpleFin {
    struct Failure: Error { let message: String; init(_ message: String) { self.message = message } }

    /// An access URL as pasted, or the one a setup token claims.
    static func accessURL(from input: String) async throws -> String {
        if input.lowercased().hasPrefix("http") {
            guard let c = URLComponents(string: input), c.user != nil, c.password != nil else {
                throw Failure("That access URL is missing its credentials.")
            }
            return input
        }
        let padded = input + String(repeating: "=", count: (4 - input.count % 4) % 4)
        guard let data = Data(base64Encoded: padded), let claim = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              let url = URL(string: claim), url.scheme == "https" else { throw Failure("That doesn't look like a SimpleFIN setup token.") }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("0", forHTTPHeaderField: "Content-Length")
        let (body, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 403 { throw Failure("That setup token was already used. Make a new one in SimpleFIN Bridge.") }
        guard (200..<300).contains(status), let access = String(data: body, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              access.lowercased().hasPrefix("http") else { throw Failure("SimpleFIN didn't accept that token (HTTP \(status)).") }
        return access
    }

    /// `GET {access}/accounts` from `start` (epoch seconds), pending included, as parsed JSON.
    static func accounts(_ access: String, start: Int) async throws -> Any {
        guard var c = URLComponents(string: access) else { throw Failure("The stored SimpleFIN access URL is malformed.") }
        let user = c.user?.removingPercentEncoding ?? "", password = c.password?.removingPercentEncoding ?? ""
        c.user = nil
        c.password = nil
        c.path = (c.path.hasSuffix("/") ? String(c.path.dropLast()) : c.path) + "/accounts"
        c.queryItems = [URLQueryItem(name: "start-date", value: String(start)), URLQueryItem(name: "pending", value: "1")]
        guard let url = c.url else { throw Failure("The stored SimpleFIN access URL is malformed.") }
        var request = URLRequest(url: url, timeoutInterval: 90)
        request.setValue("Basic \(Data("\(user):\(password)".utf8).base64EncodedString())", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let data: Data, response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw Failure("Couldn't reach SimpleFIN.")
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 402 || status == 429 { throw Failure("SimpleFIN rate limit reached (24 requests per day). Try again later.") }
        if status == 403 { throw Failure("SimpleFIN rejected these credentials. Reconnect with a new setup token.") }
        guard (200..<300).contains(status) else { throw Failure("SimpleFIN request failed (HTTP \(status)).") }
        guard let set = try? JSONSerialization.jsonObject(with: data) as? [String: Any], set["accounts"] is [Any] else {
            throw Failure("SimpleFIN returned an unexpected response body.")
        }
        return set
    }
}

/// The SimpleFIN access URL (it embeds credentials), in the Keychain only: never in the
/// database, never synced off the phone.
nonisolated enum SimpleFinCredential {
    private static let service = "com.armstrong.hub.simplefin"
    private static let account = "access-url"

    private static func base() -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    static func read() -> String? {
        var query = base()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func write(_ value: String) {
        delete()
        var query = base()
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        query[kSecValueData as String] = Data(value.utf8)
        SecItemAdd(query as CFDictionary, nil)
    }

    static func delete() { SecItemDelete(base() as CFDictionary) }
}
