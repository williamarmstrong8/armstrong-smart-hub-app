import Foundation
import Observation

/// The Fitness console's data from the hub: days, activities, sleep and heart rate.
@MainActor
@Observable
final class FitnessStore {
    private(set) var snapshot: FitnessSnapshot?
    private(set) var error: String?
    private var details: [String: FitnessActivityDetail] = [:]

    var loaded: Bool { snapshot != nil }

    func load(api: APIClient) async {
        do {
            snapshot = try await api.get("/api/mobile/fitness")
            error = nil
        } catch is CancellationError {
        } catch {
            self.error = error.localizedDescription
        }
    }

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
