import CryptoKit
import Foundation

/// Fitness from the watch, on the phone (was lib/fitness/store.ts, checkins.ts
/// and the /api/mobile/fitness routes). The phone reads each file the watch
/// hands over (HubJS.fitness, the hub's own parser), stores what it says, and
/// drops the raw file. Queries mirror the hub's, column for column, and the
/// math runs in HubJS.fitness so the numbers are the same.
///
/// Not here yet: /api/mobile/fitness/context (it needs the calendar and bank
/// transactions, which are still on the hub).
nonisolated enum LocalFitness {
    static func register(_ r: inout [String: LocalHub.Handler]) {
        r["POST /api/mobile/fitness"] = upload
        r["GET /api/mobile/fitness"] = { _ in
            snapshot().map(LocalHub.Reply.ok) ?? .error("Couldn't work out the fitness numbers.", 500)
        }
        r["GET /api/mobile/fitness/activity"] = { req in
            guard let id = req.param("id"), isFileId(id) else { return .error("Not a valid activity.") }
            guard var row = db.one("select \(activityColumns), hr_series as heartRate from fitness_activities where file_id = ?", [id]) else {
                return .notFound
            }
            row["metrics"] = LocalDB.parse(row["metrics"])
            row["heartRate"] = LocalDB.parse(row["heartRate"])
            return HubJS.fitness.call("activity", row).map(LocalHub.Reply.ok) ?? .notFound
        }
        r["GET /api/mobile/fitness/sleep"] = { _ in
            .ok(["sleep": db.query(
                "select start_time as start, end_time as \"end\" from fitness_sleep where end_ms > start_ms and end_ms > ? order by start_ms",
                [ago(days: 400)])])
        }
        r["GET /api/mobile/fitness/watch"] = { _ in
            let input: [String: Any] = [
                "now": nowMs(),
                "sleep": db.query(
                    """
                    select start_time as start, end_time as "end", deep_s as deepSeconds, light_s as lightSeconds,
                           rem_s as remSeconds, awake_s as awakeSeconds, score as watchScore
                      from fitness_sleep where end_ms > ? order by end_ms desc limit 3
                    """, [ago(days: 2)]),
                "hrv": db.query(
                    """
                    select day, last_night_avg as lastNightAverage, weekly_avg as weeklyAverage, status
                      from fitness_hrv where day > ? order by day desc
                    """, [LocalDB.addDays(LocalDB.day(), -3)]),
                "metricsInput": metricsInput(),
            ]
            return HubJS.fitness.call("watchSettings", input).map(LocalHub.Reply.ok) ?? .error("Couldn't work out the watch numbers.", 500)
        }
        r["GET /api/mobile/fitness/inspect"] = { _ in
            // Raw files aren't kept once read, so this lists what was read rather than laying it out.
            let files = db.query(
                """
                select kind, file_id as fileId, size, recorded_at as recordedAt, parse_error as error from (
                  select *, row_number() over (partition by kind order by recorded_at desc, received_at desc) as n from fitness_files)
                 where n = 1 order by kind
                """
            ).map { row -> [String: Any] in
                var out = row
                if row["error"] is NSNull { out["error"] = "Read on the phone; the raw file isn't kept." }
                return out
            }
            return .ok(["files": files])
        }
        r["POST /api/mobile/fitness/live"] = live
        r["GET /api/mobile/fitness/checkin"] = { req in
            guard let day = req.param("day"), LocalHub.isDay(day), let tz = offset(req.param("tz")) else { return .error("Not a valid day.") }
            let input: [String: Any] = ["dayInput": dayInput(tz), "entries": checkins(), "skips": db.query("select state, day from fitness_checkin_skips"), "day": day]
            return HubJS.fitness.call("checkinPage", input).map(LocalHub.Reply.ok) ?? .error("Couldn't work out the check-in.", 500)
        }
        r["PUT /api/mobile/fitness/checkin"] = putCheckin
        r["GET /api/mobile/fitness/feedback"] = { req in
            guard let kind = req.param("kind"), ["workout", "activity"].contains(kind),
                  let id = req.param("id"), isRef(id), let tz = offset(req.param("tz")) else { return .error("Not a valid session.") }
            let guess = sessionGuess(kind: kind, refId: id, tz: tz) ?? ["feel": NSNull(), "effort": NSNull(), "reasons": [String]()]
            return .ok(["guess": guess, "feedback": LocalHub.orNull(feedback(kind: kind, refId: id))])
        }
        r["PUT /api/mobile/fitness/feedback"] = putFeedback
    }

    static var db: LocalDB { .shared }

    // MARK: Time

    static func nowMs() -> Int { Int(Date().timeIntervalSince1970 * 1000) }
    static func ago(days: Double, from: Int = nowMs()) -> Int { from - Int(days * 86_400_000) }
    static func ms(_ iso: Any?) -> Int? { LocalDB.date(iso as? String).map { Int($0.timeIntervalSince1970 * 1000) } }

    static func isFileId(_ s: String) -> Bool { s.range(of: "^[0-9a-f]{32}$", options: .regularExpression) != nil }
    static func isRef(_ s: String) -> Bool { s.range(of: "^[0-9a-zA-Z-]{1,64}$", options: .regularExpression) != nil }
    static func isTag(_ s: String) -> Bool { s.range(of: "^[a-z0-9_]{1,40}$", options: .regularExpression) != nil }

    /// `tz=` seconds east of UTC, within ±14 h; nil when it isn't one.
    static func offset(_ s: String?) -> Int? {
        guard let s else { return 0 }
        guard let tz = Int(s), abs(tz) <= 14 * 3600 else { return nil }
        return tz
    }

    // MARK: Upload

    static let maxBytes = 8 * 1024 * 1024

    /// One file from the watch: read it, store what it says. The same file again is a no-op;
    /// a newer copy of today's all-day file (it grows until midnight) is read again, and
    /// since every write is additive the earlier copy's readings stay.
    static let upload: LocalHub.Handler = { req in
        let id = req.param("id") ?? ""
        let kind = req.param("kind") ?? ""
        guard isFileId(id), kind.range(of: "^[a-z0-9_]{1,40}$", options: .regularExpression) != nil else { return .error("Not a valid file.") }
        let recordedAt = req.param("recordedAt")
        if let recordedAt, LocalDB.date(recordedAt) == nil { return .error("Not a valid date.") }
        guard let tz = offset(req.param("tz")) else { return .error("Not a valid time zone.") }
        guard let data = req.raw, !data.isEmpty, data.count <= maxBytes else { return .error("File empty or too large.", 413) }

        let sha = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        if (db.one("select sha256 from fitness_files where file_id = ?", [id])?["sha256"] as? String) == sha {
            return .ok(["duplicate": true, "parsed": false])
        }
        guard let parsed = HubJS.fitness.call("parseFile", bytes: data, [tz]) as? [String: Any] else {
            return .error("couldn't read the file", 500)
        }
        if parsed["invalid"] as? Bool == true { return .error(parsed["error"] as? String ?? "not a valid FIT file", 422) }

        let now = LocalDB.iso(Date())
        db.run(
            """
            insert into fitness_files (file_id, kind, size, recorded_at, sha256, received_at) values (?, ?, ?, ?, ?, ?)
            on conflict (file_id) do update set kind = excluded.kind, size = excluded.size, sha256 = excluded.sha256,
              recorded_at = coalesce(excluded.recorded_at, fitness_files.recorded_at), received_at = excluded.received_at,
              parsed_at = null, parse_error = null
            """, [id, kind, data.count, LocalDB.normalized(recordedAt), sha, now])
        if let error = parsed["error"] as? String {
            db.run("update fitness_files set parse_error = ? where file_id = ?", [error, id])
            return .created(["duplicate": false, "parsed": false, "error": error])
        }
        db.transaction { apply(fileId: id, parsed) }
        db.run("update fitness_files set parsed_at = ? where file_id = ?", [now, id])
        return .created(["duplicate": false, "parsed": true])
    }

    /// Writes one file's summary (store.ts applySummary).
    static func apply(fileId: String, _ s: [String: Any]) {
        if let a = s["activity"] as? [String: Any], let start = a["startTime"] as? String, let startMs = ms(start) {
            db.run(
                """
                insert or replace into fitness_activities (file_id, sport, sub_sport, start_time, start_ms, utc_offset, elapsed_s,
                  moving_s, distance_m, calories, avg_hr, max_hr, ascent_m, avg_speed, training_effect, hr_series, metrics)
                values (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                [fileId, a["sport"] ?? "generic", a["subSport"], start, startMs, a["utcOffset"], a["elapsedSeconds"],
                 a["movingSeconds"], a["distanceMeters"], a["calories"], a["avgHeartRate"], a["maxHeartRate"],
                 a["ascentMeters"], a["avgSpeed"], a["trainingEffect"], LocalDB.json(a["heartRate"]) ?? "[]", LocalDB.json(a["metrics"])])
        }
        for case let d as [String: Any] in s["daily"] as? [Any] ?? [] {
            guard let day = d["day"] as? String else { continue }
            upsertDay(day: day, steps: d["steps"], goal: d["stepGoal"], restingHr: d["restingHeartRate"], final: d["final"] as? Bool == true,
                      distance: d["distanceMeters"], activeKcal: d["activeKcal"], restingKcal: d["restingKcal"],
                      activeSeconds: d["activeSeconds"], ascent: d["ascentMeters"], descent: d["descentMeters"],
                      moderate: d["moderateMinutes"], vigorous: d["vigorousMinutes"])
        }
        for case let p as [Any] in s["heartRate"] as? [Any] ?? [] where p.count == 2 {
            db.run("insert or ignore into fitness_heart_rate (at, bpm) values (?, ?)", [p[0], p[1]])
        }
        if let h = s["hrv"] as? [String: Any], let day = h["day"] as? String {
            db.run(
                """
                insert or replace into fitness_hrv (file_id, day, weekly_avg, last_night_avg, last_night_high, baseline_low_upper,
                  baseline_balanced_lower, baseline_balanced_upper, status, readings) values (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                [fileId, day, h["weeklyAverage"], h["lastNightAverage"], h["lastNight5MinHigh"], h["baselineLowUpper"],
                 h["baselineBalancedLower"], h["baselineBalancedUpper"], h["status"], LocalDB.json(h["readings"]) ?? "[]"])
        }
        for case let v as [Any] in s["vitals"] as? [Any] ?? [] where v.count == 3 {
            db.run("insert or ignore into fitness_vitals (kind, at, value) values (?, ?, ?)", [v[0], v[1], v[2]])
        }
        for case let w as [Any] in s["watch"] as? [Any] ?? [] where w.count == 3 {
            db.run("insert into fitness_watch_metrics (kind, at, data) values (?, ?, ?) on conflict (kind, at) do update set data = excluded.data",
                   [w[0], w[1], LocalDB.json(w[2]) ?? "{}"])
        }
        if let sl = s["sleep"] as? [String: Any], let start = sl["start"] as? String, let end = sl["end"] as? String,
           let startMs = ms(start), let endMs = ms(end) {
            db.run(
                """
                insert or replace into fitness_sleep (file_id, start_time, end_time, start_ms, end_ms, deep_s, light_s, rem_s, awake_s, score, levels)
                values (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                [fileId, start, end, startMs, endMs, sl["deepSeconds"], sl["lightSeconds"], sl["remSeconds"], sl["awakeSeconds"],
                 sl["score"], LocalDB.json(sl["levels"]) ?? "[]"])
        }
    }

    /// Totals only go up within a day (every source is cumulative), except that the watch's
    /// closing summary for a day is final and replaces them. Other values take the newest reading.
    static func upsertDay(day: String, steps: Any?, goal: Any?, restingHr: Any?, final: Bool = false,
                          distance: Any? = nil, activeKcal: Any? = nil, restingKcal: Any? = nil, activeSeconds: Any? = nil,
                          ascent: Any? = nil, descent: Any? = nil, moderate: Any? = nil, vigorous: Any? = nil) {
        func up(_ c: String) -> String {
            "\(c) = case when excluded.\(c) is null then fitness_daily.\(c) when ?14 then excluded.\(c) else max(coalesce(fitness_daily.\(c), 0), excluded.\(c)) end"
        }
        let totals = ["steps", "distance_m", "active_kcal", "active_s", "ascent_m", "descent_m", "moderate_min", "vigorous_min"].map(up)
        db.run(
            """
            insert into fitness_daily (day, steps, step_goal, resting_hr, distance_m, active_kcal, resting_kcal, active_s,
              ascent_m, descent_m, moderate_min, vigorous_min, updated_at)
            values (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13)
            on conflict (day) do update set \(totals.joined(separator: ", ")),
              step_goal = coalesce(excluded.step_goal, fitness_daily.step_goal),
              resting_hr = coalesce(excluded.resting_hr, fitness_daily.resting_hr),
              resting_kcal = coalesce(excluded.resting_kcal, fitness_daily.resting_kcal),
              updated_at = excluded.updated_at
            """,
            [day, steps, goal, restingHr, distance, activeKcal, restingKcal, activeSeconds, ascent, descent, moderate, vigorous,
             LocalDB.iso(Date()), final])
    }

    // MARK: Live

    /// The watch's live numbers for the phone's local day, and the minute readings streamed since the last post.
    static let live: LocalHub.Handler = { req in
        let o = req.object
        func bounded(_ key: String, _ range: ClosedRange<Int>) -> (ok: Bool, value: Int?) {
            guard let raw = o[key], !(raw is NSNull) else { return (true, nil) }
            guard let n = LocalHub.number(raw), n == n.rounded(), range.contains(Int(n)) else { return (false, nil) }
            return (true, Int(n))
        }
        let steps = bounded("steps", 0...500_000), goal = bounded("goal", 0...500_000), resting = bounded("restingHr", 20...250)
        guard let day = o["day"] as? String, LocalHub.isDay(day), steps.ok, goal.ok, resting.ok else { return .error("Not a valid reading.") }
        let samples = o["samples"] as? [Any] ?? []
        guard samples.count <= 5000 else { return .error("Not a valid reading.") }
        upsertDay(day: day, steps: steps.value, goal: goal.value, restingHr: resting.value)
        // A bad reading (out of range, from the future) is dropped, not the whole post.
        let latest = nowMs() + 5 * 60_000
        db.transaction {
            for case let s as [String: Any] in samples {
                guard let kind = s["kind"] as? String, let at = ms(s["at"]), at <= latest,
                      let value = LocalHub.number(s["value"]), value == value.rounded() else { continue }
                if kind == "heart_rate", (25...250).contains(value) {
                    db.run("insert or ignore into fitness_heart_rate (at, bpm) values (?, ?)", [at, Int(value)])
                } else if kind == "stress" || kind == "body_battery", (0...100).contains(value) {
                    db.run("insert or ignore into fitness_vitals (kind, at, value) values (?, ?, ?)", [kind, at, value])
                }
            }
        }
        return .done
    }

    // MARK: Snapshot

    static let activityColumns = """
        file_id as id, sport, sub_sport as subSport, start_time as startTime, utc_offset as utcOffset,
        elapsed_s as elapsedSeconds, moving_s as movingSeconds, distance_m as distanceMeters, calories, avg_hr as avgHr,
        max_hr as maxHr, ascent_m as ascentMeters, avg_speed as avgSpeed, training_effect as trainingEffect, metrics
        """

    /// Rows with their json columns parsed.
    static func rows(_ sql: String, _ args: [Any?] = [], json: [String] = []) -> [[String: Any]] {
        db.query(sql, args).map { row in
            var out = row
            for key in json { out[key] = LocalDB.parse(row[key]) }
            return out
        }
    }

    /// The vitals the models read (metrics.ts only looks at these kinds; the minute steps and
    /// intensity series would just be carried along).
    static let modelVitals = "('hrv', 'spo2', 'respiration', 'skin_temp')"

    /// A year of activities, a fortnight of resting heart rate, 8 days of heart rate, 35 nights.
    static func metricsInput(now: Int = nowMs()) -> [String: Any] {
        [
            "activities": rows("select start_time as start, elapsed_s as elapsed, metrics from fitness_activities where start_ms > ? order by start_ms desc",
                               [ago(days: 365, from: now)], json: ["metrics"]),
            "rest": restingHr(),
            "heartRate": db.query("select at, bpm from fitness_heart_rate where at > ? order by at", [ago(days: 8, from: now)]),
            "nights": db.query(
                """
                select start_time as start, end_time as "end", deep_s as deep, light_s as light, rem_s as rem, awake_s as awake, score
                  from fitness_sleep where end_ms > ?
                """, [ago(days: 35, from: now)]),
            "vitals": db.query(
                """
                select kind, at, value from fitness_vitals
                 where kind in \(modelVitals) and at > ? and (kind <> 'respiration' or at > ?)
                """, [ago(days: 35, from: now), ago(days: 2, from: now)]),
        ]
    }

    static func restingHr() -> [[String: Any]] {
        db.query("select resting_hr from fitness_daily where resting_hr is not null and day > ? order by day desc",
                 [LocalDB.addDays(LocalDB.day(), -14)])
    }

    /// The watch's average stress over a night (alias `s`), for the sleep score.
    static let nightStress = "(select avg(value) from fitness_vitals v where v.kind = 'stress' and v.at between s.start_ms and s.end_ms)"

    static func snapshot() -> Any? {
        let now = nowMs()
        let through = [db.one("select max(at) as m from fitness_heart_rate")?["m"] as? Int,
                       db.one("select max(at) as m from fitness_vitals where kind in ('stress', 'body_battery')")?["m"] as? Int]
            .compactMap { $0 }.max()
        // The last 24 hours of all-day data end at the newest reading, not now.
        let end = through.map { min($0, now) } ?? now
        let bucket = "(at / 300000) * 300000"

        let input: [String: Any] = [
            "now": now,
            "through": LocalHub.orNull(through),
            "days": db.query(
                """
                select day, steps, step_goal as stepGoal, resting_hr as restingHr, distance_m as distanceMeters,
                       active_kcal as activeKcal, resting_kcal as restingKcal, active_s as activeSeconds,
                       round(ascent_m / 3.048, 1) as floorsUp, round(descent_m / 3.048, 1) as floorsDown,
                       moderate_min as moderateMinutes, vigorous_min as vigorousMinutes
                  from fitness_daily order by day desc limit 90
                """),
            "activities": rows("select \(activityColumns) from fitness_activities order by start_ms desc limit 100", json: ["metrics"]),
            "sleep": rows(
                """
                select s.file_id as id, s.start_time as start, s.end_time as "end", s.deep_s as deepSeconds,
                       s.light_s as lightSeconds, s.rem_s as remSeconds, s.awake_s as awakeSeconds,
                       s.score as watchScore, s.levels, \(nightStress) as stress
                  from fitness_sleep s order by s.start_ms desc limit 30
                """, json: ["levels"]),
            "heartRate": db.query(
                "select \(bucket) as at, cast(round(avg(bpm)) as integer) as bpm from fitness_heart_rate where at > ? and at <= ? group by 1 order by 1",
                [end - 86_400_000, end]),
            "files": db.query("select kind, count(*) as count from fitness_files group by kind order by count desc"),
            "hrv": rows(
                """
                select file_id as id, day, weekly_avg as weeklyAverage, last_night_avg as lastNightAverage,
                       last_night_high as lastNight5MinHigh, baseline_low_upper as baselineLowUpper,
                       baseline_balanced_lower as baselineBalancedLower, baseline_balanced_upper as baselineBalancedUpper, status, readings
                  from fitness_hrv order by day desc limit 30
                """, json: ["readings"]),
            "heartRateTrend": db.query(
                """
                select strftime('%Y-%m-%d', at / 1000, 'unixepoch', 'localtime') as day, min(bpm) as min,
                       cast(round(avg(bpm)) as integer) as avg, max(bpm) as max
                  from fitness_heart_rate where at > ? group by 1 order by 1 desc
                """, [ago(days: 30, from: now)]),
            "watchRows": rows("select kind, at, data from fitness_watch_metrics where at > ?", [ago(days: 365, from: now)], json: ["data"]),
            "recent": db.query(
                """
                select kind, \(bucket) as at, avg(value) as value from fitness_vitals
                 where kind in ('stress', 'body_battery') and at > ? and at <= ? group by kind, 2 order by 2
                """, [end - 86_400_000, end]),
            "metricsInput": metricsInput(now: now),
            "insightsInput": insightsInput(now: now, allDayEnd: end),
        ]
        return HubJS.fitness.call("snapshot", input)
    }

    /// What the Whoop, Oura, Garmin and Apple style scores need (store.ts fitnessInsights).
    static func insightsInput(now: Int, allDayEnd: Int) -> [String: Any] {
        let nights = ago(days: 35, from: now)
        func avg(_ kind: String, _ from: String = "s.start_ms", _ to: String = "s.end_ms") -> String {
            "(select avg(value) from fitness_vitals v where v.kind = '\(kind)' and v.at between \(from) and \(to))"
        }
        return [
            "activities": rows(
                """
                select start_time as start, elapsed_s as elapsed, sport, sub_sport as subSport, ascent_m as ascent,
                       utc_offset as offset, json_extract(hr_series, '$[#-1][1]') as endHr, metrics
                  from fitness_activities where start_ms > ? order by start_ms desc
                """, [ago(days: 365, from: now)], json: ["metrics"]),
            "heartRate": db.query("select at, bpm from fitness_heart_rate where at > ? order by at", [ago(days: 8, from: now)]),
            "nights": rows(
                """
                select s.file_id as id, s.start_time as start, s.end_time as "end", s.deep_s as deep, s.light_s as light,
                       s.rem_s as rem, s.awake_s as awake, s.levels, s.score, \(nightStress) as stress,
                       \(avg("hrv", "s.start_ms - 3600000")) as hrv, \(avg("respiration")) as respiration, \(avg("spo2")) as spo2,
                       (select resting_hr from fitness_daily d where d.day = substr(s.end_time, 1, 10)) as resting
                  from fitness_sleep s where s.end_ms > ?
                """, [nights], json: ["levels"]),
            "nightHr": db.query(
                """
                select s.file_id as id, h.at, h.bpm from fitness_sleep s
                  join fitness_heart_rate h on h.at between s.start_ms and s.end_ms
                 where s.end_ms > ? order by h.at
                """, [nights]),
            "buckets": db.query(
                """
                select kind, (at / 300000) * 300000 as at, avg(value) as value from fitness_vitals
                 where (kind = 'stress' and at > ?) or (kind = 'body_battery' and at > ?)
                 group by kind, 2 order by 2
                """, [ago(days: 15, from: now), allDayEnd - 2 * 86_400_000]),
            "rest": restingHr(),
            "days": db.query("select day, steps from fitness_daily where day > ? order by day desc", [LocalDB.addDays(LocalDB.day(), -29)]),
            "spo2": db.query("select at, value from fitness_vitals where kind = 'spo2' and at > ? order by at", [ago(days: 1.5, from: now)]),
            "naps": rows("select data from fitness_watch_metrics where kind = 'nap' and at > ?", [nights], json: ["data"]),
        ]
    }

    /// The watch activity that overlaps a workout the most, with heart rate to map onto its sets.
    static func overlappingActivity(startedAt: Double, endedAt: Double) -> (id: String, start: String, points: Any)? {
        let from = Int(startedAt), to = Int(endedAt)
        guard let row = db.one(
            """
            select file_id, start_time, hr_series from fitness_activities
             where json_array_length(hr_series) > 0 and start_ms < ?2 and start_ms + coalesce(elapsed_s, 0) * 1000 > ?1
             order by max(0, min(start_ms + coalesce(elapsed_s, 0) * 1000, ?2) - max(start_ms, ?1)) desc limit 1
            """, [from, to]),
            let id = row["file_id"] as? String, let start = row["start_time"] as? String else { return nil }
        return (id, start, LocalDB.parse(row["hr_series"]))
    }

    // MARK: Check-ins

    /// Every day's numbers for the check-in models (checkins.ts dayFeatures, its queries).
    /// `tz` (seconds) places the watch's readings on local days.
    static func dayInput(_ tz: Int) -> [String: Any] {
        let since = ago(days: 400)
        let local = "strftime('%Y-%m-%d', at / 1000 + ?1, 'unixepoch')"
        return [
            "connect": rows("select day, data from fitness_connect_daily where day > ?", [LocalDB.addDays(LocalDB.day(), -400)], json: ["data"]),
            "nights": db.query(
                """
                select strftime('%Y-%m-%d', s.end_ms / 1000 + ?1, 'unixepoch') as day,
                       strftime('%Y-%m-%dT%H:%M:%S', s.start_ms / 1000 + ?1, 'unixepoch') as startLocal,
                       coalesce(s.deep_s, 0) + coalesce(s.light_s, 0) + coalesce(s.rem_s, 0) as asleep, s.score,
                       (select avg(bpm) from fitness_heart_rate h where h.at between s.start_ms and s.end_ms) as hr,
                       (select avg(value) from fitness_vitals v where v.kind = 'respiration' and v.at between s.start_ms and s.end_ms) as resp,
                       (select avg(value) from fitness_vitals v where v.kind = 'stress' and v.value between 0 and 100
                          and v.at between s.start_ms and s.end_ms) as stress,
                       (select avg(value) from fitness_vitals v where v.kind = 'spo2' and v.at between s.start_ms and s.end_ms) as spo2,
                       (select avg(value) from fitness_vitals v where v.kind = 'body_battery' and v.value between 0 and 100
                          and v.at between s.end_ms - 1200000 and s.end_ms + 600000) as battery
                  from fitness_sleep s where s.end_ms > ?2
                """, [tz, since]),
            "hrv": db.query("select day, last_night_avg as value from fitness_hrv"),
            "daily": db.query("select day, resting_hr as restingHr from fitness_daily"),
            // The morning's readiness: the first the watch wrote that day.
            "readiness": db.query(
                """
                select day, score from (
                  select \(local) as day, json_extract(data, '$.score') as score,
                         row_number() over (partition by \(local) order by at) as n
                    from fitness_watch_metrics where kind = 'readiness') where n = 1
                """, [tz]),
            "stress": db.query(
                "select \(local) as day, avg(value) as value from fitness_vitals where kind = 'stress' and value between 0 and 100 and at > ?2 group by 1",
                [tz, since]),
            // Each day's workout load: the watch's own where it wrote one, the hub's EPOC model otherwise.
            "loads": db.query(
                """
                select strftime('%Y-%m-%d', start_ms / 1000 + coalesce(utc_offset, ?1), 'unixepoch') as day,
                       sum(coalesce(json_extract(metrics, '$.watch.load'), json_extract(metrics, '$.load'), 0)) as load
                  from fitness_activities where start_ms > ?2 group by 1
                """, [tz, since]),
            "drinks": LocalDrinks.byMorning(),
        ]
    }

    static func checkin(_ row: LocalDB.Row) -> [String: Any] {
        ["day": LocalHub.value(row, "day"), "energy": LocalHub.value(row, "energy"), "mood": LocalHub.value(row, "mood"),
         "soreness": LocalHub.value(row, "soreness"), "tags": LocalDB.parse(row["tags"]) as? [String] ?? [],
         "rejected": LocalDB.parse(row["rejected"]) as? [String] ?? [], "note": LocalHub.value(row, "note"),
         "updatedAt": LocalHub.value(row, "updated_at")]
    }

    static func checkins() -> [[String: Any]] {
        db.query("select * from fitness_checkins order by day desc").map(checkin)
    }

    static let putCheckin: LocalHub.Handler = { req in
        let o = req.object
        let now = LocalDB.iso(Date())
        func days(_ from: String, _ to: String) -> [String] {
            var out: [String] = []
            var d = from
            while d <= to, out.count < 40 { out.append(d); d = LocalDB.addDays(d, 1) }
            return out
        }
        func span(_ from: String, _ to: String) -> Int {
            guard let a = LocalDB.date("\(from)T00:00:00Z"), let b = LocalDB.date("\(to)T00:00:00Z") else { return .max }
            return Int(b.timeIntervalSince(a) / 86_400)
        }
        func tags(_ v: Any?) -> [String]? { (v as? [Any])?.compactMap { $0 as? String }.filter(isTag) }
        func merge(_ day: String, _ change: (inout [String], inout [String], inout Any?) -> Void) {
            let row = db.one("select tags, rejected, note from fitness_checkins where day = ?", [day])
            var t = LocalDB.parse(row?["tags"]) as? [String] ?? []
            var r = LocalDB.parse(row?["rejected"]) as? [String] ?? []
            var note: Any? = row?["note"]
            change(&t, &r, &note)
            db.run(
                """
                insert into fitness_checkins (day, tags, rejected, note, created_at, updated_at) values (?, ?, ?, ?, ?, ?)
                on conflict (day) do update set tags = excluded.tags, rejected = excluded.rejected, note = excluded.note,
                  updated_at = excluded.updated_at
                """, [day, LocalDB.json(t), LocalDB.json(r), note, now, now])
        }

        // A past stretch: "were you sick around March 3-5?"
        if let s = o["stretch"] as? [String: Any] {
            guard let state = s["state"] as? String, ["sick", "hungover", "run_down", "stressed", "energized"].contains(state),
                  let from = s["from"] as? String, let to = s["to"] as? String, LocalHub.isDay(from), LocalHub.isDay(to),
                  let yes = LocalHub.bool(s["yes"]) else { return .error("Not a valid request.") }
            guard from <= to, span(from, to) <= 21 else { return .error("Not a valid stretch.") }
            db.transaction {
                for day in days(from, to) {
                    if LocalHub.bool(s["skip"]) == true {
                        db.run("insert or ignore into fitness_checkin_skips (state, day) values (?, ?)", [state, day])
                    } else {
                        merge(day) { t, r, _ in
                            if yes { if !t.contains(state) { t.append(state) } } else if !r.contains(state) { r.append(state) }
                        }
                    }
                }
            }
            return .done
        }
        // "I was sick Monday to Wednesday": adds the tags to each day and takes them off its rejected list.
        if let l = o["log"] as? [String: Any] {
            guard let from = l["from"] as? String, let to = l["to"] as? String, LocalHub.isDay(from), LocalHub.isDay(to),
                  let add = tags(l["tags"]), !add.isEmpty, add.count <= 30 else { return .error("Not a valid request.") }
            guard from <= to, span(from, to) <= 31 else { return .error("Not a valid range.") }
            let note = (l["note"] as? String).map { String($0.prefix(2000)) }
            db.transaction {
                for day in days(from, to) {
                    merge(day) { t, r, n in
                        t = Array(Set(t + add)).sorted()
                        r = r.filter { !add.contains($0) }.sorted()
                        if let note { n = note }
                    }
                }
            }
            return .done
        }
        // A day's check-in. Fields left out keep what was there.
        guard let day = o["day"] as? String, LocalHub.isDay(day) else { return .error("Not a valid check-in.") }
        for key in ["energy", "mood", "soreness"] {
            if let v = o[key], !(v is NSNull), !(LocalHub.int(v).map { (1...5).contains($0) } ?? false) { return .error("Not a valid check-in.") }
        }
        if o["tags"] != nil, tags(o["tags"])?.count != (o["tags"] as? [Any])?.count { return .error("Not a valid check-in.") }
        if o["rejected"] != nil, tags(o["rejected"])?.count != (o["rejected"] as? [Any])?.count { return .error("Not a valid check-in.") }
        let existing = db.one("select * from fitness_checkins where day = ?", [day])
        func pick(_ key: String, _ column: String) -> Any? {
            o.keys.contains(key) ? (o[key] is NSNull ? nil : o[key]) : existing?[column].flatMap { $0 is NSNull ? nil : $0 }
        }
        let note = o.keys.contains("note") ? (o["note"] as? String).map { String($0.prefix(2000)) } : existing?["note"] as? String
        let tagList = tags(o["tags"]).map { LocalDB.json($0) } ?? (existing?["tags"] as? String) ?? "[]"
        let rejected = tags(o["rejected"]).map { LocalDB.json($0) } ?? (existing?["rejected"] as? String) ?? "[]"
        let guess = (existing?["guess"] as? String) ?? (o.keys.contains("guess") ? LocalDB.json(o["guess"]) : nil)
        db.run(
            """
            insert or replace into fitness_checkins (day, energy, mood, soreness, tags, rejected, note, guess, created_at, updated_at)
            values (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            [day, pick("energy", "energy"), pick("mood", "mood"), pick("soreness", "soreness"), tagList, rejected, note, guess,
             (existing?["created_at"] as? String) ?? now, now])
        return db.one("select * from fitness_checkins where day = ?", [day]).map { .ok(checkin($0)) } ?? .error("Couldn't save that.", 500)
    }

    // MARK: Sessions

    /// What a session probably felt like, before the person says (checkins.ts sessionGuess).
    static func sessionGuess(kind: String, refId: String, tz: Int) -> Any? {
        let row: LocalDB.Row?
        if kind == "activity" {
            row = db.one(
                """
                select start_time as start,
                       coalesce(json_extract(metrics, '$.watch.trainingEffect'), training_effect, json_extract(metrics, '$.aerobicEffect')) as te,
                       coalesce(json_extract(metrics, '$.watch.anaerobicEffect'), json_extract(metrics, '$.anaerobicEffect')) as anaerobic,
                       avg_hr as avgHr
                  from fitness_activities where file_id = ?
                """, [refId])
        } else {
            row = db.one(
                """
                select w.started_at as start, avg(s.rpe) as rpe, count(s.workout_id) as sets
                  from workouts w left join workout_sets s on s.workout_id = w.id and s.kind <> 'warmup' and s.completed_at is not null
                 where w.id = lower(?) group by w.id
                """, [refId])
        }
        let input: [String: Any] = ["kind": kind, "row": LocalHub.orNull(row), "utcOffset": tz,
                                    "dayInput": dayInput(tz), "entries": checkins()]
        return HubJS.fitness.call("sessionGuess", input)
    }

    static func feedback(kind: String, refId: String) -> [String: Any]? {
        db.one("select * from fitness_session_feedback where kind = ? and ref_id = ?", [kind, refId]).map { row in
            ["kind": LocalHub.value(row, "kind"), "refId": LocalHub.value(row, "ref_id"), "feel": LocalHub.value(row, "feel"),
             "effort": LocalHub.value(row, "effort"), "vsExpected": LocalHub.value(row, "vs_expected"),
             "tags": LocalDB.parse(row["tags"]) as? [String] ?? [], "note": LocalHub.value(row, "note"),
             "updatedAt": LocalHub.value(row, "updated_at")]
        }
    }

    static let putFeedback: LocalHub.Handler = { req in
        let o = req.object
        func scale(_ key: String, _ range: ClosedRange<Int>) -> (ok: Bool, value: Int?) {
            guard let raw = o[key], !(raw is NSNull) else { return (o.keys.contains(key), nil) }
            guard let v = LocalHub.int(raw), range.contains(v) else { return (false, nil) }
            return (true, v)
        }
        let feel = scale("feel", 1...5), effort = scale("effort", 1...10), vs = scale("vsExpected", -1...1)
        let tagList = (o["tags"] as? [Any])?.compactMap { $0 as? String } ?? []
        guard let kind = o["kind"] as? String, ["workout", "activity"].contains(kind),
              let refId = o["refId"] as? String, isRef(refId), feel.ok, effort.ok, vs.ok,
              tagList.count == (o["tags"] as? [Any])?.count, tagList.count <= 20, tagList.allSatisfy(isTag),
              o.keys.contains("note") else { return .error("Not valid feedback.") }
        let note = (o["note"] as? String).map { String($0.prefix(2000)) }
        let previousGuess = db.one("select guess from fitness_session_feedback where kind = ? and ref_id = ?", [kind, refId])?["guess"] as? String
        db.run(
            """
            insert or replace into fitness_session_feedback (kind, ref_id, feel, effort, vs_expected, tags, note, guess, updated_at)
            values (?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            [kind, refId, feel.value, effort.value, vs.value, LocalDB.json(tagList), note,
             previousGuess ?? (o.keys.contains("guess") ? LocalDB.json(o["guess"]) : nil), LocalDB.iso(Date())])
        return feedback(kind: kind, refId: refId).map(LocalHub.Reply.ok) ?? .error("Couldn't save that.", 500)
    }
}
