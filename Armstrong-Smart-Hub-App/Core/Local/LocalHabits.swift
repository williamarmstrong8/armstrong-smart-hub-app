import Foundation

/// Daily habits (was lib/habits.ts, /api/mobile/habits and the habit Server
/// Actions). Dates are the local calendar day ("YYYY-MM-DD").
nonisolated enum LocalHabits {
    /// How far back completions are loaded; longer streaks show as "365+".
    static let historyDays = 365

    /// Two rows: Notion's palette, then brighter tones (lib/habit-types.ts).
    static let colors = [
        "#E03E3E", "#D9730D", "#DFAB01", "#0F7B6C", "#0B6E99", "#6940A5", "#AD1A72", "#9B9A97",
        "#F87171", "#FB923C", "#FACC15", "#4ADE80", "#22D3EE", "#60A5FA", "#A78BFA", "#F472B6",
    ]

    static func register(_ r: inout [String: LocalHub.Handler]) {
        r["GET /api/mobile/habits"] = { _ in
            .ok(["habits": habits(), "completions": completions(), "colors": colors, "historyDays": historyDays])
        }
    }

    static func registerActions(_ a: inout [String: @Sendable ([Any]) -> Any]) {
        a["setCompletion"] = { args in
            guard args.count >= 3, let id = args[0] as? String, LocalHub.isUUID(id) else { return LocalHub.actionError("Not a valid habit.") }
            guard let date = args[1] as? String, LocalHub.isDay(date) else { return LocalHub.actionError("Not a valid date.") }
            setCompletion(id.lowercased(), date, LocalHub.bool(args[2]) ?? false)
            return LocalHub.actionOK()
        }
        a["createHabit"] = { args in
            switch input(args.first) {
            case .failure(let message): return LocalHub.actionError(message.text)
            case .success(let i): return LocalHub.actionOK(create(i))
            }
        }
        a["updateHabit"] = { args in
            guard let id = args.first as? String, LocalHub.isUUID(id) else { return LocalHub.actionError("Not a valid habit.") }
            switch input(args.count > 1 ? args[1] : nil) {
            case .failure(let message): return LocalHub.actionError(message.text)
            case .success(let i):
                guard let habit = update(id.lowercased(), i) else { return LocalHub.actionError("That habit no longer exists.") }
                return LocalHub.actionOK(habit)
            }
        }
        a["archiveHabit"] = { args in
            guard let id = args.first as? String, LocalHub.isUUID(id) else { return LocalHub.actionError("Not a valid habit.") }
            LocalHub.db.run("update habits set archived = 1 where id = ?", [id.lowercased()])
            return LocalHub.actionOK()
        }
    }

    // MARK: Store

    struct Input { let name: String; let color: String; let icon: String? }
    struct Message: Error { let text: String }

    /// Validates `{ name, color, icon }` the way habitInputSchema did.
    static func input(_ raw: Any?) -> Result<Input, Message> {
        let o = raw as? [String: Any] ?? [:]
        let name = (o["name"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { return .failure(Message(text: "Give the habit a name.")) }
        if name.count > 40 { return .failure(Message(text: "Keep the name under 40 characters.")) }
        let color = o["color"] as? String ?? ""
        guard color.range(of: "^#[0-9a-fA-F]{6}$", options: .regularExpression) != nil else { return .failure(Message(text: "Pick a color.")) }
        let icon = (o["icon"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return .success(Input(name: name, color: color, icon: (icon?.isEmpty ?? true) ? nil : String(icon!.prefix(16))))
    }

    private static let fields = "id, name, color, icon, position, created_at"

    private static func habit(_ row: LocalDB.Row) -> [String: Any] {
        ["id": LocalHub.value(row, "id"), "name": LocalHub.value(row, "name"), "color": LocalHub.value(row, "color"),
         "icon": LocalHub.value(row, "icon"), "position": LocalHub.value(row, "position"), "createdAt": LocalHub.value(row, "created_at")]
    }

    static func habits() -> [[String: Any]] {
        LocalHub.db.query("select \(fields) from habits where not archived order by position, created_at").map(habit)
    }

    static func completions() -> [[String: Any]] {
        let from = LocalDB.addDays(LocalDB.day(), -(historyDays + 1))
        return LocalHub.db.query(
            """
            select c.habit_id, c.date from habit_completions c
              join habits h on h.id = c.habit_id and not h.archived
             where c.date >= ?
            """, [from]
        ).map { ["habitId": LocalHub.value($0, "habit_id"), "date": LocalHub.value($0, "date")] }
    }

    static func create(_ i: Input) -> [String: Any] {
        let id = LocalDB.uuid()
        LocalHub.db.run(
            """
            insert into habits (id, name, color, icon, position, created_at)
            values (?, ?, ?, ?, coalesce((select max(position) + 1 from habits where not archived), 0), ?)
            """, [id, i.name, i.color, i.icon, LocalDB.iso(Date())])
        return LocalHub.db.one("select \(fields) from habits where id = ?", [id]).map(habit) ?? [:]
    }

    static func update(_ id: String, _ i: Input) -> [String: Any]? {
        let changed = LocalHub.db.run("update habits set name = ?, color = ?, icon = ? where id = ? and not archived",
                                      [i.name, i.color, i.icon, id])
        guard changed > 0 else { return nil }
        return LocalHub.db.one("select \(fields) from habits where id = ?", [id]).map(habit)
    }

    static func setCompletion(_ id: String, _ date: String, _ done: Bool) {
        if done {
            LocalHub.db.run("insert or ignore into habit_completions (habit_id, date) values (?, ?)", [id, date])
        } else {
            LocalHub.db.run("delete from habit_completions where habit_id = ? and date = ?", [id, date])
        }
    }
}
