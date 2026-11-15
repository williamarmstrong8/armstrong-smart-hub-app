import Foundation
import Observation

// MARK: Models

enum DrinkKind: String, Codable, CaseIterable, Identifiable {
    case beer, wine, liquor

    var id: String { rawValue }
    var title: String {
        switch self {
        case .beer: "Beer"
        case .wine: "Wine"
        case .liquor: "Liquor"
        }
    }
    var longTitle: String { self == .liquor ? "Liquor or cocktail" : title }
    var emoji: String {
        switch self {
        case .beer: "🍺"
        case .wine: "🍷"
        case .liquor: "🥃"
        }
    }
    /// What one standard drink of it is.
    var serving: String {
        switch self {
        case .beer: "12 oz can or bottle"
        case .wine: "5 oz glass"
        case .liquor: "1.5 oz shot or a cocktail"
        }
    }
}

/// When in the day the drinking happened. "All day" is its own answer: a day
/// of drinking hits sleep differently than two at dinner.
enum DrinkTime: String, Codable, CaseIterable, Identifiable {
    case morning, afternoon, evening, lateNight, allDay

    var id: String { rawValue }
    var title: String {
        switch self {
        case .morning: "Morning"
        case .afternoon: "Afternoon"
        case .evening: "Evening"
        case .lateNight: "Late night"
        case .allDay: "All day"
        }
    }
    var symbol: String {
        switch self {
        case .morning: "sunrise"
        case .afternoon: "sun.max"
        case .evening: "sunset"
        case .lateNight: "moon.stars"
        case .allDay: "clock"
        }
    }
    /// Where a drink logged for this slot sits on the night's own day (late night is 11 pm, still that night).
    var hour: Int {
        switch self {
        case .morning: 10
        case .afternoon: 14
        case .evening: 19
        case .lateNight: 23
        case .allDay: 12
        }
    }

    /// The slot a clock time falls in: 5 to noon, noon to 5, 5 to 10, then late night until 5 am.
    static func of(_ date: Date) -> DrinkTime {
        switch Calendar.current.component(.hour, from: date) {
        case 5..<12: .morning
        case 12..<17: .afternoon
        case 17..<22: .evening
        default: .lateNight
        }
    }
}

/// Some drinks of one kind at one time. A count is standard drinks (a 12 oz beer, 5 oz of wine, a 1.5 oz shot).
struct DrinkEntry: Codable, Identifiable, Equatable {
    var id = UUID()
    /// The moment it was logged for. It decides the night: see AlcoholStore.night(of:).
    var date: Date
    var kind: DrinkKind
    var count: Int
    /// Missing from entries logged before the time of day was asked; those go by the clock.
    var time: DrinkTime?
    /// When it was logged, to tell a live log from one filled in the next day.
    var loggedAt: Date?

    var slot: DrinkTime { time ?? .of(date) }
}

// MARK: Store

/// Drinks, logged on the phone next to the check-in data. A "night" is named for
/// the evening it started: a drink at 1 am belongs to the night before, so it
/// lines up with the sleep and recovery numbers of the morning after.
///
/// The phone's log is the one that counts; every change is also queued for the
/// hub (/api/mobile/fitness/drinks) and sent when it answers, so logging works
/// with no hub in reach and the hub can line drinks up with everything else.
@MainActor
@Observable
final class AlcoholStore {
    static let shared = AlcoholStore()

    /// In the order they were logged.
    private(set) var entries: [DrinkEntry] = []
    /// Nights answered "No drinks".
    private(set) var dryNights: Set<String> = []
    /// Nights answered "Drank", with no idea how much.
    private(set) var drankNights: Set<String> = []
    /// The morning Body Battery by day, which the hub only keeps for the last day: saved as it passes.
    private(set) var battery: [String: Int] = [:]

    private struct Saved: Codable {
        var entries: [DrinkEntry]
        var dry: [String]
        var battery: [String: Int]
        /// Missing from files saved before "Drank" was an answer.
        var drank: [String]?
    }

    private static let url = URL.applicationSupportDirectory.appending(path: "Fitness/alcohol.json")

