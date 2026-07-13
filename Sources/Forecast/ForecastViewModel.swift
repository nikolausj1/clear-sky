import CoreLocation
import Foundation
import Observation

/// Drives the Forecast screen (`ForecastView`) from `WeatherStore`, per PRD Section 6/9's
/// "ViewModels (per screen)" layer. Holds the active location, the current `CachedWeather`,
/// and the view-state enum the screen switches on.
///
/// Since Locations (Phase 3) isn't built yet, the active location for this phase is always the
/// hardcoded Tomah, WI coordinate — this also happens to satisfy the PRD's
/// "location-permission-denied" state (Section 6 state table: "Fully usable via a
/// searched/saved city"), since the app never has to depend on CoreLocation to be useful yet.
@MainActor
@Observable
final class ForecastViewModel {
    enum ScreenState: Equatable {
        case loading
        case error(String)
        case loaded
    }

    /// Sim-verify hook (Project Build Guide's autostart-hook pattern — simctl can't tap
    /// through a UI to reach every state manually). `-forceState loading|error|stale|alert|normal`.
    enum ForcedState: String {
        case loading
        case error
        case stale
        case alert
        case normal
    }

    static let defaultLocationId = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    static let defaultCoordinate = CLLocationCoordinate2D(latitude: 43.9814, longitude: -90.5040)
    static let defaultLocationName = "Tomah"

    private(set) var screenState: ScreenState = .loading
    private(set) var payload: CachedWeather?
    private(set) var cacheState: WeatherStore.CacheState = .missing
    var isRefreshing = false
    var selectedMetric: ForecastMetric = .temp
    var expandedDayId: Date?

    let locationName: String
    private let locationId: UUID
    private let coordinate: CLLocationCoordinate2D
    private let store: WeatherStore
    private let forcedState: ForcedState?
    private let initialExpandDayIndex: Int?
    private var hasAppliedInitialExpand = false

    init(
        store: WeatherStore,
        locationName: String = ForecastViewModel.defaultLocationName,
        locationId: UUID = ForecastViewModel.defaultLocationId,
        coordinate: CLLocationCoordinate2D = ForecastViewModel.defaultCoordinate,
        forcedState: ForcedState? = nil,
        initialExpandDayIndex: Int? = nil,
        initialMetric: ForecastMetric? = nil
    ) {
        self.store = store
        self.locationName = locationName
        self.locationId = locationId
        self.coordinate = coordinate
        self.forcedState = forcedState
        self.initialExpandDayIndex = initialExpandDayIndex
        if let initialMetric {
            self.selectedMetric = initialMetric
        }
    }

    func load() async {
        await fetch(forceRefresh: false)
    }

    /// Pull-to-refresh entry point: forces `WeatherStore` to re-fetch regardless of cache age.
    /// Stale data stays visible throughout (PRD Section 6: "A refresh in flight never blanks
    /// existing data").
    func refresh() async {
        isRefreshing = true
        await fetch(forceRefresh: true)
        isRefreshing = false
    }

    private func fetch(forceRefresh: Bool) async {
        if forcedState == .loading {
            // Frozen on purpose: this forced state exists solely to screenshot the
            // first-launch/no-cache loading screen.
            screenState = .loading
            return
        }

        if forcedState == .error {
            screenState = .error(
                "Weather fetch failed: forced via -forceState error (simulating a WeatherKit "
                    + "failure with no usable cache)."
            )
            return
        }

        if payload == nil {
            screenState = .loading
        }

        do {
            var result = try await store.weather(for: locationId, coordinate: coordinate, forceRefresh: forceRefresh)
            var effectiveCacheState = store.cacheState(for: locationId)

            if forcedState == .alert {
                result.activeAlerts = [Self.forcedAlert()] + result.activeAlerts
            }
            if forcedState == .stale {
                // Simulated staleness: real data, artificially aged `fetchedAt` so the "as of"
                // banner renders without needing to wait 30 minutes or go offline in the sim.
                result.fetchedAt = Date().addingTimeInterval(-2 * 60 * 60)
                effectiveCacheState = .stale
            }

            payload = result
            cacheState = effectiveCacheState
            screenState = .loaded
            applyInitialExpandIfNeeded(result)
        } catch {
            if payload != nil {
                // Offline/stale-cache path (PRD Section 6): keep showing what we have.
                cacheState = .stale
                screenState = .loaded
            } else {
                screenState = .error((error as? LocalizedError)?.errorDescription ?? String(reflecting: error))
            }
        }
    }

    private func applyInitialExpandIfNeeded(_ payload: CachedWeather) {
        guard !hasAppliedInitialExpand, let index = initialExpandDayIndex, payload.daily.indices.contains(index) else { return }
        expandedDayId = payload.daily[index].date
        hasAppliedInitialExpand = true
    }

    /// A representative alert for `-forceState alert` sim-verify screenshots. Not real
    /// WeatherKit data — used only because Tomah, WI rarely has an active alert on demand.
    private static func forcedAlert() -> AlertSummary {
        AlertSummary(
            severityCode: "severe",
            severityDescription: "Severe",
            title: "Heat Advisory",
            agencyText: "The National Weather Service has issued a Heat Advisory for this area, "
                + "in effect until further notice. Heat index values up to 105\u{00B0}F expected. "
                + "Drink plenty of fluids, stay in an air-conditioned room if possible, and check "
                + "on relatives and neighbors. (Forced test alert for -forceState alert.)",
            region: "Monroe County, WI",
            effectiveDate: Date(),
            expirationDate: Date().addingTimeInterval(6 * 60 * 60),
            detailsURL: URL(string: "https://www.weather.gov")!
        )
    }
}
