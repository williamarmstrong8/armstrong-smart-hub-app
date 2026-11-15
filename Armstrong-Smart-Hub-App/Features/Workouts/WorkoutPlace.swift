import CoreLocation
import Foundation
import MapKit
import Observation

// MARK: Where

/// Where a workout happened: the phone's position when it started, named after
/// the nearest gym Apple Maps knows (or the nearest place, if no gym is close).
struct WorkoutPlace: Codable, Hashable {
    var latitude: Double
    var longitude: Double
    var name: String?

    var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: latitude, longitude: longitude) }
    var title: String { name ?? "Pinned location" }

    /// Opens the spot in Apple Maps.
    func openInMaps() {
        let item = MKMapItem(placemark: MKPlacemark(coordinate: coordinate))
        item.name = title
        item.openInMaps()
    }
}

/// Workout places, kept on the phone by workout id. A place is captured when a
/// workout starts, with the when-in-use location permission, once.
@MainActor
@Observable
final class WorkoutPlaces {
    static let shared = WorkoutPlaces()

    private(set) var places: [String: WorkoutPlace] = [:]

    private static let url = URL.applicationSupportDirectory.appending(path: "Workouts/places.json")

    init() {
        if !Demo.isOn, let data = try? Data(contentsOf: Self.url), let saved = try? JSONDecoder().decode([String: WorkoutPlace].self, from: data) {
            places = saved
        }
    }

    func place(_ workoutId: String) -> WorkoutPlace? { places[workoutId.lowercased()] }

    func remove(_ workoutId: String) {
        guard places.removeValue(forKey: workoutId.lowercased()) != nil else { return }
        persist()
    }

    private func persist() {
        if Demo.isOn { return }
        try? FileManager.default.createDirectory(at: Self.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(places) { try? data.write(to: Self.url, options: .atomic) }
    }

    /// Finds where the phone is and files it under the workout. Quietly does nothing
    /// without permission or a fix within 20 seconds.
    func capture(for workoutId: String) {
        if Demo.isOn { return }
        let key = workoutId.lowercased()
        Task {
            guard let location = await Self.locate() else { return }
            let name = await Self.name(for: location)
            places[key] = WorkoutPlace(latitude: location.coordinate.latitude, longitude: location.coordinate.longitude, name: name)
            persist()
        }
    }

    /// One good fix: the first within 200 m (indoors, Wi-Fi fixes are rarely tighter), else the best seen before the time runs out.
    private static func locate() async -> CLLocation? {
        let session = CLServiceSession(authorization: .whenInUse)
        defer { session.invalidate() }
        return await withTaskGroup(of: CLLocation?.self) { group in
            group.addTask {
                var best: CLLocation?
                do {
                    for try await update in CLLocationUpdate.liveUpdates() {
                        if update.authorizationDenied || update.authorizationDeniedGlobally { return nil }
                        guard let location = update.location else { continue }
                        if best == nil || location.horizontalAccuracy < best!.horizontalAccuracy { best = location }
                        if location.horizontalAccuracy <= 200 { return location }
                        if Task.isCancelled { return best }
                    }
                } catch {}
                return best
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(20))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    /// The nearest gym within 200 m, else the nearest named place within 75 m.
    private static func name(for location: CLLocation) async -> String? {
        func nearest(_ radius: CLLocationDistance, _ filter: MKPointOfInterestFilter?) async -> String? {
            let request = MKLocalPointsOfInterestRequest(center: location.coordinate, radius: radius)
            request.pointOfInterestFilter = filter
            guard let items = try? await MKLocalSearch(request: request).start().mapItems else { return nil }
            return items
                .min { a, b in
                    (a.placemark.location?.distance(from: location) ?? .infinity) < (b.placemark.location?.distance(from: location) ?? .infinity)
                }?
                .name
        }
        if let gym = await nearest(200, MKPointOfInterestFilter(including: [.fitnessCenter])) { return gym }
        return await nearest(75, nil)
    }
}

// MARK: What

/// The kind of session, from the muscles its exercises work (or the routine's name, when it says).
enum WorkoutType: String {
    case push, pull, legs, upper, lower, fullBody, core, cardio, mixed

    var title: String {
        switch self {
        case .push: "Push"
        case .pull: "Pull"
        case .legs: "Legs"
        case .upper: "Upper body"
        case .lower: "Lower body"
        case .fullBody: "Full body"
        case .core: "Core"
        case .cardio: "Cardio"
        case .mixed: "Strength"
        }
    }

    var symbol: String {
        switch self {
        case .push: "figure.strengthtraining.traditional"
        case .pull: "figure.rower"
        case .legs, .lower: "figure.step.training"
        case .upper: "figure.arms.open"
        case .fullBody: "figure.cross.training"
        case .core: "figure.core.training"
        case .cardio: "figure.run"
        case .mixed: "dumbbell"
        }
    }

    /// Which group a hub muscle (lib/workouts/library.ts) counts toward.
    static func group(_ muscle: String) -> String {
        switch muscle {
        case "chest", "shoulders", "triceps": "push"
        case "back", "biceps", "forearms", "lats", "traps": "pull"
        case "quads", "hamstrings", "glutes", "calves": "legs"
        case "core", "abs": "core"
        case "cardio": "cardio"
        default: "other"
        }
    }

    static func classify(name: String, muscles: [String]) -> WorkoutType {
        let lower = name.lowercased()
        for (word, type) in [("push", WorkoutType.push), ("pull", .pull), ("leg", .legs), ("upper", .upper), ("lower", .lower),
                             ("full body", .fullBody), ("core", .core), ("cardio", .cardio), ("run", .cardio)] where lower.contains(word) {
            return type
        }
        guard !muscles.isEmpty else { return .mixed }
        var counts: [String: Double] = [:]
        for m in muscles { counts[group(m), default: 0] += 1 }
        let total = Double(muscles.count)
        func share(_ g: String) -> Double { (counts[g] ?? 0) / total }
        if share("cardio") >= 0.6 { return .cardio }
        if share("core") >= 0.6 { return .core }
        for (g, type) in [("push", WorkoutType.push), ("pull", .pull), ("legs", .legs)] where share(g) >= 0.6 { return type }
        if share("push") + share("pull") >= 0.75 { return .upper }
        if share("legs") >= 0.5, share("push") + share("pull") < 0.25 { return .lower }
        if share("legs") >= 0.2, share("push") + share("pull") >= 0.3 { return .fullBody }
        return .mixed
    }
}
