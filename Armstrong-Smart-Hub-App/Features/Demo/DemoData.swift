#if DEBUG
import Foundation

/// The launch film's sample world (Debug only, `-DemoMode YES`): a fake hub that answers
/// every request in-process. Nothing here touches the network, the real hub or saved data.
/// Values are fixed (no randomness) and placed relative to launch time, so every take matches.
@MainActor
enum DemoHub {
    // MARK: Clock

    /// Launch time, to the minute: every series ends here and every event sits before it.
    static let now: Date = {
        let t = Date().timeIntervalSince1970
        return Date(timeIntervalSince1970: (t / 60).rounded(.down) * 60)
    }()
    /// Woke at 7:00 when filmed at 9:41: always 2 h 41 m before launch.
    static let wake = now.addingTimeInterval(-(2 * 3600 + 41 * 60))
    static let bedtime = wake.addingTimeInterval(-(7 * 3600 + 48 * 60) - 14 * 60)
    static let runStart = wake.addingTimeInterval(32 * 60)
    static let runSeconds: Double = 48 * 60 + 36

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
    static func iso(_ d: Date) -> String { isoFormatter.string(from: d) }
    static func day(_ d: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: d)
        return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }
    static func daysAgo(_ n: Int) -> Date { Calendar.current.date(byAdding: .day, value: -n, to: now)! }

    /// Smooth, repeatable wobble in about -1...1 (no random numbers anywhere).
    static func wave(_ x: Double) -> Double { (sin(x * 1.7) + 0.5 * sin(x * 4.3 + 1) + 0.25 * sin(x * 9.1 + 2)) / 1.75 }

    // MARK: Fake transport

    private static var fitnessDelayed = false

    /// Answers a request the way the hub would, with a JSON 200.
    static func respond(_ req: URLRequest) async -> (Data, URLResponse) {
        try? await Task.sleep(for: .milliseconds(60))
        let url = req.url ?? URL(string: "https://demo.local/")!
        let path = url.path
        // `-DemoFitnessDelay 2.5`: the first Fitness load waits, so the rings fill on camera.
        if path == "/api/mobile/fitness", !fitnessDelayed {
            fitnessDelayed = true
            let delay = UserDefaults.standard.double(forKey: "DemoFitnessDelay")
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
        }
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func param(_ name: String) -> String? { query.first(where: { $0.name == name })?.value }
        let isPost = req.httpMethod == "POST"
        let ok: [String: Any] = ["ok": true]
        var body: [String: Any]
        var status = 200
        switch path {
        case "/api/mobile/fitness": body = fitnessSnapshot()
        case "/api/mobile/fitness/activity": body = activityDetail(id: param("id") ?? "run-today")
        case "/api/mobile/fitness/checkin": body = isPost ? ok : checkinPage(day: param("day") ?? day(now))
        case "/api/mobile/workouts": body = isPost ? ok : workoutsHome()
        case "/api/mobile/habits": body = habitsResponse()
        case "/api/home": body = homeState()
        case "/api/mobile/me": body = ["id": "demo", "email": "alex@riverahome.net", "name": "Alex Rivera"]
        case "/api/mobile/action": body = action(req.httpBody)
        case "/api/mobile/fitness/live", "/api/mobile/fitness/feedback": body = ok
        default:
            status = 404
            body = ["error": "Not in the demo."]
        }
        let data = (try? JSONSerialization.data(withJSONObject: body)) ?? Data("{}".utf8)
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
        return (data, response)
    }

    // MARK: Home

    private static var entities: [[String: Any]] = [
        ["id": "light.living_room", "name": "Living Room", "state": "off", "room": "Living Room", "control": "light",
         "colorModes": ["color_temp", "hs"], "colorTempKelvin": 2700, "minKelvin": 2200, "maxKelvin": 6500],
        ["id": "light.kitchen", "name": "Kitchen", "state": "on", "room": "Kitchen", "control": "light",
         "brightness": 204.0, "colorModes": ["color_temp"], "colorTempKelvin": 3000, "minKelvin": 2200, "maxKelvin": 6500],
        ["id": "light.bedroom", "name": "Bedroom", "state": "off", "room": "Bedroom", "control": "light",
         "colorModes": ["color_temp", "hs"], "colorTempKelvin": 2400, "minKelvin": 2200, "maxKelvin": 6500],
        ["id": "light.office", "name": "Office Lamp", "state": "on", "room": "Office", "control": "light",
         "brightness": 153.0, "colorModes": ["brightness"]],
        ["id": "media_player.living_room_tv", "name": "Living Room TV", "state": "off", "room": "Living Room", "control": "mediaPlayer"],
        ["id": "climate.hallway", "name": "Thermostat", "state": "heat", "room": "Hallway", "control": "climate", "unit": "°F"],
        ["id": "lock.front_door", "name": "Front Door", "state": "unlocked", "room": "Entry", "control": "lock"],
        ["id": "lock.garage", "name": "Garage", "state": "locked", "room": "Garage", "control": "lock"],
        ["id": "switch.espresso", "name": "Espresso Machine", "state": "on", "room": "Kitchen", "control": "toggle"],
        ["id": "switch.office_fan", "name": "Office Fan", "state": "off", "room": "Office", "control": "toggle"],
    ]

    private static var automations: [[String: Any]] = [
        ["id": "automation.good_morning", "name": "Good Morning", "state": "on", "lastTriggered": iso(wake), "hubMade": true, "configId": "good_morning"],
        ["id": "automation.arrive_home", "name": "Arrive Home", "state": "on", "lastTriggered": iso(daysAgo(1)), "hubMade": true, "configId": "arrive_home"],
        ["id": "automation.wind_down", "name": "Wind Down at 10:30", "state": "off", "lastTriggered": iso(daysAgo(2)), "hubMade": true, "configId": "wind_down"],
        ["id": "automation.porch_sunset", "name": "Porch Light at Sunset", "state": "on", "lastTriggered": iso(daysAgo(1)), "hubMade": false, "configId": NSNull()],
    ]

    private static func homeState() -> [String: Any] { [
        "configured": true,
        "entities": entities,
        "requests": [Any](),
        // The film's Home: lights, locks and switches on one screen (no TV remote or thermostat).
        "visible": ["light.living_room", "light.kitchen", "light.bedroom", "light.office",
                    "lock.front_door", "lock.garage", "switch.espresso", "switch.office_fan"],
        "automations": [
            "automations": automations,
            "scenes": [["id": "scene.movie_night", "name": "Movie Night", "state": "scening", "lastTriggered": iso(daysAgo(3))],
                       ["id": "scene.dinner", "name": "Dinner", "state": "scening", "lastTriggered": iso(daysAgo(1))]],
            "scripts": [Any](),
        ],
        "errors": [String: Any](),
        "fetchedAt": now.timeIntervalSince1970 * 1000,
    ] }

    private static func action(_ raw: Data?) -> [String: Any] {
        guard let raw, let json = try? JSONSerialization.jsonObject(with: raw) as? [String: Any],
              let name = json["name"] as? String else { return ["ok": true] }
        let args = json["args"] as? [Any] ?? []
        let id = args.first as? String
        switch name {
        case "toggleEntity":
            if let i = entities.firstIndex(where: { $0["id"] as? String == id }) {
                let control = entities[i]["control"] as? String
                let state = entities[i]["state"] as? String ?? "off"
                if control == "lock" {
                    entities[i]["state"] = state == "locked" ? "unlocked" : "locked"
                } else {
                    let on = state != "on"
                    entities[i]["state"] = on ? "on" : "off"
                    if on, control == "light", entities[i]["brightness"] == nil { entities[i]["brightness"] = 102.0 }
                }
            }
        case "setLight":
            if let i = entities.firstIndex(where: { $0["id"] as? String == id }), let change = args.dropFirst().first as? [String: Any] {
                if let on = change["on"] as? Bool { entities[i]["state"] = on ? "on" : "off" } else { entities[i]["state"] = "on" }
                if let pct = change["brightnessPct"] as? Int { entities[i]["brightness"] = Double(pct) / 100 * 255 }
                if let k = change["kelvin"] as? Int { entities[i]["colorTempKelvin"] = k }
                if let rgb = change["rgb"] { entities[i]["rgbColor"] = rgb }
            }
        case "setAutomationEnabled":
            if let i = automations.firstIndex(where: { $0["id"] as? String == id }), let on = args.dropFirst().first as? Bool {
                automations[i]["state"] = on ? "on" : "off"
            }
        case "setCompletion":
            if let id, let date = args.dropFirst().first as? String, let done = args.dropFirst(2).first as? Bool {
                completions.removeAll { $0["habitId"] == id && $0["date"] == date }
                if done { completions.append(["habitId": id, "date": date]) }
            }
        default: break
        }
        return ["ok": true, "data": NSNull()]
    }

    // MARK: Habits

    private static let habits: [(String, String, String, String)] = [
        ("h-meditate", "Meditate", "#8B6CFF", "🧘"),
        ("h-read", "Read", "#FFB75C", "📚"),
        ("h-stretch", "Stretch", "#3DDC6E", "🤸"),
        ("h-water", "Water", "#75B8FF", "💧"),
        ("h-journal", "Journal", "#FF8288", "✍️"),
    ]

    private static var completions: [[String: String]] = {
        var out: [[String: String]] = []
        for back in 0..<45 {
            let d = day(daysAgo(back))
            for (i, h) in habits.enumerated() {
                // Today: three of five done so far; earlier days mostly done.
                let done = back == 0 ? i < 3 : (back * 7 + i * 3) % 5 != 0
                if done { out.append(["habitId": h.0, "date": d]) }
            }
        }
        return out
    }()

    private static func habitsResponse() -> [String: Any] { [
        "habits": habits.enumerated().map { i, h in
            ["id": h.0, "name": h.1, "color": h.2, "icon": h.3, "position": i, "createdAt": iso(daysAgo(120))] as [String: Any]
        },
        "completions": completions,
        "colors": ["#8B6CFF", "#FFB75C", "#3DDC6E", "#75B8FF", "#FF8288", "#C58AF9"],
        "historyDays": 60,
    ] }

    // MARK: Workouts

    private static func workoutsHome() -> [String: Any] {
        func item(_ id: String, _ name: String, _ kg: Double, _ reps: Int) -> [String: Any] {
            ["exerciseId": id, "name": name, "restSeconds": 120, "superset": NSNull(),
             "sets": Array(repeating: ["kind": "normal", "weightKg": kg, "reps": reps] as [String: Any], count: 3)]
        }
        let routines: [[String: Any]] = [
            ["id": "r-push", "name": "Push", "position": 0, "exercises": [
                item("bench", "Bench Press", 80, 6), item("ohp", "Overhead Press", 45, 8), item("dips", "Dips", 0, 12)]],
            ["id": "r-pull", "name": "Pull", "position": 1, "exercises": [
                item("deadlift", "Deadlift", 140, 5), item("row", "Barbell Row", 70, 8), item("pullup", "Pull-up", 0, 10)]],
            ["id": "r-legs", "name": "Legs", "position": 2, "exercises": [
                item("squat", "Back Squat", 110, 5), item("rdl", "Romanian Deadlift", 90, 8), item("lunge", "Walking Lunge", 24, 12)]],
        ]
        let yesterday = daysAgo(1)
        let workouts: [[String: Any]] = [
            ["id": "w-1", "name": "Pull", "startedAt": iso(yesterday.addingTimeInterval(-3 * 3600)),
             "endedAt": iso(yesterday.addingTimeInterval(-3 * 3600 + 52 * 60)), "exercises": ["Deadlift", "Barbell Row", "Pull-up"],
             "sets": 12, "volumeKg": 6240.0, "avgHr": 118, "maxHr": 162],
            ["id": "w-2", "name": "Push", "startedAt": iso(daysAgo(4)), "endedAt": iso(daysAgo(4).addingTimeInterval(48 * 60)),
             "exercises": ["Bench Press", "Overhead Press", "Dips"], "sets": 11, "volumeKg": 4180.0, "avgHr": 112, "maxHr": 155],
        ]
        return ["exercises": [Any](), "routines": routines, "workouts": workouts,
                "previous": [String: Any](), "bests": [String: Any]()]
    }

    // MARK: Check-in

    private static func checkinPage(day d: String) -> [String: Any] {
        let entry: [String: Any] = ["day": d, "energy": 4, "mood": 4, "soreness": 1, "tags": ["fine"], "rejected": [String](), "note": NSNull()]
        return [
            "day": d, "guess": NSNull(), "entry": entry, "recent": [entry], "suggestions": [Any](),
            "learning": ["labelledDays": 41, "daysOfData": 212, "states": [Any](),
                         "energy": ["ratings": 41, "error": 0.6, "drivers": [Any]()]],
            "vocabulary": ["states": [["key": "fine", "label": "Feeling good"]], "causes": [Any](), "symptoms": [Any]()],
        ]
    }

    // MARK: Fitness

    /// Heart rate at a moment: asleep, on the morning run, or the rest of the day.
    static func bpm(at t: Date) -> Int {
        let x = t.timeIntervalSince1970 / 900
        if t >= bedtime, t < wake { return Int(47 + 4 * wave(x)) }
        if t >= runStart, t < runStart.addingTimeInterval(runSeconds) {
            let p = t.timeIntervalSince(runStart) / runSeconds
            let warm = min(1, p * 6)
            return Int(112 + 44 * warm + 14 * p + 3 * wave(x * 4))
        }
        let sinceRun = t.timeIntervalSince(runStart.addingTimeInterval(runSeconds))
        let cooldown = sinceRun > 0 && sinceRun < 1800 ? 30 * (1 - sinceRun / 1800) : 0
        return Int(64 + 7 * wave(x) + cooldown)
    }

    private static func everyFiveMinutes(hours: Double = 24) -> [Date] {
        stride(from: now.addingTimeInterval(-hours * 3600), through: now, by: 300).map { $0 }
    }

    static func battery(at t: Date) -> Int {
        let lastBed = bedtime.addingTimeInterval(-86400 + 20 * 60)
        if t < lastBed {
            return 70
        } else if t < bedtime {
            let p = t.timeIntervalSince(lastBed) / bedtime.timeIntervalSince(lastBed)
            return Int(96 - 65 * p)
        } else if t < wake {
            let p = t.timeIntervalSince(bedtime) / wake.timeIntervalSince(bedtime)
            return Int(31 + 65 * sqrt(p))
        } else {
            let p = t.timeIntervalSince(wake) / now.timeIntervalSince(wake)
            return Int(96 - 18 * p)
        }
    }

    private static func stress(at t: Date) -> (Int, String) {
        if t >= bedtime, t < wake { return (Int(10 + 4 * wave(t.timeIntervalSince1970 / 600)), "rest") }
        if t >= runStart, t < runStart.addingTimeInterval(runSeconds) { return (0, "active") }
        let v = Int(26 + 12 * wave(t.timeIntervalSince1970 / 1200))
        return (v, v <= 25 ? "rest" : "low")
    }

    private static func history(_ values: [Double]) -> [[String: Any]] {
        values.enumerated().map { i, v in ["at": iso(daysAgo(values.count - 1 - i)), "value": v] }
    }

    private static func sleepNight(_ back: Int, score: Int, asleepMinutes: Int) -> [String: Any] {
        let end = wake.addingTimeInterval(Double(-back) * 86400 + Double(back % 3) * 600)
        let start = end.addingTimeInterval(-Double(asleepMinutes + 14) * 60)
        // Four-and-a-bit cycles: deep early, REM late.
        let cycles: [[(Int, Int)]] = [
            [(2, 12), (3, 46), (2, 18), (4, 14)],
            [(2, 22), (3, 34), (2, 16), (4, 22), (1, 4)],
            [(2, 30), (3, 18), (2, 14), (4, 30)],
            [(2, 34), (3, 8), (2, 16), (4, 36), (1, 3)],
        ]
        var levels: [[Double]] = [[0, 1]]
        var cursor = 7.0 * 60
        var totals: [Int: Int] = [1: 7 * 60, 2: 0, 3: 0, 4: 0]
        var budget = asleepMinutes
        outer: for cycle in cycles + [[(2, 60), (4, 40), (2, 40)]] {
            for (stage, minutes) in cycle {
                let m = min(minutes, budget)
                guard m > 0 else { break outer }
                levels.append([cursor, Double(stage)])
                cursor += Double(m * 60)
                totals[stage, default: 0] += m * 60
                if stage != 1 { budget -= m }
            }
        }
        levels.append([cursor, 1])
        totals[1, default: 0] += Int(end.timeIntervalSince(start) - cursor)
        return ["id": "sleep-\(back)", "start": iso(start), "end": iso(end),
                "deepSeconds": totals[3]!, "lightSeconds": totals[2]!, "remSeconds": totals[4]!, "awakeSeconds": totals[1]!,
                "score": score, "watchScore": score, "levels": levels]
    }

    private static let activities: [[String: Any]] = [
        activity("run-today", "running", nil, runStart, runSeconds, 10020, 712, 152, 174, 84, 3.8, "Tempo"),
        activity("strength-1", "training", "strength_training", daysAgo(1).addingTimeInterval(-3 * 3600), 52 * 60, nil, 380, 118, 162, nil, 2.6, "Base"),
        activity("ride-2", "cycling", "road", daysAgo(2).addingTimeInterval(-1 * 3600), 74 * 60, 32400, 820, 138, 166, 310, 3.4, "Tempo"),
        activity("run-3", "running", nil, daysAgo(3).addingTimeInterval(-2 * 3600), 36 * 60, 6420, 420, 136, 151, 38, 2.4, "Recovery"),
        activity("yoga-5", "training", "yoga", daysAgo(5).addingTimeInterval(1 * 3600), 40 * 60, nil, 150, 92, 118, nil, 1.2, "Recovery"),
        activity("run-6", "running", nil, daysAgo(6).addingTimeInterval(-2.5 * 3600), 88 * 60, 16100, 1180, 146, 168, 142, 4.1, "Base"),
        activity("swim-8", "swimming", "lap_swimming", daysAgo(8).addingTimeInterval(-1 * 3600), 42 * 60, 2000, 410, 128, 150, nil, 2.8, "Base"),
    ]

    private static func activity(_ id: String, _ sport: String, _ sub: String?, _ start: Date, _ seconds: Double,
                                 _ meters: Double?, _ kcal: Int, _ avg: Int, _ max: Int, _ ascent: Double?,
                                 _ te: Double, _ benefit: String) -> [String: Any] {
        var a: [String: Any] = ["id": id, "sport": sport, "startTime": iso(start), "utcOffset": TimeZone.current.secondsFromGMT(),
                                "elapsedSeconds": seconds, "movingSeconds": seconds - 30, "calories": kcal, "avgHr": avg, "maxHr": max,
                                "trainingEffect": te, "watchLoad": te * 42, "anaerobicEffect": te / 2.4, "primaryBenefit": benefit]
        if let sub { a["subSport"] = sub }
        if let meters { a["distanceMeters"] = meters; a["avgSpeed"] = meters / (seconds - 30) }
        if let ascent { a["ascentMeters"] = ascent }
        return a
    }

    private static func activityDetail(id: String) -> [String: Any] {
        var a = activities.first { $0["id"] as? String == id } ?? activities[0]
        let start = ISO.parse(a["startTime"] as! String) ?? runStart
        let seconds = a["elapsedSeconds"] as? Double ?? runSeconds
        a["heartRate"] = stride(from: 0.0, through: seconds, by: 10).map { s -> [Double] in
            let p = s / seconds
            return [s, Double(110 + Int(46 * min(1, p * 6)) + Int(14 * p) + Int(3 * wave(start.timeIntervalSince1970 + s / 40)))]
        }
        a["recoveryHours"] = 18.0
        return a
    }

    private static func fitnessSnapshot() -> [String: Any] {
        let days: [[String: Any]] = (0..<14).map { back in
            let steps = back == 0 ? 11_240 : 8_400 + Int(3_600 * wave(Double(back) * 2.3)) + (back % 3 == 0 ? 4_000 : 0)
            var d: [String: Any] = ["day": day(daysAgo(back)), "steps": steps, "stepGoal": 10_000,
                                    "restingHr": 48 + Int(2 * wave(Double(back)))]
            if back > 0 {
                d["distanceMeters"] = Double(steps) * 0.78
                d["activeKcal"] = 620 + Int(240 * wave(Double(back) * 1.3))
                d["restingKcal"] = 1_780
                d["moderateMinutes"] = 24 + back % 4 * 6
                d["vigorousMinutes"] = 18 + back % 3 * 10
                d["floorsUp"] = 12.0
                d["floorsDown"] = 11.0
            }
            return d
        }
        let heart = everyFiveMinutes().map { ["at": iso($0), "bpm": bpm(at: $0)] as [String: Any] }
        let batterySeries = everyFiveMinutes().map { ["at": iso($0), "value": battery(at: $0)] as [String: Any] }
        let stressSeries = everyFiveMinutes().map { t -> [String: Any] in
            let (v, kind) = stress(at: t)
            return ["at": iso(t), "value": v, "kind": kind]
        }
        let sleep = [sleepNight(0, score: 91, asleepMinutes: 468), sleepNight(1, score: 84, asleepMinutes: 442),
                     sleepNight(2, score: 88, asleepMinutes: 455), sleepNight(3, score: 79, asleepMinutes: 418),
                     sleepNight(4, score: 86, asleepMinutes: 450), sleepNight(5, score: 90, asleepMinutes: 471),
                     sleepNight(6, score: 82, asleepMinutes: 436)]
        let hrv: [[String: Any]] = (0..<14).map { back in
            ["id": "hrv-\(back)", "day": day(daysAgo(back)), "weeklyAverage": 64.0, "lastNightAverage": back == 0 ? 68.0 : 62 + 5 * wave(Double(back)),
             "lastNight5MinHigh": 88.0, "baselineLowUpper": 52.0, "baselineBalancedLower": 55.0, "baselineBalancedUpper": 72.0, "status": "balanced"]
        }
        let readinessHistory = history([71, 78, 66, 82, 74, 80, 69, 77, 84, 72, 79, 81, 75, 86])
        let at = iso(wake)
        let metrics: [String: Any] = [
            "profile": ["maxHr": 188, "restingHr": 48],
            "readiness": ["score": 86, "level": "high", "factors": [
                ["key": "sleep", "label": "Sleep", "score": 91, "weight": 0.3, "detail": "7h 48m, score 91"],
                ["key": "recovery", "label": "Recovery time", "score": 82, "weight": 0.2, "detail": "9 h left"],
                ["key": "hrv", "label": "HRV status", "score": 88, "weight": 0.25, "detail": "Balanced, 68 ms"],
                ["key": "load", "label": "Acute load", "score": 79, "weight": 0.25, "detail": "Productive"],
            ]],
            "bodyBattery": ["current": 78, "charged": 65, "drained": 18, "series": batterySeries],
            "stress": ["average": 22, "restMinutes": 612, "series": stressSeries],
            "vo2max": ["value": 56.0, "asOf": at, "watch": 56.0, "runs": [Any]()],
            "load": ["acute": 612, "chronic": 548, "ratio": 1.12, "recoveryHours": 9, "status": "productive"],
            "hrv": ["lastNight": 68.0, "weekly": 64.0, "baseline": ["low": 55.0, "high": 72.0], "status": "balanced"],
            "vitals": ["spo2": 97.0, "respiration": 13.8, "skinTemp": -0.2],
            "sources": ["readiness": "watch", "bodyBattery": "watch", "stress": "watch", "vo2max": "watch", "recovery": "watch"],
        ]
        let insights: [String: Any] = [
            "strain": ["today": 14.2, "level": "strenuous",
                       "week": (0..<7).reversed().map { b in ["day": day(daysAgo(b)), "strain": [9.8, 12.1, 6.4, 15.3, 10.2, 11.7, 14.2][6 - b]] as [String: Any] }],
            "recovery": ["status": "ready", "score": 88, "zone": "green", "parts": [Any]()],
            "sleep": ["need": ["hours": 8.1, "baseline": 7.8, "debt": 0.3, "strain": 0.2, "naps": 0.0],
                      "lastNight": ["asleepHours": 7.8, "needed": 8.1, "performance": 96, "score": 91, "interruptions": 1,
                                    "recoveryIndex": ["score": 88, "lowestHr": 44, "lowestAt": 14_400.0, "share": 0.31],
                                    "apple": ["score": 90, "duration": 47, "consistency": 24, "interruptions": 19]],
                      "bedtimeSpread": 22],
            "stress": ["now": 18, "today": ["stressedMinutes": 42, "restoredMinutes": 612, "summary": "Mostly restful"],
                       "resilience": ["status": "ready", "level": "strong", "daytime": 72, "overnight": 91],
                       "bodyBattery": ["current": 78, "high": 96, "low": 31, "series": batterySeries]],
            "training": [
                "lastWorkout": ["sport": "running", "at": iso(runStart), "minutes": 49, "aerobic": 3.8, "aerobicLabel": "Improving",
                                "anaerobic": 1.6, "anaerobicLabel": "Some benefit", "effort": 7, "strain": 12.4, "strainLevel": "moderate"],
                "focus": ["low": 410, "high": 280, "anaerobic": 95, "status": "balanced"],
                "lactateThreshold": ["heartRate": 168, "measured": true, "speed": 3.9, "percentOfMax": 89],
                "races": ["5k": 1182, "10k": 2470, "half": 5460, "marathon": 11520],
                "endurance": ["score": 7840, "tier": "expert", "longLoad": 340],
                "performanceCondition": ["value": 3, "at": iso(runStart)],
                "effortLoad": ["week": 612, "month": 2310, "trend": "up"],
            ],
            "age": ["age": 31, "cardioFitness": ["percentile": 92, "level": "excellent", "lowFitness": false],
                    "hubAge": ["age": 26.4, "fitnessAge": 25, "difference": -4.6, "parts": [
                        ["key": "vo2max", "label": "VO2 max", "years": -2.8], ["key": "rhr", "label": "Resting heart rate", "years": -1.2],
                        ["key": "activity", "label": "Intensity minutes", "years": -0.6]]],
                    "paceOfAging": 0.7],
            "vitals": ["outliers": 0, "calibrating": false, "readings": [
                ["key": "rhr", "value": 48.0, "low": 46.0, "high": 53.0, "outlier": false, "have": 30],
                ["key": "hrv", "value": 68.0, "low": 55.0, "high": 72.0, "outlier": false, "have": 30],
                ["key": "respiration", "value": 13.8, "low": 12.9, "high": 15.1, "outlier": false, "have": 30],
                ["key": "spo2", "value": 97.0, "low": 94.0, "high": 99.0, "outlier": false, "have": 30],
                ["key": "skinTemp", "value": -0.2, "low": -0.8, "high": 0.7, "outlier": false, "have": 30],
            ]],
        ]
        let watch: [String: Any] = [
            "readiness": ["at": at, "score": 86, "level": "high", "sleepScore": 91, "weeklyHrv": 64.0, "history": readinessHistory],
            "recovery": ["at": iso(runStart.addingTimeInterval(runSeconds)), "totalHours": 18.0, "remainingHours": 9.0],
            "endurance": ["at": at, "score": 7840, "level": "expert", "nextLevel": ["name": "superior", "at": 8800.0],
                          "gauge": ["low": 3000.0, "high": 10000.0], "bounds": [String: Any](),
                          "history": history([7420, 7460, 7510, 7530, 7590, 7620, 7660, 7700, 7720, 7760, 7790, 7800, 7820, 7840])],
            "races": ["at": at, "fiveK": 1182, "tenK": 2470, "half": 5460, "marathon": 11520, "history": [Any]()],
            "sleepNeed": ["at": at, "hours": 8.1, "usualHours": 7.8],
            "sleep": ["at": at, "overall": 91, "parts": ["duration": 94, "quality": 90, "deep": 88, "light": 85, "rem": 92,
                                                       "recovery": 89, "restlessness": 82, "interruptions": 86],
                      "awakenings": 1, "avgStress": 14.0, "lowestHr": 44, "batteryGained": 65,
                      "history": history([84, 88, 79, 86, 90, 82, 91])],
            "vo2max": ["at": at, "value": 56.0, "history": history([54, 54, 55, 55, 55, 55, 56, 56, 56, 56, 56, 56])],
            "lactateThreshold": ["at": at, "hr": 168.0, "speed": 3.9],
        ]
        return [
            "days": days, "activities": activities, "sleep": sleep, "heartRate": heart,
            "files": [["kind": "activity", "count": 214], ["kind": "sleep", "count": 188], ["kind": "monitor", "count": 1290]],
            "hrv": hrv, "metrics": metrics, "insights": insights, "watch": watch, "allDayThrough": iso(now),
        ]
    }
}
#endif
