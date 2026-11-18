import Foundation

/// Brings in the history from the old hub database (Neon), once. The Mac exports it
/// (scripts/neon-export in this repo) already shaped like the phone's tables, the Pi
/// holds it at /api/mobile/import, and the phone adds every row it doesn't have yet:
/// anything logged on the phone since the move wins over the old copy. The file on the
/// Pi is removed after a clean import.
///
/// Export format: `{ version: 1, tables: { name: { columns: [..], rows: [[..], ..] } } }`.
nonisolated enum LocalImport {
    static let doneKey = "history.imported.v1"

    /// Tries once per launch until an import has landed. `template` carries the Pi's address and key.
    static func runIfNeeded(template: URLRequest) async {
        guard !UserDefaults.standard.bool(forKey: doneKey) else { return }
        guard let (data, http) = try? await LocalHub.forward(template, path: "/api/mobile/import", method: "GET", timeout: 300),
              http.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tables = json["tables"] as? [String: Any] else { return }
        let counts = importTables(tables)
        #if DEBUG
        print("LocalImport:", counts)
        #endif
        UserDefaults.standard.set(true, forKey: doneKey)
        _ = try? await LocalHub.forward(template, path: "/api/mobile/import", method: "DELETE", timeout: 30)
    }

    /// Inserts every row it doesn't have yet, table by table. Answers rows added per table.
    @discardableResult
    static func importTables(_ tables: [String: Any]) -> [String: Int] {
        let db = LocalDB.shared
        let known = Set(db.query("select name from sqlite_master where type = 'table'").compactMap { $0["name"] as? String })
        var counts: [String: Int] = [:]
        db.transaction {
            // Parents and children arrive in any order (habit check-offs, workout sets); check the links at commit.
            db.exec("pragma defer_foreign_keys = on")
            for (name, raw) in tables {
                guard known.contains(name), let t = raw as? [String: Any],
                      let columns = t["columns"] as? [String], !columns.isEmpty, let rows = t["rows"] as? [[Any]] else { continue }
                let have = Set(db.query("select name from pragma_table_info(?)", [name]).compactMap { $0["name"] as? String })
                guard columns.allSatisfy(have.contains) else { continue }
                let sql = "insert or ignore into \"\(name)\" (\(columns.map { "\"\($0)\"" }.joined(separator: ", "))) values (\(columns.map { _ in "?" }.joined(separator: ", ")))"
                var added = 0
                for row in rows where row.count == columns.count {
                    added += db.run(sql, row.map { value -> Any? in
                        // Nested JSON goes in as text, like the phone stores it.
                        if value is [Any] || value is [String: Any] { return LocalDB.json(value) }
                        return value is NSNull ? nil : value
                    })
                }
                counts[name] = added
            }
        }
        return counts
    }
}
