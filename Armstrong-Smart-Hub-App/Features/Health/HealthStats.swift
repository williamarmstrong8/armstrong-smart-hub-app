import Foundation

/// The numbers behind the briefing: each one measured against your own
/// history, not population norms. Every finding is a full sentence that
/// already says what the number means for you (how unusual it is, which way
/// it's drifting, what tends to follow it in your data), so the on-device
/// model only has to pick the important ones and join them up.
///
/// - Baselines: the last 60 days before today, mean and standard deviation,
///   and where today falls (z-score, share of days lower).
/// - Trends: the last 7 days against the 4 weeks before them.
/// - Patterns: your mornings split by what came before (drinks, training,
///   a late night, a short night), compared only when each side has at
///   least 4 days.
@MainActor
struct HealthStats {
    let fitness: FitnessStore
    let alcohol: AlcoholStore
    let checkins: CheckinStore
    let places: PlaceMonitor

    /// A finding and how much it matters (bigger first).
    struct Finding {
        var text: String
        var weight: Double
    }

    // MARK: Per-morning table

    /// One morning: the night that ended on it and the readings taken then.
    private struct Morning {
        var day: String
        var sleep: Double?       // hours asleep
        var deep: Double?        // minutes
        var rem: Double?         // minutes
        var score: Double?
        var bedtime: Double?     // minutes after noon
        var hrv: Double?
        var rhr: Double?
    }

    private var mornings: [Morning] {
        var byDay: [String: Morning] = [:]
        func edit(_ day: String, _ change: (inout Morning) -> Void) {
            var m = byDay[day] ?? Morning(day: day)
            change(&m)
            byDay[day] = m
        }
        for n in fitness.nights {
            guard let end = n.endDate, n.asleepSeconds > 1800 else { continue }
            edit(localDay(end)) { m in
                m.sleep = Double(n.asleepSeconds) / 3600
                m.deep = Double(n.seconds(.deep)) / 60
                m.rem = Double(n.seconds(.rem)) / 60
                m.score = n.score.map(Double.init)
                m.bedtime = n.startDate.map(Self.minutesAfterNoon)
            }
        }
        for h in fitness.snapshot?.hrv ?? [] {
            if let v = h.lastNightAverage, v > 0 { edit(h.day) { $0.hrv = v } }
        }
        for d in fitness.days {
            if let r = d.restingHr, r > 0 { edit(d.day) { $0.rhr = Double(r) } }
        }
        return byDay.values.sorted { $0.day > $1.day }
    }

    private static func minutesAfterNoon(_ date: Date) -> Double {
        let c = Calendar.current.dateComponents([.hour, .minute], from: date)
        return Double(((c.hour ?? 0) * 60 + (c.minute ?? 0) - 720 + 1440) % 1440)
    }

    private static func clock(_ minutesAfterNoon: Double) -> String {
        let total = (Int(minutesAfterNoon.rounded()) + 720) % 1440
        let date = Calendar.current.date(bySettingHour: total / 60, minute: total % 60, second: 0, of: .now) ?? .now
        return date.formatted(date: .omitted, time: .shortened)
    }

    // MARK: Statistics

    struct Baseline {
        var mean: Double
        var sd: Double
        var values: [Double]
        var n: Int { values.count }

        init?(_ values: [Double], min: Int = 7) {
            guard values.count >= min else { return nil }
            self.values = values
            mean = values.reduce(0, +) / Double(values.count)
            let variance = values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(max(1, values.count - 1))
            sd = variance.squareRoot()
        }

        func z(_ x: Double) -> Double { sd > 0 ? (x - mean) / sd : 0 }
        /// Share of days below x, 0–100.
        func lower(_ x: Double) -> Int { Int((Double(values.filter { $0 < x }.count) / Double(n) * 100).rounded()) }
    }

    private static func mean(_ v: [Double]) -> Double? { v.isEmpty ? nil : v.reduce(0, +) / Double(v.count) }

