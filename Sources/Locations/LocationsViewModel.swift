import CoreLocation
import Foundation
import MapKit
import Observation

/// Drives the Locations screen (PRD Screen B). Owns search (via `LocationSearchService`),
/// the current-location row (via `CurrentLocationManager`), and saved-location CRUD (via
/// `LocationsStore`). Any change to the saved-locations list is pushed out through
/// `onLocationsChanged` so the Forecast pager (`ForecastViewModel`) stays in sync — Locations is
/// the writer, Forecast is a reader of the same underlying SwiftData rows.
@MainActor
@Observable
final class LocationsViewModel {
    enum RowFetchState: Equatable {
        case loading
        case loaded(CachedWeather)
        case failed
    }

    private(set) var savedLocations: [SavedLocation] = []
    private(set) var rowStates: [UUID: RowFetchState] = [:]

    var searchText: String = "" {
        didSet {
            guard searchText != oldValue else { return }
            searchService.updateQuery(searchText)
        }
    }
    var isAddingLocation = false
    var addLocationError: String?

    let locationManager: CurrentLocationManager
    let searchService: LocationSearchService
    let networkMonitor: NetworkMonitor

    private let store: LocationsStore
    private let weatherStore: WeatherStore
    private let onLocationsChanged: (_ locations: [SavedLocation], _ preferredActiveId: UUID?) -> Void
    private var hasRequestedCurrentLocation = false
    private var lastResolvedCurrentCoordinate: CLLocationCoordinate2D?

    var suggestions: [MKLocalSearchCompletion] { searchService.suggestions }
    var isOffline: Bool { !networkMonitor.isConnected }

    init(
        store: LocationsStore,
        weatherStore: WeatherStore,
        locationManager: CurrentLocationManager,
        searchService: LocationSearchService,
        networkMonitor: NetworkMonitor,
        onLocationsChanged: @escaping (_ locations: [SavedLocation], _ preferredActiveId: UUID?) -> Void
    ) {
        self.store = store
        self.weatherStore = weatherStore
        self.locationManager = locationManager
        self.searchService = searchService
        self.networkMonitor = networkMonitor
        self.onLocationsChanged = onLocationsChanged
        refreshSavedLocations()
    }

    /// Called from the Locations screen's `.task` on first appearance — this, not app launch,
    /// is the contextual moment PRD Section 9 requires for the CoreLocation permission prompt.
    func onAppear() async {
        if !hasRequestedCurrentLocation {
            hasRequestedCurrentLocation = true
            locationManager.requestAuthorizationAndLocation()
        }
        await refreshAllRowWeather(forceRefresh: false)
    }

    /// Explicit "Use current location" affordance — same contextual-request rule applies, so
    /// this is safe to call even if `onAppear` hasn't fired yet.
    func requestCurrentLocation() {
        hasRequestedCurrentLocation = true
        locationManager.requestAuthorizationAndLocation()
    }

    /// Call when `locationManager.coordinate` changes (observed by the view via `.onChange`,
    /// since `CurrentLocationManager` is a plain delegate-driven object, not a publisher this
    /// view model subscribes to). Resolves a display name, upserts the SwiftData row, and fetches
    /// its weather.
    func currentLocationCoordinateResolved(_ coordinate: CLLocationCoordinate2D) async {
        guard lastResolvedCurrentCoordinate == nil || !Self.isSameCoordinate(lastResolvedCurrentCoordinate!, coordinate) else { return }
        lastResolvedCurrentCoordinate = coordinate
        let name = await CurrentLocationManager.displayName(for: coordinate)
        let location = store.upsertCurrentLocation(name: name, coordinate: coordinate)
        refreshSavedLocations()
        await fetchWeather(for: location, forceRefresh: false)
        publishLocationsChange(preferredActiveId: nil)
    }

    func refreshSavedLocations() {
        savedLocations = store.fetchAll()
    }

    func addOrSwitch(to resolved: LocationSearchService.ResolvedLocation) {
        let location = store.addOrFind(name: resolved.name, coordinate: resolved.coordinate)
        refreshSavedLocations()
        searchText = ""
        searchService.clear()
        Task { await fetchWeather(for: location, forceRefresh: false) }
        publishLocationsChange(preferredActiveId: location.id)
    }

    func selectSuggestion(_ completion: MKLocalSearchCompletion) async {
        isAddingLocation = true
        addLocationError = nil
        defer { isAddingLocation = false }
        do {
            let resolved = try await searchService.resolve(completion)
            addOrSwitch(to: resolved)
        } catch {
            addLocationError = error.localizedDescription
        }
    }

    /// Tapping a saved row: makes it the active Forecast location and signals the caller to
    /// dismiss the sheet (PRD Screen B: "Tapping any saved location makes it the active location
    /// on the Forecast screen").
    func select(_ location: SavedLocation) {
        publishLocationsChange(preferredActiveId: location.id)
    }

    func delete(at offsets: IndexSet) {
        let manual = manualLocations
        for index in offsets {
            guard manual.indices.contains(index) else { continue }
            store.delete(manual[index])
        }
        refreshSavedLocations()
        publishLocationsChange(preferredActiveId: nil)
    }

    func move(from source: IndexSet, to destination: Int) {
        var manual = manualLocations
        manual.move(fromOffsets: source, toOffset: destination)
        store.reorder(manual)
        refreshSavedLocations()
        publishLocationsChange(preferredActiveId: nil)
    }

    /// Saved locations excluding the current-location row — the reorderable/deletable subset
    /// (PRD Section 8: current-location entries are "excluded from manual reorder/delete").
    var manualLocations: [SavedLocation] {
        savedLocations.filter { !$0.isCurrentLocation }
    }

    var currentLocationEntry: SavedLocation? {
        savedLocations.first { $0.isCurrentLocation }
    }

    func rowState(for location: SavedLocation) -> RowFetchState {
        rowStates[location.id] ?? .loading
    }

    func retryRow(_ location: SavedLocation) {
        Task { await fetchWeather(for: location, forceRefresh: true) }
    }

    private func refreshAllRowWeather(forceRefresh: Bool) async {
        await withTaskGroup(of: Void.self) { group in
            for location in savedLocations {
                group.addTask { await self.fetchWeather(for: location, forceRefresh: forceRefresh) }
            }
        }
    }

    private func fetchWeather(for location: SavedLocation, forceRefresh: Bool) async {
        if let cached = weatherStore.cached(for: location.id), !forceRefresh {
            rowStates[location.id] = .loaded(cached)
        } else {
            rowStates[location.id] = .loading
        }
        guard networkMonitor.isConnected || weatherStore.cached(for: location.id) == nil else {
            return
        }
        do {
            let payload = try await weatherStore.weather(for: location.id, coordinate: location.coordinate, forceRefresh: forceRefresh)
            rowStates[location.id] = .loaded(payload)
        } catch {
            if let cached = weatherStore.cached(for: location.id) {
                rowStates[location.id] = .loaded(cached)
            } else {
                rowStates[location.id] = .failed
            }
        }
    }

    private func publishLocationsChange(preferredActiveId: UUID?) {
        onLocationsChanged(savedLocations, preferredActiveId)
    }

    private static func isSameCoordinate(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Bool {
        abs(a.latitude - b.latitude) < 0.0001 && abs(a.longitude - b.longitude) < 0.0001
    }
}
