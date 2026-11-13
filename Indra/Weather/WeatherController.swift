import SwiftUI

struct WeatherHour: Identifiable, Codable {
    let id: Int
    let label: String
    let temperature: Int
    let symbol: String
}

struct WeatherSnapshot: Codable {
    var temperature: Int
    var symbol: String
    var high: Int
    var low: Int
    var uv: Int
    var windKmh: Int
    var hours: [WeatherHour]
    var graph: [Double]
    var graphNowIndex: Int
}

/// The last weather that was shown, kept on disk so the page opens with it at once instead of waiting for the network.
private struct WeatherCache: Codable {
    let city: String
    let fetched: Date
    let snapshot: WeatherSnapshot
}

enum WeatherPhase {
    case needsCity
    case loading
    case ready(WeatherSnapshot)
    case failed(String)
}

private enum WeatherError: Error {
    case notFound
    case badData
}

private struct GeocodeResponse: Decodable {
    struct Place: Decodable {
        let latitude: Double
        let longitude: Double
    }
    let results: [Place]?
}

private struct ForecastResponse: Decodable {
    struct Current: Decodable {
        let time: String
        let temperature: Double
        let code: Int
        let wind: Double
        enum CodingKeys: String, CodingKey {
            case time
            case temperature = "temperature_2m"
            case code = "weather_code"
            case wind = "wind_speed_10m"
        }
    }

    struct Hourly: Decodable {
        let time: [String]
        let temperature: [Double?]
        let code: [Int?]
        let uv: [Double?]
        enum CodingKeys: String, CodingKey {
            case time
            case temperature = "temperature_2m"
            case code = "weather_code"
            case uv = "uv_index"
        }
    }

    struct Daily: Decodable {
        let highs: [Double?]
        let lows: [Double?]
        enum CodingKeys: String, CodingKey {
            case highs = "temperature_2m_max"
            case lows = "temperature_2m_min"
        }
    }

    let offset: Int
    let current: Current
    let hourly: Hourly
    let daily: Daily
    enum CodingKeys: String, CodingKey {
        case offset = "utc_offset_seconds"
        case current, hourly, daily
    }
}

/// Weather from Open-Meteo (free, no account). Only the city name and its coordinates are sent.
@MainActor
final class WeatherController: ObservableObject {
    @Published private(set) var phase: WeatherPhase = .needsCity

    private var coordinate: (latitude: Double, longitude: Double)?
    private var coordinateCity = ""
    private var loadedCity = ""
    private var lastFetch: Date?
    private var loading = false
    private var reloadAgain = false
    private static let cacheKey = "weatherCache"

    init() {
        // The last weather is shown immediately; the page never waits on a "Loading" state.
        let city = Preferences.weatherCity.trimmingCharacters(in: .whitespacesAndNewlines)
        if !city.isEmpty {
            if let data = UserDefaults.standard.data(forKey: Self.cacheKey),
               let cache = try? JSONDecoder().decode(WeatherCache.self, from: data),
               cache.city == city {
                phase = .ready(cache.snapshot)
                loadedCity = city
                lastFetch = cache.fetched
            } else {
                phase = .loading
            }
            // Fresh data is fetched in the background as soon as the app starts.
            Task { @MainActor [weak self] in self?.activate() }
        }
    }

    /// Called when the weather page appears.
    func activate() {
        guard Preferences.weatherEnabled else { return }
        let city = Preferences.weatherCity.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !city.isEmpty else {
            phase = .needsCity
            return
        }
        if let saved = Preferences.weatherSavedCoordinate(for: city),
           coordinate?.latitude != saved.latitude || coordinate?.longitude != saved.longitude {
            coordinate = saved
            coordinateCity = city
            // v495: this used to clear `loadedCity`, which made `load` switch the page from the cached weather it was
            // already showing to "Loading" on every launch. Forgetting the fetch time is enough to fetch again.
            lastFetch = nil
        }
        if city == loadedCity, let last = lastFetch, Date().timeIntervalSince(last) < 900, case .ready = phase {
            return
        }
        guard !loading else {
            reloadAgain = true
            return
        }
        loading = true
        Task {
            await load(city: city)
            loading = false
            if reloadAgain {
                reloadAgain = false
                activate()
            }
        }
    }

    private func load(city: String) async {
        if city != loadedCity { phase = .loading }
        do {
            if coordinateCity != city || coordinate == nil {
                coordinate = try await geocode(city)
                coordinateCity = city
            }
            guard let coordinate else { throw WeatherError.notFound }
            let snapshot = try await forecast(latitude: coordinate.latitude, longitude: coordinate.longitude)
            phase = .ready(snapshot)
            loadedCity = city
            lastFetch = Date()
            if let data = try? JSONEncoder().encode(WeatherCache(city: city, fetched: Date(), snapshot: snapshot)) {
                UserDefaults.standard.set(data, forKey: Self.cacheKey)
            }
        } catch {
            if error is WeatherError {
                // City not found: shown on the page, not a fault.
            } else if Self.isOffline(error) {
                // No connection is not a bug. Noted once, kept out of the problem list, and tried again soon.
                IndraLog.crumb("Weather: no internet connection")
                scheduleRetry()
            } else {
                IndraLog.error("Weather request failed", error)
            }
            if case .ready = phase { return }
            phase = .failed(error is WeatherError ? "City not found" : "Weather unavailable")
        }
    }

    // MARK: - Network

    nonisolated private static func isOffline(_ error: Error) -> Bool {
        let ns = error as NSError
        guard ns.domain == NSURLErrorDomain else { return false }
        return [NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost, NSURLErrorTimedOut,
                NSURLErrorCannotFindHost, NSURLErrorCannotConnectToHost, NSURLErrorDNSLookupFailed,
                NSURLErrorDataNotAllowed, NSURLErrorInternationalRoamingOff, NSURLErrorBadServerResponse].contains(ns.code)
    }

