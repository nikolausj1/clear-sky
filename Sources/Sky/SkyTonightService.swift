import Foundation

/// Per-location "Tonight's Sky" orchestrator (PRD Revision Notes 2026-07-17): combines the
/// on-device Astronomy engine (`Sources/Sky/Astronomy` — synchronous, always available: moon,
/// planets, sun/twilight) with the networked ISS-pass and Aurora engines (`Sources/Sky/ISS`,
/// `Sources/Sky/Aurora` — each independently async and independently degradable), for
/// `TonightSkyCard`.
///
/// **Don't-modify-engine-logic note:** this file only *calls* the three sibling engines; it adds
/// no logic to them. `ISSPass`'s `Equatable` conformance below is the one additive extension —
/// harmless (it only compares the fields that make two passes "the same pass"), needed so this
/// file's own `State`/`SectionState` types can be compared in SwiftUI.
///
/// **v1 time-zone limitation, per work order:** uses the DEVICE's time zone for "tonight" (civil
/// dusk -> civil dawn), not the saved location's own time zone. A saved city on the far side of
/// the world will show ISS/aurora/twilight times in device-local time, not that city's local
/// evening — acceptable for v1's single-real-user scope (most saved cities share a rough time
/// zone with the device); a real per-location time zone (e.g. via reverse geocoding) is future
/// work, not required here.
@MainActor
final class SkyTonightService {
    static let shared = SkyTonightService()

    enum SectionState<T> {
        case loading
        case available(T)
        case unavailable
    }

    struct State {
        var astronomy: SkyTonight.TonightSky
        var iss: SectionState<[ISSPass]>
        var aurora: SectionState<AuroraOutlook>
    }

    /// Sim-verify overrides (`-forceAuroraBand`, `-forceISSPass`, `-forceNoISS`,
    /// `-forceSkyUnavailable`) — bypass the network/cache entirely so a screenshot can show a
    /// specific state on demand without needing real conditions (or a real pass tonight) to
    /// cooperate. See `NavigationShell`'s launch-arg parsing.
    struct ForcedOverrides {
        var auroraBand: AuroraBand?
        var issPass: Bool = false
        var noISS: Bool = false
        var unavailable: Bool = false

        var isActive: Bool { auroraBand != nil || issPass || noISS || unavailable }
    }

    private struct CacheKey: Hashable {
        let locationId: UUID
        let eveningDayStart: Date
    }

    // In-memory cache per (location, calendar-evening) — see class doc. Forced (sim-verify)
    // results deliberately bypass both this cache and `inFlight` so they always reflect exactly
    // what was asked for, on every call.
    private var cache: [CacheKey: State] = [:]
    private var inFlight: [CacheKey: Task<State, Never>] = [:]

    private init() {}

