import CoreLocation
import SwiftUI

/// Finds the user's city once, on request, and saves it. Nothing keeps tracking the location afterwards:
/// the saved city and coordinates are used until the city is changed by hand.
@MainActor
final class WeatherLocator: NSObject, ObservableObject, CLLocationManagerDelegate {
    static let shared = WeatherLocator()

    enum State: Equatable {
        case idle
        case working
        case done(String)
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    private let manager = CLLocationManager()

    private override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
    }

    var isWorking: Bool { state == .working }

    func locate() {
        guard state != .working else { return }
        state = .working
        NSApp.activate()
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .denied, .restricted:
            state = .failed("Location access is off for Indra. Turn it on in System Settings, Privacy & Security, Location Services.")
        default:
            manager.requestLocation()
        }
        // Never stay on "Locating..." forever.
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 25_000_000_000)
            guard let self, self.state == .working else { return }
            self.state = .failed("Could not get your location. Try again, or type your city.")
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor [weak self] in
            guard let self, self.state == .working else { return }
            switch status {
            case .notDetermined:
                break
            case .denied, .restricted:
                self.state = .failed("Location access was not allowed. You can type your city instead.")
            default:
                self.manager.requestLocation()
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        CLGeocoder().reverseGeocodeLocation(location) { placemarks, _ in
            let place = placemarks?.first
            let city = place?.locality ?? place?.subAdministrativeArea ?? place?.administrativeArea ?? "My location"
            let latitude = location.coordinate.latitude
            let longitude = location.coordinate.longitude
            Task { @MainActor [weak self] in
                guard let self, self.state == .working else { return }
                Preferences.saveWeatherLocation(city: city, latitude: latitude, longitude: longitude)
                self.state = .done(city)
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor [weak self] in
            guard let self, self.state == .working else { return }
            self.state = .failed("Could not get your location. Try again, or type your city.")
        }
    }
}
