import Foundation

/// The weather at home (was lib/weather.ts and /api/mobile/weather): Open-Meteo,
/// asked straight from the phone, no key needed. Home is the Home place set in
/// Places; until one is set it's New York, like the hub's default. A forecast
/// is kept for 10 minutes, and an older one beats none when Open-Meteo is down.
nonisolated enum LocalWeather {
    static func registerAsync(_ r: inout [String: LocalHub.AsyncHandler]) {
        r["GET /api/mobile/weather"] = { _ in
            if let fresh = cache.get(maxAge: 600) { return .ok(fresh) }
            do {
                let value = try await fetch()
                cache.put(value)
                return .ok(value)
            } catch {
                if let stale = cache.get(maxAge: .infinity) { return .ok(stale) }
                return .error("Couldn't get the weather right now.", 502)
            }
        }
    }

    static let labels: [([Int], String)] = [
        ([0], "Clear"), ([1], "Mostly clear"), ([2], "Partly cloudy"), ([3], "Overcast"), ([45, 48], "Fog"),
        ([51, 53, 55, 56, 57], "Drizzle"), ([61, 63, 66, 80, 81], "Rain"), ([65, 67, 82], "Heavy rain"),
        ([71, 73, 77, 85], "Snow"), ([75, 86], "Heavy snow"), ([95, 96, 99], "Thunderstorms"),
    ]

    static func label(_ code: Int) -> String { labels.first { $0.0.contains(code) }?.1 ?? "Unknown" }

    /// Home from Places (Application Support/Places/places.json), else New York.
    static func home() -> (lat: Double, lon: Double, name: String) {
        let url = URL.applicationSupportDirectory.appending(path: "Places/places.json")
        if let data = try? Data(contentsOf: url),
           let saved = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let home = (saved["places"] as? [String: Any])?["home"] as? [String: Any],
           let lat = LocalHub.number(home["latitude"]), let lon = LocalHub.number(home["longitude"]) {
            return (lat, lon, "Home")
        }
        return (40.7128, -74.006, "New York")
    }

    static func fetch() async throws -> [String: Any] {
        let place = home()
        var c = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        c.queryItems = [
            .init(name: "latitude", value: String(place.lat)), .init(name: "longitude", value: String(place.lon)),
            .init(name: "current", value: "temperature_2m,apparent_temperature,weather_code,is_day,relative_humidity_2m,wind_speed_10m"),
            .init(name: "hourly", value: "temperature_2m,weather_code,precipitation_probability,is_day"),
            .init(name: "daily", value: "weather_code,temperature_2m_max,temperature_2m_min,precipitation_probability_max,sunrise,sunset"),
            .init(name: "temperature_unit", value: "fahrenheit"), .init(name: "wind_speed_unit", value: "mph"),
            .init(name: "timezone", value: TimeZone.current.identifier),
            .init(name: "forecast_days", value: "6"), .init(name: "forecast_hours", value: "12"),
        ]
        let (data, response) = try await URLSession.shared.data(for: URLRequest(url: c.url!, timeoutInterval: 8))
        guard ((response as? HTTPURLResponse)?.statusCode ?? 0) == 200,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let current = json["current"] as? [String: Any], let hourly = json["hourly"] as? [String: Any],
              let daily = json["daily"] as? [String: Any] else { throw URLError(.badServerResponse) }

        func round(_ v: Any?) -> Int { Int((LocalHub.number(v) ?? 0).rounded()) }
        func list(_ o: [String: Any], _ key: String) -> [Any] { o[key] as? [Any] ?? [] }
        let code = LocalHub.int(current["weather_code"]) ?? 3
        let hourTimes = list(hourly, "time"), dayTimes = list(daily, "time")
        func at(_ o: [String: Any], _ key: String, _ i: Int) -> Any? { let l = list(o, key); return i < l.count ? l[i] : nil }

        return [
            "place": place.name,
            "current": [
                "temp": round(current["temperature_2m"]),
                "feelsLike": round(current["apparent_temperature"]),
                "code": code,
                "isDay": LocalHub.int(current["is_day"]) == 1,
                "humidity": LocalHub.orNull(LocalHub.number(current["relative_humidity_2m"])),
                "windMph": LocalHub.orNull(LocalHub.number(current["wind_speed_10m"]).map { Int($0.rounded()) }),
                "label": label(code),
            ],
            "hours": hourTimes.indices.map { i -> [String: Any] in
                ["time": hourTimes[i], "temp": round(at(hourly, "temperature_2m", i)), "code": LocalHub.int(at(hourly, "weather_code", i)) ?? 3,
                 "isDay": LocalHub.int(at(hourly, "is_day", i)) == 1,
                 "precipChance": LocalHub.orNull(LocalHub.number(at(hourly, "precipitation_probability", i)))]
            },
            "days": dayTimes.indices.map { i -> [String: Any] in
                ["day": dayTimes[i], "high": round(at(daily, "temperature_2m_max", i)), "low": round(at(daily, "temperature_2m_min", i)),
                 "code": LocalHub.int(at(daily, "weather_code", i)) ?? 3,
                 "precipChance": LocalHub.orNull(LocalHub.number(at(daily, "precipitation_probability_max", i)))]
            },
            "sunrise": LocalHub.orNull(list(daily, "sunrise").first),
            "sunset": LocalHub.orNull(list(daily, "sunset").first),
            "updatedAt": LocalDB.iso(Date()),
            "source": "open-meteo",
        ]
    }

    final class Cache: @unchecked Sendable {
        private let lock = NSLock()
        private var entry: (at: Date, value: [String: Any])?
        func get(maxAge: TimeInterval) -> [String: Any]? {
            lock.lock(); defer { lock.unlock() }
            guard let e = entry, Date().timeIntervalSince(e.at) < maxAge else { return nil }
            return e.value
        }
        func put(_ value: [String: Any]) { lock.lock(); entry = (Date(), value); lock.unlock() }
    }

    static let cache = Cache()
}
