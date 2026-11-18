import Foundation

/// Life around the body data (was lib/fitness/context.ts and /api/mobile/fitness/context):
/// calendar load per day, spending per night, and likely bar charges on nights the drinks
/// log hasn't answered, so the phone can ask "Drinks at Kingston Hall last night?". The
/// matching rules run in HubJS.finance (the hub's own code); answers teach which merchants are bars.
nonisolated enum LocalContext {
    static var db: LocalDB { .shared }

    static func register(_ r: inout [String: LocalHub.Handler]) {
        r["PUT /api/mobile/fitness/context"] = { req in
            let o = req.object
            guard let merchant = o["merchant"] as? String, (1...60).contains(merchant.count), let drinks = LocalHub.bool(o["drinks"]) else {
                return .error("Expected { merchant, drinks }.")
            }
            db.run(
                """
                insert into fitness_merchant_drinks (merchant, yes, no, updated_at) values (?, ?, ?, ?)
                on conflict (merchant) do update set yes = yes + excluded.yes, no = no + excluded.no, updated_at = excluded.updated_at
                """, [merchant, drinks ? 1 : 0, drinks ? 0 : 1, LocalDB.iso(Date())])
            return .done
        }
    }

    static func registerAsync(_ r: inout [String: LocalHub.AsyncHandler]) {
        r["GET /api/mobile/fitness/context"] = { req in
            let asked = Int(req.param("days") ?? "60") ?? 60
            let days = min(max(asked, 7), 120)
            let now = Date()
            let since = now.addingTimeInterval(-Double(days) * 86_400)
            // Up to the end of tomorrow, so the night briefing can look ahead. No calendar is fine.
            var events: Any = NSNull()
            if GoogleCredential.status() == "connected",
               let list = try? await LocalCalendar.listEvents(from: since, to: now.addingTimeInterval(2 * 86_400)) {
                events = list
            }
            let recent = LocalCalendar.day(now.addingTimeInterval(-4 * 86_400))
            let input: [String: Any] = [
                "now": Int(now.timeIntervalSince1970 * 1000),
                "timeZone": LocalCalendar.timeZone.identifier,
                "events": events,
                "rows": db.query(
                    """
                    select id, coalesce(strftime('%Y-%m-%dT%H:%M:%SZ', json_extract(raw, '$.transacted_at'), 'unixepoch'), posted) as at,
                           amount, description, nullif(payee, '') as payee
                      from transactions where cast(amount as real) < 0 and posted >= ? order by at desc
                    """, [LocalDB.iso(since)]),
                "memory": db.query("select merchant, yes, no from fitness_merchant_drinks"),
                "answered": db.query(
                    """
                    select night from fitness_drinks where night >= ?1 union select night from fitness_dry_nights where night >= ?1
                    union select night from fitness_drank_nights where night >= ?1
                    """, [recent]).compactMap { $0["night"] },
            ]
            return HubJS.finance.call("context", input).map(LocalHub.Reply.ok) ?? .error("Couldn't work out the context.", 500)
        }
    }
}