    /// "the lowest 8% of your mornings" / "higher than 93% of your mornings" / nil when ordinary.
    private static func rank(_ b: Baseline, _ x: Double, noun: String) -> String? {
        let below = b.lower(x)
        if below <= 15 { return "lower than all but \(max(below, 1))% of your \(noun)" }
        if below >= 85 { return "higher than \(below)% of your \(noun)" }
        return nil
    }

    private static func sd(_ z: Double) -> String {
        String(format: "%.1f standard deviations %@ your average", abs(z), z < 0 ? "below" : "above")
    }

    private static func hm(_ hours: Double) -> String { FitnessFormat.duration(hours * 3600) }

    private static func pct(_ a: Double, vs b: Double) -> Int { b == 0 ? 0 : Int(((a - b) / b * 100).rounded()) }

    // MARK: Morning

    func morning() -> [Finding] {
        var out: [Finding] = []
        let table = mornings
        let today = localDay()
        guard let now = table.first(where: { $0.day == today }) ?? table.first else { return out }
        let history = Array(table.filter { $0.day < now.day }.prefix(60))

        // Last night against your own nights.
        if let x = now.sleep, let b = Baseline(history.compactMap(\.sleep)) {
            let z = b.z(x)
            var line = "You slept \(Self.hm(x)), \(Self.sd(z)) of \(Self.hm(b.mean)) over your last \(b.n) nights"
            if let r = Self.rank(b, x, noun: "nights") { line += ", \(r)" }
            out.append(Finding(text: line + ".", weight: abs(z)))
        }
        if let x = now.deep, let b = Baseline(history.compactMap(\.deep)), abs(b.z(x)) >= 1 {
            out.append(Finding(text: "Deep sleep was \(Int(x)) minutes against your usual \(Int(b.mean)), \(Self.sd(b.z(x))).", weight: abs(b.z(x)) * 0.8))
        }
        if let x = now.bedtime, let b = Baseline(history.compactMap(\.bedtime)), abs(x - b.mean) >= 45 {
            let late = x > b.mean
            out.append(Finding(text: "You fell asleep at \(Self.clock(x)), \(Int(abs(x - b.mean))) minutes \(late ? "later" : "earlier") than your usual \(Self.clock(b.mean)).",
                               weight: abs(b.z(x)) * 0.7))
        }
        if let x = now.hrv, let b = Baseline(history.compactMap(\.hrv)) {
            let z = b.z(x)
            var line = "Overnight HRV was \(Int(x.rounded())) ms, \(Self.sd(z)) of \(Int(b.mean.rounded())) ms"
            if let r = Self.rank(b, x, noun: "mornings") { line += ", \(r)" }
            line += z <= -1 ? ", which in your data points to a body still recovering." : z >= 1 ? ", a sign you recovered well." : ", inside your normal range."
            out.append(Finding(text: line, weight: abs(z) * 1.2))
        }
        if let x = now.rhr, let b = Baseline(history.compactMap(\.rhr)) {
            let z = b.z(x)
            if abs(z) >= 0.8 {
                out.append(Finding(text: "Resting heart rate is \(Int(x)) bpm against your usual \(Int(b.mean.rounded())), \(Self.sd(z))\(z > 0 ? ", usually a sign of strain, short sleep, alcohol or getting ill" : "").",
                                   weight: abs(z)))
            }
        }

        // How many recovery markers are off together, and how often that happens to you.
        if let hb = Baseline(history.compactMap(\.hrv)), let rb = Baseline(history.compactMap(\.rhr)), let sb = Baseline(history.compactMap(\.sleep)) {
            func flags(_ m: Morning) -> Int {
                [m.hrv.map { hb.z($0) <= -1 }, m.rhr.map { rb.z($0) >= 1 }, m.sleep.map { sb.z($0) <= -1 }].compactMap { $0 }.filter { $0 }.count
            }
            let count = flags(now)
            if count >= 2 {
                let alike = history.filter { flags($0) >= 2 }.count
                out.append(Finding(text: "\(count) of your 3 recovery markers (HRV, resting heart rate, sleep) are outside your normal range at once, which has happened on \(alike) of your last \(history.count) mornings.",
                                   weight: 2.5))
            }
        }

        // Week against the month before it.
        for (name, unit, values, goodUp) in [("HRV", "ms", table.compactMap(\.hrv), true), ("resting heart rate", "bpm", table.compactMap(\.rhr), false)] {
            let recent = Array(values.prefix(7)), before = Array(values.dropFirst(7).prefix(28))
            guard recent.count >= 5, before.count >= 14, let a = Self.mean(recent), let b = Self.mean(before) else { continue }
            let change = Self.pct(a, vs: b)
            guard abs(change) >= 5 else { continue }
            let better = (change > 0) == goodUp
            out.append(Finding(text: "Your 7-day \(name) averages \(Int(a.rounded())) \(unit), \(abs(change))% \(change > 0 ? "above" : "below") the 4 weeks before, a \(better ? "positive" : "worrying") drift.",
                               weight: Double(abs(change)) / 8))
        }

        // What drinking does to your mornings.
        let lastNight = addDays(now.day, -1)
        let drankLast = alcohol.drinks(on: lastNight) > 0 || alcohol.amountUnknown(lastNight)
        if let effect = drinkEffect(table) {
            let tonight = drankLast ? " You drank last night (\(alcohol.drinks(on: lastNight)) logged), so expect that pattern today." : ""
            out.append(Finding(text: effect + tonight, weight: drankLast ? 2.2 : 0.6))
        } else if drankLast {
            out.append(Finding(text: "You had \(alcohol.drinks(on: lastNight)) drinks last night.", weight: 1))
        }

        // What training does to your next morning.
        if let effect = trainingEffect(table), trainedOn(addDays(now.day, -1)) {
            out.append(Finding(text: effect, weight: 1.2))
        }

        if let top = checkins.likely.first {
            out.append(Finding(text: "The hub's check-in model puts \(top.label.lowercased()) at \(Int(top.probability * 100))% this morning, from your own past check-ins.", weight: 1.5))
        }
        return out.sorted { $0.weight > $1.weight }
    }

