import Foundation

/// The workout logger (was lib/workouts/store.ts, heart-rate.ts and the
/// /api/mobile/workouts routes): the exercise library plus custom exercises,
/// routines, and logged workouts with one row per checked-off set.
nonisolated enum LocalWorkouts {
    static let muscles: Set<String> = ["chest", "back", "shoulders", "biceps", "triceps", "forearms",
                                       "quads", "hamstrings", "glutes", "calves", "core", "full_body", "cardio"]
    static let equipment: Set<String> = ["barbell", "dumbbell", "machine", "cable", "bodyweight", "kettlebell", "band", "other"]
    static let exerciseKinds: Set<String> = ["weight_reps", "reps", "duration"]
    static let setKinds: Set<String> = ["warmup", "normal", "drop", "failure"]

    static func register(_ r: inout [String: LocalHub.Handler]) {
        r["GET /api/mobile/workouts"] = { _ in .ok(home()) }
        r["POST /api/mobile/workouts"] = { req in
            guard let input = WorkoutInput(req.body) else { return .error("Not a valid workout.") }
            guard input.endedAt >= input.startedAt else { return .error("The workout ends before it starts.") }
            save(input)
            return detail(input.id).map(LocalHub.Reply.created) ?? .notFound
        }
        r["GET /api/mobile/workouts/detail"] = { req in
            guard let id = req.param("id"), LocalHub.isUUID(id) else { return .error("Not a valid workout.") }
            return detail(id.lowercased()).map(LocalHub.Reply.ok) ?? .notFound
        }
        r["DELETE /api/mobile/workouts/detail"] = { req in
            guard let id = req.param("id"), LocalHub.isUUID(id) else { return .error("Not a valid workout.") }
            return .ok(["deleted": LocalHub.db.run("delete from workouts where id = ?", [id.lowercased()]) > 0])
        }
        r["GET /api/mobile/workouts/exercises"] = { req in
            guard let id = req.param("id"), (1...80).contains(id.count) else { return .error("Not a valid exercise.") }
            return .ok(["sessions": history(id)])
        }
        r["POST /api/mobile/workouts/exercises"] = { req in
            let o = req.object
            guard let name = trimmedName(o["name"]),
                  let muscle = o["muscle"] as? String, muscles.contains(muscle),
                  let equip = o["equipment"] as? String, equipment.contains(equip) else { return .error("Not a valid exercise.") }
            let kind = o["kind"] as? String ?? "weight_reps"
            guard exerciseKinds.contains(kind) else { return .error("Not a valid exercise.") }
            let id = LocalDB.uuid()
            LocalHub.db.run("insert into workout_exercises (id, name, muscle, equipment, kind, created_at) values (?, ?, ?, ?, ?, ?)",
                            [id, name, muscle, equip, kind, LocalDB.iso(Date())])
            return .created(["id": id, "name": name, "muscle": muscle, "equipment": equip, "kind": kind, "custom": true])
        }
        r["PUT /api/mobile/workouts/place"] = { req in
            let o = req.object
            guard let id = o["id"] as? String, LocalHub.isUUID(id), let place = place(o["place"]) else { return .error("Not a valid place.") }
            let changed = LocalHub.db.run("update workouts set place = ?, updated_at = ? where id = ?",
                                          [LocalDB.json(place), LocalDB.iso(Date()), id.lowercased()])
            return changed > 0 ? .done : .notFound
        }
        r["POST /api/mobile/workouts/routines"] = { req in
            guard let routine = routine(req.body) else { return .error("Not a valid routine.") }
            LocalHub.db.run(
                """
                insert into workout_routines (id, name, exercises, position, updated_at) values (?, ?, ?, ?, ?)
                on conflict (id) do update set name = excluded.name, exercises = excluded.exercises,
                  position = excluded.position, updated_at = excluded.updated_at
                """, [routine.id, routine.name, LocalDB.json(routine.exercises), routine.position, LocalDB.iso(Date())])
            return .done
        }
        r["DELETE /api/mobile/workouts/routines"] = { req in
            guard let id = req.param("id"), LocalHub.isUUID(id) else { return .error("Not a valid routine.") }
            return .ok(["deleted": LocalHub.db.run("delete from workout_routines where id = ?", [id.lowercased()]) > 0])
        }
    }

    // MARK: Library

    /// The built-in library (exercise-library.json, exported from the hub's lib/workouts/library.ts):
    /// `[id, name, muscle, equipment, kind]`. Ids are stable slugs.
    static let library: [[String: Any]] = {
        guard let url = Bundle.main.url(forResource: "exercise-library", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let rows = try? JSONSerialization.jsonObject(with: data) as? [[Any]] else { return [] }
        return rows.compactMap { e in
            guard e.count >= 4 else { return nil }
            return ["id": e[0], "name": e[1], "muscle": e[2], "equipment": e[3],
                    "kind": e.count > 4 ? e[4] : "weight_reps", "custom": false]
        }
    }()

    // MARK: Home

    static func home() -> [String: Any] {
        let db = LocalHub.db
        let custom = db.query("select id, name, muscle, equipment, kind from workout_exercises where not archived order by name")
            .map { row -> [String: Any] in
                ["id": LocalHub.value(row, "id"), "name": LocalHub.value(row, "name"), "muscle": LocalHub.value(row, "muscle"),
                 "equipment": LocalHub.value(row, "equipment"), "kind": LocalHub.value(row, "kind"), "custom": true]
            }
        let routines = db.query("select id, name, position, exercises, updated_at from workout_routines order by position, name")
            .map { row -> [String: Any] in
                ["id": LocalHub.value(row, "id"), "name": LocalHub.value(row, "name"), "position": LocalHub.value(row, "position"),
                 "exercises": LocalDB.parse(row["exercises"]), "updatedAt": LocalHub.value(row, "updated_at")]
            }
        let workouts = db.query("select id, name, started_at, ended_at, hr_series, place from workouts order by started_at desc limit 60")

        // Every set of the listed workouts, plus the sets from the newest workout each exercise appears in.
        let sets = db.query(
            """
            with listed as (select id from workouts order by started_at desc limit 60),
                 ranked as (
                   select s.exercise_id, s.workout_id,
                          row_number() over (partition by s.exercise_id order by w.started_at desc) as n
                     from workout_sets s join workouts w on w.id = s.workout_id
                    where s.completed_at is not null),
                 latest as (select exercise_id, workout_id from ranked where n = 1)
            select s.*, exists (select 1 from latest l where l.workout_id = s.workout_id and l.exercise_id = s.exercise_id) as latest
              from workout_sets s
             where s.workout_id in (select id from listed)
                or exists (select 1 from latest l where l.workout_id = s.workout_id and l.exercise_id = s.exercise_id)
             order by s.workout_id, s.exercise_order, s.set_order
            """)

        let bests = db.query(
            """
            with scored as (
              select s.exercise_id, s.weight_kg, s.reps, s.completed_at,
                     case when s.reps = 1 then s.weight_kg else s.weight_kg * (1 + s.reps / 30.0) end as e1rm
                from workout_sets s
               where s.completed_at is not null and s.kind <> 'warmup' and s.weight_kg > 0 and s.reps between 1 and 12),
            ranked as (select *, row_number() over (partition by exercise_id order by e1rm desc) as n from scored)
            select exercise_id, e1rm, weight_kg, reps, completed_at from ranked where n = 1
            """)

        var byWorkout: [String: [LocalDB.Row]] = [:]
        var previous: [String: [[String: Any]]] = [:]
        for row in sets {
            let workoutId = row["workout_id"] as? String ?? ""
            byWorkout[workoutId, default: []].append(row)
            if (row["latest"] as? Int ?? 0) == 1, !(row["completed_at"] is NSNull), let exercise = row["exercise_id"] as? String {
                previous[exercise, default: []].append(
                    ["kind": LocalHub.value(row, "kind"), "weightKg": LocalHub.value(row, "weight_kg"),
                     "reps": LocalHub.value(row, "reps"), "durationSeconds": LocalHub.value(row, "duration_s")])
            }
        }

        let summaries = workouts.map { w -> [String: Any] in
            let id = w["id"] as? String ?? ""
            let rows = (byWorkout[id] ?? []).filter { !($0["completed_at"] is NSNull) }
            let start = ms(w["started_at"]), end = ms(w["ended_at"])
            let hr = summary(series(start: start, points: LocalDB.parse(w["hr_series"])), from: start, to: end)
            var names: [String] = []
            for r in rows { if let n = r["exercise_name"] as? String, !names.contains(n) { names.append(n) } }
            return ["id": id, "name": LocalHub.value(w, "name"), "startedAt": LocalHub.value(w, "started_at"),
                    "endedAt": LocalHub.value(w, "ended_at"), "exercises": names,
                    "sets": rows.filter { ($0["kind"] as? String) != "warmup" }.count,
                    "volumeKg": volume(rows), "avgHr": LocalHub.orNull(hr.avg), "maxHr": LocalHub.orNull(hr.max),
                    "place": LocalDB.parse(w["place"])]
        }

        var bestMap: [String: Any] = [:]
        for b in bests {
            guard let id = b["exercise_id"] as? String else { continue }
            bestMap[id] = ["e1rmKg": LocalHub.value(b, "e1rm"), "weightKg": LocalHub.value(b, "weight_kg"),
                           "reps": LocalHub.value(b, "reps"), "at": LocalHub.value(b, "completed_at")]
        }
        return ["exercises": library + custom, "routines": routines, "workouts": summaries, "previous": previous, "bests": bestMap]
    }

    // MARK: Save

    struct WorkoutInput {
        struct Set { let kind: String; let weightKg, durationSeconds, rpe: Double?; let reps: Int?; let completedAt, startedAt: String?; let liveHr: Int? }
        struct Exercise { let exerciseId, name: String; let superset: Int?; let sets: [Set] }
        let id, name: String
        let routineId: String?
        let startedAt, endedAt: String
        let notes: String?
        let heartRate: [[Double]]
        let exercises: [Exercise]
        let place: [String: Any]?

        init?(_ raw: Any) {
            guard let o = raw as? [String: Any],
                  let id = o["id"] as? String, LocalHub.isUUID(id),
                  let name = LocalWorkouts.trimmedName(o["name"]),
                  let started = LocalDB.normalized(o["startedAt"]), let ended = LocalDB.normalized(o["endedAt"]),
                  let exercises = o["exercises"] as? [[String: Any]], exercises.count <= 60 else { return nil }
            self.id = id.lowercased()
            self.name = name
            self.routineId = (o["routineId"] as? String).flatMap { LocalHub.isUUID($0) ? $0.lowercased() : nil }
            self.startedAt = started
            self.endedAt = ended
            self.notes = (o["notes"] as? String).map { String($0.prefix(4000)) }
            self.heartRate = (o["heartRate"] as? [[Any]] ?? []).prefix(20_000).compactMap { p in
                guard p.count >= 2, let t = LocalHub.number(p[0]), let bpm = LocalHub.number(p[1]), (20...250).contains(bpm) else { return nil }
                return [t, bpm.rounded()]
            }
            var parsed: [Exercise] = []
            for e in exercises {
                guard let exerciseId = e["exerciseId"] as? String, (1...80).contains(exerciseId.count),
                      let name = LocalWorkouts.trimmedName(e["name"]) else { return nil }
                let sets = (e["sets"] as? [[String: Any]] ?? []).prefix(100).map { s in
                    Set(kind: (s["kind"] as? String).flatMap { LocalWorkouts.setKinds.contains($0) ? $0 : nil } ?? "normal",
                        weightKg: LocalHub.number(s["weightKg"]), durationSeconds: LocalHub.number(s["durationSeconds"]),
                        rpe: LocalHub.number(s["rpe"]), reps: LocalHub.int(s["reps"]),
                        completedAt: LocalDB.normalized(s["completedAt"]), startedAt: LocalDB.normalized(s["startedAt"]),
                        liveHr: LocalHub.int(s["liveHr"]))
                }
                parsed.append(Exercise(exerciseId: exerciseId, name: name, superset: LocalHub.int(e["superset"]), sets: Array(sets)))
            }
            self.exercises = parsed
            self.place = LocalWorkouts.place(o["place"])
        }
    }

    /// Stores a finished workout, replacing any earlier copy with the same id (the phone retries
    /// uploads). Only checked-off sets are kept; a known place survives an upload without one.
    static func save(_ w: WorkoutInput) {
        let db = LocalHub.db
        db.transaction {
            db.run(
                """
                insert into workouts (id, name, routine_id, started_at, ended_at, notes, hr_series, place, updated_at)
                values (?, ?, ?, ?, ?, ?, ?, ?, ?)
                on conflict (id) do update set name = excluded.name, routine_id = excluded.routine_id,
                  started_at = excluded.started_at, ended_at = excluded.ended_at, notes = excluded.notes,
                  hr_series = excluded.hr_series, place = coalesce(excluded.place, workouts.place), updated_at = excluded.updated_at
                """,
                [w.id, w.name, w.routineId, w.startedAt, w.endedAt, w.notes, LocalDB.json(w.heartRate) ?? "[]",
                 w.place.flatMap(LocalDB.json), LocalDB.iso(Date())])
            db.run("delete from workout_sets where workout_id = ?", [w.id])
            for (exerciseOrder, e) in w.exercises.enumerated() {
                for (setOrder, s) in e.sets.filter({ $0.completedAt != nil }).enumerated() {
                    db.run(
                        """
                        insert into workout_sets (workout_id, exercise_order, set_order, exercise_id, exercise_name, superset, kind,
                                                  weight_kg, reps, duration_s, rpe, completed_at, started_at, live_hr)
                        values (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                        """,
                        [w.id, exerciseOrder, setOrder, e.exerciseId, e.name, e.superset, s.kind,
                         s.weightKg, s.reps, s.durationSeconds, s.rpe, s.completedAt, s.startedAt, s.liveHr])
                }
            }
        }
    }

    // MARK: Detail

    static func detail(_ id: String) -> [String: Any]? {
        let db = LocalHub.db
        guard let w = db.one("select * from workouts where id = ?", [id]) else { return nil }
        let startedAt = w["started_at"] as? String ?? ""
        let endedAt = w["ended_at"] as? String ?? ""
        let start = ms(startedAt), end = ms(endedAt)
        let sets = db.query("select * from workout_sets where workout_id = ? order by exercise_order, set_order", [id])
        var best: [String: Double] = [:]
        for row in db.query(
            """
            select s.exercise_id, max(case when s.reps = 1 then s.weight_kg else s.weight_kg * (1 + s.reps / 30.0) end) as e1rm
              from workout_sets s join workouts w on w.id = s.workout_id
             where w.started_at < ? and s.completed_at is not null and s.kind <> 'warmup' and s.weight_kg > 0 and s.reps between 1 and 12
             group by s.exercise_id
            """, [startedAt]) {
            if let e = row["exercise_id"] as? String, let v = LocalHub.number(row["e1rm"]) { best[e] = v }
        }

        // The watch's activity file (second-by-second) is preferred when one overlaps; until
        // fitness data lives on the phone, the live stream recorded during the workout is used.
        let activity = LocalWorkouts.overlappingActivity?(startedAt, endedAt)
        let activitySeries = activity.map { series(start: ms($0.start), points: $0.points) } ?? []
        let live = series(start: start, points: LocalDB.parse(w["hr_series"]))
        let useActivity = !activitySeries.isEmpty && activitySeries.count >= live.count
        let hrSeries = useActivity ? activitySeries : live
        let hrSource: Any = hrSeries.isEmpty ? NSNull() : (useActivity ? "activity" : "live")
        let mapped = mapSets(sets, hrSeries, workoutStart: start)

        var exercises: [[String: Any]] = []
        var groupSets: [[String: Any]] = []
        var order: Int?
        func flush() {
            guard !groupSets.isEmpty, var last = exercises.popLast() else { return }
            last["sets"] = groupSets
            exercises.append(last)
            groupSets = []
        }
        for (i, row) in sets.enumerated() {
            let exerciseOrder = row["exercise_order"] as? Int ?? 0
            if exerciseOrder != order {
                flush()
                order = exerciseOrder
                exercises.append(["exerciseId": LocalHub.value(row, "exercise_id"), "name": LocalHub.value(row, "exercise_name"),
                                  "superset": LocalHub.value(row, "superset"), "sets": [Any]()])
            }
            let kind = row["kind"] as? String ?? "normal"
            let e1rm = kind != "warmup" ? oneRepMax(LocalHub.number(row["weight_kg"]), row["reps"] as? Int) : nil
            let exerciseId = row["exercise_id"] as? String ?? ""
            let pr = e1rm.map { $0 > (best[exerciseId] ?? 0) + 1e-6 } ?? false
            if pr, let e1rm { best[exerciseId] = e1rm }
            let heart = mapped[i]
            let endHr: Any = heart.endHr.map { $0 as Any } ?? LocalHub.value(row, "live_hr")
            groupSets.append([
                "kind": kind, "weightKg": LocalHub.value(row, "weight_kg"), "reps": LocalHub.value(row, "reps"),
                "durationSeconds": LocalHub.value(row, "duration_s"), "rpe": LocalHub.value(row, "rpe"),
                "completedAt": LocalHub.value(row, "completed_at"), "liveHr": LocalHub.value(row, "live_hr"),
                "startedAt": (row["started_at"] as? String) ?? LocalHub.orNull(heart.startedAt),
                "avgHr": LocalHub.orNull(heart.avgHr), "peakHr": LocalHub.orNull(heart.peakHr), "endHr": endHr,
                "recoveryBpm": LocalHub.orNull(heart.recoveryBpm), "restSeconds": LocalHub.orNull(heart.restSeconds),
                "e1rmKg": LocalHub.orNull(e1rm), "pr": pr,
            ])
        }
        flush()

        let totals = summary(hrSeries, from: start, to: end)
        let chart = downsample(hrSeries.filter { $0.t >= start - 60_000 && $0.t <= end + 60_000 }, max: 600)
            .map { [Int(((($0.t - start) / 1000)).rounded()), $0.bpm] }
        return [
            "id": id, "name": LocalHub.value(w, "name"), "routineId": LocalHub.value(w, "routine_id"),
            "startedAt": startedAt, "endedAt": endedAt, "notes": LocalHub.value(w, "notes"),
            "volumeKg": volume(sets), "avgHr": LocalHub.orNull(totals.avg), "maxHr": LocalHub.orNull(totals.max),
            "hrSource": hrSource, "activityId": LocalHub.orNull(activity?.id), "place": LocalDB.parse(w["place"]),
            "heartRate": chart, "exercises": exercises,
        ]
    }

    /// Set once the watch's activities are stored on the phone: the activity overlapping a
    /// workout the most (id, start ISO, `[seconds from start, bpm]` points).
    nonisolated(unsafe) static var overlappingActivity: ((String, String) -> (id: String, start: String, points: Any)?)?

    // MARK: History

    /// Every checked-off set of one exercise, newest workout first (at most 200 workouts).
    static func history(_ exerciseId: String) -> [[String: Any]] {
        let rows = LocalHub.db.query(
            """
            with recent as (
              select w.id, w.name, w.started_at from workouts w
               where exists (select 1 from workout_sets s where s.workout_id = w.id and s.exercise_id = ? and s.completed_at is not null)
               order by w.started_at desc limit 200)
            select r.id as workout_id, r.name as workout_name, r.started_at, s.kind, s.weight_kg, s.reps, s.duration_s
              from recent r join workout_sets s on s.workout_id = r.id
             where s.exercise_id = ? and s.completed_at is not null
             order by r.started_at desc, s.exercise_order, s.set_order
            """, [exerciseId, exerciseId])
        var sessions: [[String: Any]] = []
        var sets: [[String: Any]] = []
        var current: String?
        func flush() {
            guard !sets.isEmpty, var last = sessions.popLast() else { return }
            last["sets"] = sets
            sessions.append(last)
            sets = []
        }
        for row in rows {
            let workoutId = row["workout_id"] as? String ?? ""
            if workoutId != current {
                flush()
                current = workoutId
                sessions.append(["workoutId": workoutId, "workoutName": LocalHub.value(row, "workout_name"),
                                 "startedAt": LocalHub.value(row, "started_at"), "sets": [Any]()])
            }
            sets.append(["kind": LocalHub.value(row, "kind"), "weightKg": LocalHub.value(row, "weight_kg"),
                         "reps": LocalHub.value(row, "reps"), "durationSeconds": LocalHub.value(row, "duration_s")])
        }
        flush()
        return sessions
    }

    // MARK: Validation

    static func trimmedName(_ v: Any?) -> String? {
        guard let s = (v as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), (1...120).contains(s.count) else { return nil }
        return s
    }

    static func place(_ v: Any?) -> [String: Any]? {
        guard let o = v as? [String: Any], let lat = LocalHub.number(o["latitude"]), let lon = LocalHub.number(o["longitude"]),
              (-90...90).contains(lat), (-180...180).contains(lon) else { return nil }
        let name = (o["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200)
        return ["latitude": lat, "longitude": lon, "name": name.map(String.init) ?? NSNull()]
    }

    static func routine(_ raw: Any) -> (id: String, name: String, position: Int, exercises: [[String: Any]])? {
        guard let o = raw as? [String: Any], let id = o["id"] as? String, LocalHub.isUUID(id),
              let name = trimmedName(o["name"]), let list = o["exercises"] as? [[String: Any]], list.count <= 60 else { return nil }
        var exercises: [[String: Any]] = []
        for e in list {
            guard let exerciseId = e["exerciseId"] as? String, (1...80).contains(exerciseId.count), let n = trimmedName(e["name"]) else { return nil }
            let sets = (e["sets"] as? [[String: Any]] ?? []).prefix(50).map { s -> [String: Any] in
                ["kind": (s["kind"] as? String).flatMap { setKinds.contains($0) ? $0 : nil } ?? "normal",
                 "weightKg": LocalHub.orNull(LocalHub.number(s["weightKg"])), "reps": LocalHub.orNull(LocalHub.int(s["reps"]))]
            }
            exercises.append(["exerciseId": exerciseId, "name": n,
                              "restSeconds": LocalHub.orNull(LocalHub.int(e["restSeconds"])),
                              "superset": LocalHub.orNull(LocalHub.int(e["superset"])), "sets": Array(sets)])
        }
        let position = min(max(LocalHub.int(o["position"]) ?? 0, 0), 10_000)
        return (id.lowercased(), name, position, exercises)
    }

    // MARK: Heart rate (was lib/workouts/heart-rate.ts)

    struct Reading { let t: Double; let bpm: Int }
    struct SetHeart { var startedAt: String?; var avgHr, peakHr, endHr, recoveryBpm, restSeconds: Int? }

    static func ms(_ iso: Any?) -> Double { (LocalDB.date(iso as? String)?.timeIntervalSince1970 ?? 0) * 1000 }

    /// `[seconds from start, bpm]` points as epoch-millisecond readings, sorted.
    static func series(start: Double, points: Any) -> [Reading] {
        (points as? [[Any]] ?? []).compactMap { p in
            guard p.count >= 2, let s = LocalHub.number(p[0]), let bpm = LocalHub.number(p[1]) else { return nil }
            return Reading(t: start + s * 1000, bpm: Int(bpm))
        }.sorted { $0.t < $1.t }
    }

    static func volume(_ rows: [LocalDB.Row]) -> Double {
        rows.reduce(0) { sum, r in
            (r["kind"] as? String) == "warmup" ? sum : sum + (LocalHub.number(r["weight_kg"]) ?? 0) * Double(r["reps"] as? Int ?? 0)
        }
    }

    /// Epley estimated one-rep max; nil past 12 reps, where it stops meaning much.
    static func oneRepMax(_ weight: Double?, _ reps: Int?) -> Double? {
        guard let weight, weight > 0, let reps, (1...12).contains(reps) else { return nil }
        return reps == 1 ? weight : weight * (1 + Double(reps) / 30)
    }

    private static func inRange(_ s: [Reading], _ from: Double, _ to: Double) -> [Int] {
        var out: [Int] = []
        for r in s {
            if r.t > to { break }
            if r.t >= from { out.append(r.bpm) }
        }
        return out
    }

    private static func nearest(_ s: [Reading], _ at: Double, within: Double = 15_000) -> Int? {
        var best: Int?
        var gap = within + 1
        for r in s {
            let g = abs(r.t - at)
            if g < gap { best = r.bpm; gap = g }
            if r.t > at + within { break }
        }
        return best
    }

    static func summary(_ s: [Reading], from: Double, to: Double) -> (avg: Int?, max: Int?) {
        let v = inRange(s, from, to)
        guard !v.isEmpty else { return (nil, nil) }
        return (Int((Double(v.reduce(0, +)) / Double(v.count)).rounded()), v.max())
    }

    /// A set is only checked off when it ends, so its start is estimated: about four seconds a
    /// rep (20-90 s), never before the previous set ended. The peak is read a little past the end;
    /// recovery is the drop from that peak a minute later, when the next set hadn't started.
    static func mapSets(_ sets: [LocalDB.Row], _ s: [Reading], workoutStart: Double) -> [SetHeart] {
        let done: [Double?] = sets.map { ($0["completed_at"] as? String).map { ms($0) } }
        var starts: [Double?] = []
        var previousEnd = workoutStart
        for (i, set) in sets.enumerated() {
            guard let end = done[i] else { starts.append(nil); continue }
            let explicit = (set["started_at"] as? String).map { ms($0) }
            let duration = LocalHub.number(set["duration_s"]) ?? 0
            let work = duration > 0 ? duration : min(90, max(20, Double((set["reps"] as? Int) ?? 8) * 4))
            let start = explicit ?? max(previousEnd, end - work * 1000)
            starts.append(min(start, end))
            previousEnd = max(previousEnd, end)
        }
        return sets.indices.map { i in
            guard let end = done[i], let start = starts[i] else { return SetHeart() }
            let nextStart = starts[(i + 1)...].compactMap { $0 }.first { $0 >= end }
            let during = inRange(s, start, end)
            let peakWindow = inRange(s, start, min(end + 20_000, nextStart ?? .infinity))
            let peak = peakWindow.max()
            let recoveryAt = end + 60_000
            let later = (nextStart == nil || nextStart! >= recoveryAt) ? nearest(s, recoveryAt, within: 10_000) : nil
            return SetHeart(
                startedAt: LocalDB.iso(Date(timeIntervalSince1970: start / 1000)),
                avgHr: during.isEmpty ? nil : Int((Double(during.reduce(0, +)) / Double(during.count)).rounded()),
                peakHr: peak, endHr: nearest(s, end),
                recoveryBpm: (peak != nil && later != nil) ? peak! - later! : nil,
                restSeconds: nextStart.map { Int((($0 - end) / 1000).rounded()) })
        }
    }

    /// At most `max` readings, keeping each bucket's highest so peaks survive.
    static func downsample(_ s: [Reading], max: Int) -> [Reading] {
        guard s.count > max else { return s }
        let size = Int((Double(s.count) / Double(max)).rounded(.up))
        return stride(from: 0, to: s.count, by: size).map { i in
            s[i..<Swift.min(i + size, s.count)].max { $0.bpm < $1.bpm }!
        }
    }
}