    private var retryTask: Task<Void, Never>?

    /// After a failed load with no connection, look again in a minute (the page also retries every time it opens).
    private func scheduleRetry() {
        guard retryTask == nil else { return }
        retryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 60_000_000_000)
            guard let self, !Task.isCancelled else { return }
            self.retryTask = nil
            self.activate()
        }
    }

    private func fetch(_ urlString: String) async throws -> Data {
        guard let url = URL(string: urlString) else { throw WeatherError.badData }
        let request = URLRequest(url: url, timeoutInterval: 12)
        // v437: Net.send already tries a busy answer (429, 5xx) or a passing network error once more before giving up.
        let (data, http) = try await Net.send(request, policy: RetryPolicy(maxAttempts: 2, baseDelay: 1, maxDelay: 4))
        // v419: an error answer used to be read as weather data, failed to decode, was reported as a fault and never
        // retried. It is treated like a missing connection: quiet, and tried again later.
        if !(200..<300).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }
        return data
    }

    private func geocode(_ city: String) async throws -> (latitude: Double, longitude: Double) {
        var components = URLComponents(string: "https://geocoding-api.open-meteo.com/v1/search")
        components?.queryItems = [URLQueryItem(name: "name", value: city),
                                  URLQueryItem(name: "count", value: "1"),
                                  URLQueryItem(name: "language", value: "en"),
                                  URLQueryItem(name: "format", value: "json")]
        guard let url = components?.url else { throw WeatherError.badData }
        let data = try await fetch(url.absoluteString)
        let response = try JSONDecoder().decode(GeocodeResponse.self, from: data)
        guard let place = response.results?.first else { throw WeatherError.notFound }
        return (place.latitude, place.longitude)
    }

    private func forecast(latitude: Double, longitude: Double) async throws -> WeatherSnapshot {
        let query = "latitude=\(latitude)&longitude=\(longitude)"
            + "&current=temperature_2m,weather_code,wind_speed_10m"
            + "&hourly=temperature_2m,weather_code,uv_index"
            + "&daily=temperature_2m_max,temperature_2m_min"
            + "&timezone=auto&forecast_days=3"
        let data = try await fetch("https://api.open-meteo.com/v1/forecast?\(query)")
        let response = try JSONDecoder().decode(ForecastResponse.self, from: data)
        return try WeatherController.snapshot(from: response)
    }

    // MARK: - Mapping

    private static func snapshot(from response: ForecastResponse) throws -> WeatherSnapshot {
        let zone = TimeZone(secondsFromGMT: response.offset) ?? .current
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.timeZone = zone
        parser.dateFormat = "yyyy-MM-dd'T'HH:mm"
        let labeler = DateFormatter()
        labeler.locale = Locale(identifier: "en_US_POSIX")
        labeler.timeZone = zone
        labeler.dateFormat = "ha"
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone

        let times = response.hourly.time.compactMap { parser.date(from: $0) }
        let temperatures = response.hourly.temperature
        let codes = response.hourly.code
        guard times.count == response.hourly.time.count,
              times.count == temperatures.count,
              times.count == codes.count,
              let now = parser.date(from: response.current.time) else { throw WeatherError.badData }

        guard !times.isEmpty else { throw WeatherError.badData }
        let nowIndex = times.lastIndex(where: { $0 <= now }) ?? 0
        func isDay(_ date: Date) -> Bool {
            let hour = calendar.component(.hour, from: date)
            return hour >= 6 && hour < 19
        }

        var hours: [WeatherHour] = []
        let end = min(nowIndex + 25, times.count)
        if nowIndex + 1 < end {
            for index in (nowIndex + 1)..<end {
                hours.append(WeatherHour(id: index,
                                         label: labeler.string(from: times[index]),
                                         temperature: Int((temperatures[index] ?? 0).rounded()),
                                         symbol: symbol(code: codes[index] ?? 0, day: isDay(times[index]))))
            }
        }

        let start = max(0, nowIndex - 6)
        let graphEnd = max(min(times.count - 1, nowIndex + 12), start)
        let graph = (start...graphEnd).map { temperatures[$0] ?? 0 }

        let uv = (response.hourly.uv.indices.contains(nowIndex) ? response.hourly.uv[nowIndex] : nil) ?? 0
        return WeatherSnapshot(temperature: Int(response.current.temperature.rounded()),
                               symbol: symbol(code: response.current.code, day: isDay(now)),
                               high: Int((response.daily.highs.first.flatMap { $0 } ?? 0).rounded()),
                               low: Int((response.daily.lows.first.flatMap { $0 } ?? 0).rounded()),
                               uv: Int(uv.rounded()),
                               windKmh: Int(response.current.wind.rounded()),
                               hours: hours,
                               graph: graph,
                               graphNowIndex: nowIndex - start)
    }

    /// WMO weather codes to SF Symbols.
    private static func symbol(code: Int, day: Bool) -> String {
        switch code {
        case 0: return day ? "sun.max.fill" : "moon.stars.fill"
        case 1, 2: return day ? "cloud.sun.fill" : "cloud.moon.fill"
        case 3: return "cloud.fill"
        case 45, 48: return "cloud.fog.fill"
        case 51...57: return "cloud.drizzle.fill"
        case 61...67: return "cloud.rain.fill"
        case 71...77, 85, 86: return "cloud.snow.fill"
        case 80...82: return "cloud.heavyrain.fill"
        case 95...99: return "cloud.bolt.rain.fill"
        default: return "cloud.fill"
        }
    }
}
