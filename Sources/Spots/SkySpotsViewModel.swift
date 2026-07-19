import CoreLocation
import Foundation
import Observation

/// Drives the Sky Spots tab (replaces the old Rankings tab): "your saved cities, ranked by
/// tonight's stargazing score" plus the curated `SkySpot` atlas's three live-data sections
/// (launch sites, aurora capitals, dark-sky legends). Mirrors the "ViewModels (per screen)"
/// layer `RankingsViewModel`/`SpaceViewModel` already use -- this type owns no networking/math
/// of its own beyond orchestration; every number on screen comes from `Sources/Sky/Spots/
/// SkySpots.swift`'s pure binding functions or the same engines `SpaceViewModel` already calls
/// (`LaunchesUpcoming`, `AuroraService`/`AuroraLikelihood`).
///
/// **One aurora fetch, reused across 8 spots** (work order): `auroraFeedState` holds the single
/// OVATION grid + Kp forecast fetch; `auroraRows` below re-runs `SkySpots.auroraSpotOutlook`
/// against that one cached fetch for each of the 8 aurora-capital spots, rather than fetching
/// per-spot.
@MainActor
@Observable
final class SkySpotsViewModel {

    // MARK: - Your Cities Tonight

    /// One saved city's live-weather load state -- same three-state shape
    /// `RankingsViewModel.RowFetchState` used, kept independent here since this screen only ever
    /// needs today's `DailyEntry`, not the full ranked-row plumbing that type carried.
    enum CityRowState: Equatable {
        case loading
        case loaded(CachedWeather)
        case failed
    }

    private(set) var locations: [SavedLocation] = []
    private(set) var cityRowStates: [UUID: CityRowState] = [:]

    // MARK: - Launch sites (reuses `Sources/Sky/Launches`, same cache `SpaceViewModel` uses)

    enum LaunchesState: Equatable {
        case loading
        case loaded(launches: [UpcomingLaunch], isStale: Bool)
        case unavailable
    }
    private(set) var launchesState: LaunchesState = .loading

    // MARK: - Aurora capitals (one OVATION + Kp fetch, reused across all 8 spots)

    enum AuroraFeedState {
        case loading
        case loaded(grid: AuroraLikelihood.IndexedGrid, kpForecast: [KpForecastRow])
        case unavailable
    }
    private(set) var auroraFeedState: AuroraFeedState = .loading

    private let store: WeatherStore
    /// `-forceDate` sim-verify hook, mirrored from every other tab's view model.
    private let forcedDate: Date?

