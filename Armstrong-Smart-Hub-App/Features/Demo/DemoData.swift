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
        case "/api/mobile/workouts/detail": body = workoutDetail()
        case "/api/mobile/finance": body = isPost ? ["ok": true, "message": "Synced 5 accounts"] : finance()
        case "/api/mobile/calendar": body = calendar()
        case "/api/mobile/todos": body = ["items": todos]
        case "/api/mobile/habits": body = habitsResponse()
        case "/api/home": body = homeState()
        case "/api/mobile/me": body = ["id": "demo", "email": "alex@riverahome.net", "name": "Alex Rivera"]
        case "/api/mobile/action": body = action(req.httpBody)
        case "/api/mobile/fitness/feedback" where !isPost:
            // How a session felt: already answered, with the hub's guess beside it.
            body = ["guess": ["feel": 4, "effort": 7, "reasons": ["Heart rate came down fast between sets", "Slept 7h 48m"]],
                    "feedback": ["kind": param("kind") ?? "workout", "refId": param("id") ?? "w-1", "feel": 4, "effort": 7,
                                 "vsExpected": 1, "tags": [String](), "note": NSNull()]]
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
              let name = json["name"] as? String else { return ["ok": true, "status": "ok"] }
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
        // Server Actions answer `{ ok, data }`; the finance ones `{ status, message }`.
        return ["ok": true, "data": NSNull(), "status": "ok"]
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
                item("bench-press-barbell", "Bench Press", 80, 6), item("overhead-press-barbell", "Overhead Press", 45, 8),
                item("chest-dip", "Dips", 0, 12)]],
            ["id": "r-pull", "name": "Pull", "position": 1, "exercises": [
                item("deadlift-barbell", "Deadlift", 140, 5), item("bent-over-row-barbell", "Barbell Row", 70, 8),
                item("pull-up", "Pull-up", 0, 10)]],
            ["id": "r-legs", "name": "Legs", "position": 2, "exercises": [
                item("squat-barbell", "Back Squat", 110, 5), item("romanian-deadlift-barbell", "Romanian Deadlift", 90, 8),
                item("lunge-dumbbell", "Walking Lunge", 24, 12)]],
        ]
        let yesterday = daysAgo(1)
        let workouts: [[String: Any]] = [
            ["id": "w-1", "name": "Pull", "startedAt": iso(yesterday.addingTimeInterval(-3 * 3600)),
             "endedAt": iso(yesterday.addingTimeInterval(-3 * 3600 + 52 * 60)), "exercises": ["Deadlift", "Barbell Row", "Pull-up"],
             "sets": 12, "volumeKg": 6240.0, "avgHr": 118, "maxHr": 162],
            ["id": "w-2", "name": "Push", "startedAt": iso(daysAgo(4)), "endedAt": iso(daysAgo(4).addingTimeInterval(48 * 60)),
             "exercises": ["Bench Press", "Overhead Press", "Dips"], "sets": 11, "volumeKg": 4180.0, "avgHr": 112, "maxHr": 155],
        ]
        func prev(_ kg: Double, _ reps: Int) -> [[String: Any]] { Array(repeating: ["kind": "normal", "weightKg": kg, "reps": reps], count: 3) }
        return ["exercises": [Any](), "routines": routines, "workouts": workouts,
                "previous": ["bench-press-barbell": prev(77.5, 6), "overhead-press-barbell": prev(42.5, 8), "chest-dip": prev(0, 11)],
                "bests": ["bench-press-barbell": ["e1rmKg": 93.0, "weightKg": 80.0, "reps": 5]]]
    }

    /// Yesterday's Pull session, with heart rate on every set.
    private static func workoutDetail() -> [String: Any] {
        let start = daysAgo(1).addingTimeInterval(-3 * 3600)
        var t = 300.0
        func sets(_ kg: Double, _ reps: [Int], peak: Int) -> [[String: Any]] {
            reps.enumerated().map { i, r in
                t += 150
                return ["kind": "normal", "weightKg": kg, "reps": r, "completedAt": iso(start.addingTimeInterval(t)),
                        "startedAt": iso(start.addingTimeInterval(t - 40)), "avgHr": peak - 18, "peakHr": peak + i * 3,
                        "endHr": peak - 6, "recoveryBpm": 28 - i * 2, "restSeconds": 150, "pr": i == 0 && kg == 145,
                        "e1rmKg": kg * (1 + Double(r) / 30)] as [String: Any]
            }
        }
        let groups: [[String: Any]] = [
            ["exerciseId": "deadlift-barbell", "name": "Deadlift", "sets": sets(145, [5, 5, 4], peak: 158)],
            ["exerciseId": "bent-over-row-barbell", "name": "Barbell Row", "sets": sets(70, [8, 8, 8], peak: 142)],
            ["exerciseId": "pull-up", "name": "Pull-up", "sets": sets(0, [11, 10, 9], peak: 146)],
        ]
        let hr: [[Double]] = stride(from: 0.0, through: 52 * 60, by: 15).map { s in
            let cycle = (s.truncatingRemainder(dividingBy: 150)) / 150
            return [s, 96 + 50 * exp(-pow((cycle - 0.25) * 4, 2)) + 4 * wave(s / 60)]
        }
        return ["id": "w-1", "name": "Pull", "routineId": "r-pull", "startedAt": iso(start), "endedAt": iso(start.addingTimeInterval(52 * 60)),
                "volumeKg": 6240.0, "avgHr": 118, "maxHr": 162, "hrSource": "live", "heartRate": hr, "exercises": groups]
    }

    // MARK: Finance

    private static func finance() -> [String: Any] {
        let nowS = now.timeIntervalSince1970
        func acct(_ id: String, _ name: String, _ inst: String, _ kind: String, _ bal: Double) -> [String: Any] {
            let liability = kind == "credit"
            return ["id": id, "name": name, "institution": inst, "currency": "USD", "kind": kind, "isLiability": liability,
                    "rawBalance": liability ? -bal : bal, "magnitude": bal, "contribution": liability ? -bal : bal,
                    "availableBalance": liability ? NSNull() : bal, "balanceDate": nowS - 1200]
        }
        let accounts: [[String: Any]] = [
            acct("a-check", "Everyday Checking", "Harbor Credit Union", "cash", 6420.18),
            acct("a-save", "High-Yield Savings", "Northline Bank", "cash", 18250.00),
            acct("a-card", "Rewards Card", "Northline Bank", "credit", 912.44),
            acct("a-brok", "Brokerage", "Summit Investing", "investment", 42180.55),
            acct("a-ira", "Roth IRA", "Summit Investing", "investment", 28904.12),
        ]
        var n = 0
        func tx(_ daysBack: Double, _ payee: String, _ amount: Double, _ category: String, _ account: String = "Rewards Card",
                source: String = "auto") -> [String: Any] {
            n += 1
            return ["id": "t-\(n)", "accountId": account == "Everyday Checking" ? "a-check" : "a-card", "accountName": account,
                    "institution": account == "Everyday Checking" ? "Harbor Credit Union" : "Northline Bank", "currency": "USD",
                    "posted": nowS - daysBack * 86400, "amount": amount, "netEffect": amount, "description": payee.uppercased(),
                    "payee": payee, "memo": NSNull(), "pending": daysBack < 1, "hold": false, "category": category, "categorySource": source]
        }
        let review: [[String: Any]] = [
            tx(0.2, "Blue Door Coffee", -6.50, "Food & Drinks"),
            tx(0.6, "Hillside Market", -64.12, "Groceries"),
            tx(1.1, "Metro Transit", -18.40, "Transport"),
            tx(1.4, "Riverside Climbing", -22.00, "Lifestyle"),
        ]
        let rest: [[String: Any]] = [
            tx(1.8, "Luca's Trattoria", -58.30, "Food & Drinks", source: "manual"),
            tx(2.3, "Paycheck · Brightline Studio", 3925.00, "Income", "Everyday Checking", source: "manual"),
            tx(3.0, "Green Valley Grocer", -41.87, "Groceries", source: "manual"),
            tx(3.4, "City Power & Light", -88.20, "Bills & Utilities", "Everyday Checking", source: "manual"),
            tx(4.2, "Cinema Paloma", -24.00, "Lifestyle", source: "manual"),
            tx(5.0, "Music streaming", -10.99, "Subscriptions & Fees", source: "manual"),
            tx(5.6, "Ferry Building Bakery", -12.75, "Food & Drinks", source: "manual"),
            tx(6.1, "Rideshare", -21.60, "Transport", source: "manual"),
            tx(7.3, "Hillside Market", -72.48, "Groceries", source: "manual"),
            tx(8.0, "Fiber internet", -60.00, "Bills & Utilities", "Everyday Checking", source: "manual"),
            tx(9.2, "Trailhead Outfitters", -86.00, "Lifestyle", source: "manual"),
            tx(10.5, "Sunday brunch", -46.20, "Food & Drinks", source: "manual"),
            tx(12.0, "Rent · Elm Street", -1450.00, "Rent", "Everyday Checking", source: "manual"),
            tx(12.1, "Weekend train", -76.00, "Travel", source: "manual"),
            tx(14.0, "Cloud storage", -2.99, "Subscriptions & Fees", source: "manual"),
            tx(16.3, "Paycheck · Brightline Studio", 3925.00, "Income", "Everyday Checking", source: "manual"),
        ]
        func cat(_ c: String, _ a: Double, _ total: Double) -> [String: Any] { ["category": c, "amount": a, "share": a / total] }
        let total = 2486.0
        let byCategory: [[String: Any]] = [
            cat("Rent", 1450, total), cat("Food & Drinks", 242, total), cat("Lifestyle", 214, total), cat("Groceries", 186, total),
            cat("Bills & Utilities", 168, total), cat("Transport", 96, total), cat("Travel", 76, total), cat("Subscriptions & Fees", 54, total),
        ]
        let worth: [[String: Any]] = (0..<90).reversed().map { b in
            ["date": day(daysAgo(b)), "value": 88_400 + Double(89 - b) * 72 + 900 * wave(Double(b) / 6)]
        }
        let months: [[String: Any]] = (0..<6).reversed().map { b in
            let d = Calendar.current.date(byAdding: .month, value: -b, to: now)!
            let c = Calendar.current.dateComponents([.year, .month], from: d)
            let income = 7850.0, spend = 2480 + 260 * wave(Double(b) * 1.7)
            return ["month": String(format: "%04d-%02d", c.year!, c.month!), "income": income, "spending": spend, "net": income - spend]
        }
        let dashboard: [String: Any] = [
            "accounts": accounts, "transactions": review + rest, "currency": "USD",
            "netWorth": 94_842.41, "totalAssets": 95_754.85, "totalLiabilities": 912.44, "errors": [String](),
            "netWorthSeries": worth, "cashFlow": months,
            "spending": ["windowDays": 30, "total": total, "byCategory": byCategory],
            "monthSpending": ["total": total, "lastMonthToDate": 2712.0, "byCategory": byCategory],
            "cash": 24_670.18, "toReview": review, "income30d": 7850.0, "spending30d": total, "netFlow30d": 7850 - total,
            "netWorthChange": 1_964.20,
        ]
        func sub(_ id: String, _ name: String, _ c: String, _ amt: Double, _ next: Double) -> [String: Any] {
            ["id": id, "name": name, "category": c, "accountName": "Rewards Card", "cadence": "monthly", "amount": amt,
             "previousAmount": NSNull(), "lastCharged": nowS - (30 - next) * 86400, "nextExpected": nowS + next * 86400,
             "monthlyCost": amt, "chargeCount": 14]
        }
        return [
            "configured": true, "hasData": true,
            "sync": ["lastSuccessAt": (nowS - 1200) * 1000, "failureReason": NSNull(), "notices": [String]()],
            "historyDays": 412, "dashboard": dashboard,
            "recurring": [sub("r1", "Music streaming", "Subscriptions & Fees", 10.99, 25), sub("r2", "Fiber internet", "Bills & Utilities", 60, 22),
                          sub("r3", "Cloud storage", "Subscriptions & Fees", 2.99, 16), sub("r4", "Climbing membership", "Lifestyle", 89, 9)],
            "history": ["series": worth, "source": "snapshots"],
            "goal": ["target": 1_000_000.0, "monthlyContribution": 2500.0, "annualReturnPct": 7.0],
            "customCategories": ["Climbing"],
            "quickCategories": ["out": ["Food & Drinks", "Groceries", "Transport"], "in": ["Income", "Transfers"]],
        ]
    }

    // MARK: Calendar

    private static let todos: [[String: Any]] = [
        ["id": "td1", "text": "Book flights for Denver", "done": false],
        ["id": "td2", "text": "Renew car registration", "done": false],
        ["id": "td3", "text": "Call Mom back", "done": false],
        ["id": "td4", "text": "Pick up dry cleaning", "done": true],
    ]

    private static func calendar() -> [String: Any] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: now)
        func at(_ d: Int, _ h: Double) -> Date { cal.date(byAdding: .day, value: d, to: today)!.addingTimeInterval(h * 3600) }
        var n = 0
        func ev(_ d: Int, _ h: Double, _ len: Double, _ title: String, _ calName: String, _ color: String, _ place: String? = nil) -> [String: Any] {
            n += 1
            return ["id": "e\(n)", "title": title, "start": iso(at(d, h)), "end": iso(at(d, h + len)), "allDay": false,
                    "location": place ?? NSNull(), "calendar": calName, "color": color, "url": NSNull(), "birthday": false]
        }
        let work = "#4285F4", personal = "#33B679", fitness = "#F6BF26", family = "#E67C73"
        let days: [[Any]] = [
            [ev(0, 7.5, 0.8, "Morning run", "Fitness", fitness), ev(0, 10.5, 0.75, "Design review", "Work", work, "Studio 3"),
             ev(0, 12.5, 1, "Lunch with Maya", "Personal", personal, "Luca's Trattoria"), ev(0, 15, 0.5, "1:1 with Jordan", "Work", work),
             ev(0, 18.5, 1.5, "Climbing with Sam", "Fitness", fitness, "Riverside Climbing")],
            [ev(1, 9, 0.5, "Team standup", "Work", work), ev(1, 11, 1, "Dentist", "Personal", personal, "Elm Street Dental"),
             ev(1, 17.5, 1, "Push day", "Fitness", fitness)],
            [ev(2, 9, 0.5, "Team standup", "Work", work), ev(2, 13, 2, "Product planning", "Work", work, "Studio 1"),
             ev(2, 19, 2, "Dinner at Mom & Dad's", "Family", family)],
            [ev(3, 8, 1.5, "Long run · 16 km", "Fitness", fitness), ev(3, 14, 3, "Farmers market", "Personal", personal)],
            [ev(4, 10, 2, "Sunday reset", "Personal", personal)],
            [ev(5, 9, 0.5, "Team standup", "Work", work), ev(5, 16, 1, "Haircut", "Personal", personal)],
            [ev(6, 9, 0.5, "Team standup", "Work", work), ev(6, 18, 1, "Pull day", "Fitness", fitness)],
        ]
        return ["status": "connected", "timeZone": TimeZone.current.identifier, "upcomingDays": 7, "today": day(now),
                "days": days.enumerated().map { i, events in ["day": day(cal.date(byAdding: .day, value: i, to: today)!), "events": events] as [String: Any] },
                "error": NSNull()]
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