    /// `sky/` subdirectory of the app's caches directory (work-order spec), shared by both the
    /// ISS TLE cache (`TLEFetcher`) and the Aurora feed cache (`AuroraService`) — each already
    /// manages its own file(s) within whatever directory it's handed.
    private nonisolated static var cacheDirectory: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("sky", isDirectory: true)
    }

    private func cacheKey(locationId: UUID, date: Date, timeZone: TimeZone) -> CacheKey {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return CacheKey(locationId: locationId, eveningDayStart: calendar.startOfDay(for: date))
    }

    /// Astronomy is synchronous, pure math (a few hundred trig calls) — recomputed on every call
    /// rather than cached, so callers (`TonightSkyCard`) can render the moon/planet rows
    /// immediately without waiting on the async ISS/aurora fetch below.
    nonisolated static func astronomy(latitude: Double, longitude: Double, date: Date, timeZone: TimeZone) -> SkyTonight.TonightSky {
        SkyTonight.compute(date: date, latitude: latitude, longitude: longitude, timeZone: timeZone)
    }

    /// Full state for a location tonight. `astronomy` is always computed fresh; `iss`/`aurora`
    /// are served from the in-memory cache when this calendar evening was already resolved,
    /// otherwise fetched — each independently falling back to `.unavailable` on failure rather
    /// than blocking the other section or any on-device row.
    /// Each of the four force flags (`-forceAuroraBand`, `-forceISSPass`, `-forceNoISS`,
    /// `-forceSkyUnavailable`) is applied to **only its own section** — e.g. `-forceAuroraBand
    /// good` still fetches (and shows) real ISS data; it does not also blank the ISS row. The
    /// one exception is `-forceSkyUnavailable`, which by its own nature (work-order spec: "—"
    /// on BOTH network rows) applies to both. This is why the real network/cache fetch below
    /// always runs (skipped only when every section is force-overridden anyway) rather than
    /// being bypassed wholesale by "any override is active" — an earlier version of this method
    /// did exactly that and, as a result, forcing just the aurora band silently made the ISS row
    /// report "no pass" even when a real pass existed tonight (caught during sim-verify).
    func state(
        locationId: UUID,
        latitude: Double,
        longitude: Double,
        date: Date,
        timeZone: TimeZone = .current,
        overrides: ForcedOverrides? = nil
    ) async -> State {
        let astro = Self.astronomy(latitude: latitude, longitude: longitude, date: date, timeZone: timeZone)

        // `-forceSkyUnavailable` forces both sections regardless of any real data, so the real
        // fetch (network + cache) can be skipped entirely in that specific case.
        if overrides?.unavailable == true {
            return State(astronomy: astro, iss: .unavailable, aurora: .unavailable)
        }

        let real = await realState(locationId: locationId, latitude: latitude, longitude: longitude, date: date, timeZone: timeZone, astronomy: astro)

        guard let overrides, overrides.isActive else {
            return real
        }

        let iss: SectionState<[ISSPass]> = overrides.issPass
            ? .available([Self.syntheticISSPass(referenceDate: astro.sun.sunset ?? Date())])
            : (overrides.noISS ? .available([]) : real.iss)
        let aurora: SectionState<AuroraOutlook> = overrides.auroraBand
            .map { SectionState.available(Self.syntheticAuroraOutlook(band: $0)) } ?? real.aurora

        return State(astronomy: astro, iss: iss, aurora: aurora)
    }

    /// The real (network/cache-backed) result for this location/evening, independent of any
    /// sim-verify overrides — always resolved so an override on one section never has to fake
    /// data for the other.
    private func realState(
        locationId: UUID,
        latitude: Double,
        longitude: Double,
        date: Date,
        timeZone: TimeZone,
        astronomy astro: SkyTonight.TonightSky
    ) async -> State {
        let key = cacheKey(locationId: locationId, date: date, timeZone: timeZone)
        if let cached = cache[key] {
            return State(astronomy: astro, iss: cached.iss, aurora: cached.aurora)
        }
        if let existingTask = inFlight[key] {
            let result = await existingTask.value
            return State(astronomy: astro, iss: result.iss, aurora: result.aurora)
        }

        let task = Task<State, Never> { [weak self] in
            await self?.fetchFresh(latitude: latitude, longitude: longitude, astronomy: astro, date: date, timeZone: timeZone)
                ?? State(astronomy: astro, iss: .unavailable, aurora: .unavailable)
        }
        inFlight[key] = task
        let result = await task.value
        inFlight[key] = nil
        cache[key] = result
        return result
    }

    /// The actual network work — deliberately `nonisolated` so it (and everything it calls)
    /// runs off the main actor: `TLEFetcher.fetch` is a blocking call internally (a semaphore
    /// wait around a `URLSession` task, per its own doc comment), and there's no reason to hold
    /// up the main actor for `AuroraTonight.fetch` either. ISS and aurora are fetched
    /// concurrently and independently degrade to `.unavailable` — one failing never blocks or
    /// delays the other.
    private nonisolated func fetchFresh(
        latitude: Double,
        longitude: Double,
        astronomy: SkyTonight.TonightSky,
        date: Date,
        timeZone: TimeZone
    ) async -> State {
        let window = Self.tonightWindow(latitude: latitude, longitude: longitude, date: date, timeZone: timeZone)
        async let issResult = Self.fetchISS(latitude: latitude, longitude: longitude, window: window)
        async let auroraResult = Self.fetchAurora(latitude: latitude, longitude: longitude, window: window)
        let (iss, aurora) = await (issResult, auroraResult)
        return State(astronomy: astronomy, iss: iss, aurora: aurora)
    }

    /// **Important gotcha this fixes:** `SkyTonight.TonightSky.sun` (the public Astronomy API)
    /// reports `civilDawn`/`sunrise` etc. for the calendar day containing `date` — i.e. THIS
    /// MORNING's dawn, which is *earlier* than that same day's evening `civilDusk`/`sunset`.
    /// `SkyTonight.compute` internally derives a proper "tonight's dusk -> tomorrow morning's
    /// dawn" window for its own planet-visibility scan, but doesn't expose that derived value on
    /// `SunInfo` — using `sun.civilDawn` here as "tomorrow's dawn" produced an inverted
    /// `DateInterval` (end before start) that crashed `AuroraLikelihood.outlook` on first
    /// sim-verify. Fixed by independently computing tomorrow's sunrise/civil-dawn the same way
    /// `SkyTonight.compute` does: `SunMoon.sunTimes` for tomorrow's calendar day, not today's.
    private nonisolated static func tonightWindow(
        latitude: Double,
        longitude: Double,
        date: Date,
        timeZone: TimeZone
    ) -> (civilDuskTonight: Date?, civilDawnTomorrow: Date?, sunsetTonight: Date?, sunriseTomorrow: Date?) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let dayStart = calendar.startOfDay(for: date)
        let tomorrowStart = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart.addingTimeInterval(86400)
        let todaySun = SunMoon.sunTimes(after: dayStart, lat: latitude, lon: longitude)
        let tomorrowSun = SunMoon.sunTimes(after: tomorrowStart, lat: latitude, lon: longitude)
        return (todaySun.civilDusk, tomorrowSun.civilDawn, todaySun.sunset, tomorrowSun.sunrise)
    }

    private nonisolated static func fetchISS(
        latitude: Double,
        longitude: Double,
        window: (civilDuskTonight: Date?, civilDawnTomorrow: Date?, sunsetTonight: Date?, sunriseTomorrow: Date?)
    ) async -> SectionState<[ISSPass]> {
        guard let windowStart = window.civilDuskTonight, let windowEnd = window.civilDawnTomorrow, windowEnd > windowStart else {
            return .unavailable
        }
        do {
            let fetcher = TLEFetcher(cacheDirectory: cacheDirectory)
            let fetchResult = try fetcher.fetch(now: Date())
            let passes = try ISSTonight.passes(
                tle: fetchResult.tle,
                windowStart: windowStart,
                windowEnd: windowEnd,
                latitudeDeg: latitude,
                longitudeDeg: longitude
            )
            return .available(passes)
        } catch {
            return .unavailable
        }
    }

    /// Aurora's own "tonight" window is sunset -> next sunrise (its dark-hours convention, per
    /// `AuroraTonight.fetch`'s doc comment), distinct from ISS's civil-twilight-bounded window.
    private nonisolated static func fetchAurora(
        latitude: Double,
        longitude: Double,
        window: (civilDuskTonight: Date?, civilDawnTomorrow: Date?, sunsetTonight: Date?, sunriseTomorrow: Date?)
    ) async -> SectionState<AuroraOutlook> {
        guard let sunset = window.sunsetTonight, let sunrise = window.sunriseTomorrow, sunrise > sunset else {
            return .unavailable
        }
        do {
            let result = try await AuroraTonight.fetch(
                latitude: latitude,
                longitude: longitude,
                tonightSunset: sunset,
                tonightSunrise: sunrise,
                cacheDirectory: cacheDirectory
            )
            return .available(result.outlook)
        } catch {
            return .unavailable
        }
    }

    // MARK: - Sim-verify forced overrides

    private func forcedISS(_ overrides: ForcedOverrides, astronomy: SkyTonight.TonightSky) -> SectionState<[ISSPass]> {
        if overrides.unavailable { return .unavailable }
        if overrides.noISS { return .available([]) }
        if overrides.issPass { return .available([Self.syntheticISSPass(referenceDate: astronomy.sun.sunset ?? Date())]) }
        return .available([])
    }

    private func forcedAurora(_ overrides: ForcedOverrides) -> SectionState<AuroraOutlook> {
        if overrides.unavailable { return .unavailable }
        return .available(Self.syntheticAuroraOutlook(band: overrides.auroraBand ?? .none))
    }

    /// A fixed synthetic pass — 9:42 PM, WNW -> ESE, 4 minutes, bright — per work-order spec for
    /// `-forceISSPass`, so a sim-verify screenshot doesn't depend on a real pass existing
    /// tonight over whatever location happens to be active.
    private nonisolated static func syntheticISSPass(referenceDate: Date) -> ISSPass {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        var components = calendar.dateComponents([.year, .month, .day], from: referenceDate)
        components.hour = 21
        components.minute = 42
        components.second = 0
        let start = calendar.date(from: components) ?? referenceDate
        return ISSPass(
            startTime: start,
            peakTime: start.addingTimeInterval(120),
            endTime: start.addingTimeInterval(240),
            peakAltitudeDeg: 62,
            startAzimuthDeg: 292.5,
            endAzimuthDeg: 112.5,
            startAzimuthCompass: "WNW",
            endAzimuthCompass: "ESE",
            peakRangeKm: 480,
            brightness: .bright
        )
    }

    private nonisolated static func syntheticAuroraOutlook(band: AuroraBand) -> AuroraOutlook {
        let chanceNow: Int
        switch band {
        case .none: chanceNow = 2
        case .low: chanceNow = 8
        case .fair: chanceNow = 22
        case .good: chanceNow = 45
        case .strong: chanceNow = 70
        }
        let now = Date()
        let window = DateInterval(start: now.addingTimeInterval(2 * 3600), end: now.addingTimeInterval(4 * 3600))
        return AuroraOutlook(
            chanceNow: chanceNow,
            tonightPeakKp: Double(band.rawValue) * 2,
            tonightPeakKpWindow: window,
            bestViewingWindow: window,
            band: band,
            geomagneticLatitude: 55,
            visibilityLatitudeThreshold: 60
        )
    }
}

/// Additive-only: lets `SkyTonightService.State` (and, transitively, sim-verify code) compare
/// passes for equality. Compares the fields that identify "the same predicted pass," not every
/// stored field — no engine logic touched, `ISSPass` itself is unchanged.
extension ISSPass: Equatable {
    public static func == (lhs: ISSPass, rhs: ISSPass) -> Bool {
        lhs.startTime == rhs.startTime
            && lhs.peakTime == rhs.peakTime
            && lhs.endTime == rhs.endTime
            && lhs.startAzimuthCompass == rhs.startAzimuthCompass
            && lhs.endAzimuthCompass == rhs.endAzimuthCompass
            && lhs.brightness == rhs.brightness
    }
}
