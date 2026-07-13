import CoreLocation
import Observation

/// Wraps `CLLocationManager` for the Locations screen's "current location" row (PRD Screen B /
/// Section 9). Permission is requested **contextually only** — callers must call
/// `requestAuthorizationAndLocation()` themselves (from the Locations screen's first
/// appearance, or an explicit "Use current location" affordance); this type never requests
/// anything on its own at init, so simply constructing it at app launch cannot trigger the
/// system permission prompt.
///
/// `forcedDenied` is the `-locationDenied` sim-verify launch-arg hook (Project Build Guide's
/// autostart-hook pattern): `simctl` can revoke location permission for real
/// (`simctl privacy ... reset location`), but forcing the state via launch argument is the
/// reliable path for repeatable screenshots per the Phase 3 build brief.
///
/// `forcedAuthorizedCoordinate` (`-locationGranted`) is the same idea in reverse: on this
/// project's Xcode 26.6 / iOS 26.5 Simulator pairing, `simctl privacy grant location` does not
/// reliably suppress the system "Allow Once / Allow While Using App" alert (confirmed by direct
/// testing — the alert re-appears on every fresh launch regardless), and `simctl` cannot tap
/// through that alert. Forcing the authorized state via launch argument sidesteps the same
/// simulator limitation `-locationDenied` was already added to work around, for a clean
/// sim-verify screenshot of the granted current-location row. The real contextual-request path
/// (`requestAuthorizationAndLocation()` calling the actual `CLLocationManager`) is unchanged and
/// is what runs on a real device or an un-flagged sim launch.
@MainActor
@Observable
final class CurrentLocationManager: NSObject, CLLocationManagerDelegate {
    enum Status: Equatable {
        case notDetermined
        case authorized
        case denied
    }

    private(set) var status: Status
    private(set) var coordinate: CLLocationCoordinate2D?
    private(set) var isResolving = false
    private(set) var lastError: String?
    /// `CLLocationCoordinate2D` isn't `Equatable`, so views that need to react to a *new*
    /// resolved coordinate (via SwiftUI's `.onChange`) observe this counter instead — it
    /// increments every time `coordinate` is updated.
    private(set) var coordinateUpdateToken = 0

    private let manager = CLLocationManager()
    private let forcedDenied: Bool
    private let forcedAuthorizedCoordinate: CLLocationCoordinate2D?

    init(forcedDenied: Bool = false, forcedAuthorizedCoordinate: CLLocationCoordinate2D? = nil) {
        self.forcedDenied = forcedDenied
        self.forcedAuthorizedCoordinate = forcedAuthorizedCoordinate
        let initialManager = CLLocationManager()
        if forcedDenied {
            self.status = .denied
        } else if let forcedAuthorizedCoordinate {
            self.status = .authorized
            self.coordinate = forcedAuthorizedCoordinate
        } else {
            self.status = Self.mapStatus(initialManager.authorizationStatus)
        }
        super.init()
        manager.delegate = self
    }

    /// Entry point for the Locations screen. Safe to call repeatedly (e.g. every time the
    /// screen appears) — it only prompts the system dialog once, on the first `.notDetermined`
    /// call; subsequent calls just re-resolve a location if already authorized.
    func requestAuthorizationAndLocation() {
        guard forcedAuthorizedCoordinate == nil else {
            // Already authorized + resolved at init; bump the token so observers (which fire
            // from `.onChange`, i.e. after the first appearance) still see the update once.
            coordinateUpdateToken += 1
            return
        }
        guard !forcedDenied else {
            status = .denied
            return
        }
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse, .authorizedAlways:
            status = .authorized
            resolveLocation()
        case .denied, .restricted:
            status = .denied
        @unknown default:
            status = .denied
        }
    }

    private func resolveLocation() {
        isResolving = true
        manager.requestLocation()
    }

    // MARK: - CLLocationManagerDelegate

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        // iOS calls this once immediately after `manager.delegate = self` is set, reporting the
        // *real* current status — which would otherwise clobber a forced sim-verify state right
        // after `init` runs, since this fires asynchronously just after construction.
        let authorizationStatus = manager.authorizationStatus
        Task { @MainActor in
            guard !self.forcedDenied, self.forcedAuthorizedCoordinate == nil else { return }
            let mapped = Self.mapStatus(authorizationStatus)
            self.status = mapped
            if mapped == .authorized {
                self.resolveLocation()
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        Task { @MainActor in
            self.coordinate = location.coordinate
            self.coordinateUpdateToken += 1
            self.isResolving = false
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in
            self.isResolving = false
            self.lastError = error.localizedDescription
        }
    }

    private static func mapStatus(_ status: CLAuthorizationStatus) -> Status {
        switch status {
        case .authorizedAlways, .authorizedWhenInUse: return .authorized
        case .denied, .restricted: return .denied
        case .notDetermined: return .notDetermined
        @unknown default: return .denied
        }
    }

    /// Best-effort "City, ST" reverse geocode for the current-location row's display name.
    static func displayName(for coordinate: CLLocationCoordinate2D) async -> String {
        let geocoder = CLGeocoder()
        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        guard let placemark = try? await geocoder.reverseGeocodeLocation(location).first else {
            return "Current Location"
        }
        if let locality = placemark.locality {
            if let admin = placemark.administrativeArea {
                return "\(locality), \(admin)"
            }
            return locality
        }
        return placemark.name ?? "Current Location"
    }
}
