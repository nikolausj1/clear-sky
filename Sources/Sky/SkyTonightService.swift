import Foundation

/// Per-location "Tonight's Sky" orchestrator (PRD Revision Notes 2026-07-17): combines the
/// on-device Astronomy engine (`Sources/Sky/Astronomy` — synchronous, always available: moon,
/// planets, sun/twilight) with the networked ISS-pass and Aurora engines (`Sources/Sky/ISS`,
/// `Sources/Sky/Aurora` — each independently async and independently degradable), for
/// `TonightSkyCard`.
///
/// **Don't-modify-engine-logic note:** this file only *calls* the sibling engines; it adds no
/// logic to them. `ISSPass`'s `Equatable` conformance and `MeteorShowers.MoonInterference`'s
/// `argValue` initializer below are the only additive extensions — harmless (one only compares
/// the fields that make two passes "the same pass", the other only parses a launch-arg string
/// into the engine's own enum cases), needed so this file's own `State`/`SectionState` types can
/// be compared in SwiftUI and so `-forceMeteorPeak` can select an engine-native case.
///
/// **v1 time-zone limitation, per work order:** uses the DEVICE's time zone for "tonight" (civil
/// dusk -> civil dawn), not the saved location's own time zone. A saved city on the far side of
/// the world will show ISS/aurora/twilight times in device-local time, not that city's local
/// evening — acceptable for v1's single-real-user scope (most saved cities share a rough time
/// zone with the device); a real per-location time zone (e.g. via reverse geocoding) is future
/// work, not required here.
///
/// **Sky-intelligence rows (work package WP-F):** meteor outlook and close pairings are, like
/// astronomy, synchronous pure math — computed fresh on every call, never cached, via
/// `meteorAndPairings(latitude:longitude:date:timeZone:overrides:)`. `bestMoment` (the card's
/// headline) is a pure function of whatever astronomy/ISS/aurora/meteor/pairings data is
/// *currently available* — see that function's own doc comment for how `TonightSkyCard` uses it
/// to get an immediate sync-only headline guess that smoothly upgrades once the async ISS/aurora
/// sections resolve, without ever passing through a blank/nil state in between.
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
        /// Active shower's outlook for tonight, if any — `nil` when no shower is active
        /// (`MeteorShowers.outlook` itself returned `nil`). Synchronous, defaults to `nil` here
        /// only because a few internal helpers construct a partial `State` before this field is
        /// known; `state(...)`'s own return value always fills it in properly.
        var meteor: MeteorShowers.MeteorOutlook? = nil
        /// Visible close pairings tonight, tightest-separation first (see
        /// `Conjunctions.closePairings`'s own doc comment on sort order). Empty, not optional,
        /// when none clear tonight.
        var pairings: [Conjunctions.Pairing] = []
        /// Tonight's single headline moment, or `nil` if nothing clears any of `BestMoment`'s
        /// tiers. See the type-level doc comment on the "sky-intelligence rows" work package.
        var bestMoment: BestMoment.SkyMoment? = nil
    }

    /// Sim-verify overrides (`-forceAuroraBand`, `-forceISSPass`, `-forceNoISS`,
    /// `-forceSkyUnavailable`, `-forceMeteorPeak`, `-forcePairing`) — bypass the network/cache
    /// (or, for meteor/pairing, the real date-driven lookup) entirely so a screenshot can show a
    /// specific state on demand without needing real conditions (or a real pass/shower/pairing
    /// tonight) to cooperate. See `NavigationShell`'s launch-arg parsing.
    struct ForcedOverrides {
        var auroraBand: AuroraBand?
        var issPass: Bool = false
        var noISS: Bool = false
        var unavailable: Bool = false
        /// `-forceMeteorPeak none|some|severe` — synthesizes a Perseids-at-peak `MeteorOutlook`
        /// at the given Moon-interference level, so the meteor row (and headline) can be
        /// screenshotted without waiting for a real shower to be active/peaking.
        var meteorPeak: MeteorShowers.MoonInterference?
        /// `-forcePairing` — synthesizes a single Moon-Jupiter 1.3°-apart pairing, so the
        /// conjunction row (and headline) can be screenshotted without a real close pairing
        /// existing tonight.
        var pairing: Bool = false

        var isActive: Bool { auroraBand != nil || issPass || noISS || unavailable || meteorPeak != nil || pairing }
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

    /// Meteor outlook + close pairings for tonight — like `astronomy(...)` above, synchronous
    /// pure math (no network), so `TonightSkyCard` can render the meteor/conjunction rows
    /// immediately, in the same call it computes astronomy, before the async ISS/aurora fetch
    /// even starts. `overrides.meteorPeak`/`overrides.pairing` are applied here (rather than only
    /// inside `state(...)`) so the card's own immediate sync-only pass already reflects them —
    /// see `state(...)`'s doc comment for why that matters for the headline.
    nonisolated static func meteorAndPairings(
        latitude: Double,
        longitude: Double,
        date: Date,
        timeZone: TimeZone,
        overrides: ForcedOverrides? = nil
    ) -> (meteor: MeteorShowers.MeteorOutlook?, pairings: [Conjunctions.Pairing]) {
        let meteor = overrides?.meteorPeak.map { Self.syntheticMeteorOutlook(interference: $0, referenceDate: date) }
            ?? MeteorShowers.outlook(on: date, latitude: latitude, longitude: longitude, timeZone: timeZone)
        let pairings = (overrides?.pairing == true)
            ? [Self.syntheticPairing(referenceDate: date)]
            : Conjunctions.closePairings(on: date, latitude: latitude, longitude: longitude, timeZone: timeZone)
        return (meteor, pairings)
    }

    /// Tonight's headline moment given whatever data is *currently available* — a thin wrapper
    /// over `BestMoment.bestMoment(tonight:)` that only exists to bundle the five inputs the same
    /// way `state(...)` and `TonightSkyCard.load()` both need to. Called twice per card load,
    /// deliberately:
    /// 1. Immediately, with `iss: []` and `aurora: nil` (those two sections haven't resolved
    ///    yet) — gives the card an instant headline guess from whatever synchronous data
    ///    (planets, meteor, pairings, moonrise) qualifies.
    /// 2. Again once the async ISS/aurora fetch resolves, with their real (or `.unavailable` ->
    ///    empty/nil) values folded in.
    /// Because `BestMoment`'s only tiers that can *newly* qualify between call 1 and call 2 are
    /// ISS pass and aurora window — both strictly higher-priority than anything sync-only data
    /// can produce — call 2's result is never a lower-priority moment than call 1's. That
    /// monotonicity is what makes the upgrade feel smooth rather than a flicker: the headline
    /// either stays exactly the same or gets replaced by something *more* exciting, never blanks
    /// out in between.
    nonisolated static func bestMoment(
        astronomy: SkyTonight.TonightSky,
        iss: [ISSPass],
        aurora: AuroraOutlook?,
        meteor: MeteorShowers.MeteorOutlook?,
        pairings: [Conjunctions.Pairing]
    ) -> BestMoment.SkyMoment? {
        BestMoment.bestMoment(tonight: BestMoment.TonightData(
            sky: astronomy,
            issPasses: iss,
            auroraOutlook: aurora,
            meteorOutlook: meteor,
            pairings: pairings
        ))
    }

    /// Pulls the payload out of a `.available` section, `nil`/empty otherwise — used to feed
    /// `bestMoment(...)` from whatever `iss`/`aurora` `SectionState` a given branch of
    /// `state(...)` ends up with (real, forced, or `.unavailable`).
    private static func availableValue<T>(_ state: SectionState<T>) -> T? {
        if case .available(let value) = state { return value }
        return nil
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
        let (meteor, pairings) = Self.meteorAndPairings(latitude: latitude, longitude: longitude, date: date, timeZone: timeZone, overrides: overrides)

        // `-forceSkyUnavailable` forces both network sections regardless of any real data, so
        // the real fetch (network + cache) can be skipped entirely in that specific case. Meteor
        // outlook/pairings are unaffected (they're synchronous, not network-backed) — they're
        // still computed above and still feed the headline.
        if overrides?.unavailable == true {
            let moment = Self.bestMoment(astronomy: astro, iss: [], aurora: nil, meteor: meteor, pairings: pairings)
            return State(astronomy: astro, iss: .unavailable, aurora: .unavailable, meteor: meteor, pairings: pairings, bestMoment: moment)
        }

        let real = await realState(locationId: locationId, latitude: latitude, longitude: longitude, date: date, timeZone: timeZone, astronomy: astro)

        guard let overrides, overrides.isActive else {
            let moment = Self.bestMoment(astronomy: astro, iss: Self.availableValue(real.iss) ?? [], aurora: Self.availableValue(real.aurora), meteor: meteor, pairings: pairings)
            return State(astronomy: astro, iss: real.iss, aurora: real.aurora, meteor: meteor, pairings: pairings, bestMoment: moment)
        }

        let iss: SectionState<[ISSPass]> = overrides.issPass
            ? .available([Self.syntheticISSPass(referenceDate: astro.sun.sunset ?? Date())])
            : (overrides.noISS ? .available([]) : real.iss)
        let aurora: SectionState<AuroraOutlook> = overrides.auroraBand
            .map { SectionState.available(Self.syntheticAuroraOutlook(band: $0)) } ?? real.aurora

        let moment = Self.bestMoment(astronomy: astro, iss: Self.availableValue(iss) ?? [], aurora: Self.availableValue(aurora), meteor: meteor, pairings: pairings)
        return State(astronomy: astro, iss: iss, aurora: aurora, meteor: meteor, pairings: pairings, bestMoment: moment)
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

    /// A synthetic Perseids-at-peak `MeteorOutlook` for `-forceMeteorPeak none|some|severe` —
    /// real shower/ZHR/window fields (the Perseids' actual table entry, from `MeteorShowers.all`,
    /// looked up by name so this stays honest even if that table's numbers change), with the
    /// Moon-interference fields set directly to a value that produces the requested
    /// `MoonInterference` bucket, rather than re-deriving them from a real Moon position (there's
    /// no guarantee tonight's real Moon happens to produce all three buckets on demand). The rate
    /// numbers (60/35/15 per hour) are chosen to land clearly inside each of `MeteorShowers`'
    /// `moonRetentionFactor` bands (0.50 moonless -> 0.20 bright-Moon-all-night, applied to the
    /// Perseids' ZHR of 100) so the card's "on paper vs. actual" honesty line reads sensibly for
    /// each forced state.
    private nonisolated static func syntheticMeteorOutlook(interference: MeteorShowers.MoonInterference, referenceDate: Date) -> MeteorShowers.MeteorOutlook {
        let perseids = MeteorShowers.all.first { $0.name == "Perseids" }
            ?? MeteorShowers.MeteorShower(
                name: "Perseids",
                activeStart: .init(month: 7, day: 17), activeEnd: .init(month: 8, day: 24),
                peak: .init(month: 8, day: 12), zhr: 100,
                radiantConstellation: "Perseus", radiantRA: 48, radiantDec: 58,
                viewingNotes: "The most reliable major shower."
            )
        let estimatedVisiblePerHour: Double
        let moonIlluminatedPercent: Double
        let moonUpFraction: Double
        switch interference {
        case .none:
            estimatedVisiblePerHour = 60
            moonIlluminatedPercent = 4
            moonUpFraction = 0.05
        case .some:
            estimatedVisiblePerHour = 35
            moonIlluminatedPercent = 45
            moonUpFraction = 0.4
        case .severe:
            estimatedVisiblePerHour = 15
            moonIlluminatedPercent = 88
            moonUpFraction = 0.9
        }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        var components = calendar.dateComponents([.year, .month, .day], from: referenceDate)
        components.hour = 1
        let windowStart = calendar.date(from: components) ?? referenceDate
        let windowEnd = windowStart.addingTimeInterval(3 * 3600)

        return MeteorShowers.MeteorOutlook(
            shower: perseids,
            isPeakNight: true,
            daysFromPeak: 0,
            theoreticalZHR: perseids.zhr,
            estimatedVisiblePerHour: estimatedVisiblePerHour,
            moonInterference: interference,
            bestWindow: DateInterval(start: windowStart, end: windowEnd),
            moonIlluminatedPercent: moonIlluminatedPercent,
            moonUpFraction: moonUpFraction
        )
    }

    /// A fixed synthetic Moon-Jupiter pairing, 1.3° apart, high in the SSW around 9:15 PM — per
    /// work-order spec for `-forcePairing`, so a sim-verify screenshot doesn't depend on a real
    /// close pairing existing tonight.
    private nonisolated static func syntheticPairing(referenceDate: Date) -> Conjunctions.Pairing {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        var components = calendar.dateComponents([.year, .month, .day], from: referenceDate)
        components.hour = 21
        components.minute = 15
        let viewingTime = calendar.date(from: components) ?? referenceDate
        return Conjunctions.Pairing(
            bodyA: .moon,
            bodyB: .planet(.jupiter),
            separationDegrees: 1.3,
            bestViewingTime: viewingTime,
            altitudeAtBest: 34,
            azimuthAtBest: 200,
            directionDescription: "high in the SSW"
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

/// Additive-only: lets `-forceMeteorPeak none|some|severe` parse a launch-arg string directly
/// into `MeteorShowers.MoonInterference`'s own engine-native cases, without duplicating that
/// vocabulary in a second enum — no engine logic touched, `MoonInterference` itself is unchanged.
extension MeteorShowers.MoonInterference {
    init?(launchArgValue: String) {
        switch launchArgValue {
        case "none": self = .none
        case "some": self = .some
        case "severe": self = .severe
        default: return nil
        }
    }
}
