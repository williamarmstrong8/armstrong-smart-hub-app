import Foundation
import Observation

/// The Fitness console's data from the hub: days, activities, sleep and heart rate.
@MainActor
@Observable
final class FitnessStore {
    private(set) var snapshot: FitnessSnapshot? {
        didSet { seriesCache = [:] }
    }
    private(set) var error: String?
    /// When the snapshot came from the hub; older than this session when the
    /// hub can't be reached and the copy on the phone is showing.
    private(set) var updatedAt: Date?
    private var details: [String: FitnessActivityDetail] = [:]
    /// The watch's live readings on the phone: today's charts come from here until the hub has them.
    let live = LiveStore.shared

    var loaded: Bool { snapshot != nil }
    /// Showing the copy on the phone because the hub didn't answer.
    var isOffline: Bool { loaded && error != nil }

    /// The last snapshot is kept on the phone, so the page works with no hub in reach.
    private static let cacheURL = URL.applicationSupportDirectory.appending(path: "Fitness/snapshot.json")

    init() {
        if let data = try? Data(contentsOf: Self.cacheURL), let cached = try? APIClient.decoder.decode(FitnessSnapshot.self, from: data) {
            snapshot = cached
            updatedAt = (try? Self.cacheURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        }
    }

    func load(api: APIClient) async {
        do {
            let data = try await api.data(api.request("/api/mobile/fitness"))
            snapshot = try APIClient.decoder.decode(FitnessSnapshot.self, from: data)
            updatedAt = .now
            error = nil
            WidgetSync.fitness(self)
            try? FileManager.default.createDirectory(at: Self.cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: Self.cacheURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch is CancellationError {
        } catch {
            #if DEBUG
            print("FITNESS load failed:", error)
            #endif
            self.error = error.localizedDescription
        }
    }

    // MARK: Hub and phone together

    /// A day-long chart reading.
    struct Reading { var date: Date; var value: Int }

    /// The last 24 hours: the hub's readings, with the phone's filling every
    /// 5 minutes the hub has nothing for. The hub can have tonight (streamed
    /// live) but not yet the day before (that comes in the watch's midnight
    /// file), so the phone fills gaps anywhere, not only after the hub's last
    /// reading. Stress and Body Battery go in 5-minute averages like the hub's.
    func series(_ kind: LiveStore.Kind) -> [Reading] {
        // Views ask for this on every redraw, and it parses thousands of hub
        // timestamps, so it's worked out once per snapshot, new live reading
        // and 5 minutes. Reading `snapshot` and `revision` keeps those views
        // redrawing when either changes.
        _ = snapshot
        let key = "\(live.revision)|\(Int(Date.now.timeIntervalSince1970 / 300))"
        if let cached = seriesCache[kind], cached.key == key { return cached.readings }
        let readings = buildSeries(kind)
        seriesCache[kind] = (key, readings)
        return readings
    }

    @ObservationIgnored private var seriesCache: [LiveStore.Kind: (key: String, readings: [Reading])] = [:]

    private func buildSeries(_ kind: LiveStore.Kind) -> [Reading] {
        let since = Date.now.addingTimeInterval(-86400)
        let bucket = { (date: Date) in Int(date.timeIntervalSince1970 / 300) }
        let hub = hubSeries(kind).filter { $0.date >= since }
        let covered = Set(hub.map { bucket($0.date) })
        let phone = live.series(kind, since: since).filter { !covered.contains(bucket($0.at)) }
        if kind == .bodyBattery { return (hub + heldBodyBattery(since: since, skip: covered)).sorted { $0.date < $1.date } }
        let local: [Reading] = kind == .heartRate
            ? phone.map { Reading(date: $0.at, value: $0.value) }
            : Dictionary(grouping: phone) { bucket($0.at) }
                .map { Reading(date: Date(timeIntervalSince1970: Double($0.key) * 300), value: $0.value.map(\.value).reduce(0, +) / $0.value.count) }
        return (hub + local).sorted { $0.date < $1.date }
    }

    /// The watch sends Body Battery live only when it changes, so between
    /// readings the level holds. Every 5 minutes the phone was hearing the
    /// watch (it has heart rate then) gets the newest level so far, so the line
    /// doesn't break between changes; while the link was down it still breaks.
    private func heldBodyBattery(since: Date, skip covered: Set<Int>) -> [Reading] {
        let levels = live.series(.bodyBattery, since: since.addingTimeInterval(-6 * 3600))
        let heard = Set(live.series(.heartRate, since: since).map { Int($0.at.timeIntervalSince1970 / 300) })
        var out: [Reading] = []
        var next = 0
        var level: Int?
        for slot in heard.subtracting(covered).sorted() {
            let end = Date(timeIntervalSince1970: Double(slot + 1) * 300)
            while next < levels.count, levels[next].at < end {
                level = levels[next].value
                next += 1
            }
            if let level { out.append(Reading(date: Date(timeIntervalSince1970: Double(slot) * 300), value: level)) }
        }
        return out
    }

    private func hubSeries(_ kind: LiveStore.Kind) -> [Reading] {
        switch kind {
        case .heartRate:
            return (snapshot?.heartRate ?? []).compactMap { p in p.date.map { Reading(date: $0, value: p.bpm) } }
        case .stress:
            return (snapshot?.metrics?.stress?.series ?? []).compactMap { p in
                guard let date = ISO.parse(p.at), let value = p.value else { return nil }
                return Reading(date: date, value: value)
            }
        case .bodyBattery:
            // The watch's own series when it has one (longer, and the real model); the hub's otherwise.
            let watch = (snapshot?.insights?.stress.bodyBattery?.series ?? []).compactMap { p in ISO.parse(p.at).map { Reading(date: $0, value: p.value) } }
            let hub = (snapshot?.metrics?.bodyBattery?.series ?? []).compactMap { p in ISO.parse(p.at).map { Reading(date: $0, value: p.value) } }
            return !watch.isEmpty && watch.count >= hub.count ? watch : hub
        }
    }

    /// Whether the newest Body Battery reading is the watch's (live, or its all-day file).
    var bodyBatteryFromWatch: Bool {
        if live.latest(.bodyBattery, maxAge: 86400) != nil { return true }
        let watch = snapshot?.insights?.stress.bodyBattery?.series.count ?? 0
        return watch > 0 && watch >= (snapshot?.metrics?.bodyBattery?.series.count ?? 0)
    }

    /// Where the day-long charts run to: the hub's newest all-day reading or the phone's, whichever is later.
    var allDayThrough: Date? {
        let hub = (snapshot?.allDayThrough).flatMap(ISO.parse)
        let phone = LiveStore.Kind.allCases.compactMap { live.latest($0, maxAge: 86400)?.at }.max()
        return [hub, phone].compactMap { $0 }.max()
    }

    /// The watch's stress and Body Battery right now, when it has sent them in the last half hour
    /// (it sends a level when it changes, so a steady one can be a while old).
    var currentStress: Int? { live.latest(.stress, maxAge: 1800)?.value }
    var currentBodyBattery: Int? { live.latest(.bodyBattery, maxAge: 1800)?.value }

    /// An activity's detail if it has been loaded already.
    func cachedDetail(_ id: String) -> FitnessActivityDetail? { details[id] }

    func detail(_ id: String, api: APIClient) async -> FitnessActivityDetail? {
        if let cached = details[id] { return cached }
        let detail: FitnessActivityDetail? = try? await api.get("/api/mobile/fitness/activity?id=\(id)")
        details[id] = detail
        return detail
    }

    var days: [FitnessDay] { snapshot?.days ?? [] }
    var activities: [FitnessActivity] { snapshot?.activities ?? [] }
    var nights: [SleepNight] { snapshot?.sleep ?? [] }
    var today: FitnessDay? { days.first { $0.day == localDay() } }
    var lastNight: SleepNight? { nights.first }

    /// The newest resting heart rate the hub has.
    var restingHr: Int? { days.lazy.compactMap(\.restingHr).first }

    /// Activities in the last 7 days.
    var thisWeek: [FitnessActivity] {
        let cutoff = Date.now.addingTimeInterval(-7 * 86400)
        return activities.filter { ($0.start ?? .distantPast) > cutoff }
    }
}

#if DEBUG
extension FitnessStore {
    /// TEMPORARY: lets FitnessRenderDebug load a snapshot from a file.
    func debugSet(_ snapshot: FitnessSnapshot) { self.snapshot = snapshot }
    func debugSetDetail(_ detail: FitnessActivityDetail) { details[detail.activity.id] = detail }
}
#endif