    private func trainedOn(_ day: String) -> Bool {
        fitness.activities.contains { a in a.start.map(localDay) == day && (a.duration ?? 0) >= 15 * 60 }
    }

    /// Mornings after drinking against mornings after a dry night: HRV and sleep.
    private func drinkEffect(_ table: [Morning]) -> String? {
        var wet: [Morning] = [], dry: [Morning] = []
        for m in table {
            let night = addDays(m.day, -1)
            if alcohol.drinks(on: night) > 0 || alcohol.amountUnknown(night) { wet.append(m) }
            else if alcohol.isAnswered(night) { dry.append(m) }
        }
        var parts: [String] = []
        if let a = Self.mean(wet.compactMap(\.hrv)), let b = Self.mean(dry.compactMap(\.hrv)), wet.compactMap(\.hrv).count >= 4, dry.compactMap(\.hrv).count >= 4 {
            let c = Self.pct(a, vs: b)
            if abs(c) >= 3 { parts.append("HRV runs \(abs(c))% \(c < 0 ? "lower" : "higher")") }
        }
        if let a = Self.mean(wet.compactMap(\.rhr)), let b = Self.mean(dry.compactMap(\.rhr)), wet.compactMap(\.rhr).count >= 4, dry.compactMap(\.rhr).count >= 4 {
            let d = a - b
            if abs(d) >= 1 { parts.append("resting heart rate \(Int(abs(d).rounded())) bpm \(d > 0 ? "higher" : "lower")") }
        }
        if let a = Self.mean(wet.compactMap(\.score)), let b = Self.mean(dry.compactMap(\.score)), wet.compactMap(\.score).count >= 4, dry.compactMap(\.score).count >= 4 {
            let d = a - b
            if abs(d) >= 2 { parts.append("sleep score \(Int(abs(d).rounded())) points \(d < 0 ? "lower" : "higher")") }
        }
        guard !parts.isEmpty else { return nil }
        return "In your data, mornings after drinking (\(wet.count) of them) show " + Self.list(parts) + " than mornings after a dry night (\(dry.count))."
    }

