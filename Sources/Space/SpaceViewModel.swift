import Foundation
import Observation

/// Drives the Space tab (work package WP-K: launches, solar activity, 30-day sky calendar).
/// Mirrors the "ViewModels (per screen)" layer `RankingsViewModel`/`ForecastViewModel` already
/// use: this type owns no networking/math of its own beyond orchestration -- launches come from
/// `Sources/Sky/Launches`, solar activity from `Sources/Sky/Solar`, and the sky calendar from
/// `SkyCalendar.swift` (which itself only calls the already-verified Astronomy engines).
///
/// **Location context:** the Launch Schedule and Sun cards are location-independent. The Sky
/// Calendar's meteor-peak/pairing rows are not (they need lat/lon) -- `SpaceView` passes down
/// whichever location it resolves (active Forecast location, falling back to the first saved
/// location, falling back to `nil`) via `updateLocationAndRecomputeCalendar(_:)`, called from a
/// `.task(id:)` keyed on that location's id so the 30-day computation only reruns when the
/// location (or calendar day) actually changes -- see that method's doc comment.
@MainActor
@Observable
final class SpaceViewModel {

    // MARK: - Launch schedule

    enum LaunchesState: Equatable {
        case loading
        case loaded(launches: [UpcomingLaunch], isStale: Bool)
        case unavailable
    }

    // MARK: - Solar activity

    struct SolarCardState: Equatable {
        let outlook: SolarOutlook
        /// Weekday name (e.g. "Sunday") of the day within the 3-day G forecast that hit
        /// `outlook.gScaleForecastMax`, or `nil` when that max is below G1 (no aurora tie-in to
        /// show) or the day couldn't be resolved. See `Self.forecastDayName(...)`.
        let forecastDayName: String?
        let isStale: Bool
    }

    enum SolarState: Equatable {
        case loading
        case loaded(SolarCardState)
        case unavailable
    }

    // MARK: - Sim-verify overrides

    /// `-forceSolarLevel quiet|active|stormy`, `-forceLaunchesSample`, `-forceSpaceOffline` (see
    /// `NavigationShell`'s launch-arg parsing).
    struct ForcedOverrides {
        var solarLevel: SolarActivityLevel?
        /// Bypasses the network entirely with 3 synthetic launches (a Go Falcon 9 Starlink today,
        /// a Hold NASA SLS tomorrow, a TBD Blue Origin New Glenn +3 days) so all three status
        /// chips can be screenshotted without waiting on a real schedule to line up.
        var launchesSample: Bool = false
        /// Simulates "no network, no cache" for launches (unavailable quiet line) and "cached,
        /// stale" for solar (an "as of" caveat) in one flag -- one screenshot, both degraded
        /// states visible per the work order's `space-offline.png` ask.
        var offline: Bool = false

        var isActive: Bool { solarLevel != nil || launchesSample || offline }
    }

    private(set) var launchesState: LaunchesState = .loading
    private(set) var solarState: SolarState = .loading
    private(set) var calendarEvents: [SkyCalendar.Event] = []

    private let overrides: ForcedOverrides
    private let forcedDate: Date?
    private var calendarCacheKey: String?

    init(overrides: ForcedOverrides = ForcedOverrides(), forcedDate: Date? = nil) {
        self.overrides = overrides
        self.forcedDate = forcedDate
    }

    /// Exposed (not `private`) so `SpaceView` can seed phrase-bank rotation off the same date this
    /// view model uses internally, keeping the "same day -> same forced date" contract consistent
    /// end to end (mirrors `RankingsViewModel.rankingDate`/`ForecastViewModel`'s own exposed date).
    var referenceDateForDisplay: Date { forcedDate ?? Date() }

    private var referenceDate: Date { referenceDateForDisplay }

