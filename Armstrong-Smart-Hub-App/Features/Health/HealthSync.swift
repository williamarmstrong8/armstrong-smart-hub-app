import Foundation
import HealthKit
import Observation

/// Writes what the watch and the app know into Apple Health, so other apps
/// (and Health's own trends) see it:
/// - Garmin activities as workouts, with their energy and distance;
/// - sleep nights as Core / Deep / REM / Awake stages;
/// - overnight HRV and each finished day's resting heart rate;
/// - drinks from the alcohol log, as Health's "Alcoholic beverages";
/// - each check-in as a daily mood (State of Mind).
///
/// Steps aren't written: the iPhone already counts them, and two sources
/// would only make Health pick one.
///
/// Every sample carries a sync identifier, so writing it again replaces it
/// instead of adding a copy, and the phone remembers what it has written so
/// a sync only sends what's new or changed. Off until turned on in Account.
@MainActor
@Observable
final class HealthSync {
    static let shared = HealthSync()

    /// Turned on in Account; asking Health for access happens then.
    private(set) var enabled: Bool
    private(set) var lastSync: Date?
    private(set) var lastError: String?

    @ObservationIgnored private let store = HKHealthStore()
    /// Sync identifier → fingerprint of what was written under it.
    @ObservationIgnored private var written: [String: String] = [:]
    @ObservationIgnored private var syncing = false

    private static let enabledKey = "health.enabled"
    private static let url = URL.applicationSupportDirectory.appending(path: "Health/written.json")
    private static let source = "ArmstrongHub"

    var available: Bool { HKHealthStore.isHealthDataAvailable() }

    init() {
        enabled = UserDefaults.standard.bool(forKey: Self.enabledKey) && !Demo.isOn
        if let data = try? Data(contentsOf: Self.url), let saved = try? JSONDecoder().decode([String: String].self, from: data) {
            written = saved
        }
    }

    // MARK: Access

    private static var shareTypes: Set<HKSampleType> {
        var types: Set<HKSampleType> = [
            HKObjectType.workoutType(),
            HKCategoryType(.sleepAnalysis),
            HKQuantityType(.heartRateVariabilitySDNN),
            HKQuantityType(.restingHeartRate),
            HKQuantityType(.numberOfAlcoholicBeverages),
            HKQuantityType(.activeEnergyBurned),
            HKQuantityType(.distanceWalkingRunning),
            HKQuantityType(.distanceCycling),
            HKQuantityType(.distanceSwimming),
        ]
        types.insert(HKSampleType.stateOfMindType())
        return types
    }

    /// Asks Health for write access and turns syncing on (or off).
    func setEnabled(_ on: Bool) async {
        guard available, !Demo.isOn else { return }
        if on {
            do {
                try await store.requestAuthorization(toShare: Self.shareTypes, read: [])
            } catch {
                lastError = error.localizedDescription
                return
            }
        }
        enabled = on
        UserDefaults.standard.set(on, forKey: Self.enabledKey)
    }

    // MARK: Sync

    /// Writes everything new in the Fitness snapshot and the alcohol log.
    func sync(_ snapshot: FitnessSnapshot?, drinks: [DrinkEntry]) async {
        guard enabled, available, !syncing else { return }
        syncing = true
        defer { syncing = false }
        var samples: [(id: String, fingerprint: String, sample: HKSample)] = []
        if let snapshot {
            samples += sleep(snapshot.sleep)
            samples += hrv(snapshot)
            samples += restingHeartRate(snapshot.days)
        }
        samples += alcohol(drinks)
        let fresh = samples.filter { written[$0.id] != $0.fingerprint }
        do {
            if !fresh.isEmpty {
                try await store.save(fresh.map { $0.sample })
                for s in fresh { written[s.id] = s.fingerprint }
            }
            try await removeDeletedDrinks(keeping: Set(drinks.map { Self.drinkID($0.id) }))
            if let snapshot { try await workouts(snapshot.activities) }
            persist()
            lastSync = .now
            lastError = nil
        } catch {
            persist()
            lastError = error.localizedDescription
        }
    }

