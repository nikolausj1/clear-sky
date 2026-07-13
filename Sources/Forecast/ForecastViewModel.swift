import CoreLocation
import Foundation
import Observation

/// Drives the Forecast screen (`ForecastView`) from `WeatherStore`, per PRD Section 6/9's
/// "ViewModels (per screen)" layer.
///
/// Phase 3 rewrite: this now holds an **ordered list of locations and an active index** (PRD
/// Section 6, Screen B: "The Forecast screen also supports horizontal swipe to page between
/// saved locations"), instead of a single hardcoded Tomah, WI location. Each location gets its
/// own `PageState` (screen state / payload / cache state), keyed by `SavedLocation.id`, so
/// switching pages shows that page's already-cached data immediately while a refresh happens in
/// the background — the Locations screen (`LocationsViewModel`) is the writer of the underlying
/// SwiftData rows; this view model is a reader that also owns the paging UI state.
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

    struct PageState {
        var screenState: ScreenState = .loading
        var payload: CachedWeather?
        var cacheState: WeatherStore.CacheState = .missing
        var isRefreshing = false
    }

    /// Phase 2's hardcoded default — kept as the fallback location so `-forceState` sim-verify
    /// screenshots (which don't pass `-seedLocations`) keep working unchanged even though the
    /// app no longer hardcodes Tomah for normal use.
    static let defaultLocationId = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    static let defaultCoordinate = CLLocationCoordinate2D(latitude: 43.9814, longitude: -90.5040)
    static let defaultLocationName = "Tomah"

    private(set) var locations: [SavedLocation] = []
    var activeIndex: Int = 0 {
        didSet {
            guard activeIndex != oldValue else { return }
            persistActiveLocationId()
        }
    }

    private(set) var pageStates: [UUID: PageState] = [:]
    var selectedMetric: ForecastMetric = .temp
    var expandedDayId: Date?

    private let store: WeatherStore
    private let forcedState: ForcedState?
    private let initialExpandDayIndex: Int?
    private var hasAppliedInitialExpand = false
    private static let activeLocationIdDefaultsKey = "clearSky.activeLocationId"

    init(
        store: WeatherStore,
        forcedState: ForcedState? = nil,
        initialExpandDayIndex: Int? = nil,
        initialMetric: ForecastMetric? = nil
    ) {
        self.store = store
        self.forcedState = forcedState
        self.initialExpandDayIndex = initialExpandDayIndex
        if let initialMetric {
            self.selectedMetric = initialMetric
        }
    }

    // MARK: - Active-page convenience passthroughs (most of ForecastView reads these)

    var activeLocation: SavedLocation? {
        locations.indices.contains(activeIndex) ? locations[activeIndex] : nil
    }

    var locationName: String {
        activeLocation?.name ?? Self.defaultLocationName
    }

    var screenState: ScreenState {
        state(for: activeLocation).screenState
    }

    var payload: CachedWeather? {
        state(for: activeLocation).payload
    }

    var cacheState: WeatherStore.CacheState {
        state(for: activeLocation).cacheState
    }

    var isRefreshing: Bool {
        state(for: activeLocation).isRefreshing
    }

    func state(for location: SavedLocation?) -> PageState {
        guard let location else { return PageState() }
        return pageStates[location.id] ?? PageState()
    }

    // MARK: - Locations sync (called by whoever owns the SwiftData-backed list, e.g. the
    // Navigation shell at launch and `LocationsViewModel` after any add/remove/reorder)

    /// Replaces the ordered locations list. `preferredActiveId`, when it matches a location in
    /// the new list, becomes the active page (e.g. the user just tapped or added that location);
    /// otherwise the previously-active location is preserved by id if it still exists.
    func applyLocations(_ newLocations: [SavedLocation], preferredActiveId: UUID? = nil) {
        let previousActiveId = activeLocation?.id

        if newLocations.isEmpty, forcedState != nil {
            // `-forceState` sim-verify screenshots predate the saved-locations system and don't
            // pass `-seedLocations`; fall back to the Phase 2 default so those screenshots keep
            // working unchanged.
            locations = [
                SavedLocation(
                    id: Self.defaultLocationId,
                    name: Self.defaultLocationName,
                    latitude: Self.defaultCoordinate.latitude,
                    longitude: Self.defaultCoordinate.longitude,
                    sortOrder: 0
                )
            ]
        } else {
            locations = newLocations
        }

        if let preferredActiveId, let index = locations.firstIndex(where: { $0.id == preferredActiveId }) {
            activeIndex = index
        } else if let previousActiveId, let index = locations.firstIndex(where: { $0.id == previousActiveId }) {
            activeIndex = index
        } else if let storedId = restoredActiveLocationId(), let index = locations.firstIndex(where: { $0.id == storedId }) {
            activeIndex = index
        } else {
            activeIndex = locations.isEmpty ? 0 : min(activeIndex, locations.count - 1)
        }

        Task { await loadAllPages() }
    }

    private func restoredActiveLocationId() -> UUID? {
        guard let raw = UserDefaults.standard.string(forKey: Self.activeLocationIdDefaultsKey) else { return nil }
        return UUID(uuidString: raw)
    }

    private func persistActiveLocationId() {
        guard let id = activeLocation?.id else { return }
        UserDefaults.standard.set(id.uuidString, forKey: Self.activeLocationIdDefaultsKey)
    }

    // MARK: - Loading

    func loadAllPages() async {
        await withTaskGroup(of: Void.self) { group in
            for location in locations {
                group.addTask { await self.load(location: location, forceRefresh: false) }
            }
        }
    }

    /// Pull-to-refresh entry point for the active page: forces `WeatherStore` to re-fetch
    /// regardless of cache age. Stale data stays visible throughout (PRD Section 6: "A refresh
    /// in flight never blanks existing data").
    func refreshActive() async {
        guard let location = activeLocation else { return }
        var current = state(for: location)
        current.isRefreshing = true
        pageStates[location.id] = current
        await load(location: location, forceRefresh: true)
        current = state(for: location)
        current.isRefreshing = false
        pageStates[location.id] = current
    }

    func load(location: SavedLocation, forceRefresh: Bool) async {
        var page = pageStates[location.id] ?? PageState()

        if forcedState == .loading {
            // Frozen on purpose: this forced state exists solely to screenshot the
            // first-launch/no-cache loading screen.
            page.screenState = .loading
            pageStates[location.id] = page
            return
        }

        if forcedState == .error {
            page.screenState = .error(
                "Weather fetch failed: forced via -forceState error (simulating a WeatherKit "
                    + "failure with no usable cache)."
            )
            pageStates[location.id] = page
            return
        }

        if page.payload == nil {
            // Show cached data immediately if present (PRD Screen B: paging "should switch to
            // the paged location's cached data immediately then refresh").
            if let cached = store.cached(for: location.id) {
                page.payload = cached
                page.cacheState = store.cacheState(for: location.id)
                page.screenState = .loaded
            } else {
                page.screenState = .loading
            }
            pageStates[location.id] = page
        }

        do {
            var result = try await store.weather(for: location.id, coordinate: location.coordinate, forceRefresh: forceRefresh)
            var effectiveCacheState = store.cacheState(for: location.id)

            if forcedState == .alert {
                result.activeAlerts = [Self.forcedAlert()] + result.activeAlerts
            }
            if forcedState == .stale {
                // Simulated staleness: real data, artificially aged `fetchedAt` so the "as of"
                // banner renders without needing to wait 30 minutes or go offline in the sim.
                result.fetchedAt = Date().addingTimeInterval(-2 * 60 * 60)
                effectiveCacheState = .stale
            }

            page.payload = result
            page.cacheState = effectiveCacheState
            page.screenState = .loaded
            pageStates[location.id] = page
            applyInitialExpandIfNeeded(result, isActive: location.id == activeLocation?.id)
        } catch {
            if page.payload != nil {
                // Offline/stale-cache path (PRD Section 6): keep showing what we have.
                page.cacheState = .stale
                page.screenState = .loaded
            } else {
                page.screenState = .error((error as? LocalizedError)?.errorDescription ?? String(reflecting: error))
            }
            pageStates[location.id] = page
        }
    }

    private func applyInitialExpandIfNeeded(_ payload: CachedWeather, isActive: Bool) {
        guard isActive, !hasAppliedInitialExpand, let index = initialExpandDayIndex, payload.daily.indices.contains(index) else { return }
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
