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

    /// Phase 4 sim-verify hooks (Project Build Guide's autostart-hook pattern): `-forceCondition
    /// clear|cloudy|rain|snow|fog|wind|storm` and `-forceTempBand cold|mild|hot` override which
    /// phrase-bank bucket `summaryLine`/`doodleCaptionLine` query, without touching the actual
    /// fetched numbers on screen — `simctl` can't force real distinct WeatherKit conditions on
    /// demand, so this is how a screenshot shows the rain/snow/hot/cold copy specifically.
    /// `-forceDate YYYY-MM-DD` overrides the date fed into the phrase bank's rotation (which
    /// variant of a bucket shows), for verifying rotation without waiting real days.
    private let forcedCondition: PhraseBank.ConditionGroup?
    private let forcedTempBand: PhraseBank.TempBand?
    private let forcedDate: Date?
    /// `-forceComparisonDelta <signed integer>` — sim-verify only. Real `dailyActuals` history
    /// only exists after the app has genuinely been used on a prior calendar day (Phase 3's
    /// `WeatherStore` builds it from real fetches), so a fresh sim install has no yesterday to
    /// compare against and `comparisonLine` correctly returns `nil`. This hook synthesizes a
    /// single "yesterday" `DailyActual` (today's high minus this delta) so `phase4-comparison
    /// .png` can show a warmer/cooler line without waiting real days.
    private let forcedComparisonDelta: Double?

    init(
        store: WeatherStore,
        forcedState: ForcedState? = nil,
        initialExpandDayIndex: Int? = nil,
        initialMetric: ForecastMetric? = nil,
        forcedCondition: PhraseBank.ConditionGroup? = nil,
        forcedTempBand: PhraseBank.TempBand? = nil,
        forcedDate: Date? = nil,
        forcedComparisonDelta: Double? = nil
    ) {
        self.store = store
        self.forcedState = forcedState
        self.initialExpandDayIndex = initialExpandDayIndex
        self.forcedCondition = forcedCondition
        self.forcedTempBand = forcedTempBand
        self.forcedDate = forcedDate
        self.forcedComparisonDelta = forcedComparisonDelta
        if let initialMetric {
            self.selectedMetric = initialMetric
        }
    }

    /// The date used for phrase-bank rotation (which variant of a bucket shows today) — real
    /// "now" unless overridden by `-forceDate` for sim-verify. Deliberately separate from the
    /// *data* dates in `payload.daily`/`payload.dailyActuals` (those always reflect whatever
    /// WeatherKit/the cache actually returned) — this only controls which pre-written line
    /// rotation lands on, not which day's forecast is being described.
    var phraseBankDate: Date {
        forcedDate ?? Date()
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
            if let forcedComparisonDelta, let today = result.daily.first {
                let calendar = Calendar.current
                let yesterday = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: today.date)) ?? today.date
                let todayHighF = today.high.converted(to: .fahrenheit).value
                let yesterdayHighF = todayHighF - forcedComparisonDelta
                result.dailyActuals.removeAll { calendar.isDate($0.date, inSameDayAs: yesterday) }
                result.dailyActuals.append(
                    DailyActual(
                        date: yesterday,
                        observedHigh: Measurement(value: yesterdayHighF, unit: .fahrenheit),
                        observedLow: Measurement(value: yesterdayHighF - 15, unit: .fahrenheit),
                        dominantConditionCode: today.conditionCode,
                        dominantConditionDescription: today.conditionDescription
                    )
                )
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

// MARK: - Phrase bank (Phase 4)
//
// PRD Section 6, items 1/4/5: the doodle caption, dry-wit summary line, and comparison line.
// These are pure functions of (location, payload, unit) plus the forced-state hooks above —
// no stored phrase-bank state lives on the view model itself, so paging between locations
// never needs to invalidate/recompute anything eagerly; `ForecastPageView` just calls these
// on render.
extension ForecastViewModel {
    /// PRD Section 6, item 4: "Dry-wit summary line - plain-language read on the day's
    /// conditions from the phrase bank."
    func summaryLine(location: SavedLocation, payload: CachedWeather, unit: TemperatureUnit) -> String {
        PhraseBank.summary(
            condition: effectiveConditionGroup(for: payload),
            tempBand: effectiveTempBand(for: payload),
            date: phraseBankDate,
            locationId: location.id,
            tokens: phraseTokens(location: location, payload: payload, unit: unit)
        )
    }

    /// PRD Section 6, item 1: the doodle header's "one-line dry-wit caption keyed to date +
    /// current conditions."
    func doodleCaptionLine(location: SavedLocation, payload: CachedWeather, unit: TemperatureUnit) -> String {
        PhraseBank.doodleCaption(
            condition: effectiveConditionGroup(for: payload),
            tempBand: effectiveTempBand(for: payload),
            date: phraseBankDate,
            locationId: location.id,
            tokens: phraseTokens(location: location, payload: payload, unit: unit)
        )
    }

