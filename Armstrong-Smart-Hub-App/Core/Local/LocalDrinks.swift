import Foundation

/// Drinks logged on the phone (was lib/fitness/drinks.ts and
/// /api/mobile/fitness/drinks). A night is the local evening the drinking
/// started; AlcoholStore works it out. Nights can also be answered "No drinks"
/// (dry) or "Drank, not sure how much" (drank) without amounts.
nonisolated enum LocalDrinks {
    static let kinds: Set<String> = ["beer", "wine", "liquor"]
    static let times: Set<String> = ["morning", "afternoon", "evening", "lateNight", "allDay"]

    static func register(_ r: inout [String: LocalHub.Handler]) {
        r["GET /api/mobile/fitness/drinks"] = { req in
            let since = req.param("since")
            if let since, !LocalHub.isDay(since) { return .error("Not a valid day.") }
            return .ok(list(since: since))
        }
        r["PUT /api/mobile/fitness/drinks"] = { req in
            let o = req.object
            if let d = o["drink"] {
                guard let drink = parse(d) else { return .error("Not a valid drink.") }
                save([drink])
            } else if let entries = o["entries"] as? [Any] {
                let drinks = entries.compactMap(parse)
                guard drinks.count == entries.count else { return .error("Not a valid drink.") }
                let dry = (o["dry"] as? [String] ?? []).filter(LocalHub.isDay)
                let drank = (o["drank"] as? [String] ?? []).filter(LocalHub.isDay)
                LocalHub.db.transaction {
                    save(drinks)
                    setNight(dry, answer: "dry", on: true)
                    setNight(drank, answer: "drank", on: true)
                }
            } else if let n = o["drank"] as? [String: Any], let night = n["night"] as? String, LocalHub.isDay(night),
                      let on = LocalHub.bool(n["drank"]) {
                setNight([night], answer: "drank", on: on)
            } else if let n = o["dry"] as? [String: Any], let night = n["night"] as? String, LocalHub.isDay(night),
                      let on = LocalHub.bool(n["dry"]) {
                setNight([night], answer: "dry", on: on)
            } else {
                return .error("Not a valid drink.")
            }
            return .done
        }
        r["DELETE /api/mobile/fitness/drinks"] = { req in
            guard let id = req.param("id"), LocalHub.isUUID(id) else { return .error("Not a valid drink.") }
            LocalHub.db.run("delete from fitness_drinks where id = ?", [id.lowercased()])
            return .done
        }
    }

    struct Drink {
        let id, night, at, kind: String
        let count: Int
        let time, loggedAt: String?
    }

    static func parse(_ raw: Any) -> Drink? {
        guard let o = raw as? [String: Any],
              let id = o["id"] as? String, LocalHub.isUUID(id),
              let night = o["night"] as? String, LocalHub.isDay(night),
              let at = LocalDB.normalized(o["at"]),
              let kind = o["kind"] as? String, kinds.contains(kind),
              let count = LocalHub.int(o["count"]), (1...1000).contains(count) else { return nil }
        let time = o["time"] as? String
        if let time, !times.contains(time) { return nil }
        return Drink(id: id.lowercased(), night: night, at: at, kind: kind, count: count, time: time,
                     loggedAt: LocalDB.normalized(o["loggedAt"]))
    }

    /// Every drink, dry night and amount-unknown night, newest night first, optionally from a night on.
    static func list(since: String?) -> [String: Any] {
        let from = since ?? "1900-01-01"
        let entries = LocalHub.db.query(
            "select id, night, at, kind, count, time_of_day, logged_at from fitness_drinks where night >= ? order by night desc, at", [from]
        ).map { row -> [String: Any] in
            ["id": LocalHub.value(row, "id"), "night": LocalHub.value(row, "night"), "at": LocalHub.value(row, "at"),
             "kind": LocalHub.value(row, "kind"), "count": LocalHub.value(row, "count"),
             "time": LocalHub.value(row, "time_of_day"), "loggedAt": LocalHub.value(row, "logged_at")]
        }
        func nights(_ table: String) -> [Any] {
            LocalHub.db.query("select night from \(table) where night >= ? order by night desc", [from]).map { LocalHub.value($0, "night") }
        }
        return ["entries": entries, "dry": nights("fitness_dry_nights"), "drank": nights("fitness_drank_nights")]
    }

    /// Adds or replaces drinks by id. A night with drinks is no longer a dry one, nor one of unknown amount.
    static func save(_ drinks: [Drink]) {
        let now = LocalDB.iso(Date())
        LocalHub.db.transaction {
            for d in drinks {
                LocalHub.db.run(
                    """
                    insert into fitness_drinks (id, night, at, kind, count, time_of_day, logged_at, updated_at)
                    values (?, ?, ?, ?, ?, ?, ?, ?)
                    on conflict (id) do update set night = excluded.night, at = excluded.at, kind = excluded.kind,
                      count = excluded.count, time_of_day = excluded.time_of_day, logged_at = excluded.logged_at,
                      updated_at = excluded.updated_at
                    """, [d.id, d.night, d.at, d.kind, d.count, d.time, d.loggedAt, now])
            }
            for night in Set(drinks.map(\.night)) {
                LocalHub.db.run("delete from fitness_dry_nights where night = ?", [night])
                LocalHub.db.run("delete from fitness_drank_nights where night = ?", [night])
            }
        }
    }

    /// Answers nights with no amounts, or takes the answer back. The two answers replace each
    /// other, and a night that already has drinks logged keeps them instead.
    static func setNight(_ nights: [String], answer: String, on: Bool) {
        let table = answer == "dry" ? "fitness_dry_nights" : "fitness_drank_nights"
        let other = answer == "dry" ? "fitness_drank_nights" : "fitness_dry_nights"
        LocalHub.db.transaction {
            for night in nights {
                if !on {
                    LocalHub.db.run("delete from \(table) where night = ?", [night])
                    continue
                }
                LocalHub.db.run("delete from \(other) where night = ?", [night])
                LocalHub.db.run(
                    "insert or ignore into \(table) (night) select ? where not exists (select 1 from fitness_drinks where night = ?)",
                    [night, night])
            }
        }
    }

    /// Standard drinks per morning: the day after each logged night, 0 for a dry night,
    /// NSNull for drinking of unknown amount. Mornings with nothing logged are missing.
    /// (For the check-in engine and Jarvis once they move here.)
    static func byMorning() -> [String: Any] {
        var out: [String: Any] = [:]
        func rank(_ v: Any?) -> Double {
            switch v {
            case nil: -2
            case is NSNull: 0.5
            case let n as Int: n == 0 ? 0 : 1
            default: -2
            }
        }
        func offer(_ day: String, _ v: Any) { if rank(v) > rank(out[day]) { out[day] = v } }
        for row in LocalHub.db.query("select night, sum(count) as drinks from fitness_drinks group by night") {
            if let night = row["night"] as? String { offer(LocalDB.addDays(night, 1), row["drinks"] as? Int ?? 0) }
        }
        for row in LocalHub.db.query("select night from fitness_dry_nights") {
            if let night = row["night"] as? String { offer(LocalDB.addDays(night, 1), 0) }
        }
        for row in LocalHub.db.query("select night from fitness_drank_nights") {
            if let night = row["night"] as? String { offer(LocalDB.addDays(night, 1), NSNull()) }
        }
        return out
    }
}
