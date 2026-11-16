import CoreLocation
import Foundation
import Observation
import UIKit
import UserNotifications

/// Home, work and the gym, set from where the phone is, watched with
/// geofences (CLMonitor) that keep working with the app closed: iOS relaunches
/// the app in the background on an arrival or departure.
///
/// - Arriving at the gym with no workout going asks to start one; leaving with
///   one still going asks to finish it.
/// - Every arrival and departure is kept (the last 60 days), so the evening
///   briefing can say how long you were at work or the gym.
///
/// Needs "Always" location access; places live only on this phone.
@MainActor
@Observable
final class PlaceMonitor {
    static let shared = PlaceMonitor()

    enum Kind: String, Codable, CaseIterable, Identifiable {
        case home, work, gym
        var id: String { rawValue }
        var title: String {
            switch self {
            case .home: "Home"
            case .work: "Work"
            case .gym: "Gym"
            }
        }
        var symbol: String {
            switch self {
            case .home: "house"
            case .work: "briefcase"
            case .gym: "dumbbell"
            }
        }
    }

    struct Place: Codable, Equatable {
        var latitude: Double
        var longitude: Double
        var radius: Double
        /// The address it was set from; nil when set from where the phone was.
        var address: String?
        var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: latitude, longitude: longitude) }
    }

    struct Visit: Codable, Equatable, Identifiable {
        var id = UUID()
        var kind: Kind
        var arrived: Date
        var left: Date?
    }

    private(set) var places: [Kind: Place] = [:]
    private(set) var visits: [Visit] = []
    /// Where the phone is now, as far as the geofences know.
    private(set) var inside: Set<Kind> = []
    private(set) var setting: Kind?
    private(set) var problem: String?

    /// Ask to start a workout on arriving at the gym.
    var gymPrompts: Bool {
        didSet { UserDefaults.standard.set(gymPrompts, forKey: Self.gymPromptsKey) }
    }
    /// Turn William's room lamp on when you get home.
    var homeLamp: Bool {
        didSet { UserDefaults.standard.set(homeLamp, forKey: "places.homeLamp") }
    }
    /// Send the evening check-in when you get home.
    var homeCheckin: Bool {
        didSet {
            UserDefaults.standard.set(homeCheckin, forKey: "places.homeCheckin")
            Task { await CheckinReminders.shared.schedule(CheckinStore.shared) }
        }
    }

    @ObservationIgnored private var monitor: CLMonitor?
    @ObservationIgnored private var session: CLServiceSession?
    @ObservationIgnored private var listening: Task<Void, Never>?

    private static let monitorName = "places"
    private static let gymPromptsKey = "places.gymPrompts"
    private static let url = URL.applicationSupportDirectory.appending(path: "Places/places.json")
    static let defaultRadius: Double = 150

    private struct Saved: Codable {
        var places: [String: Place]
        var visits: [Visit]
    }

    init() {
        gymPrompts = UserDefaults.standard.object(forKey: Self.gymPromptsKey) as? Bool ?? true
        homeLamp = UserDefaults.standard.object(forKey: "places.homeLamp") as? Bool ?? true
        homeCheckin = UserDefaults.standard.object(forKey: "places.homeCheckin") as? Bool ?? true
        guard !Demo.isOn, let data = try? Data(contentsOf: Self.url), let saved = try? JSONDecoder().decode(Saved.self, from: data) else { return }
        places = Dictionary(uniqueKeysWithValues: saved.places.compactMap { k, v in Kind(rawValue: k).map { ($0, v) } })
        visits = saved.visits
        inside = Set(visits.filter { $0.left == nil }.map(\.kind))
    }

    private func persist() {
        if Demo.isOn { return }
        try? FileManager.default.createDirectory(at: Self.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let saved = Saved(places: Dictionary(uniqueKeysWithValues: places.map { ($0.key.rawValue, $0.value) }), visits: visits)
        if let data = try? JSONEncoder().encode(saved) { try? data.write(to: Self.url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]) }
    }

    // MARK: Watching

    /// Call at launch: a background relaunch for a geofence event only delivers
    /// it once the monitor of the same name is open and its events are read.
    func start() {
        guard !Demo.isOn, !places.isEmpty, listening == nil else { return }
        session = CLServiceSession(authorization: .always)
        listening = Task { @MainActor [weak self] in
            let monitor = await CLMonitor(Self.monitorName)
            self?.monitor = monitor
            await self?.syncConditions()
            do {
                for try await event in await monitor.events {
                    self?.handle(event)
                }
            } catch {
                self?.problem = error.localizedDescription
            }
        }
    }

    /// Makes the monitor's geofences match the saved places.
    private func syncConditions() async {
        guard let monitor else { return }
        let wanted = Set(places.keys.map(\.rawValue))
        for id in await monitor.identifiers where !wanted.contains(id) {
            await monitor.remove(id)
        }
        for (kind, place) in places {
            let condition = CLMonitor.CircularGeographicCondition(center: place.coordinate, radius: place.radius)
            // Adding again with the same identifier replaces the old circle.
            await monitor.add(condition, identifier: kind.rawValue, assuming: inside.contains(kind) ? .satisfied : .unsatisfied)
        }
    }

    private func handle(_ event: CLMonitor.Event) {
        guard let kind = Kind(rawValue: event.identifier) else { return }
        switch event.state {
        case .satisfied:
            guard !inside.contains(kind) else { return }
            inside.insert(kind)
            visits.append(Visit(kind: kind, arrived: event.date))
            arrived(kind)
        case .unsatisfied:
            guard inside.contains(kind) else { return }
            inside.remove(kind)
            if let i = visits.lastIndex(where: { $0.kind == kind && $0.left == nil }) { visits[i].left = event.date }
            left(kind)
        default:
            return
        }
        let cutoff = Date.now.addingTimeInterval(-60 * 86400)
        visits.removeAll { ($0.left ?? .now) < cutoff }
        persist()
    }

    // MARK: Setting places

    /// Saves where the phone is now as one of the places and starts watching it.
    func setHere(_ kind: Kind) async {
        setting = kind
        defer { setting = nil }
        problem = nil
        let session = CLServiceSession(authorization: .always)
        defer { session.invalidate() }
        guard let location = await Self.locate() else {
            problem = "Couldn't find where you are. Check that location is allowed for this app (Always)."
            return
        }
        places[kind] = Place(latitude: location.coordinate.latitude, longitude: location.coordinate.longitude,
                             radius: max(Self.defaultRadius, location.horizontalAccuracy))
        // Setting a place while standing in it: count it as arrived, without a prompt.
        if !inside.contains(kind) {
            inside.insert(kind)
            visits.append(Visit(kind: kind, arrived: .now))
        }
        persist()
        if listening == nil { start() } else { await syncConditions() }
        // Home moves the evening check-in to getting home.
        if kind == .home { await CheckinReminders.shared.schedule(CheckinStore.shared) }
    }

    /// Saves a place from an address picked in the search sheet. The geofence
    /// starts out assuming you're away; iOS corrects that within a few minutes if you're there.
    func set(_ kind: Kind, coordinate: CLLocationCoordinate2D, address: String) async {
        problem = nil
        places[kind] = Place(latitude: coordinate.latitude, longitude: coordinate.longitude, radius: Self.defaultRadius, address: address)
        inside.remove(kind)
        if let i = visits.lastIndex(where: { $0.kind == kind && $0.left == nil }) { visits[i].left = .now }
        persist()
        if listening == nil { start() } else { await syncConditions() }
        // Home moves the evening check-in to getting home.
        if kind == .home { await CheckinReminders.shared.schedule(CheckinStore.shared) }
    }

    func remove(_ kind: Kind) async {
        places[kind] = nil
        inside.remove(kind)
        if let i = visits.lastIndex(where: { $0.kind == kind && $0.left == nil }) { visits[i].left = .now }
        persist()
        await monitor?.remove(kind.rawValue)
        if kind == .home { await CheckinReminders.shared.schedule(CheckinStore.shared) }
        if places.isEmpty {
            listening?.cancel()
            listening = nil
            monitor = nil
            session?.invalidate()
            session = nil
        }
    }

    /// One good fix within 20 seconds: the first within 50 m, else the best seen.
    private static func locate() async -> CLLocation? {
        await withTaskGroup(of: CLLocation?.self) { group in
            group.addTask {
                var best: CLLocation?
                do {
                    for try await update in CLLocationUpdate.liveUpdates() {
                        if update.authorizationDenied || update.authorizationDeniedGlobally { return nil }
                        guard let location = update.location else { continue }
                        if best == nil || location.horizontalAccuracy < best!.horizontalAccuracy { best = location }
                        if location.horizontalAccuracy <= 50 { return location }
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

    // MARK: Time at places

    /// Seconds spent at a place on a calendar day (visits clipped to the day).
    func seconds(at kind: Kind, on day: Date = .now) -> TimeInterval {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: day)
        guard let end = calendar.date(byAdding: .day, value: 1, to: start) else { return 0 }
        return visits.filter { $0.kind == kind }.reduce(0) { total, v in
            let from = max(v.arrived, start)
            let to = min(v.left ?? .now, end)
            return total + max(0, to.timeIntervalSince(from))
        }
    }

    // MARK: Notifications

    nonisolated static let categoryPrefix = "place."
    private nonisolated static let gymArrived = "place.gym.arrived"
    private nonisolated static let gymLeft = "place.gym.left"
    private nonisolated static let startAction = "place.start"
    private nonisolated static let lampFailed = "place.home.lamp"
    private nonisolated static let openAction = "place.open"

    /// Registered with the check-in categories (CheckinReminders.start).
    nonisolated static var notificationCategory: UNNotificationCategory {
        UNNotificationCategory(identifier: gymArrived, actions: [
            UNNotificationAction(identifier: startAction, title: "Start workout", options: [.foreground],
                                 icon: UNNotificationActionIcon(systemImageName: "dumbbell")),
        ], intentIdentifiers: [])
    }

    private func arrived(_ kind: Kind) {
        if kind == .home { arrivedHome() }
        guard kind == .gym, gymPrompts, WorkoutStore.shared.active == nil else { return }
        notify(category: Self.gymArrived, title: "At the gym", body: "Start a workout?")
    }

    /// Home: William's room lamp on (through the hub, as the Home tab does) and the evening check-in.
    private func arrivedHome() {
        let task = UIApplication.shared.beginBackgroundTask(withName: "Arrived home")
        Task {
            defer { if task != .invalid { UIApplication.shared.endBackgroundTask(task) } }
            if homeLamp, let api = Self.api() {
                do {
                    let _: Empty? = try await api.run("setLight", [.string(WakeAlarm.lampEntity), .object(["on": .bool(true)])])
                } catch {
                    notify(category: Self.lampFailed, title: "Welcome home", body: "Couldn't turn your lamp on: the hub didn't answer.")
                }
            }
            if homeCheckin { await CheckinReminders.shared.arrivedHome() }
        }
    }

    /// The hub, from the signed-in app or, in a background relaunch with no window, the saved session.
    private static func api() -> APIClient? {
        if let api = BackgroundRefresh.shared.api { return api }
        let session = AppSession()
        return session.isSignedIn ? session.api : nil
    }

    private func left(_ kind: Kind) {
        guard kind == .gym, WorkoutStore.shared.active != nil else { return }
        notify(category: Self.gymLeft, title: "Left the gym", body: "Your workout is still going. Finish it?")
    }

    // MARK: Tests (Account › Test features)

    /// Turns William's room lamp on now, as getting home does. Returns what happened.
    func testLamp() async -> String {
        guard let api = Self.api() else { return "Not signed in to the hub." }
        do {
            let _: Empty? = try await api.run("setLight", [.string(WakeAlarm.lampEntity), .object(["on": .bool(true)])])
            return "Lamp on."
        } catch {
            return "The hub didn't turn it on: \(error.localizedDescription)"
        }
    }

    /// Plays an arrival or departure without moving: the lamp is real, the check-in is a test one.
    func simulate(_ kind: Kind, arriving: Bool) async -> String {
        switch (kind, arriving) {
        case (.home, true):
            var result = "Lamp switch is off."
            if homeLamp { result = await testLamp() }
            if homeCheckin {
                await CheckinReminders.shared.sendTest(.home)
                result += " Check-in arrives in 5 seconds."
            }
            return result
        case (.gym, true):
            notify(category: Self.gymArrived, title: "At the gym", body: "Start a workout?", after: 5)
            return "Gym notification in 5 seconds. Start workout really starts one; discard it after."
        case (.gym, false):
            notify(category: Self.gymLeft, title: "Left the gym", body: "Your workout is still going. Finish it?", after: 5)
            return "Leaving-the-gym notification in 5 seconds."
        default:
            return "Nothing happens for that yet; it's only logged."
        }
    }

    private func notify(category: String, title: String, body: String, after seconds: TimeInterval = 0) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.categoryIdentifier = category
        content.interruptionLevel = .timeSensitive
        let trigger = seconds > 0 ? UNTimeIntervalNotificationTrigger(timeInterval: seconds, repeats: false) : nil
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: category, content: content, trigger: trigger))
    }

    /// A place notification answered. Gym: Start opens a new workout, a tap opens
    /// the one going. Home (the lamp didn't come on): the Home tab, with the lights.
    func handle(category: String, action: String) async {
        if category == Self.lampFailed {
            await CheckinReminders.route(.home)
            return
        }
        let workouts = WorkoutStore.shared
        if action == Self.startAction, workouts.active == nil {
            let unit = WeightUnit(rawValue: UserDefaults.standard.string(forKey: "workouts.unit") ?? "") ?? .localDefault
            workouts.start(unit: unit)
        }
        await CheckinReminders.route(.fitness)
        if workouts.active != nil { workouts.isPresented = true }
    }
}
