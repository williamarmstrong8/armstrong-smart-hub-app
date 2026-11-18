import Foundation

/// Which devices Home shows, kept on the phone (was home_visible_entities on the hub). The
/// lights and TV themselves stay on the Pi: /api/home is fetched from it as before, and the
/// phone fills in `visible` (nil means every device that's reachable).
nonisolated enum LocalHome {
    static var db: LocalDB { .shared }

    static func registerActions(_ a: inout [String: @Sendable ([Any]) -> Any]) {
        a["saveVisibleDevices"] = { args in
            let ids = (args.first as? [Any] ?? []).compactMap { $0 as? String }.prefix(500)
            db.transaction {
                db.run("delete from home_visible")
                for id in Set(ids) { db.run("insert or ignore into home_visible (entity_id) values (?)", [id]) }
                db.run("insert or replace into settings (key, value) values ('home_visible_set', '1')")
            }
            return LocalHub.actionOK()
        }
    }

    static func registerMaybe(_ r: inout [String: LocalHub.MaybeHandler]) {
        r["GET /api/home"] = { req in
            var reply = await LocalHub.forwardJSON(req.original, timeout: 30)
            guard var body = reply.body as? [String: Any], reply.status == 200 else { return reply }
            body["visible"] = visible() ?? NSNull()
            if let entities = body["entities"] as? [[String: Any]] { body["entities"] = entities.map(plugAsLight) }
            reply = .ok(body)
            return reply
        }
    }

    /// A smart plug driving lights (the Kasa "Copper Lights") is a switch to Home Assistant,
    /// but it belongs with the lights: same toggle, counted as a light. The plug's own
    /// indicator LED stays a switch.
    static func plugAsLight(_ entity: [String: Any]) -> [String: Any] {
        guard let id = entity["id"] as? String, id.hasPrefix("switch."), !id.hasSuffix("_led"),
              entity["control"] as? String == "toggle",
              let name = (entity["name"] as? String)?.lowercased(),
              !name.hasSuffix(" led"),
              name.contains("light") || name.contains("lamp") else { return entity }
        var e = entity
        e["control"] = "light"
        return e
    }

    /// The picked devices, or nil before any were picked.
    static func visible() -> [String]? {
        guard db.one("select value from settings where key = 'home_visible_set'") != nil else { return nil }
        return db.query("select entity_id from home_visible order by entity_id").compactMap { $0["entity_id"] as? String }
    }
}
