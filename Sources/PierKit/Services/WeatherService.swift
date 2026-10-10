import AppKit
import Combine
import CoreLocation

public struct WeatherReport: Equatable {
    public var temperature: Double
    public var high: Double
    public var low: Double
    public var code: Int
    public var isDay: Bool
    public var place: String
    public var unit: TemperatureUnit

    public var symbol: String { WeatherCode.symbol(code, isDay: isDay) }
    public var summary: String { WeatherCode.summary(code) }
}

/// WMO weather interpretation codes, as returned by Open-Meteo.
public enum WeatherCode {
    public static func symbol(_ code: Int, isDay: Bool) -> String {
        switch code {
        case 0: return isDay ? "sun.max.fill" : "moon.stars.fill"
        case 1, 2: return isDay ? "cloud.sun.fill" : "cloud.moon.fill"
        case 3: return "cloud.fill"
        case 45, 48: return "cloud.fog.fill"
        case 51...57: return "cloud.drizzle.fill"
        case 61...67, 80...82: return "cloud.rain.fill"
        case 71...77, 85, 86: return "cloud.snow.fill"
        case 95...99: return "cloud.bolt.rain.fill"
        default: return "cloud.fill"
        }
    }

    public static func summary(_ code: Int) -> String {
        switch code {
        case 0: return "Clear"
        case 1: return "Mostly Clear"
        case 2: return "Partly Cloudy"
        case 3: return "Cloudy"
        case 45, 48: return "Fog"
        case 51...57: return "Drizzle"
        case 61...67: return "Rain"
        case 71...77: return "Snow"
        case 80...82: return "Showers"
        case 85, 86: return "Snow Showers"
        case 95...99: return "Thunderstorms"
        default: return "—"
        }
    }
}

/// Fetches current conditions from Open-Meteo (free, no API key) for a named city or the Mac's location.
@MainActor
public final class WeatherService: NSObject, ObservableObject, CLLocationManagerDelegate {
    public static let shared = WeatherService()

    @Published public private(set) var report: WeatherReport?
    @Published public private(set) var status: String = "Set a location in Settings"

    private var timer: Timer?
    private var consumers = 0
    private var location: CLLocationManager?
    private var lastCoordinate: CLLocationCoordinate2D?
    private let refreshInterval: TimeInterval = 15 * 60

    public func start() {
        consumers += 1
        guard timer == nil else { return }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: refreshInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    public func stop() {
        consumers = max(0, consumers - 1)
        guard consumers == 0 else { return }
        timer?.invalidate()
        timer = nil
    }

    public func refresh() {
        let settings = PierStore.shared.settings
        if settings.weatherUseLocation {
            requestLocation()
        } else if !settings.weatherCity.trimmingCharacters(in: .whitespaces).isEmpty {
            Task { await fetch(city: settings.weatherCity, unit: settings.temperatureUnit) }
        } else {
            report = nil
            status = "Set a location in Settings"
        }
    }

    private func requestLocation() {
        if location == nil {
            location = CLLocationManager()
            location?.delegate = self
            location?.desiredAccuracy = kCLLocationAccuracyKilometer
        }
        switch location?.authorizationStatus {
        case .notDetermined: location?.requestWhenInUseAuthorization()
        case .denied, .restricted: status = "Location access is off"
        default: location?.requestLocation()
        }
    }

    nonisolated public func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            if manager.authorizationStatus == .authorizedAlways || manager.authorizationStatus == .authorized {
                manager.requestLocation()
            }
        }
    }

    nonisolated public func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }
        Task { @MainActor in
            let unit = PierStore.shared.settings.temperatureUnit
            let name = await Self.placeName(for: loc)
            await self.fetch(lat: loc.coordinate.latitude, lon: loc.coordinate.longitude, place: name, unit: unit)
        }
    }

    nonisolated public func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in self.status = "Location unavailable" }
    }

    private static func placeName(for location: CLLocation) async -> String {
        let marks = try? await CLGeocoder().reverseGeocodeLocation(location)
        return marks?.first?.locality ?? "Here"
    }

    // MARK: Network

    private struct GeoResponse: Decodable {
        struct Result: Decodable { let name: String; let latitude: Double; let longitude: Double }
        let results: [Result]?
    }

    private struct ForecastResponse: Decodable {
        struct Current: Decodable { let temperature_2m: Double; let weather_code: Int; let is_day: Int }
        struct Daily: Decodable { let temperature_2m_max: [Double]; let temperature_2m_min: [Double] }
        let current: Current
        let daily: Daily
    }

    private func fetch(city: String, unit: TemperatureUnit) async {
        var comps = URLComponents(string: "https://geocoding-api.open-meteo.com/v1/search")!
        comps.queryItems = [URLQueryItem(name: "name", value: city), URLQueryItem(name: "count", value: "1")]
        do {
            let (data, _) = try await URLSession.shared.data(from: comps.url!)
            guard let place = try JSONDecoder().decode(GeoResponse.self, from: data).results?.first else {
                status = "Couldn’t find “\(city)”"
                report = nil
                return
            }
            await fetch(lat: place.latitude, lon: place.longitude, place: place.name, unit: unit)
        } catch {
            status = "Weather unavailable"
        }
    }

    private func fetch(lat: Double, lon: Double, place: String, unit: TemperatureUnit) async {
        var comps = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        comps.queryItems = [
            URLQueryItem(name: "latitude", value: String(lat)),
            URLQueryItem(name: "longitude", value: String(lon)),
            URLQueryItem(name: "current", value: "temperature_2m,weather_code,is_day"),
            URLQueryItem(name: "daily", value: "temperature_2m_max,temperature_2m_min"),
            URLQueryItem(name: "forecast_days", value: "1"),
            URLQueryItem(name: "timezone", value: "auto"),
            URLQueryItem(name: "temperature_unit", value: unit.rawValue),
        ]
        do {
            let (data, _) = try await URLSession.shared.data(from: comps.url!)
            let decoded = try JSONDecoder().decode(ForecastResponse.self, from: data)
            report = WeatherReport(
                temperature: decoded.current.temperature_2m,
                high: decoded.daily.temperature_2m_max.first ?? decoded.current.temperature_2m,
                low: decoded.daily.temperature_2m_min.first ?? decoded.current.temperature_2m,
                code: decoded.current.weather_code, isDay: decoded.current.is_day == 1,
                place: place, unit: unit)
            status = ""
        } catch {
            status = "Weather unavailable"
        }
    }
}