    /// Same shared `sky/` cache directory `SpaceViewModel` uses for launches/solar -- reusing it
    /// (rather than a Spots-only directory) is what makes this tab's launch/aurora reads genuine
    /// cache hits when the Space tab already populated them this session, per work order ("ONE
    /// fetch, reuse across spots" / "cached LL2 data").
    private nonisolated static var cacheDirectory: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("sky", isDirectory: true)
    }

    init(store: WeatherStore, forcedDate: Date? = nil) {
        self.store = store
        self.forcedDate = forcedDate
    }

    var referenceDate: Date { forcedDate ?? Date() }

    // MARK: - Your Cities Tonight: bootstrap

    /// Called by whoever owns the SwiftData-backed list (`NavigationShell`, mirroring
    /// `RankingsViewModel.applyLocations`/`ForecastViewModel.applyLocations`).
    func applyLocations(_ newLocations: [SavedLocation]) {
        locations = newLocations
        let knownIds = Set(newLocations.map(\.id))
        cityRowStates = cityRowStates.filter { knownIds.contains($0.key) }
        Task { await loadAllCities() }
    }

    private func loadAllCities() async {
        await withTaskGroup(of: Void.self) { group in
            for location in locations {
                group.addTask { await self.loadCity(location) }
            }
        }
    }

    private func loadCity(_ location: SavedLocation) async {
        if let cached = store.cached(for: location.id) {
            cityRowStates[location.id] = .loaded(cached)
        } else if cityRowStates[location.id] == nil {
            cityRowStates[location.id] = .loading
        }
        do {
            let payload = try await store.weather(for: location.id, coordinate: location.coordinate, forceRefresh: false)
            cityRowStates[location.id] = .loaded(payload)
        } catch {
            if store.cached(for: location.id) == nil {
                cityRowStates[location.id] = .failed
            }
            // Otherwise: leave the already-cached `.loaded` state in place -- same "stale data
            // stays visible" rule `RankingsViewModel.load(_:)` documents.
        }
    }

    /// Tonight's stargazing ranking for every saved city with a usable cache -- cities with no
    /// cache yet (never fetched, or fetch failed with nothing to fall back on) are simply
    /// excluded here (work order: "skip cities with no cache, quiet note"); `SkySpotsView` shows
    /// the quiet note when this comes back empty despite `locations` being non-empty.
    var cityRankings: [SkySpots.CityRanking] {
        let inputs: [SkySpots.CityForecastInput] = locations.compactMap { location in
            guard case .loaded(let payload) = cityRowStates[location.id] ?? .loading else { return nil }
            // PRD Section 8 convention (also relied on by `WeatherStore.mergingDailyActuals`):
            // `daily.first` is today's entry.
            guard let today = payload.daily.first else { return nil }
            return SkySpots.CityForecastInput(
                name: location.name,
                latitude: location.latitude,
                longitude: location.longitude,
                conditionCode: today.conditionCode,
                precipChance: today.precipChance
            )
        }
        guard !inputs.isEmpty else { return [] }
        return SkySpots.savedCityRanking(cities: inputs, timeZone: .current, now: referenceDate)
    }

    /// True while at least one saved city's very first load hasn't resolved one way or another
    /// yet -- lets the view show a loading note instead of prematurely claiming "no data."
    var isLoadingAnyCity: Bool {
        locations.contains { cityRowStates[$0.id] == nil || cityRowStates[$0.id] == .loading }
    }

    // MARK: - Launches + aurora (location-independent fetches)

    /// Safe to call every time the tab appears -- both engines' own freshness windows mean
    /// repeat calls are mostly cache hits (same contract as `SpaceViewModel.refresh()`).
    func refresh() async {
        async let launchesTask: Void = loadLaunches()
        async let auroraTask: Void = loadAurora()
        _ = await (launchesTask, auroraTask)
    }

    private func loadLaunches() async {
        do {
            // LL2's upcoming feed is capped at 15 results per fetch (see `LaunchService`'s fixed
            // `limit=15` URL) -- `count: 15` simply asks for everything the cache holds, so every
            // atlas launch site gets a fair shot at a match rather than only the soonest few.
            let result = try await LaunchesUpcoming.nextLaunches(
                cacheDirectory: Self.cacheDirectory, from: referenceDate, count: 15
            )
            launchesState = .loaded(launches: result.launches, isStale: result.isStale)
        } catch {
            launchesState = .unavailable
        }
    }

    private func loadAurora() async {
        let service = AuroraService()
        do {
            async let gridFetch = service.fetchOvationGrid(cacheDirectory: Self.cacheDirectory)
            async let kpFetch = service.fetchKpForecast(cacheDirectory: Self.cacheDirectory)
            let (grid, _) = try await gridFetch
            let (kpRows, _) = try await kpFetch
            auroraFeedState = .loaded(grid: AuroraLikelihood.IndexedGrid(grid: grid), kpForecast: kpRows)
        } catch {
            auroraFeedState = .unavailable
        }
    }

    // MARK: - Launch sites: atlas order, next-launch lookup per spot

    var launchSiteSpots: [SkySpot] {
        SkySpotsAtlas.all.filter { $0.category == .launchSite }
    }

    func nextLaunch(for spot: SkySpot) -> UpcomingLaunch? {
        guard case .loaded(let launches, _) = launchesState else { return nil }
        return SkySpots.launchSiteNext(spot: spot, launches: launches)
    }

    // MARK: - Aurora capitals: one grid/Kp fetch, per-spot outlook, best-first tonight

    struct AuroraSpotRow: Identifiable {
        let spot: SkySpot
        let outlook: AuroraOutlook
        var id: String { spot.id }
    }

    /// Every `auroraSpot` atlas entry with tonight's outlook computed against the one shared
    /// OVATION/Kp fetch, sorted best-first (band descending, ties broken by `chanceNow`
    /// descending, then name) -- work order: "sorted best-first tonight." Empty while the feed is
    /// still loading/unavailable.
    var auroraRows: [AuroraSpotRow] {
        guard case .loaded(let grid, let kpForecast) = auroraFeedState else { return [] }
        let spots = SkySpotsAtlas.all.filter { $0.category == .auroraSpot }
        let rows = spots.map { spot -> AuroraSpotRow in
            let window = Self.nightWindow(for: spot, date: referenceDate)
            let outlook = SkySpots.auroraSpotOutlook(
                spot: spot,
                grid: grid,
                kpForecast: kpForecast,
                darkHoursStart: window.start,
                darkHoursEnd: window.end
            )
            return AuroraSpotRow(spot: spot, outlook: outlook)
        }
        return rows.sorted { lhs, rhs in
            if lhs.outlook.band != rhs.outlook.band { return lhs.outlook.band > rhs.outlook.band }
            if lhs.outlook.chanceNow != rhs.outlook.chanceNow { return lhs.outlook.chanceNow > rhs.outlook.chanceNow }
            return lhs.spot.name.localizedStandardCompare(rhs.spot.name) == .orderedAscending
        }
    }

    /// This calendar night's dark-hours window (this day's civil dusk -> next day's civil dawn)
    /// at `spot`'s own coordinates -- same "tonight" convention `SkySpots.darkSkyTonight` and
    /// `BestNight.computeNight` already use, duplicated here (a small, already-twice-duplicated
    /// pure calc in this codebase) since `SkySpots.auroraSpotOutlook` needs the window as an
    /// explicit parameter rather than computing it internally.
    private static func nightWindow(for spot: SkySpot, date: Date) -> (start: Date, end: Date) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        let day = calendar.startOfDay(for: date)

        let sunToday = SunMoon.sunTimes(after: day, lat: spot.latitude, lon: spot.longitude)
        let nightStart = sunToday.civilDusk ?? calendar.date(byAdding: .hour, value: 21, to: day) ?? day
        let nextDay = calendar.date(byAdding: .day, value: 1, to: day) ?? day.addingTimeInterval(86400)
        let sunTomorrow = SunMoon.sunTimes(after: nextDay, lat: spot.latitude, lon: spot.longitude)
        let nightEnd = sunTomorrow.civilDawn ?? calendar.date(byAdding: .hour, value: 6, to: nextDay) ?? nextDay
        return (nightStart, nightEnd)
    }

    // MARK: - Dark sky legends: pure per-spot moon note, no fetch

    struct DarkSkySpotRow: Identifiable {
        let spot: SkySpot
        let tonight: SkySpots.DarkSkyTonight
        var id: String { spot.id }
    }

    /// Atlas order (not re-sorted) -- work order lists these as "the 10 parks," not a ranking.
    var darkSkyRows: [DarkSkySpotRow] {
        SkySpotsAtlas.all
            .filter { $0.category == .darkSky }
            .map { DarkSkySpotRow(spot: $0, tonight: SkySpots.darkSkyTonight(spot: $0, date: referenceDate)) }
    }

    // MARK: - Distance from the user's first saved city

    /// Great-circle distance (km) between the user's first saved city and `spot`, or `nil` if
    /// there's no saved city yet to measure from. `SkySpotsView` converts to mi/km for display.
    func distanceKm(to spot: SkySpot) -> Double? {
        guard let origin = locations.first else { return nil }
        return Self.haversineKm(
            lat1: origin.latitude, lon1: origin.longitude,
            lat2: spot.latitude, lon2: spot.longitude
        )
    }

    private static func haversineKm(lat1: Double, lon1: Double, lat2: Double, lon2: Double) -> Double {
        let earthRadiusKm = 6371.0
        let dLat = (lat2 - lat1) * .pi / 180
        let dLon = (lon2 - lon1) * .pi / 180
        let a = sin(dLat / 2) * sin(dLat / 2)
            + cos(lat1 * .pi / 180) * cos(lat2 * .pi / 180) * sin(dLon / 2) * sin(dLon / 2)
        let c = 2 * atan2(sqrt(a), sqrt(1 - a))
        return earthRadiusKm * c
    }
}
