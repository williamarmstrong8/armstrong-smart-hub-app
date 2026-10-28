import Foundation
import Observation
import SwiftUI

/// The weather at home, for the wall. Kept on disk so it paints at once.
@MainActor
@Observable
final class WeatherStore {
    private(set) var weather: WeatherData? = DiskCache.read("weather")
    private(set) var error: String?

    func load(api: APIClient) async {
        do {
            let data = try await api.data(api.request("/api/mobile/weather", timeout: 20))
            weather = try APIClient.decoder.decode(WeatherData.self, from: data)
            DiskCache.write(data, "weather")
            error = nil
        } catch is CancellationError {
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// The Pi's health and its services, and starting, stopping or restarting one.
@MainActor
@Observable
final class PiStore {
    private(set) var status: PiStatus?
    private(set) var error: String?
    /// The container being changed right now.
    private(set) var busy: String?

    func load(api: APIClient) async {
        do {
            let next: PiStatus = try await api.send(api.request("/api/mobile/pi", timeout: 20))
            status = next
            error = nil
        } catch is CancellationError {
        } catch {
            self.error = error.localizedDescription
        }
    }

    enum Action: String { case start, stop, restart }

    func control(_ container: PiContainer, _ action: Action, api: APIClient, toast: Toast) async {
        struct Body: Encodable { let container: String; let action: String }
        struct Reply: Decodable { let container: PiContainer; let status: PiStatus }
        busy = container.name
        defer { busy = nil }
        do {
            let reply: Reply = try await api.send(
                api.request("/api/mobile/pi", method: "POST", body: Body(container: container.name, action: action.rawValue), timeout: 75)
            )
            status = reply.status
            let done = switch action { case .start: "Started"; case .stop: "Stopped"; case .restart: "Restarted" }
            toast.show("\(done) \(container.name)")
        } catch {
            toast.error(error)
        }
    }
}

/// WMO weather codes as SF Symbols and colors.
enum WeatherLook {
    static func symbol(_ code: Int, isDay: Bool = true) -> String {
        switch code {
        case 0: isDay ? "sun.max.fill" : "moon.stars.fill"
        case 1: isDay ? "sun.min.fill" : "moon.fill"
        case 2: isDay ? "cloud.sun.fill" : "cloud.moon.fill"
        case 3: "cloud.fill"
        case 45, 48: "cloud.fog.fill"
        case 51, 53, 55, 56, 57: "cloud.drizzle.fill"
        case 61, 63, 66, 80, 81: isDay ? "cloud.sun.rain.fill" : "cloud.rain.fill"
        case 65, 67, 82: "cloud.heavyrain.fill"
        case 71, 73, 77, 85: "cloud.snow.fill"
        case 75, 86: "snowflake"
        case 95, 96, 99: "cloud.bolt.rain.fill"
        default: "cloud.fill"
        }
    }

    /// The hub's words for a WMO code (lib/weather.ts), for the days ahead.
    static func label(_ code: Int) -> String {
        switch code {
        case 0: "Clear"
        case 1: "Mostly clear"
        case 2: "Partly cloudy"
        case 3: "Overcast"
        case 45, 48: "Fog"
        case 51, 53, 55, 56, 57: "Drizzle"
        case 61, 63, 66, 80, 81: "Rain"
        case 65, 67, 82: "Heavy rain"
        case 71, 73, 77, 85: "Snow"
        case 75, 86: "Heavy snow"
        case 95, 96, 99: "Thunderstorms"
        default: "Cloudy"
        }
    }

    /// Multicolor symbols carry their own colors; this tints the rest.
    static func tint(_ code: Int, isDay: Bool = true) -> Color {
        switch code {
        case 0, 1: isDay ? .yellow : .indigo
        case 61...67, 80...82, 51...57: .cyan
        case 71...77, 85, 86: .mint
        case 95...99: .purple
        default: .gray
        }
    }

    /// "16:00" in "2026-10-28T16:00" → "4 PM"; the first hour reads "Now".
    static func hour(_ local: String, first: Bool) -> String {
        if first { return "Now" }
        let h = Int(local.dropFirst(11).prefix(2)) ?? 0
        return "\(h % 12 == 0 ? 12 : h % 12) \(h < 12 ? "AM" : "PM")"
    }

    /// "Today", then "Wed".
    static func weekday(_ day: String, first: Bool) -> String {
        if first { return "Today" }
        guard let date = DayFormat.parse(day) else { return day }
        return date.formatted(Date.FormatStyle(timeZone: .gmt).weekday(.abbreviated))
    }
}

/// How you're doing in one word and one sentence, from the watch's readiness, sleep and Body
/// Battery. The iPhone's Home hero and the wall share it.
extension FitnessStore {
    var readinessScore: Int? { snapshot?.watch?.readiness?.score ?? snapshot?.metrics?.readiness.score }
    var sleepScore: Int? { snapshot?.watch?.sleep?.overall ?? lastNight?.score }
    var energy: Int? { currentBodyBattery ?? snapshot?.metrics?.bodyBattery?.current ?? snapshot?.insights?.stress.bodyBattery?.current }

    var dayStatus: (title: String, summary: String)? {
        let readiness = readinessScore
        let sleep = sleepScore
        let energy = energy
        guard readiness != nil || sleep != nil || energy != nil else { return nil }
        let drained = (energy ?? 100) < 30
        let slept = (sleep ?? 0) >= 75
        let ready = readiness ?? 0
        if drained || ready < 40 {
            return ("Run down", drained ? "Battery is low. Take it easy and get to bed early." : "Your body is asking for rest today.")
        }
        if ready >= 75 && (energy ?? 100) >= 60 {
            return ("Energized", slept ? "Slept well and ready to push. A good day to train." : "Ready to go, even on a short night.")
        }
        if slept { return ("Rested", "Slept well and recovered. Steady day ahead.") }
        return ("Steady", "A middling night. Fine for an easy day.")
    }
}