    /// Mornings after a training day against mornings after a rest day.
    private func trainingEffect(_ table: [Morning]) -> String? {
        var after: [Morning] = [], rest: [Morning] = []
        for m in table {
            if trainedOn(addDays(m.day, -1)) { after.append(m) } else { rest.append(m) }
        }
        var parts: [String] = []
        if let a = Self.mean(after.compactMap(\.hrv)), let b = Self.mean(rest.compactMap(\.hrv)), after.compactMap(\.hrv).count >= 4, rest.compactMap(\.hrv).count >= 4 {
            let c = Self.pct(a, vs: b)
            if abs(c) >= 3 { parts.append("HRV \(abs(c))% \(c < 0 ? "lower" : "higher")") }
        }
        if let a = Self.mean(after.compactMap(\.deep)), let b = Self.mean(rest.compactMap(\.deep)), after.compactMap(\.deep).count >= 4, rest.compactMap(\.deep).count >= 4 {
            let d = a - b
            if abs(d) >= 5 { parts.append("\(Int(abs(d).rounded())) minutes \(d > 0 ? "more" : "less") deep sleep") }
        }
        guard !parts.isEmpty else { return nil }
        return "After a training day you typically wake with " + Self.list(parts) + " than after a rest day (\(after.count) vs \(rest.count) mornings), and yesterday was a training day."
    }

    private static func list(_ parts: [String]) -> String {
        parts.count == 1 ? parts[0] : parts.dropLast().joined(separator: ", ") + " and " + parts.last!
    }

    // MARK: Night