    /// A check-in as the day's mood, replacing the one written for that day before.
    func saveMood(_ checkin: Checkin) async {
        guard enabled, available else { return }
        guard let (valence, labels) = Self.mood(checkin), let date = Self.date(checkin.day)?.addingTimeInterval(12 * 3600) else { return }
        let id = "checkin.mood.\(checkin.day)"
        let fingerprint = "\(valence)|\(labels.map(\.rawValue))"
        guard written[id] != fingerprint else { return }
        let sample = HKStateOfMind(date: min(date, .now), kind: .dailyMood, valence: valence, labels: labels,
                                   associations: [.health, .fitness], metadata: metadata(id))
        do {
            try await store.save(sample)
            written[id] = fingerprint
            persist()
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Feeling tags (and the 1–5 mood, when given) as a valence from -1 to 1, with Health's labels.
    private static func mood(_ c: Checkin) -> (Double, [HKStateOfMind.Label])? {
        let tags = Set(c.tags)
        var valence: Double?
        var labels: [HKStateOfMind.Label] = []
        if tags.contains("energized") { valence = 0.7; labels.append(.excited) }
        if tags.contains("fine") { valence = valence ?? 0.35; labels.append(.content) }
        if tags.contains("stressed") { valence = min(valence ?? 0, -0.4); labels.append(.stressed) }
        if tags.contains("run_down") { valence = min(valence ?? 0, -0.35); labels.append(.drained) }
        if tags.contains("hungover") { valence = min(valence ?? 0, -0.45); labels.append(.drained) }
        if tags.contains("sick") { valence = min(valence ?? 0, -0.55); labels.append(.drained) }
        if let mood = c.mood, (1...5).contains(mood) { valence = Double(mood - 3) / 2 }
        guard let valence else { return nil }
        var seen = Set<HKStateOfMind.Label>()
        return (max(-1, min(1, valence)), labels.filter { seen.insert($0).inserted })
    }

    // MARK: Samples

    private func metadata(_ id: String, _ extra: [String: Any] = [:]) -> [String: Any] {
        // The version only has to grow for a rewrite to replace the old sample.
        var m: [String: Any] = [HKMetadataKeySyncIdentifier: id, HKMetadataKeySyncVersion: Int(Date.now.timeIntervalSince1970)]
        for (k, v) in extra { m[k] = v }
        return m
    }

    private func sleep(_ nights: [SleepNight]) -> [(id: String, fingerprint: String, sample: HKSample)] {
        let type = HKCategoryType(.sleepAnalysis)
        var out: [(id: String, fingerprint: String, sample: HKSample)] = []
        for night in nights {
            guard let start = night.startDate, let end = night.endDate, end > start, end < .now else { continue }
            let segments = night.segments
            let fingerprint = "\(night.end)|\(segments.count)|\(night.asleepSeconds)"
            if segments.isEmpty {
                let id = "garmin.sleep.\(night.id)"
                let value = HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue
                out.append((id, fingerprint, HKCategorySample(type: type, value: value, start: start, end: end, metadata: metadata(id))))
                continue
            }
            for (i, seg) in segments.enumerated() {
                let id = "garmin.sleep.\(night.id).\(i)"
                let value: HKCategoryValueSleepAnalysis = switch seg.stage {
                case .awake: .awake
                case .rem: .asleepREM
                case .light: .asleepCore
                case .deep: .asleepDeep
                }
                out.append((id, fingerprint, HKCategorySample(type: type, value: value.rawValue, start: seg.start, end: seg.end, metadata: metadata(id))))
            }
        }
        return out
    }

    /// Garmin's overnight HRV is an RMSSD; Health only has an SDNN type, so it
    /// goes there, marked as RMSSD in its metadata. The two run on similar scales
    /// but aren't the same measure.
    private func hrv(_ snapshot: FitnessSnapshot) -> [(id: String, fingerprint: String, sample: HKSample)] {
        let type = HKQuantityType(.heartRateVariabilitySDNN)
        return (snapshot.hrv ?? []).compactMap { h in
            guard let value = h.lastNightAverage, value > 0, let day = h.date else { return nil }
            // At the end of that morning's sleep, or 7 am when there's no night for it.
            let wake = snapshot.sleep.first { $0.endDate.map(localDay) == h.day }?.endDate
            let at = wake ?? day.addingTimeInterval(7 * 3600)
            guard at < .now else { return nil }
            let id = "garmin.hrv.\(h.day)"
            let quantity = HKQuantity(unit: .secondUnit(with: .milli), doubleValue: value)
            let sample = HKQuantitySample(type: type, quantity: quantity, start: at, end: at,
                                          metadata: metadata(id, ["ArmstrongHubMethod": "RMSSD (Garmin overnight average)"]))
            return (id, "\(value)", sample)
        }
    }

    /// Finished days only: today's resting heart rate still moves.
    private func restingHeartRate(_ days: [FitnessDay]) -> [(id: String, fingerprint: String, sample: HKSample)] {
        let type = HKQuantityType(.restingHeartRate)
        let today = localDay()
        return days.compactMap { d in
            guard d.day < today, let bpm = d.restingHr, bpm > 0, let start = d.date,
                  let end = Calendar.current.date(byAdding: .day, value: 1, to: start) else { return nil }
            let id = "garmin.rhr.\(d.day)"
            let quantity = HKQuantity(unit: .count().unitDivided(by: .minute()), doubleValue: Double(bpm))
            return (id, "\(bpm)", HKQuantitySample(type: type, quantity: quantity, start: start, end: end, metadata: metadata(id)))
        }
    }

    private static func drinkID(_ id: UUID) -> String { "drink.\(id.uuidString)" }

    private func alcohol(_ drinks: [DrinkEntry]) -> [(id: String, fingerprint: String, sample: HKSample)] {
        let type = HKQuantityType(.numberOfAlcoholicBeverages)
        return drinks.compactMap { d in
            guard d.count > 0, d.date <= .now else { return nil }
            let id = Self.drinkID(d.id)
            let quantity = HKQuantity(unit: .count(), doubleValue: Double(d.count))
            let sample = HKQuantitySample(type: type, quantity: quantity, start: d.date, end: d.date,
                                          metadata: metadata(id, [HKMetadataKeyFoodType: d.kind.title]))
            return (id, "\(d.count)|\(d.date.timeIntervalSince1970)|\(d.kind.rawValue)", sample)
        }
    }

    /// Drinks deleted from the log come out of Health too.
    private func removeDeletedDrinks(keeping: Set<String>) async throws {
        let gone = written.keys.filter { $0.hasPrefix("drink.") && !keeping.contains($0) }
        guard !gone.isEmpty else { return }
        let predicate = HKQuery.predicateForObjects(withMetadataKey: HKMetadataKeySyncIdentifier, allowedValues: gone)
        _ = try await store.deleteObjects(of: HKQuantityType(.numberOfAlcoholicBeverages), predicate: predicate)
        for id in gone { written[id] = nil }
    }

    /// Finished activities as Health workouts, one at a time (each needs a builder).
    private func workouts(_ activities: [FitnessActivity]) async throws {
        for a in activities {
            guard let start = a.start, let end = a.end, end > start, end < .now else { continue }
            let id = "garmin.activity.\(a.id)"
            let fingerprint = "\(a.elapsedSeconds ?? 0)|\(a.calories ?? 0)|\(a.distanceMeters ?? 0)"
            guard written[id] != fingerprint else { continue }
            let configuration = HKWorkoutConfiguration()
            configuration.activityType = Self.activityType(sport: a.sport, subSport: a.subSport)
            configuration.locationType = a.hasDistance && a.subSport?.contains("indoor") != true && a.subSport != "treadmill" ? .outdoor : .unknown
            let builder = HKWorkoutBuilder(healthStore: store, configuration: configuration, device: nil)
            try await builder.beginCollection(at: start)
            var samples: [HKSample] = []
            if let kcal = a.calories, kcal > 0 {
                samples.append(HKQuantitySample(type: HKQuantityType(.activeEnergyBurned),
                                                quantity: HKQuantity(unit: .kilocalorie(), doubleValue: Double(kcal)), start: start, end: end))
            }
            if let meters = a.distanceMeters, a.hasDistance, let type = Self.distanceType(a.sport) {
                samples.append(HKQuantitySample(type: type, quantity: HKQuantity(unit: .meter(), doubleValue: meters), start: start, end: end))
            }
            if !samples.isEmpty { try await builder.addSamples(samples) }
            var extra: [String: Any] = [HKMetadataKeyExternalUUID: a.id]
            if let avg = a.avgHr { extra["ArmstrongHubAverageHeartRate"] = avg }
            if let max = a.maxHr { extra["ArmstrongHubMaxHeartRate"] = max }
            try await builder.addMetadata(metadata(id, extra))
            try await builder.endCollection(at: end)
            _ = try await builder.finishWorkout()
            written[id] = fingerprint
        }
    }

    private static func distanceType(_ sport: String) -> HKQuantityType? {
        switch sport {
        case "running", "walking", "hiking", "mountaineering": HKQuantityType(.distanceWalkingRunning)
        case "cycling", "e_biking": HKQuantityType(.distanceCycling)
        case "swimming": HKQuantityType(.distanceSwimming)
        default: nil
        }
    }

    static func activityType(sport: String, subSport: String?) -> HKWorkoutActivityType {
        switch subSport {
        case "strength_training": return .traditionalStrengthTraining
        case "yoga": return .yoga
        case "pilates": return .pilates
        case "hiit": return .highIntensityIntervalTraining
        case "indoor_rowing": return .rowing
        case "elliptical": return .elliptical
        case "stair_climbing": return .stairClimbing
        default: break
        }
        switch sport {
        case "running": return .running
        case "cycling", "e_biking": return .cycling
        case "swimming": return .swimming
        case "walking": return .walking
        case "hiking", "mountaineering": return .hiking
        case "training", "fitness_equipment": return .functionalStrengthTraining
        case "rowing": return .rowing
        case "paddling", "kayaking": return .paddleSports
        case "tennis": return .tennis
        case "soccer": return .soccer
        case "basketball": return .basketball
        case "golf": return .golf
        case "boxing": return .boxing
        case "mixed_martial_arts": return .martialArts
        case "alpine_skiing": return .downhillSkiing
        case "snowboarding": return .snowboarding
        case "cross_country_skiing": return .crossCountrySkiing
        default: return .other
        }
    }

    // MARK: Helpers

    private static func date(_ day: String) -> Date? {
        let parts = day.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return Calendar.current.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    private func persist() {
        try? FileManager.default.createDirectory(at: Self.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(written) { try? data.write(to: Self.url, options: .atomic) }
    }
}
