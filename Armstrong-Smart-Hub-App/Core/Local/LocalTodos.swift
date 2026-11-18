import Foundation

/// The to-do list (was lib/todos.ts and /api/mobile/todos): open items, plus
/// ones checked off in the last day so a fresh check stays on screen. Every
/// call answers with the whole list.
nonisolated enum LocalTodos {
    static func register(_ r: inout [String: LocalHub.Handler]) {
        r["GET /api/mobile/todos"] = { _ in .ok(["items": list()]) }
        r["POST /api/mobile/todos"] = { req in
            let text = String((LocalHub.string(req.object["text"]) ?? "").trimmingCharacters(in: .whitespacesAndNewlines).prefix(200))
            guard !text.isEmpty else { return .error("Say what to add.") }
            add([text])
            return .ok(["items": list()])
        }
        r["PATCH /api/mobile/todos"] = { req in
            guard let id = LocalHub.string(req.object["id"]), let done = LocalHub.bool(req.object["done"]) else {
                return .error("Not a valid request.")
            }
            setDone(id, done)
            return .ok(["items": list()])
        }
        r["DELETE /api/mobile/todos"] = { req in
            guard let id = LocalHub.string(req.object["id"]) else { return .error("Not a valid request.") }
            LocalHub.db.run("delete from todos where id = ?", [id.lowercased()])
            return .ok(["items": list()])
        }
    }

    static func list() -> [[String: Any]] {
        let since = LocalDB.iso(Date().addingTimeInterval(-86_400))
        return LocalHub.db.query(
            "select id, text, done, done_at from todos where not done or done_at > ? order by done, created_at", [since]
        ).map { ["id": $0["id"] ?? "", "text": $0["text"] ?? "", "done": ($0["done"] as? Int ?? 0) != 0] }
    }

    @discardableResult
    static func add(_ texts: [String]) -> Int {
        let clean = texts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        let now = Date()
        LocalHub.db.transaction {
            // Spread created_at by a millisecond each so a batch keeps its order.
            for (i, text) in clean.enumerated() {
                LocalHub.db.run("insert into todos (id, text, created_at) values (?, ?, ?)",
                                [LocalDB.uuid(), text, LocalDB.iso(now.addingTimeInterval(Double(i) / 1000))])
            }
        }
        return clean.count
    }

    static func setDone(_ id: String, _ done: Bool) {
        LocalHub.db.run("update todos set done = ?, done_at = ? where id = ?",
                        [done, done ? LocalDB.iso(Date()) : nil, id.lowercased()])
    }
}
