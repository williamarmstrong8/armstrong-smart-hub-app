import Foundation

/// Jarvis's voice, with its data on the phone (was the data half of lib/agent/voice.ts,
/// lib/agent/memory.ts and the /api/mobile/voice routes). The realtime model still runs
/// through the Pi, which holds the AI Gateway key and the house:
///
/// - session: the Pi mints the token and writes the instructions; the phone adds its habits and memory.
/// - tool: money, calendar, habits, weather, fitness, to-dos and memory run here; lights,
///   movies, the Pi and app changes go on to the Pi.
/// - intent: the Pi guesses the screen (its router model); the phone fills in its own cards.
/// - log: kept here; what's worth remembering is worked out by a small model through the Pi.
nonisolated enum LocalJarvis {
    static var db: LocalDB { .shared }

    static let localTools: Set<String> = [
        "showFinance", "showCalendar", "addCalendarEvent", "editCalendarEvent", "deleteCalendarEvent",
        "showHabits", "setHabit", "showWeather", "showFitness", "remember", "forget", "recall",
        "showTodos", "addTodos", "checkTodo", "removeTodo", "clearDoneTodos",
    ]

    static func registerMaybe(_ r: inout [String: LocalHub.MaybeHandler]) {
        r["POST /api/mobile/voice/tool"] = { req in
            guard let name = req.object["name"] as? String, localTools.contains(name) else { return nil }
            var args: Any = req.object["arguments"] ?? [String: Any]()
            if let text = args as? String {
                guard let parsed = text.trimmingCharacters(in: .whitespaces).isEmpty ? [String: Any]() : try? JSONSerialization.jsonObject(with: Data(text.utf8)) else {
                    return .ok(["output": ["error": "The arguments weren't valid JSON."]])
                }
                args = parsed
            }
            return .ok(await run(name, args as? [String: Any] ?? [:]))
        }
        r["POST /api/mobile/voice/session"] = { req in
            let habits = LocalHabits.habits().map { ["id": $0["id"] ?? "", "name": $0["name"] ?? ""] }
            return await LocalHub.forwardJSON(req.original, body: ["habits": habits, "memory": memoryInstructions()], timeout: 30)
        }
        r["POST /api/mobile/voice/intent"] = { req in
            var reply = await LocalHub.forwardJSON(req.original, timeout: 10)
            guard var body = reply.body as? [String: Any], let screen = body["screen"] as? String else { return reply }
            let transcript = req.object["transcript"] as? String ?? ""
            if let view = await prefetch(screen, transcript) {
                body["view"] = view
                reply = .ok(body)
            }
            return reply
        }
        r["POST /api/mobile/voice/log"] = { req in
            let heard = String((req.object["heard"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines).prefix(2000))
            let said = String((req.object["reply"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines).prefix(2000))
            guard !heard.isEmpty else { return .done }
            db.run("insert into voice_log (heard, reply, created_at) values (?, ?, ?)", [heard, said, LocalDB.iso(Date())])
            let original = req.original
            Task.detached(priority: .background) { await learn(heard: heard, reply: said, via: original) }
            return .done
        }
    }

    // MARK: Tools

    struct Failure: Error { let message: String }

    static func run(_ name: String, _ a: [String: Any]) async -> [String: Any] {
        do {
            switch name {
            case "showFinance": return finance(a)
            case "showCalendar": return try await showCalendar(day: a["day"] as? String, days: min(max(LocalHub.int(a["days"]) ?? 1, 1), 7))
            case "addCalendarEvent": return try await addEvent(a)
            case "editCalendarEvent": return try await editEvent(a)
            case "deleteCalendarEvent": return try await deleteEvent(a)
            case "showHabits": return habitsView()
            case "setHabit": return try setHabit(a)
            case "showWeather": return try await weatherView()
            case "showFitness": return try fitnessView(focus: a["focus"] as? String ?? "readiness")
            case "remember":
                guard let fact = (a["fact"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), fact.count >= 3 else {
                    throw Failure(message: "Say what to remember.")
                }
                addMemories([String(fact.prefix(300))])
                return ["output": ["ok": true, "remembered": fact]]
            case "forget":
                let hits = findMemories(a["find"] as? String ?? "")
                guard !hits.isEmpty else { return ["output": ["error": "Nothing in memory matches \"\(a["find"] as? String ?? "")\"."]] }
                for h in hits { db.run("delete from voice_memories where id = ?", [h.id]) }
                return ["output": ["ok": true, "forgot": hits.map(\.text)]]
            case "recall":
                let q = a["query"] as? String ?? ""
                return ["output": ["facts": findMemories(q).map(\.text), "pastRequests": searchRequests(q)]]
            case "showTodos": return todosView()
            case "addTodos":
                let items = (a["items"] as? [Any] ?? []).compactMap { $0 as? String }.map { String($0.prefix(200)) }
                guard !items.isEmpty else { throw Failure(message: "Say what to add.") }
                let before = Set(LocalTodos.list().compactMap { $0["id"] as? String })
                LocalTodos.add(Array(items.prefix(20)))
                let added = LocalTodos.list().filter { !before.contains($0["id"] as? String ?? "") }
                var result = todosView(changed: added.compactMap { $0["id"] as? String })
                result["output"] = merged(["ok": true, "added": added.compactMap { $0["text"] }], result["output"])
                return result
            case "checkTodo":
                let done = LocalHub.bool(a["done"]) ?? true
                let item = try findTodo(id: a["id"] as? String, find: a["find"] as? String, done: !done)
                LocalTodos.setDone(item.id, done)
                var result = todosView(changed: [item.id])
                result["output"] = merged(["ok": true, "item": item.text, "done": done], result["output"])
                return result
            case "removeTodo":
                let item = try findTodo(id: a["id"] as? String, find: a["find"] as? String, done: nil)
                db.run("delete from todos where id = ?", [item.id])
                var result = todosView()
                result["output"] = merged(["ok": true, "removed": item.text], result["output"])
                return result
            case "clearDoneTodos":
                let cleared = db.run("delete from todos where done")
                var result = todosView()
                result["output"] = merged(["ok": true, "cleared": cleared], result["output"])
                return result
            default:
                return ["output": ["error": "Unknown tool."]]
            }
        } catch let failure as Failure {
            return ["output": ["error": failure.message]]
        } catch let failure as LocalCalendar.Failure {
            return ["output": ["error": failure.message]]
        } catch {
            return ["output": ["error": "That didn't work."]]
        }
    }

    static func merged(_ a: [String: Any], _ b: Any?) -> [String: Any] { a.merging(b as? [String: Any] ?? [:]) { x, _ in x } }

    // MARK: Words

    static var today: String { LocalCalendar.day(Date()) }

    /// "Today", "Tomorrow" or "Wednesday, November 19".
    static func dayTitle(_ day: String) -> String {
        if day == today { return "Today" }
        if day == LocalDB.addDays(today, 1) { return "Tomorrow" }
        guard let date = LocalDB.date("\(day)T12:00:00Z") else { return day }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "EEEE, MMMM d"
        return f.string(from: date)
    }

    /// "9:30 AM" in the phone's time zone.
    static func localTime(_ iso: Any?) -> String {
        guard let date = LocalDB.date(iso as? String) else { return "" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US")
        f.timeZone = LocalCalendar.timeZone
        f.dateFormat = "h:mm a"
        return f.string(from: date)
    }

    // MARK: Money

    static func finance(_ a: [String: Any]) -> [String: Any] {
        guard SimpleFinCredential.read() != nil else { return ["output": ["error": "SimpleFIN isn't configured."]] }
        let input: [String: Any] = ["rows": LocalFinance.dashboardInput(), "input": a, "timeZone": LocalCalendar.timeZone.identifier]
        return HubJS.finance.call("voiceFinance", input) as? [String: Any] ?? ["output": ["error": "Couldn't load finances."]]
    }

    // MARK: Calendar

    static func eventsFor(_ first: String, days: Int) async throws -> [[String: Any]] {
        let events = try await LocalCalendar.listEvents(from: LocalCalendar.instant(first, 0),
                                                        to: LocalCalendar.instant(LocalDB.addDays(first, days), 0))
        return (0..<days).map { i in
            let day = LocalDB.addDays(first, i)
            let list = events.enumerated().filter { LocalCalendar.eventDays($0.element).contains(day) }.sorted { a, b in
                let (x, y) = ((a.element["allDay"] as? Bool) == true, (b.element["allDay"] as? Bool) == true)
                return x != y ? x : a.offset < b.offset
            }.map(\.element)
            return ["day": day, "events": list]
        }
    }

    static func calendarView(_ title: String, _ days: [[String: Any]], added: String? = nil, removed: String? = nil) -> [String: Any] {
        ["kind": "calendar", "title": title, "timeZone": LocalCalendar.timeZone.identifier, "days": days,
         "addedId": LocalHub.orNull(added), "removedId": LocalHub.orNull(removed)]
    }

    static func what(_ e: [String: Any]) -> String {
        let title = e["title"] as? String ?? ""
        return (e["allDay"] as? Bool) == true ? "\(title) (all day)" : "\(localTime(e["start"]))–\(localTime(e["end"])) \(title)"
    }

    static func showCalendar(day: String?, days: Int) async throws -> [String: Any] {
        let first = LocalHub.isDay(day) ? day! : today
        let list = try await eventsFor(first, days: days)
        return [
            "output": ["days": list.map { d in
                ["day": dayTitle(d["day"] as? String ?? ""),
                 "events": (d["events"] as? [[String: Any]] ?? []).map { ["id": $0["id"] ?? "", "what": what($0)] }]
            }],
            "view": calendarView(days == 1 ? dayTitle(first) : "Next \(days) days", list),
        ]
    }

    static let workoutMinutes = 90
    static let dayStart = 7 * 60, dayEnd = 21 * 60

    static func parseTime(_ value: String?) throws -> Int {
        let parts = (value ?? "").split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2, (0...23).contains(parts[0]), (0...59).contains(parts[1]) else { throw Failure(message: "Give the time as HH:mm.") }
        return parts[0] * 60 + parts[1]
    }

    /// The first gap of `minutes` between timed events, from `after` (local minutes) until 9 PM.
    static func freeSlot(_ events: [[String: Any]], day: String, after: Int, minutes: Int) -> Int? {
        let busy = events.filter { ($0["allDay"] as? Bool) != true }.compactMap { e -> (Int, Int)? in
            guard let s = LocalDB.date(e["start"] as? String), let en = LocalDB.date(e["end"] as? String) else { return nil }
            return (LocalCalendar.day(s) < day ? 0 : LocalCalendar.minutes(s), LocalCalendar.day(en) > day ? 24 * 60 : LocalCalendar.minutes(en))
        }.sorted { $0.0 < $1.0 }
        var cursor = max(after, dayStart)
        for (s, e) in busy {
            if s - cursor >= minutes { break }
            cursor = max(cursor, e)
        }
        return cursor + minutes <= dayEnd ? cursor : nil
    }

    static func addEvent(_ a: [String: Any]) async throws -> [String: Any] {
        guard let title = (a["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), (1...120).contains(title.count) else {
            throw Failure(message: "Give the event a title.")
        }
        let isWorkout = title.range(of: "\\b(workout|work out|gym|lift|lifting|run|running|training|exercise)\\b",
                                    options: [.regularExpression, .caseInsensitive]) != nil
        let minutes = LocalHub.int(a["durationMinutes"]) ?? (isWorkout ? workoutMinutes : 60)
        let asked = a["day"] as? String
        var day = LocalHub.isDay(asked) ? asked! : today
        if day < today { throw Failure(message: "That day has already passed.") }
        let start: Int
        if let time = a["startTime"] as? String {
            start = try parseTime(time)
        } else {
            // No time given: the first free slot, starting from the next half hour today.
            let now = LocalCalendar.minutes(Date())
            var slot: Int?
            for _ in 0..<3 where slot == nil {
                let events = try await eventsFor(day, days: 1).first?["events"] as? [[String: Any]] ?? []
                let after = day == today ? Int((Double(now + 5) / 30).rounded(.up)) * 30 : dayStart
                slot = freeSlot(events, day: day, after: after, minutes: minutes)
                if slot == nil {
                    if LocalHub.isDay(asked) { break }
                    day = LocalDB.addDays(day, 1)
                }
            }
            guard let slot else { throw Failure(message: "There's no free \(minutes)-minute slot on \(dayTitle(day)) between 7 AM and 9 PM.") }
            start = slot
        }
        let created = try await LocalCalendar.createEvent(title: title, start: LocalCalendar.instant(day, start),
                                                          end: LocalCalendar.instant(day, start + minutes))
        LocalCalendar.cache.clear()
        var days = try await eventsFor(day, days: 1)
        let createdId = created["id"] as? String ?? ""
        var events = days[0]["events"] as? [[String: Any]] ?? []
        // Google can take a moment to list a new event; make sure it's on the card.
        if !events.contains(where: { ($0["id"] as? String) == createdId }) {
            events.append(created)
            days[0]["events"] = events
        }
        return [
            "output": ["ok": true, "added": created["title"] ?? title, "day": dayTitle(day), "start": localTime(created["start"]),
                       "end": localTime(created["end"]), "id": createdId,
                       "sameDay": events.filter { ($0["id"] as? String) != createdId }.map { e in
                           (e["allDay"] as? Bool) == true ? "\(e["title"] ?? "") (all day)" : "\(localTime(e["start"])) \(e["title"] ?? "")"
                       }],
            "view": calendarView(dayTitle(day), days, added: createdId),
        ]
    }

    /// The event a request means: by id, else by title words on a day or over the next two weeks.
    static func resolveEvent(_ a: [String: Any]) async throws -> (id: String, title: String) {
        if let id = a["eventId"] as? String, !id.isEmpty { return (id, try await LocalCalendar.getEvent(id).title) }
        guard let needle = (a["find"] as? String)?.trimmingCharacters(in: .whitespaces).lowercased(), !needle.isEmpty else {
            throw Failure(message: "Say which event: pass find (its title) or eventId.")
        }
        let onDay = a["onDay"] as? String
        let first = LocalHub.isDay(onDay) ? onDay! : today
        var seen = Set<String>()
        let all = try await eventsFor(first, days: LocalHub.isDay(onDay) ? 1 : 14)
            .flatMap { $0["events"] as? [[String: Any]] ?? [] }
            .filter { seen.insert($0["id"] as? String ?? "").inserted }
        let matches = all.filter { ($0["title"] as? String ?? "").lowercased().contains(needle) }
        let exact = matches.filter { ($0["title"] as? String ?? "").lowercased() == needle }
        let pick = exact.count == 1 ? exact : matches
        if pick.isEmpty {
            throw Failure(message: "No event matching \"\(a["find"] as? String ?? "")\" \(LocalHub.isDay(onDay) ? "on \(dayTitle(first))" : "in the next two weeks").")
        }
        if pick.count > 1 {
            let list = pick.prefix(6).map { e in
                "\(e["title"] ?? "") \(dayTitle(LocalCalendar.eventDays(e).first ?? ""))\((e["allDay"] as? Bool) == true ? "" : " \(localTime(e["start"]))") [eventId \(e["id"] ?? "")]"
            }.joined(separator: "; ")
            throw Failure(message: "Several events match: \(list). Ask which one, then call again with its eventId.")
        }
        return (pick[0]["id"] as? String ?? "", pick[0]["title"] as? String ?? "")
    }

    static func editEvent(_ a: [String: Any]) async throws -> [String: Any] {
        let (id, _) = try await resolveEvent(a)
        let current = try await LocalCalendar.getEvent(id)
        let newTitle = (a["newTitle"] as? String)?.trimmingCharacters(in: .whitespaces)
        let moving = a["newDay"] != nil || a["newStartTime"] != nil || a["durationMinutes"] != nil
        if !moving && (newTitle?.isEmpty ?? true) { throw Failure(message: "Nothing to change: pass newTitle, newDay, newStartTime or durationMinutes.") }
        if moving && current.allDay { throw Failure(message: "I can only move timed events, not all-day ones.") }
        var day = current.start.map(LocalCalendar.day) ?? today
        var start: Date?, end: Date?
        if moving, let s = current.start, let e = current.end {
            let length = LocalHub.int(a["durationMinutes"]) ?? Int((e.timeIntervalSince(s) / 60).rounded())
            if let newDay = a["newDay"] as? String {
                guard LocalHub.isDay(newDay) else { throw Failure(message: "Give the day as YYYY-MM-DD.") }
                day = newDay
            }
            let startMin = a["newStartTime"] != nil ? try parseTime(a["newStartTime"] as? String) : LocalCalendar.minutes(s)
            start = LocalCalendar.instant(day, startMin)
            end = LocalCalendar.instant(day, startMin + length)
        }
        try await LocalCalendar.updateEvent(id, title: (newTitle?.isEmpty ?? true) ? nil : newTitle, start: start, end: end)
        LocalCalendar.cache.clear()
        let days = try await eventsFor(day, days: 1)
        let moved = (days[0]["events"] as? [[String: Any]] ?? []).first { ($0["id"] as? String) == id }
        var output: [String: Any] = ["ok": true, "updated": moved?["title"] ?? newTitle ?? current.title, "day": dayTitle(day)]
        if let moved, (moved["allDay"] as? Bool) != true { output["start"] = localTime(moved["start"]); output["end"] = localTime(moved["end"]) }
        return ["output": output, "view": calendarView(dayTitle(day), days, added: id)]
    }

    static func deleteEvent(_ a: [String: Any]) async throws -> [String: Any] {
        let (id, title) = try await resolveEvent(a)
        let current = try await LocalCalendar.getEvent(id)
        let day = current.start.map(LocalCalendar.day) ?? today
        // The day as it was, so the card can show the event leaving.
        let before = try await eventsFor(day, days: 1)
        try await LocalCalendar.deleteEvent(id)
        LocalCalendar.cache.clear()
        return ["output": ["ok": true, "deleted": title, "day": dayTitle(day)], "view": calendarView(dayTitle(day), before, removed: id)]
    }

    // MARK: Habits

    static func habitsView(changed: String? = nil) -> [String: Any] {
        let day = today
        var doneDays: [String: Set<String>] = [:]
        for c in LocalHabits.completions() {
            if let id = c["habitId"] as? String, let date = c["date"] as? String { doneDays[id, default: []].insert(date) }
        }
        let rows = LocalHabits.habits().map { h -> [String: Any] in
            let id = h["id"] as? String ?? ""
            let days = doneDays[id] ?? []
            // A streak still counts while today is open: it runs back from today or yesterday.
            var cursor = days.contains(day) ? day : LocalDB.addDays(day, -1)
            var streak = 0
            while days.contains(cursor) { streak += 1; cursor = LocalDB.addDays(cursor, -1) }
            return ["id": id, "name": h["name"] ?? "", "color": h["color"] ?? "", "icon": h["icon"] ?? NSNull(), "done": days.contains(day), "streak": streak]
        }
        return [
            "output": ["today": day, "habits": rows.map { ["id": $0["id"]!, "name": $0["name"]!, "doneToday": $0["done"]!, "streakDays": $0["streak"]!] }],
            "view": ["kind": "habits", "date": day, "habits": rows, "changedId": LocalHub.orNull(changed)],
        ]
    }

    static func setHabit(_ a: [String: Any]) throws -> [String: Any] {
        let habits = LocalHabits.habits()
        let id = (a["habitId"] as? String ?? "").lowercased()
        guard let habit = habits.first(where: { ($0["id"] as? String) == id }) else {
            throw Failure(message: "No habit with id \(id). Habits: \(habits.map { "\($0["name"] ?? "") (\($0["id"] ?? ""))" }.joined(separator: ", "))")
        }
        let done = LocalHub.bool(a["done"]) ?? true
        LocalHabits.setCompletion(id, today, done)
        var result = habitsView(changed: id)
        result["output"] = merged(["ok": true, "habit": habit["name"] ?? "", "done": done], result["output"])
        return result
    }

    // MARK: Weather

    static func weatherView() async throws -> [String: Any] {
        let w: [String: Any]
        if let cached = LocalWeather.cache.get(maxAge: 600) {
            w = cached
        } else {
            do {
                w = try await LocalWeather.fetch()
                LocalWeather.cache.put(w)
            } catch {
                guard let stale = LocalWeather.cache.get(maxAge: .infinity) else { throw Failure(message: "Couldn't get the weather right now.") }
                w = stale
            }
        }
        let current = w["current"] as? [String: Any] ?? [:]
        let days = w["days"] as? [[String: Any]] ?? []
        let hours = w["hours"] as? [[String: Any]] ?? []
        var output: [String: Any] = [
            "place": w["place"] ?? "",
            "now": "\(current["temp"] ?? 0) degrees, \((current["label"] as? String ?? "").lowercased()), feels like \(current["feelsLike"] ?? 0)",
            "nextDays": days.dropFirst().prefix(3).map { d in
                "\(dayTitle(d["day"] as? String ?? "")): \(d["high"] ?? 0)/\(d["low"] ?? 0), \(LocalHub.int(d["precipChance"]) ?? 0)% rain"
            },
        ]
        if let t = days.first { output["today"] = "high \(t["high"] ?? 0), low \(t["low"] ?? 0), \(LocalHub.int(t["precipChance"]) ?? 0)% chance of rain" }
        if let rain = hours.first(where: { (LocalHub.int($0["precipChance"]) ?? 0) >= 50 }), let time = rain["time"] as? String, time.count >= 13,
           let h = Int(time.dropFirst(11).prefix(2)) {
            output["rainLikelyAt"] = "\(h % 12 == 0 ? 12 : h % 12) \(h < 12 ? "AM" : "PM")"
        }
        return ["output": output, "view": ["kind": "weather", "weather": w]]
    }

    // MARK: Fitness

    final class SnapshotCache: @unchecked Sendable {
        private let lock = NSLock()
        private var entry: (at: Date, value: [String: Any])?
        func get() -> [String: Any]? {
            lock.lock(); defer { lock.unlock() }
            guard let e = entry, Date().timeIntervalSince(e.at) < 300 else { return nil }
            return e.value
        }
        func put(_ v: [String: Any]) { lock.lock(); entry = (Date(), v); lock.unlock() }
    }
    static let snapshots = SnapshotCache()

    static func fitnessView(focus: String) throws -> [String: Any] {
        guard let snap = snapshots.get() ?? (LocalFitness.snapshot() as? [String: Any]) else { throw Failure(message: "Couldn't load the fitness numbers.") }
        snapshots.put(snap)
        let days = snap["days"] as? [[String: Any]] ?? []
        let sleep = snap["sleep"] as? [[String: Any]] ?? []
        let activities = snap["activities"] as? [[String: Any]] ?? []
        let metrics = snap["metrics"] as? [String: Any] ?? [:]
        let readiness = metrics["readiness"] as? [String: Any] ?? [:]
        let latest = days.first { !($0["steps"] is NSNull) && $0["steps"] != nil }
        let night = sleep.first
        let sleepSeconds: Int? = night.map { n in ["deepSeconds", "lightSeconds", "remSeconds"].reduce(0) { $0 + (LocalHub.int(n[$1]) ?? 0) } }.flatMap { $0 > 0 ? $0 : nil }
        let byDay = Dictionary(days.compactMap { d in (d["day"] as? String).map { ($0, d["steps"] ?? NSNull()) } }) { a, _ in a }
        let week = (0..<7).map { i -> [String: Any] in
            let day = LocalDB.addDays(today, i - 6)
            return ["day": day, "steps": byDay[day] ?? NSNull()]
        }
        let w = activities.first
        let minutes = w.flatMap { LocalHub.number($0["elapsedSeconds"]) }.map { Int(($0 / 60).rounded()) }
        let fitness: [String: Any] = [
            "focus": ["readiness", "sleep", "bodyBattery", "steps", "heart", "workout"].contains(focus) ? focus : "readiness",
            "readiness": readiness["score"] ?? NSNull(),
            "readinessLevel": readiness["level"] ?? NSNull(),
            "sleepScore": night?["score"] ?? NSNull(),
            "sleepSeconds": LocalHub.orNull(sleepSeconds),
            "bodyBattery": (metrics["bodyBattery"] as? [String: Any])?["current"] ?? NSNull(),
            "stepsDay": latest?["day"] ?? NSNull(),
            "steps": latest?["steps"] ?? NSNull(),
            "stepGoal": latest?["stepGoal"] ?? NSNull(),
            "restingHr": days.first { !($0["restingHr"] is NSNull) && $0["restingHr"] != nil }?["restingHr"] ?? NSNull(),
            "hrv": (snap["hrv"] as? [[String: Any]])?.first?["lastNightAverage"] ?? NSNull(),
            "week": week,
            "lastWorkout": w.map { w -> Any in
                ["sport": w["sport"] ?? "", "startTime": w["startTime"] ?? "", "minutes": LocalHub.orNull(minutes), "distanceMeters": w["distanceMeters"] ?? NSNull()]
            } ?? NSNull(),
        ]
        let hours = sleepSeconds.map { (Double($0) / 3600 * 10).rounded() / 10 }
        var lastWorkout: Any = NSNull()
        if let w, let start = LocalDB.date(w["startTime"] as? String) {
            lastWorkout = "\(w["sport"] ?? "") \(dayTitle(LocalCalendar.day(start)))\(minutes.map { ", \($0) min" } ?? "")"
        }
        return [
            "output": [
                "readiness": fitness["readiness"]!, "readinessLevel": fitness["readinessLevel"]!, "sleepScore": fitness["sleepScore"]!,
                "sleepHours": LocalHub.orNull(hours), "bodyBattery": fitness["bodyBattery"]!, "steps": fitness["steps"]!,
                "stepsDay": (fitness["stepsDay"] as? String).map(dayTitle) ?? NSNull(), "restingHr": fitness["restingHr"]!,
                "hrv": fitness["hrv"]!, "lastWorkout": lastWorkout,
            ],
            "view": ["kind": "fitness", "fitness": fitness],
        ]
    }

    /// Which fitness number a request is about, from its words.
    static func guessFocus(_ transcript: String) -> String {
        let t = transcript.lowercased()
        func has(_ p: String) -> Bool { t.range(of: p, options: .regularExpression) != nil }
        if has("\\bsteps?\\b|walked|walking") { return "steps" }
        if has("sleep|slept|\\bnight\\b|\\bbed\\b") { return "sleep" }
        if has("battery|energy|tired|drained") { return "bodyBattery" }
        if has("heart|\\bhrv\\b|pulse|resting") { return "heart" }
        if has("workout|\\bran\\b|\\brun\\b|lift|gym|exercise|trained") { return "workout" }
        return "readiness"
    }

    // MARK: To-dos

    static func todosView(changed: [String] = []) -> [String: Any] {
        let items = LocalTodos.list()
        return [
            "output": ["open": items.filter { ($0["done"] as? Bool) != true }.compactMap { $0["text"] },
                       "doneToday": items.filter { ($0["done"] as? Bool) == true }.compactMap { $0["text"] }],
            "view": ["kind": "todos", "items": items, "changed": changed],
        ]
    }

    /// The open (or, to undo, checked) item a request means: by id, else by words from its text.
    static func findTodo(id: String?, find: String?, done: Bool?) throws -> (id: String, text: String) {
        let items = LocalTodos.list()
        func pair(_ t: [String: Any]) -> (String, String) { (t["id"] as? String ?? "", t["text"] as? String ?? "") }
        if let id, let hit = items.first(where: { ($0["id"] as? String) == id.lowercased() }) { return pair(hit) }
        guard let needle = find?.trimmingCharacters(in: .whitespaces).lowercased(), !needle.isEmpty else {
            throw Failure(message: "Say which item: pass find (words from it).")
        }
        let pool = done == nil ? items : items.filter { ($0["done"] as? Bool) == done }
        let matches = pool.filter { ($0["text"] as? String ?? "").lowercased().contains(needle) }
        let exact = matches.filter { ($0["text"] as? String ?? "").lowercased() == needle }
        let pick = exact.count == 1 ? exact : matches
        if pick.isEmpty {
            let list = items.compactMap { $0["text"] as? String }.joined(separator: "; ")
            throw Failure(message: "Nothing on the list matches \"\(find ?? "")\". List: \(list.isEmpty ? "empty" : list).")
        }
        if pick.count > 1 {
            throw Failure(message: "Several match: \(pick.map { "\($0["text"] ?? "") [id \($0["id"] ?? "")]" }.joined(separator: "; ")). Ask which, then call again with its id.")
        }
        return pair(pick[0])
    }

    // MARK: Intent

    /// Real data for the screen the Pi's router guessed, for the cards the phone owns.
    static func prefetch(_ screen: String, _ transcript: String) async -> [String: Any]? {
        switch screen {
        case "habits": return habitsView()["view"] as? [String: Any]
        case "todos": return todosView()["view"] as? [String: Any]
        case "calendar": return (try? await showCalendar(day: nil, days: 1))?["view"] as? [String: Any]
        case "weather": return (try? await weatherView())?["view"] as? [String: Any]
        case "fitness": return (try? fitnessView(focus: guessFocus(transcript)))?["view"] as? [String: Any]
        default: return nil
        }
    }

    // MARK: Memory (lib/agent/memory.ts)

    static func listMemories(_ limit: Int = 80) -> [(id: String, text: String)] {
        db.query("select id, text from voice_memories order by updated_at desc limit ?", [limit])
            .map { ($0["id"] as? String ?? "", $0["text"] as? String ?? "") }
    }

    /// Saying the same thing again refreshes it instead of storing a duplicate.
    static func addMemories(_ texts: [String]) {
        let now = LocalDB.iso(Date())
        for text in Set(texts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }) {
            if db.run("update voice_memories set updated_at = ? where lower(text) = lower(?)", [now, text]) == 0 {
                db.run("insert into voice_memories (id, text, updated_at) values (?, ?, ?)", [LocalDB.uuid(), text, now])
            }
        }
    }

    /// Facts whose text contains every word of `find`.
    static func findMemories(_ find: String) -> [(id: String, text: String)] {
        let words = find.lowercased().split(whereSeparator: \.isWhitespace).map(String.init).filter { $0.count > 1 }
        guard !words.isEmpty else { return [] }
        let clause = words.map { _ in "lower(text) like ?" }.joined(separator: " and ")
        return db.query("select id, text from voice_memories where \(clause) order by updated_at desc limit 10", words.map { "%\($0)%" })
            .map { ($0["id"] as? String ?? "", $0["text"] as? String ?? "") }
    }

    static func recentRequests(_ limit: Int = 15) -> [[String: Any]] {
        db.query("select heard, reply, created_at as at from voice_log order by created_at desc limit ?", [limit]).reversed()
    }

    /// Past exchanges mentioning any of the words, newest first.
    static func searchRequests(_ text: String, limit: Int = 10) -> [[String: Any]] {
        let words = text.lowercased().split(whereSeparator: \.isWhitespace).map(String.init).filter { $0.count > 2 }
        guard !words.isEmpty else { return recentRequests(limit) }
        let clause = words.map { _ in "lower(heard || ' ' || reply) like ?" }.joined(separator: " or ")
        return db.query("select heard, reply, created_at as at from voice_log where \(clause) order by created_at desc limit ?",
                        words.map { "%\($0)%" } + [limit])
    }

    /// What Jarvis knows, for the session's instructions.
    static func memoryInstructions() -> String {
        let facts = listMemories()
        let recent = recentRequests()
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US")
        f.timeZone = LocalCalendar.timeZone
        f.dateFormat = "EEE, MMM d, h:mm a"
        let factList = facts.isEmpty ? "nothing yet." : facts.map { "\n- \($0.text)" }.joined()
        let recentList = recent.isEmpty ? "none yet." : recent.map { r in
            let when = LocalDB.date(r["at"] as? String).map(f.string) ?? ""
            return "\n- \(when): \"\(r["heard"] ?? "")\" → you said \"\(String((r["reply"] as? String ?? "").prefix(160)))\""
        }.joined()
        return """
        Memory:
        What you know about them (use it naturally, never recite it): \(factList)
        Their recent requests, oldest first: \(recentList)
        - "Remember that…", or a lasting preference, interest or fact about their life → remember. "Forget that…" → forget.
        - "What did I ask you…", "what was that movie I wanted", anything older than the list above → recall.
        - Facts are learned from conversations automatically too, so only call remember when asked or for something clearly worth keeping.
        """
    }

    static let learnModel = "anthropic/claude-haiku-5.5"

    /// Reads one exchange and updates what's known about the user, with a small model through the Pi.
    /// A failure only means nothing was learned this time.
    static func learn(heard: String, reply: String, via original: URLRequest) async {
        let known = listMemories(200)
        let name = "William"
        let prompt = """
        You keep the long-term memory of Jarvis, \(name)'s home voice assistant.

        Known facts (id: text):
        \(known.isEmpty ? "(none)" : known.map { "\($0.id): \($0.text)" }.joined(separator: "\n"))

        New exchange:
        \(name): "\(heard)"
        Jarvis: "\(reply)"

        Return facts worth knowing for weeks or months: preferences (how they like the lights, favorite shows, genres), interests, people and pets in their life, routines (wake time, workouts), goals, and standing requests ("always…", "don't…"). Skip one-off commands ("turn off the lamp"), what's already known, small talk, and anything Jarvis said rather than \(name). Most exchanges teach nothing: return empty lists then. In forget, list ids of known facts this exchange clearly replaces.
        """
        let schema: [String: Any] = [
            "type": "object", "additionalProperties": false, "required": ["remember", "forget"],
            "properties": [
                "remember": ["type": "array", "items": ["type": "string"], "description": "New durable facts, each one short sentence in the third person"],
                "forget": ["type": "array", "items": ["type": "string"], "description": "Ids of known facts this exchange shows are wrong or out of date"],
            ],
        ]
        let body: [String: Any] = ["model": learnModel, "messages": [["role": "user", "content": prompt]], "output": schema, "tags": ["memory", "iphone"]]
        guard let (data, http) = try? await LocalHub.forward(original, path: "/api/mobile/llm", method: "POST", body: body, timeout: 60),
              http.statusCode == 200,
              let object = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["object"] as? [String: Any] else { return }
        let ids = Set(known.map(\.id))
        for id in (object["forget"] as? [String] ?? []) where ids.contains(id) { db.run("delete from voice_memories where id = ?", [id]) }
        addMemories(object["remember"] as? [String] ?? [])
    }
}