    /// `sky/` subdirectory of the app's caches directory -- same shared cache directory
    /// `SkyTonightService` already uses for ISS/Aurora; the Launch/Solar caches use their own
    /// distinctly-named files within it (see `LaunchService`/`SolarService`'s cache file names),
    /// so there's no collision.
    private nonisolated static var cacheDirectory: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("sky", isDirectory: true)
    }

    // MARK: - Launches + solar (location-independent)

    /// Loads (or reuses cache for) the launch schedule and solar outlook concurrently. Safe to
    /// call every time the Space tab appears -- both engines' own freshness windows (6h/1h) mean
    /// repeat calls are mostly cache hits, and this only overwrites state on completion (no
    /// intermediate `.loading` flash on a re-appear once data is already loaded).
    func refresh() async {
        async let launchesTask: Void = loadLaunches()
        async let solarTask: Void = loadSolar()
        _ = await (launchesTask, solarTask)
    }

    private func loadLaunches() async {
        if overrides.launchesSample {
            launchesState = .loaded(launches: Self.sampleLaunches(referenceDate: referenceDate), isStale: false)
            return
        }
        if overrides.offline {
            launchesState = .unavailable
            return
        }
        do {
            let result = try await LaunchesUpcoming.nextLaunches(
                cacheDirectory: Self.cacheDirectory, from: referenceDate, count: 7
            )
            launchesState = .loaded(launches: result.launches, isStale: result.isStale)
        } catch {
            launchesState = .unavailable
        }
    }

    private func loadSolar() async {
        if let level = overrides.solarLevel {
            solarState = .loaded(SolarCardState(
                outlook: Self.syntheticOutlook(level: level, referenceDate: referenceDate),
                forecastDayName: Self.syntheticForecastDayName(level: level, referenceDate: referenceDate),
                isStale: false
            ))
            return
        }
        if overrides.offline {
            solarState = .loaded(SolarCardState(
                outlook: Self.syntheticOutlook(level: .quiet, referenceDate: referenceDate),
                forecastDayName: nil,
                isStale: true
            ))
            return
        }
        do {
            let result = try await SolarToday.fetch(now: referenceDate, cacheDirectory: Self.cacheDirectory)
            let isStale = result.scalesIsStale || result.flaresIsStale || result.sunspotsIsStale
            let dayName = await Self.forecastDayName(outlook: result.outlook, cacheDirectory: Self.cacheDirectory)
            solarState = .loaded(SolarCardState(outlook: result.outlook, forecastDayName: dayName, isStale: isStale))
        } catch {
            solarState = .unavailable
        }
    }

    /// The Sun card's aurora tie-in needs to name *which* of the 3 forecast days hit
    /// `outlook.gScaleForecastMax` ("G2 storm forecast Sunday"), but `SolarOutlook` only exposes
    /// the max value, not which day (see that type's doc comment) -- **don't-modify-engine-logic
    /// note**: rather than changing `SolarActivity.swift` to add that, this calls `SolarService`
    /// directly (a public consume-only API, same "call the sibling engine, add no logic to it"
    /// rule `SkyTonightService` follows) to re-read the same scales feed and find the matching
    /// forecast day. Since `SolarToday.fetch` above just wrote/refreshed this exact cache file,
    /// this call is a fresh-cache hit in practice -- no second network round-trip.
    private static func forecastDayName(outlook: SolarOutlook, cacheDirectory: URL) async -> String? {
        guard outlook.gScaleForecastMax >= 1 else { return nil }
        guard let (scales, _) = try? await SolarService().fetchScales(cacheDirectory: cacheDirectory) else { return nil }
        for key in ["1", "2", "3"] {
            if let entry = scales[key], entry.g.scaleValue == outlook.gScaleForecastMax, let date = entry.date {
                return weekdayFormatter.string(from: date)
            }
        }
        return nil
    }

    private static let weekdayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE"
        return formatter
    }()

    // MARK: - Sky calendar (location-dependent rows only when a location is available)

    /// Recomputes the 30-day sky calendar off the main thread, but only when the (day, location)
    /// pair actually changed since the last computation -- work-order ask: "cache the 30-day
    /// computation per calendar day so it doesn't recompute every render." `SpaceView` calls this
    /// from a `.task(id: location?.id)`, which itself already skips re-running when the id is
    /// unchanged; this cache additionally covers the case where the location is unchanged but the
    /// view re-appears (e.g. switching tabs and back) on the same calendar day.
    func updateLocationAndRecomputeCalendar(_ location: SavedLocation?) async {
        let date = referenceDate
        let key = Self.cacheKey(date: date, location: location)
        guard key != calendarCacheKey else { return }

        let latitude = location?.latitude
        let longitude = location?.longitude
        let events = await Task.detached(priority: .userInitiated) {
            SkyCalendar.events(from: date, days: 30, latitude: latitude, longitude: longitude, timeZone: .current)
        }.value

        calendarEvents = events
        calendarCacheKey = key
    }

    private static func cacheKey(date: Date, location: SavedLocation?) -> String {
        let dayStart = Calendar.current.startOfDay(for: date).timeIntervalSince1970
        return "\(dayStart)|\(location?.id.uuidString ?? "none")"
    }

    // MARK: - `-forceLaunchesSample`

    /// 3 synthetic launches bypassing the network entirely, per work order: a SpaceX Falcon 9
    /// Starlink mission "Go" today, a NASA SLS "Hold" tomorrow, a Blue Origin New Glenn "TBD" +3
    /// days -- one of each status chip, so a screenshot doesn't depend on a real schedule
    /// happening to have all three states at once.
    private static func sampleLaunches(referenceDate: Date) -> [UpcomingLaunch] {
        let calendar = Calendar(identifier: .gregorian)
        let today = calendar.startOfDay(for: referenceDate)
        func at(dayOffset: Int, hour: Int) -> Date {
            let day = calendar.date(byAdding: .day, value: dayOffset, to: today) ?? today
            return calendar.date(byAdding: .hour, value: hour, to: day) ?? day
        }

        return [
            UpcomingLaunch(
                id: "sample-falcon9-starlink",
                missionName: "Starlink Group 12-4",
                provider: "SpaceX",
                providerAbbrev: "SpaceX",
                vehicle: "Falcon 9 Block 5",
                padName: "SLC-40",
                locationDisplay: "Cape Canaveral, FL",
                net: at(dayOffset: 0, hour: 14),
                netPrecision: .exact,
                status: .go,
                isCrewed: false,
                webcastLive: true,
                imageURL: nil,
                missionDescription: "A batch of Starlink satellites to low Earth orbit."
            ),
            UpcomingLaunch(
                id: "sample-sls-artemis",
                missionName: "Artemis III",
                provider: "National Aeronautics and Space Administration",
                providerAbbrev: "NASA",
                vehicle: "Space Launch System Block 1",
                padName: "LC-39B",
                locationDisplay: "Cape Canaveral, FL",
                net: at(dayOffset: 1, hour: 9),
                netPrecision: .exact,
                status: .hold,
                isCrewed: true,
                webcastLive: false,
                imageURL: nil,
                missionDescription: "Crewed lunar flyby mission."
            ),
            UpcomingLaunch(
                id: "sample-newglenn-ng4",
                missionName: "NG-4",
                provider: "Blue Origin",
                providerAbbrev: "Blue Origin",
                vehicle: "New Glenn",
                padName: "LC-36",
                locationDisplay: "Cape Canaveral, FL",
                net: at(dayOffset: 3, hour: 12),
                netPrecision: .approximate,
                status: .tbd,
                isCrewed: false,
                webcastLive: false,
                imageURL: nil,
                missionDescription: "Orbital payload deployment."
            ),
        ]
    }

    // MARK: - `-forceSolarLevel`

    /// A synthetic `SolarOutlook` at the given level, including a notable flare and a G2 3-day
    /// forecast max for `.active`/`.stormy` (work order: "synthetic outlook incl. a notable flare
    /// + G2-forecast for stormy/active"), so the flare line and aurora tie-in can both be
    /// screenshotted without waiting for real space weather to cooperate.
    private static func syntheticOutlook(level: SolarActivityLevel, referenceDate: Date) -> SolarOutlook {
        let flare: NotableFlare?
        let gForecastMax: Int
        let gNow: Int
        let rNow: Int

        switch level {
        case .quiet:
            flare = nil
            gForecastMax = 0
            gNow = 0
            rNow = 0
        case .active:
            flare = NotableFlare(
                classString: "M4.2",
                peakTime: referenceDate.addingTimeInterval(-3 * 3600),
                beginTime: referenceDate.addingTimeInterval(-3.2 * 3600),
                endTime: referenceDate.addingTimeInterval(-2.8 * 3600)
            )
            gForecastMax = 2
            gNow = 1
            rNow = 1
        case .stormy:
            flare = NotableFlare(
                classString: "X1.8",
                peakTime: referenceDate.addingTimeInterval(-5 * 3600),
                beginTime: referenceDate.addingTimeInterval(-5.2 * 3600),
                endTime: referenceDate.addingTimeInterval(-4.8 * 3600)
            )
            gForecastMax = 2
            gNow = 2
            rNow = 3
        }

        return SolarOutlook(
            activityLevel: level,
            latestNotableFlare: flare,
            sunspotNumber: 88,
            sunspotObservationDate: referenceDate,
            rScaleNow: rNow,
            sScaleNow: 0,
            gScaleNow: gNow,
            gScaleForecastMax: gForecastMax,
            scalesObservedDate: referenceDate
        )
    }

    /// A deterministic "2 days out" weekday name for the synthetic aurora tie-in -- only used
    /// when the synthesized `gScaleForecastMax` clears G1 (`.active`/`.stormy`; see
    /// `syntheticOutlook`).
    private static func syntheticForecastDayName(level: SolarActivityLevel, referenceDate: Date) -> String? {
        guard level != .quiet else { return nil }
        guard let day = Calendar.current.date(byAdding: .day, value: 2, to: referenceDate) else { return nil }
        return weekdayFormatter.string(from: day)
    }
}