    /// PRD Section 6, item 5: "Data source: WeatherKit's historical/daily comparison data
    /// where available, with yesterday's cached actuals (`CachedWeather.dailyActuals`) as the
    /// fallback; if neither exists yet (first day of use), the line is omitted rather than
    /// faked." WeatherKit's native framework has no simple "yesterday's observed weather" API
    /// distinct from the forward-looking daily forecast, so in practice this app has only ever
    /// had the `dailyActuals` fallback to implement (Phase 3's `WeatherStore` already builds
    /// that rolling history from each day's fetch) — there is no separate "historical
    /// comparison" primary source to wire up. Returns `nil` (render nothing) whenever
    /// yesterday's actual isn't in the rolling window yet.
    func comparisonLine(location: SavedLocation, payload: CachedWeather, unit: TemperatureUnit) -> String? {
        guard let today = payload.daily.first else { return nil }
        let calendar = Calendar.current
        guard let yesterday = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: today.date)) else { return nil }
        guard let yesterdayActual = payload.dailyActuals.first(where: { calendar.isDate($0.date, inSameDayAs: yesterday) }) else {
            return nil
        }

        let todayHighF = today.high.converted(to: .fahrenheit).value
        let yesterdayHighF = yesterdayActual.observedHigh.converted(to: .fahrenheit).value
        let deltaF = (todayHighF - yesterdayHighF).rounded()

        let direction: PhraseBank.ComparisonDirection = deltaF > 0 ? .warmer : (deltaF < 0 ? .cooler : .same)
        let magnitude: PhraseBank.ComparisonMagnitude? = direction == .same ? nil : .forDelta(abs(deltaF))

        var tokens = phraseTokens(location: location, payload: payload, unit: unit)
        tokens["delta"] = TemperatureFormatting.deltaString(fahrenheitDelta: abs(deltaF), unit: unit)

        return PhraseBank.comparison(
            direction: direction,
            magnitude: magnitude,
            date: phraseBankDate,
            locationId: location.id,
            tokens: tokens
        )
    }

    // MARK: - Forced-hook resolution

    private func effectiveConditionGroup(for payload: CachedWeather) -> PhraseBank.ConditionGroup {
        forcedCondition ?? PhraseBank.conditionGroup(forRawCode: payload.currentConditions.conditionCode)
    }

    private func effectiveTempBand(for payload: CachedWeather) -> PhraseBank.TempBand {
        forcedTempBand ?? PhraseBank.TempBand.forMeasurement(payload.currentConditions.temperature)
    }

    // MARK: - Token gathering (see `Sources/PhraseBank/README.md` for the full token table)

    private func phraseTokens(location: SavedLocation, payload: CachedWeather, unit: TemperatureUnit) -> [String: String] {
        var tokens: [String: String] = [
            "temp": TemperatureFormatting.string(payload.currentConditions.temperature, unit: unit),
            "feelsLike": TemperatureFormatting.string(payload.currentConditions.feelsLike, unit: unit),
            "condition": payload.currentConditions.conditionDescription,
            "city": location.name,
            "time": Self.peakPrecipHourToken(payload: payload),
        ]
        if let today = payload.daily.first {
            tokens["high"] = TemperatureFormatting.string(today.high, unit: unit)
            tokens["low"] = TemperatureFormatting.string(today.low, unit: unit)
            tokens["chance"] = Self.percentToken(today.precipChance)
        }
        return tokens
    }

    private static func percentToken(_ fraction: Double) -> String {
        "\(Int((fraction * 100).rounded()))%"
    }

    /// `{time}` — the friendly hour of today's most notable upcoming precipitation chance
    /// (used by a handful of rain/snow lines, e.g. "Rain moving in around {time}."). Always
    /// resolvable: falls back to the literal word "later" if nothing in the remaining hourly
    /// list clears a 40% precipitation-chance threshold and nothing has any chance at all, so
    /// a line using `{time}` never renders a raw unfilled token.
    private static func peakPrecipHourToken(payload: CachedWeather) -> String {
        let now = Date()
        let upcoming = payload.hourly.filter { $0.date >= now }
        if let onset = upcoming.first(where: { $0.precipChance >= 0.4 }) {
            return hourFormatter.string(from: onset.date)
        }
        if let peak = upcoming.max(by: { $0.precipChance < $1.precipChance }), peak.precipChance > 0 {
            return hourFormatter.string(from: peak.date)
        }
        return "later"
    }

    private static let hourFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "h a"
        return formatter
    }()
}