    func night() -> [Finding] {
        var out: [Finding] = []
        let calendar = Calendar.current
        let now = Date.now.addingTimeInterval(-3 * 3600)
        let today = localDay(now)
        let past = fitness.days.filter { $0.day < today }.prefix(60)

        if let steps = fitness.days.first(where: { $0.day == today })?.steps, let b = Baseline(past.compactMap(\.steps).map(Double.init)) {
            let z = b.z(Double(steps))
            var line = "\(steps.formatted()) steps today against your daily average of \(Int(b.mean).formatted()), \(Self.sd(z))"
            if let r = Self.rank(b, Double(steps), noun: "days") { line += ", \(r)" }
            out.append(Finding(text: line + ".", weight: abs(z)))
        }

        let todays = fitness.activities.filter { $0.start.map { calendar.isDate($0, inSameDayAs: now) } ?? false }
        for a in todays {
            var line = "You did \(a.title.lowercased()) for \(FitnessFormat.duration(a.duration))"
            if let hr = a.avgHr { line += " at an average \(hr) bpm" }
            if let te = a.trainingEffect { line += String(format: ", training effect %.1f", te) }
            out.append(Finding(text: line + ".", weight: 1.5))
        }

        // This week's training against your usual week.
        let weekStart = calendar.dateInterval(of: .weekOfYear, for: now)?.start ?? now
        let thisWeek = Set(fitness.activities.compactMap { a -> String? in
            guard let s = a.start, s >= weekStart, (a.duration ?? 0) >= 15 * 60 else { return nil }
            return localDay(s)
        }).count
        let weeks = (1...8).compactMap { back -> Int? in
            guard let start = calendar.date(byAdding: .weekOfYear, value: -back, to: weekStart),
                  let end = calendar.date(byAdding: .day, value: 7, to: start) else { return nil }
            let days = Set(fitness.activities.compactMap { a -> String? in
                guard let s = a.start, s >= start, s < end, (a.duration ?? 0) >= 15 * 60 else { return nil }
                return localDay(s)
            })
            return days.count
        }
        if let usual = Self.mean(weeks.map(Double.init)), weeks.count >= 4 {
            let dayOfWeek = (calendar.dateComponents([.day], from: weekStart, to: now).day ?? 0) + 1
            let pace = usual * Double(dayOfWeek) / 7
            out.append(Finding(text: String(format: "%d training days so far this week; by day %d you usually have %.1f (%.1f a week over the last 8 weeks).", thisWeek, dayOfWeek, pace, usual),
                               weight: abs(Double(thisWeek) - pace) / 1.5))
        }

        let stress = fitness.series(.stress).filter { calendar.isDate($0.date, inSameDayAs: now) }.map(\.value).filter { $0 >= 0 }
        if stress.count >= 24, let average = Self.mean(stress.map(Double.init)) {
            let high = Double(stress.filter { $0 >= 60 }.count) / Double(stress.count) * 100
            out.append(Finding(text: String(format: "Stress averaged %.0f out of 100 today, with %.0f%% of readings in the high range.", average, high),
                               weight: average >= 40 || high >= 20 ? 1.5 : 0.4))
        }

        // Tonight: what your own nights say about bedtime and drinks.
        let table = mornings
        let bedtimes = table.compactMap(\.bedtime)
        if bedtimes.count >= 14 {
            let cut = bedtimes.sorted()[bedtimes.count / 2]
            let early = table.filter { ($0.bedtime ?? .infinity) <= cut }, late = table.filter { ($0.bedtime ?? -1) > cut }
            if let a = Self.mean(early.compactMap(\.score)), let b = Self.mean(late.compactMap(\.score)), a - b >= 3 {
                out.append(Finding(text: "Nights you're asleep by \(Self.clock(cut)) score \(Int((a - b).rounded())) points higher on average than later ones (\(early.count) vs \(late.count) nights).", weight: 1.3))
            } else if let a = Self.mean(early.compactMap(\.sleep)), let b = Self.mean(late.compactMap(\.sleep)), a - b >= 0.33 {
                out.append(Finding(text: "Nights you're asleep by \(Self.clock(cut)) give you \(Self.hm(a - b)) more sleep on average than later ones.", weight: 1.1))
            }
        }
        let tonight = alcohol.tonight
        let drinks = alcohol.drinks(on: tonight)
        if drinks > 0 {
            if let effect = drinkEffect(table) {
                out.append(Finding(text: "You've had \(drinks) drink\(drinks == 1 ? "" : "s") tonight. " + effect, weight: 2.2))
            } else {
                out.append(Finding(text: "You've had \(drinks) drink\(drinks == 1 ? "" : "s") tonight.", weight: 1.2))
            }
        }
        if !todays.isEmpty, let effect = trainingEffect(table) {
            out.append(Finding(text: effect.replacingOccurrences(of: ", and yesterday was a training day.", with: ", so expect that tomorrow."), weight: 1))
        }

        // Time at work against your other workdays.
        let workToday = places.seconds(at: .work, on: now)
        if workToday >= 1800 {
            let others = (1...28).compactMap { back -> Double? in
                guard let d = calendar.date(byAdding: .day, value: -back, to: now) else { return nil }
                let s = places.seconds(at: .work, on: d)
                return s >= 1800 ? s / 3600 : nil
            }
            var line = "You spent \(Self.hm(workToday / 3600)) at work"
            if let usual = Self.mean(others), others.count >= 3 { line += " against your usual \(Self.hm(usual))" }
            out.append(Finding(text: line + ".", weight: 0.8))
        }
        if let feeling = checkins.entry(for: today).flatMap(Feeling.of) {
            out.append(Finding(text: "You checked in as \(Feeling.label(feeling).lowercased()) today.", weight: 0.9))
        }
        return out.sorted { $0.weight > $1.weight }
    }
}