    init() {
        if !Demo.isOn, let data = try? Data(contentsOf: Self.url), let saved = try? JSONDecoder().decode(Saved.self, from: data) {
            entries = saved.entries
            dryNights = Set(saved.dry)
            drankNights = Set(saved.drank ?? [])
            battery = saved.battery
        }
        if !Demo.isOn, let data = try? Data(contentsOf: Self.queueURL), let saved = try? JSONDecoder().decode(Queue.self, from: data) {
            pending = saved.pending
            // A backfill from before "Drank" nights existed didn't carry them: send it again.
            backfilled = saved.backfilled && (saved.version ?? 1) >= Self.backfillVersion
        }
    }

    private func persist() {
        if Demo.isOn { return }
        try? FileManager.default.createDirectory(at: Self.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let saved = Saved(entries: entries, dry: dryNights.sorted(), battery: battery, drank: drankNights.sorted())
        if let data = try? JSONEncoder().encode(saved) { try? data.write(to: Self.url, options: .atomic) }
    }

    // MARK: Nights

    /// The night a moment belongs to: before 5 am it is still the evening before.
    static func night(of date: Date) -> String { localDay(date.addingTimeInterval(-5 * 3600)) }

    /// Where drinks added to a past night start: 9 pm that evening.
    static func evening(of night: String) -> Date {
        let day = MorningCheckin.date(night) ?? .now
        return Calendar.current.date(bySettingHour: 21, minute: 0, second: 0, of: day) ?? day
    }

    static func isWeekend(_ night: String) -> Bool {
        guard let date = DayFormat.parse(night) else { return false }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        let weekday = calendar.component(.weekday, from: date)
        return weekday == 6 || weekday == 7
    }

    var tonight: String { Self.night(of: .now) }

    func entries(on night: String) -> [DrinkEntry] {
        entries.filter { Self.night(of: $0.date) == night }
    }

    func drinks(on night: String) -> Int { entries(on: night).reduce(0) { $0 + $1.count } }

    func isAnswered(_ night: String) -> Bool { dryNights.contains(night) || drankNights.contains(night) || drinks(on: night) > 0 }

    /// Drank that night but didn't say how much.
    func amountUnknown(_ night: String) -> Bool { drankNights.contains(night) && drinks(on: night) == 0 }

    /// "2 Beer · 1 Wine", or nil with nothing logged.
    func summary(_ night: String) -> String? {
        let parts = DrinkKind.allCases.compactMap { kind -> String? in
            let n = entries(on: night).filter { $0.kind == kind }.reduce(0) { $0 + $1.count }
            return n > 0 ? "\(n) \(kind.title)" : nil
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// "2 Beer · 1 Wine · Evening", or "Drank, amount unknown".
    func detail(_ night: String) -> String? {
        guard let summary = summary(night) else { return amountUnknown(night) ? "Drank, amount unknown" : nil }
        let times = times(night).map(\.title).joined(separator: ", ")
        return times.isEmpty ? summary : "\(summary) · \(times)"
    }

    /// Nights with something logged, newest first.
    var loggedNights: [String] {
        Set(entries.map { Self.night(of: $0.date) }).union(dryNights).union(drankNights).sorted(by: >)
    }

    /// The first night he used the log; nights before it say nothing about dry ones.
    var trackingSince: String? { loggedNights.last }

    /// The time slots of a night, in order of the day: "Evening, Late night", or "All day".
    func times(_ night: String) -> [DrinkTime] {
        let slots = Set(entries(on: night).map(\.slot))
        if slots.contains(.allDay) { return [.allDay] }
        return DrinkTime.allCases.filter(slots.contains)
    }

    /// How a drinking night is filed for the timing comparison: all day, else the latest slot.
    func timing(_ night: String) -> DrinkTime? { times(night).last }

    // MARK: Logging

    /// The moment to file drinks under: now, when it's tonight and now is in that slot; else the slot's hour on the night's day.
    static func moment(night: String, time: DrinkTime, now: Date = .now) -> Date {
        if night == Self.night(of: now), time != .allDay, DrinkTime.of(now) == time { return now }
        let day = MorningCheckin.date(night) ?? now
        return Calendar.current.date(bySettingHour: time.hour, minute: 0, second: 0, of: day) ?? day
    }

    /// Logs a round: any number of each kind, for one night and time of day, as one entry per kind.
    func log(_ counts: [DrinkKind: Int], night: String, time: DrinkTime) {
        let date = Self.moment(night: night, time: time)
        let now = Date.now
        for kind in DrinkKind.allCases {
            guard let n = counts[kind], n > 0 else { continue }
            let entry = DrinkEntry(date: date, kind: kind, count: n, time: time, loggedAt: now)
            entries.append(entry)
            enqueue(.put(entry))
        }
        if entries(on: night).isEmpty { return }
        dryNights.remove(night)
        drankNights.remove(night)
        persist()
        sync()
    }

    func add(_ kind: DrinkKind, count: Int = 1, at date: Date = .now) {
        let entry = DrinkEntry(date: date, kind: kind, count: max(1, count), time: .of(date), loggedAt: .now)
        entries.append(entry)
        enqueue(.put(entry))
        dryNights.remove(Self.night(of: date))
        persist()
        sync()
    }

    func update(_ id: UUID, kind: DrinkKind, count: Int, date: Date) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].kind = kind
        entries[index].count = max(1, count)
        entries[index].date = date
        enqueue(.put(entries[index]))
        dryNights.remove(Self.night(of: date))
        persist()
        sync()
    }

    func remove(_ id: UUID) {
        entries.removeAll { $0.id == id }
        enqueue(.delete(id))
        persist()
        sync()
    }

    /// Takes back the newest entry of a night.
    func undoLast(on night: String) {
        guard let last = entries.last(where: { Self.night(of: $0.date) == night }) else { return }
        remove(last.id)
    }

    func markDry(_ night: String) {
        guard drinks(on: night) == 0 else { return }
        dryNights.insert(night)
        drankNights.remove(night)
        enqueue(.dry(night: night, dry: true))
        persist()
        sync()
    }

    /// "Drank that night", amount not known. Logging drinks for the night later replaces it.
    func markDrank(_ night: String) {
        guard drinks(on: night) == 0 else { return }
        drankNights.insert(night)
        dryNights.remove(night)
        enqueue(.drank(night: night, drank: true))
        persist()
        sync()
    }

    func clearDrank(_ night: String) {
        drankNights.remove(night)
        enqueue(.drank(night: night, drank: false))
        persist()
        sync()
    }

    func clearDry(_ night: String) {
        dryNights.remove(night)
        enqueue(.dry(night: night, dry: false))
        persist()
        sync()
    }

    // MARK: Sending to the hub

    /// Changes the hub hasn't confirmed yet, oldest first.
    private(set) var pending: [Pending] = []
    /// Whether everything logged before syncing existed has been sent once.
    private var backfilled = false
    /// Bumped when the backfill starts carrying more (2: "Drank" nights).
    private static let backfillVersion = 2
    /// Set while signed in; a new session sends what's waiting.
    @ObservationIgnored var api: APIClient? {
        didSet { if api != nil { sync() } }
    }

    enum Pending: Codable, Equatable {
        case put(DrinkEntry)
        case delete(UUID)
        case dry(night: String, dry: Bool)
        /// "Drank, not sure how much", or taking that back.
        case drank(night: String, drank: Bool)
    }

    private struct Queue: Codable {
        var pending: [Pending]
        var backfilled: Bool
        /// Missing from queues saved by the first version of the backfill.
        var version: Int?
    }

    private static let queueURL = URL.applicationSupportDirectory.appending(path: "Fitness/alcohol-pending.json")

    /// Queues a change, dropping older ones it makes moot (an earlier edit of the same drink, an earlier answer for the same night).
    private func enqueue(_ item: Pending) {
        if Demo.isOn { return }
        switch item {
        case let .put(e):
            pending.removeAll { if case let .put(old) = $0 { old.id == e.id } else { false } }
        case let .delete(id):
            pending.removeAll { if case let .put(old) = $0 { old.id == id } else { false } }
        case let .dry(night, _), let .drank(night, _):
            // One answer per night: a later dry or drank answer replaces an earlier one.
            pending.removeAll {
                switch $0 {
                case let .dry(old, _), let .drank(old, _): old == night
                default: false
                }
            }
        }
        pending.append(item)
        saveQueue()
    }

    private func saveQueue() {
        try? FileManager.default.createDirectory(at: Self.queueURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(Queue(pending: pending, backfilled: backfilled, version: Self.backfillVersion)) {
            try? data.write(to: Self.queueURL, options: .atomic)
        }
    }

    /// Sends what's waiting in the background.
    func sync() {
        guard api != nil, !Demo.isOn else { return }
        Task { await flush() }
    }

    /// A drink as the hub keeps it: the night worked out here, where the time zone is known.
    private struct Wire: Encodable {
        var id: String
        var night: String
        var at: String
        var kind: String
        var count: Int
        var time: String?
        var loggedAt: String?

        init(_ e: DrinkEntry) {
            id = e.id.uuidString.lowercased()
            night = AlcoholStore.night(of: e.date)
            at = AlcoholStore.iso.string(from: e.date)
            kind = e.kind.rawValue
            count = e.count
            time = e.time?.rawValue
            loggedAt = e.loggedAt.map(AlcoholStore.iso.string(from:))
        }
    }

    nonisolated(unsafe) private static let iso = ISO8601DateFormatter()

    /// A refusal (400) arrives as `{ error }`: retrying won't fix it, so the item is dropped.
    private struct Reply: Decodable { var error: String? }
    private struct Refused: Error {}

    private func send(_ api: APIClient, _ request: URLRequest) async throws {
        let reply: Reply = try await api.send(request)
        if reply.error != nil { throw Refused() }
    }

    private var flushing = false

    /// Sends the one-time backfill, then each change in order, stopping at the first
    /// one the hub can't take right now so the order holds.
    func flush() async {
        guard let api, !flushing, !Demo.isOn else { return }
        flushing = true
        defer { flushing = false }
        if !backfilled {
            struct Batch: Encodable { var entries: [Wire]; var dry: [String]; var drank: [String] }
            do {
                try await send(api, api.request("/api/mobile/fitness/drinks", method: "PUT",
                                                body: Batch(entries: entries.map(Wire.init), dry: dryNights.sorted(), drank: drankNights.sorted())))
            } catch is Refused {
            } catch {
                return
            }
            backfilled = true
            saveQueue()
        }
        while let item = pending.first {
            do {
                switch item {
                case let .put(entry):
                    struct Body: Encodable { var drink: Wire }
                    try await send(api, api.request("/api/mobile/fitness/drinks", method: "PUT", body: Body(drink: Wire(entry))))
                case let .delete(id):
                    try await send(api, api.request("/api/mobile/fitness/drinks?id=\(id.uuidString.lowercased())", method: "DELETE"))
                case let .dry(night, dry):
                    struct Dry: Encodable { var night: String; var dry: Bool }
                    struct Body: Encodable { var dry: Dry }
                    try await send(api, api.request("/api/mobile/fitness/drinks", method: "PUT", body: Body(dry: Dry(night: night, dry: dry))))
                case let .drank(night, drank):
                    struct Drank: Encodable { var night: String; var drank: Bool }
                    struct Body: Encodable { var drank: Drank }
                    try await send(api, api.request("/api/mobile/fitness/drinks", method: "PUT", body: Body(drank: Drank(night: night, drank: drank))))
                }
            } catch is Refused {
            } catch {
                return
            }
            pending.removeFirst()
            saveQueue()
        }
    }

    // MARK: Body Battery

    /// Keeps each morning's Body Battery peak (4 am to noon) from the readings the page has now.
    /// A day only counts when the readings reach back before 9 am, so a window
    /// that starts mid-morning can't save a low reading for the day.
    func recordBattery(_ readings: [FitnessStore.Reading]) {
        let calendar = Calendar.current
        var days: [String: (peak: Int, early: Bool)] = [:]
        for r in readings {
            let hour = calendar.component(.hour, from: r.date)
            guard hour >= 4, hour < 12 else { continue }
            let key = localDay(r.date)
            let old = days[key] ?? (0, false)
            days[key] = (max(old.peak, r.value), old.early || hour < 9)
        }
        var changed = false
        for (day, found) in days where found.early && found.peak > (battery[day] ?? 0) {
            battery[day] = found.peak
            changed = true
        }
        if changed { persist() }
    }

    // MARK: Prompts

    /// The night to ask about: on Friday, Saturday and Sunday from 5 am, the night
    /// before (Thursday, Friday, Saturday), until it's answered.
    func promptNight(now: Date = .now) -> String? {
        let calendar = Calendar.current
        guard calendar.component(.hour, from: now) >= 5 else { return nil }
        let weekday = calendar.component(.weekday, from: now)
        guard weekday == 6 || weekday == 7 || weekday == 1 else { return nil }
        let night = addDays(localDay(now), -1)
        return isAnswered(night) ? nil : night
    }
}

// MARK: Insights

/// The next-day numbers alcohol is compared against.
enum AlcoholMetric: CaseIterable, Identifiable {
    case sleep, hrv, restingHr, battery, readiness

    var id: Self { self }
    var title: String {
        switch self {
        case .sleep: "Sleep score"
        case .hrv: "HRV"
        case .restingHr: "Resting heart rate"
        case .battery: "Body Battery"
        case .readiness: "Readiness"
        }
    }
    var unit: String {
        switch self {
        case .hrv: " ms"
        case .restingHr: " bpm"
        default: ""
        }
    }
    /// Lower resting heart rate is the better one.
    var higherIsBetter: Bool { self != .restingHr }

    func format(_ value: Double) -> String { "\(Int(value.rounded()))\(unit)" }
}

/// Drinks per night against what the next morning looked like.
@MainActor
struct AlcoholInsights {
    struct Bucket: Identifiable {
        var label: String
        var average: Double?
        var nights: Int
        var id: String { label }
    }

    static let labels = ["None", "1–2", "3+"]

    private let store: AlcoholStore
    private let values: [AlcoholMetric: [String: Double]]
    private let since: String?

    init(store: AlcoholStore, fitness: FitnessStore) {
        self.store = store
        since = store.trackingSince
        var values: [AlcoholMetric: [String: Double]] = [:]
        func put(_ metric: AlcoholMetric, _ day: String, _ value: Double) {
            if values[metric]?[day] == nil { values[metric, default: [:]][day] = value }
        }
        for n in fitness.nights {
            if let end = n.endDate, let score = n.score { put(.sleep, localDay(end), Double(score)) }
        }
        for n in fitness.snapshot?.hrv ?? [] {
            if let v = n.lastNightAverage { put(.hrv, n.day, v) }
        }
        for d in fitness.days {
            if let v = d.restingHr { put(.restingHr, d.day, Double(v)) }
        }
        let readiness = fitness.snapshot?.watch?.readiness
        for p in readiness?.history ?? [] {
            if let date = p.date { put(.readiness, localDay(date), p.value) }
        }
        if let r = readiness, let date = ISO.parse(r.at) { put(.readiness, localDay(date), Double(r.score)) }
        for (day, v) in store.battery { put(.battery, day, Double(v)) }
        self.values = values
    }

    /// Average of a metric on mornings after none, 1–2 and 3+ drinks. Only mornings from the first logged night on count; nights without a log count as none.
    func buckets(_ metric: AlcoholMetric) -> [Bucket] {
        var sums = [Double](repeating: 0, count: 3)
        var counts = [Int](repeating: 0, count: 3)
        for (day, value) in values[metric] ?? [:] {
            let night = addDays(day, -1)
            guard let since, night >= since, !store.amountUnknown(night) else { continue }
            let n = store.drinks(on: night)
            let index = n == 0 ? 0 : n <= 2 ? 1 : 2
            sums[index] += value
            counts[index] += 1
        }
        return Self.labels.indices.map { Bucket(label: Self.labels[$0], average: counts[$0] > 0 ? sums[$0] / Double(counts[$0]) : nil, nights: counts[$0]) }
    }

    static let timingLabels = ["None", "Daytime", "Evening", "Late", "All day"]

    /// Average of a metric on mornings after no drinks, and after drinking that ran latest in the daytime, the evening, late at night, or all day.
    func timing(_ metric: AlcoholMetric) -> [Bucket] {
        var sums = [Double](repeating: 0, count: Self.timingLabels.count)
        var counts = [Int](repeating: 0, count: Self.timingLabels.count)
        for (day, value) in values[metric] ?? [:] {
            let night = addDays(day, -1)
            guard let since, night >= since, !store.amountUnknown(night) else { continue }
            let index: Int = switch store.timing(night) {
            case nil: 0
            case .morning, .afternoon: 1
            case .evening: 2
            case .lateNight: 3
            case .allDay: 4
            }
            sums[index] += value
            counts[index] += 1
        }
        return Self.timingLabels.indices.map { Bucket(label: Self.timingLabels[$0], average: counts[$0] > 0 ? sums[$0] / Double(counts[$0]) : nil, nights: counts[$0]) }
    }

    /// The heaviest bucket with data against the none bucket.
    func change(_ metric: AlcoholMetric) -> (label: String, delta: Double)? {
        let b = buckets(metric)
        guard let base = b[0].average, let heavy = b.dropFirst().last(where: { $0.average != nil }), let value = heavy.average else { return nil }
        return (heavy.label, value - base)
    }
}
