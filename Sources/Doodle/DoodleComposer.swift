import Foundation

/// Phase 5 ("Doodle layer system with programmatic placeholder layers") — PRD Section 7's
/// "Doodle layer grammar" and "Resolution order."
///
/// `DoodleComposer` is the single place that resolves (date, current conditions, sunrise/
/// sunset) into the parameters each of the five layers needs. It intentionally holds no
/// SwiftUI — it is a pure function of its inputs (PRD Section 5, "Deterministic over
/// random"), so the same inputs always produce the same `Scene`, and the resolution logic
/// is unit-testable without a simulator. `DoodleSceneView` (this same directory) is the
/// View-layer consumer that turns a `Scene` into pixels.
///
/// PRD Section 9 notes `DoodleComposer` and `PhraseBank` should share the "special day >
/// weather > season > time of day" priority concept. This phase builds `DoodleComposer`
/// cleanly against that same priority order (see `Scene.captionPriorityContext`) without
/// refactoring `PhraseBank` itself — that unification is left for a later pass.
enum DoodleComposer {

    // MARK: - Season (layer 2 input)

    /// Meteorological (calendar-month) seasons, not astronomical (solstice/equinox-bounded)
    /// ones — a deliberate v1.0 simplification: month-based boundaries are trivial to compute
    /// and explain, and the visual difference from the exact astronomical boundary (which
    /// floats by a few days year to year) is invisible in a header illustration. Assumes the
    /// **northern hemisphere** by default per the build brief ("assume northern for now but
    /// centralize the logic") — the `hemisphere` parameter exists so a future latitude-derived
    /// call site (the saved location's coordinate) can flip southern-hemisphere locations to
    /// the mirrored season without touching any call site's logic, just the argument passed.
    enum Season: String, CaseIterable {
        case winter, spring, summer, fall

        static func current(for date: Date, hemisphere: Hemisphere = .northern, calendar: Calendar = Calendar(identifier: .gregorian)) -> Season {
            let month = calendar.component(.month, from: date)
            let northernSeason: Season
            switch month {
            case 12, 1, 2: northernSeason = .winter
            case 3, 4, 5: northernSeason = .spring
            case 6, 7, 8: northernSeason = .summer
            default: northernSeason = .fall // 9, 10, 11
            }
            switch hemisphere {
            case .northern: return northernSeason
            case .southern: return northernSeason.opposite
            }
        }

        private var opposite: Season {
            switch self {
            case .winter: return .summer
            case .spring: return .fall
            case .summer: return .winter
            case .fall: return .spring
            }
        }
    }

    enum Hemisphere {
        case northern, southern
    }

    // MARK: - Tonight-preview representative time (always-night hero)

    /// The owner's decision (build brief, "always-night tonight preview"): the hero no longer
    /// mirrors the current moment — it always shows a preview of TONIGHT's sky. This resolves
    /// *which instant in time* that preview depicts: `now` itself when `now` already falls
    /// inside tonight's dark window (a genuinely live view of the current sky), or a fixed point
    /// this evening when it doesn't (daytime viewing shows a preview of a sky not reached yet).
    struct TonightPreviewResolution: Equatable {
        var representativeDate: Date
        /// True when `representativeDate` hasn't happened yet relative to `now` — i.e. `now`
        /// fell outside tonight's dark window, so the scene is a forecast preview rather than a
        /// live one. Drives the "A look at tonight's sky" caption (`DoodleHeaderView`).
        var isForecastPreview: Bool
    }

    /// How long after tonight's civil dusk the "upcoming" representative time sits, when `now`
    /// falls outside tonight's dark window (i.e. it's currently daytime): per work order,
    /// "upcoming dusk + 90 minutes" — solidly past the dusk instant itself, into full-dark,
    /// stars-out evening, rather than the strip of afterglow dusk still carries.
    private static let previewDuskOffset: TimeInterval = 90 * 60

    /// Resolves the representative time per the rule above. `latitude`/`longitude` are the
    /// DISPLAY location's coordinates (per work order: "thread the display location through to
    /// the classifier" — the same location this feeds into `TerrainClassifier`), used only to
    /// compute tonight's civil dusk/dawn via `SkyTonightService.duskDawnWindow` (the exact same
    /// dusk/dawn math `TonightSkyCard`/`DoodleHeaderView`'s Tonight Headline already rely on — no
    /// second astronomy implementation). Checks BOTH tonight's window (today's dusk -> tomorrow's
    /// dawn, in case `now` is this evening/night) and yesterday's (yesterday's dusk -> today's
    /// dawn, in case `now` is the early-morning hours before today's dawn) — a single "today's"
    /// window alone would wrongly call 2 AM "daytime" (today's dusk is still hours in the
    /// future; only yesterday's window actually covers the current dark stretch).
    static func resolveTonightPreview(
        now: Date,
        latitude: Double,
        longitude: Double,
        timeZone: TimeZone = .current
    ) -> TonightPreviewResolution {
        let todayWindow = SkyTonightService.duskDawnWindow(latitude: latitude, longitude: longitude, date: now, timeZone: timeZone)
        let yesterdayWindow = SkyTonightService.duskDawnWindow(latitude: latitude, longitude: longitude, date: now.addingTimeInterval(-86400), timeZone: timeZone)

        if todayWindow?.contains(now) == true || yesterdayWindow?.contains(now) == true {
            return TonightPreviewResolution(representativeDate: now, isForecastPreview: false)
        }

        if let dusk = todayWindow?.start {
            return TonightPreviewResolution(representativeDate: dusk.addingTimeInterval(previewDuskOffset), isForecastPreview: true)
        }

        // Polar edge case: dusk/dawn didn't resolve at all (polar day/night). Rather than
        // fabricate a time with no real dusk to anchor to, fall back to "now" and treat it as
        // live — same "no regression" fallback spirit as the rest of this file.
        return TonightPreviewResolution(representativeDate: now, isForecastPreview: false)
    }

    // MARK: - Time-of-day lighting (layer 4 input)

    enum TimeOfDay: String, CaseIterable {
        case dawn, day, dusk, night

        /// **Documented revert lever:** this full day/dawn/dusk/night resolution is no longer
        /// called by `resolve(...)` below — the always-night hero (owner's decision, build
        /// brief) hardcodes `.night` there instead. Kept intact (not deleted) specifically so a
        /// future decision to revert to "mirror the current moment" only needs to swap that one
        /// call site back to `TimeOfDay.resolve(...)`, not reconstruct this logic from git
        /// history. `-forceTimeOfDay` (sim-verify) still bypasses both paths via `resolve`'s own
        /// `forcedTimeOfDay ?? .night` — it never routes through this function either.
        ///
        /// Prefers real sunrise/sunset (from `DailyEntry`) when available: dawn/dusk are the
        /// ~40-minute windows straddling sunrise/sunset, day is strictly between them, night is
        /// everything else. Falls back to an hour-of-day heuristic (gated by `isDaylight`) when
        /// sunrise/sunset aren't available — `CurrentConditions` alone doesn't carry them, so
        /// this path covers any call site that only has current conditions in hand.
        static func resolve(
            date: Date,
            isDaylight: Bool?,
            sunrise: Date?,
            sunset: Date?,
            calendar: Calendar = Calendar(identifier: .gregorian)
        ) -> TimeOfDay {
            let twilightWindow: TimeInterval = 40 * 60

            if let sunrise, let sunset, sunset > sunrise {
                if abs(date.timeIntervalSince(sunrise)) <= twilightWindow {
                    return .dawn
                }
                if abs(date.timeIntervalSince(sunset)) <= twilightWindow {
                    return .dusk
                }
                if date > sunrise && date < sunset {
                    return .day
                }
                return .night
            }

            if let isDaylight, !isDaylight {
                return .night
            }
            let hour = calendar.component(.hour, from: date)
            switch hour {
            case 5..<7: return .dawn
            case 7..<17: return .day
            case 17..<20: return .dusk
            default: return .night
            }
        }
    }

    // MARK: - Weather condition (layer 3 input)

    /// The condition categories the layer grammar draws (PRD Section 7: "sun, cloud cover,
    /// rain, snow, fog"). Deliberately a *different* (smaller) enum than
    /// `PhraseBank.ConditionGroup` — the art only needs six visually-distinct buckets (no
    /// separate "wind" scene; gusty conditions read visually as `cloudy` with drifting
    /// clouds), whereas the phrase bank's copy has a dedicated `wind` bucket for wording. The
    /// two are bridged by `init(phraseBankGroup:)` below specifically so the shared
    /// `-forceCondition` sim-verify launch argument can drive both systems from one flag.
    enum ConditionCategory: String, CaseIterable {
        case clear, cloudy, rain, snow, fog, storm

        /// Mirrors `PhraseBank.conditionGroup(forRawCode:)`'s lowercased-contains checks so the
        /// doodle scene and the phrase-bank copy agree on what a given WeatherKit condition
        /// code "counts as."
        static func category(forRawCode rawCode: String) -> ConditionCategory {
            let code = rawCode.lowercased()
            if code.contains("thunder") {
                return .storm
            }
            if code.contains("snow") || code.contains("flurries") || code.contains("sleet") || code.contains("hail") || code.contains("ice") || code.contains("wintry") {
                return .snow
            }
            if code.contains("rain") || code.contains("drizzle") {
                return .rain
            }
            if code.contains("fog") || code.contains("haze") || code.contains("smok") {
                return .fog
            }
            if code.contains("cloud") || code.contains("overcast") || code.contains("windy") || code.contains("breezy") || code.contains("hazy") || code.contains("squall") {
                return .cloudy
            }
            return .clear
        }

        init(phraseBankGroup: PhraseBank.ConditionGroup) {
            switch phraseBankGroup {
            case .clear: self = .clear
            case .cloudy, .wind: self = .cloudy
            case .rain: self = .rain
            case .snow: self = .snow
            case .fog: self = .fog
            case .storm: self = .storm
            }
        }
    }

    // MARK: - True-sky doodle (additive layer, between sky background and clouds)

    /// One planet's resolved dot for the true-sky doodle (`TrueSkyLayer`) — azimuth/altitude/
    /// magnitude only; screen-coordinate mapping and magnitude->size/color are `TrueSkyLayer`'s
    /// own rendering concern (same split as `CelestialBody`'s xFraction/yFraction, which also
    /// aren't computed here).
    struct TrueSkyPlanetDot: Equatable {
        var body: Planets.Body
        var azimuthDegrees: Double
        var altitudeDegrees: Double
        var magnitude: Double
    }

    /// Everything `TrueSkyLayer` needs: planets already filtered to "worth a dot" altitude,
    /// tonight's aurora band (`nil` when unknown/unresolved — renders no glow, not a fake
    /// "none"), and whichever ISS pass (if any) `date` currently falls inside. Non-optional with
    /// an all-empty default so `Scene` stays trivially constructible wherever true-sky data isn't
    /// available yet (loading/error states, previews) — `TrueSkyLayer` renders nothing for an
    /// empty `TrueSkyScene`, which is the "no regression" fallback the work order asks for.
    struct TrueSkyScene: Equatable {
        var planets: [TrueSkyPlanetDot] = []
        var auroraBand: AuroraBand? = nil
        var activeISSPass: ISSPass? = nil
        /// Header space-event layers (WP: "meteor streaks on active-shower nights"): tonight's
        /// meteor outlook, `nil` when no shower is active. Drives `MeteorStreakLayer`'s
        /// eligibility (a shower has to actually be active) and cadence
        /// (`estimatedVisiblePerHour` — a busier, darker night streaks more often).
        var meteorOutlook: MeteorShowers.MeteorOutlook? = nil
        /// Header space-event layers ("conjunction nights"): tonight's closest Moon-planet
        /// pairing, if any. Planet-planet pairings need no synthetic treatment here — both
        /// bodies already get their own real-position dot from `planets` above, so they read as
        /// close together for free. See `TrueSkyLayer`'s "conjunction scene" doc comment for the
        /// full rule, including why only Moon-involving pairings land here.
        var conjunctionPairing: Conjunctions.Pairing? = nil
        /// Tonight's Moon illumination/waxing — needed only to draw an accurate mini crescent
        /// next to a conjunction's planet dot (`TrueSkyLayer`). `CelestialBody`'s own night-moon
        /// graphic sits at a fixed decorative position, not derived from real phase math, so
        /// these two fields exist purely to feed the conjunction-scene mini-moon.
        var moonIlluminatedFraction: Double? = nil
        var moonWaxing: Bool? = nil
        /// Header space-event layers ("launch-day contrail"): true when a `.go`-status launch's
        /// T-0 falls on `date`'s calendar day. Cache-only read (mirrors `HourlySkyEvents`' own
        /// launch-icon sourcing — see `DoodleHeaderView`'s doc comment on where this comes from);
        /// never triggers a new network fetch of its own.
        var hasGoLaunchToday: Bool = false
    }

    // MARK: - Resolved scene

    /// Everything the five (now six, with the additive true-sky layer) layers need to render,
    /// resolved once per header render.
    struct Scene: Equatable {
        var date: Date
        var season: Season
        var timeOfDay: TimeOfDay
        var condition: ConditionCategory
        var specialDay: SpecialDay?
        var trueSky: TrueSkyScene = TrueSkyScene()
        /// Location terrain integration: which of `IllustratedLandscapeLayer`'s curated art sets
        /// (mountains/desert/coast/hills) matches the display location. `.hills` — the existing
        /// default landscape — for every call site that doesn't pass a location (loading/error/
        /// empty previews), matching those states' existing "no regression" fallback pattern.
        var terrainClass: TerrainClass = .hills
    }

    /// Layers 1-4 always resolve (there is no "off" state for season/condition/time-of-day —
    /// PRD Section 7's "Resolution order"). Layer 5 (`specialDay`) is `nil` on most days and
    /// renders additively only when `SpecialDayTable` has an entry for `date`.
    static func resolve(
        date: Date,
        current: CurrentConditions?,
        /// Unused by this function's own `timeOfDay` resolution now that the hero is always-
        /// night (see `TimeOfDay.resolve`'s doc comment on the revert lever this bypasses) — kept
        /// as parameters (not removed) purely so a future revert only has to change the one
        /// `timeOfDay` line above, not this call site's signature too.
        sunrise: Date?,
        sunset: Date?,
        forcedCondition: ConditionCategory? = nil,
        forcedTimeOfDay: TimeOfDay? = nil,
        hemisphere: Hemisphere = .northern,
        terrainClass: TerrainClass = .hills,
        /// Tonight-preview composer mode: the nearest hourly forecast entry's `conditionCode` to
        /// the representative time (`date`, already resolved to "now" or "this evening" by the
        /// caller — see `resolveTonightPreview`), so the weather-condition layer reflects
        /// TONIGHT's forecast instead of the current moment. `nil` when the caller has no hourly
        /// coverage reaching that far (falls back to `current`'s condition below — same
        /// documented fallback every other optional input here uses).
        tonightConditionCode: String? = nil,
        trueSkyPlanets: [SkyTonight.CurrentPlanetPosition] = [],
        trueSkyAuroraBand: AuroraBand? = nil,
        trueSkyISSPasses: [ISSPass] = [],
        forceTrueSkyPlanets: Bool = false,
        forceISSStreakNow: Bool = false,
        trueSkyMeteorOutlook: MeteorShowers.MeteorOutlook? = nil,
        trueSkyConjunctionPairing: Conjunctions.Pairing? = nil,
        trueSkyMoonIlluminatedFraction: Double? = nil,
        trueSkyMoonWaxing: Bool? = nil,
        hasGoLaunchToday: Bool = false,
        forceMeteorStreaks: Bool = false,
        forceConjunctionScene: Bool = false,
        forceLaunchContrail: Bool = false
    ) -> Scene {
        let season = Season.current(for: date, hemisphere: hemisphere)
        // Always-night hero (owner's decision): the weather-condition layer draws TONIGHT's
        // forecast condition (nearest hourly entry to the representative time), not whatever
        // `current` happens to be right now — `tonightConditionCode` is `nil` only when the
        // caller has no hourly coverage reaching the representative time, in which case this
        // falls back to `current`'s condition (same as the old, pre-tonight-preview behavior).
        let condition = forcedCondition ?? ConditionCategory.category(forRawCode: tonightConditionCode ?? current?.conditionCode ?? "clear")
        // Always-night hero: the hero's sky is always the night palette + stars now — see
        // `TimeOfDay.resolve`'s doc comment for the documented revert lever this bypasses.
        // `-forceTimeOfDay` still overrides for sim-verify, exactly as before.
        let timeOfDay = forcedTimeOfDay ?? .night
        let specialDay = SpecialDayTable.specialDay(for: date)
        let trueSky = resolveTrueSky(
            date: date,
            planets: trueSkyPlanets,
            auroraBand: trueSkyAuroraBand,
            issPasses: trueSkyISSPasses,
            forcePlanets: forceTrueSkyPlanets,
            forceISSStreakNow: forceISSStreakNow,
            meteorOutlook: trueSkyMeteorOutlook,
            conjunctionPairing: trueSkyConjunctionPairing,
            moonIlluminatedFraction: trueSkyMoonIlluminatedFraction,
            moonWaxing: trueSkyMoonWaxing,
            hasGoLaunchToday: hasGoLaunchToday,
            forceMeteorStreaks: forceMeteorStreaks,
            forceConjunctionScene: forceConjunctionScene,
            forceLaunchContrail: forceLaunchContrail
        )
        return Scene(date: date, season: season, timeOfDay: timeOfDay, condition: condition, specialDay: specialDay, trueSky: trueSky, terrainClass: terrainClass)
    }

    /// The minimum altitude (degrees) a planet needs to clear before the true-sky doodle bothers
    /// with a dot — mirrors `SkyTonight`'s own `minimumViewingAltitude` (10°: "just above
    /// rooftops/trees"), kept as a separate constant here rather than referencing that (private)
    /// one so this file doesn't need to reach into `SkyTonight`'s private implementation details.
    private static let trueSkyMinimumAltitude = 10.0

    /// Folds the raw astronomy/aurora/ISS data `resolve(...)` is handed into the small bundle
    /// `TrueSkyLayer` paints. Aurora/ISS pass through close to as-is (their band-threshold /
    /// "is `date` inside a pass window" gating lives in `TrueSkyLayer` itself, alongside its
    /// `timeOfDay`/`condition` gating, which this function has no reason to duplicate) — the
    /// only real resolution work here is the planet altitude filter and the two sim-verify
    /// forcing hooks.
    private static func resolveTrueSky(
        date: Date,
        planets: [SkyTonight.CurrentPlanetPosition],
        auroraBand: AuroraBand?,
        issPasses: [ISSPass],
        forcePlanets: Bool,
        forceISSStreakNow: Bool,
        meteorOutlook: MeteorShowers.MeteorOutlook?,
        conjunctionPairing: Conjunctions.Pairing?,
        moonIlluminatedFraction: Double?,
        moonWaxing: Bool?,
        hasGoLaunchToday: Bool,
        forceMeteorStreaks: Bool,
        forceConjunctionScene: Bool,
        forceLaunchContrail: Bool
    ) -> TrueSkyScene {
        let resolvedPlanets: [TrueSkyPlanetDot]
        if forcePlanets {
            resolvedPlanets = Self.syntheticTrueSkyPlanets
        } else {
            resolvedPlanets = planets
                .filter { $0.altitude >= Self.trueSkyMinimumAltitude }
                .map { TrueSkyPlanetDot(body: $0.body, azimuthDegrees: $0.azimuth, altitudeDegrees: $0.altitude, magnitude: $0.apparentMagnitude) }
        }

        let activeISSPass: ISSPass?
        if forceISSStreakNow {
            activeISSPass = Self.syntheticActiveISSPass(now: date)
        } else {
            activeISSPass = issPasses.first { date >= $0.startTime && date <= $0.endTime }
        }

        let resolvedMeteor = forceMeteorStreaks ? Self.syntheticMeteorOutlookForStreaks(referenceDate: date) : meteorOutlook
        let resolvedPairing = forceConjunctionScene ? Self.syntheticConjunctionPairing(referenceDate: date) : conjunctionPairing
        let resolvedMoonIlluminatedFraction = forceConjunctionScene ? 0.32 : moonIlluminatedFraction
        let resolvedMoonWaxing = forceConjunctionScene ? true : moonWaxing
        let resolvedLaunchToday = forceLaunchContrail ? true : hasGoLaunchToday

        return TrueSkyScene(
            planets: resolvedPlanets,
            auroraBand: auroraBand,
            activeISSPass: activeISSPass,
            meteorOutlook: resolvedMeteor,
            conjunctionPairing: resolvedPairing,
            moonIlluminatedFraction: resolvedMoonIlluminatedFraction,
            moonWaxing: resolvedMoonWaxing,
            hasGoLaunchToday: resolvedLaunchToday
        )
    }

    /// `-forceTrueSkyPlanets` sim-verify synthetic set (work-order spec): Venus low in the west
    /// (bright, should render), Saturn mid-high in the SE (dim, should render), and Mars low in
    /// the ENE — deliberately azimuth 68°, just *outside* `TrueSkyLayer`'s 90°-270° "faces south"
    /// window, included specifically to prove the "behind the viewer" skip logic actually hides
    /// a real planet, rather than that code path only ever going untested.
    private static let syntheticTrueSkyPlanets: [TrueSkyPlanetDot] = [
        TrueSkyPlanetDot(body: .venus, azimuthDegrees: 262, altitudeDegrees: 12, magnitude: -4.2),
        TrueSkyPlanetDot(body: .saturn, azimuthDegrees: 140, altitudeDegrees: 35, magnitude: 0.8),
        TrueSkyPlanetDot(body: .mars, azimuthDegrees: 68, altitudeDegrees: 12, magnitude: 0.9),
    ]

    /// `-forceISSStreakNow` sim-verify synthetic pass (work-order spec: "active right now,
    /// WNW->ESE") — centered on `now` (half elapsed) rather than a fixed clock time (unlike
    /// `SkyTonightService.syntheticISSPass`'s fixed 9:42 PM, which isn't guaranteed to be "now"),
    /// so the streak is always mid-transit whenever this flag is set, regardless of when the
    /// screenshot is actually taken.
    private static func syntheticActiveISSPass(now: Date) -> ISSPass {
        ISSPass(
            startTime: now.addingTimeInterval(-120),
            peakTime: now,
            endTime: now.addingTimeInterval(120),
            peakAltitudeDeg: 40,
            startAzimuthDeg: 292.5,
            endAzimuthDeg: 112.5,
            startAzimuthCompass: "WNW",
            endAzimuthCompass: "ESE",
            peakRangeKm: 450,
            brightness: .bright
        )
    }

    /// `-forceMeteorStreaks` sim-verify synthetic outlook: a Perseids-at-peak, moon-out-of-the-
    /// way `MeteorOutlook` with a high `estimatedVisiblePerHour` so `MeteorStreakLayer` streaks
    /// at its fastest cadence (~6s) regardless of whether a real shower is active tonight. Reuses
    /// the real Perseids table entry (looked up by name, same "stay honest even if the table's
    /// numbers change" rationale as `SkyTonightService.syntheticMeteorOutlook`), falling back to
    /// an inline literal only if that lookup ever fails.
    private static func syntheticMeteorOutlookForStreaks(referenceDate: Date) -> MeteorShowers.MeteorOutlook {
        let perseids = MeteorShowers.all.first { $0.name == "Perseids" }
            ?? MeteorShowers.MeteorShower(
                name: "Perseids",
                activeStart: .init(month: 7, day: 17), activeEnd: .init(month: 8, day: 24),
                peak: .init(month: 8, day: 12), zhr: 100,
                radiantConstellation: "Perseus", radiantRA: 48, radiantDec: 58,
                viewingNotes: "The most reliable major shower."
            )
        return MeteorShowers.MeteorOutlook(
            shower: perseids,
            isPeakNight: true,
            daysFromPeak: 0,
            theoreticalZHR: perseids.zhr,
            estimatedVisiblePerHour: 80,
            moonInterference: .none,
            bestWindow: DateInterval(start: referenceDate, end: referenceDate.addingTimeInterval(3 * 3600)),
            moonIlluminatedPercent: 4,
            moonUpFraction: 0.05
        )
    }

    /// `-forceConjunctionScene` sim-verify synthetic pairing: a fixed Moon-Jupiter pairing 1.8°
    /// apart, high in the SSW — mirrors `SkyTonightService.syntheticPairing`'s spec, kept as its
    /// own literal here rather than a cross-file call since that one lives on `@MainActor
    /// SkyTonightService` and this is a `nonisolated`-callable pure function.
    private static func syntheticConjunctionPairing(referenceDate: Date) -> Conjunctions.Pairing {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        var components = calendar.dateComponents([.year, .month, .day], from: referenceDate)
        components.hour = 21
        components.minute = 15
        let viewingTime = calendar.date(from: components) ?? referenceDate
        return Conjunctions.Pairing(
            bodyA: .moon,
            bodyB: .planet(.jupiter),
            separationDegrees: 1.8,
            bestViewingTime: viewingTime,
            altitudeAtBest: 34,
            azimuthAtBest: 200,
            directionDescription: "high in the SSW"
        )
    }
}

/// Additive-only: lets `DoodleComposer.TrueSkyScene` (Equatable) compare two meteor outlooks —
/// compares the fields that identify "the same outlook," not every stored field (mirrors
/// `SkyTonightService`'s own additive `ISSPass: Equatable`/`MoonInterference` extensions, same
/// don't-modify-engine-logic rationale: `MeteorShowers.swift` itself is untouched).
extension MeteorShowers.MeteorOutlook: Equatable {
    public static func == (lhs: MeteorShowers.MeteorOutlook, rhs: MeteorShowers.MeteorOutlook) -> Bool {
        lhs.shower.name == rhs.shower.name
            && lhs.isPeakNight == rhs.isPeakNight
            && lhs.estimatedVisiblePerHour == rhs.estimatedVisiblePerHour
            && lhs.bestWindow == rhs.bestWindow
    }
}

/// Additive-only: lets `DoodleComposer.TrueSkyScene` (Equatable) compare two pairings — same
/// rationale as the `MeteorOutlook` extension just above; `Conjunctions.swift` itself is
/// untouched.
extension Conjunctions.Pairing: Equatable {
    public static func == (lhs: Conjunctions.Pairing, rhs: Conjunctions.Pairing) -> Bool {
        lhs.bodyA == rhs.bodyA
            && lhs.bodyB == rhs.bodyB
            && lhs.separationDegrees == rhs.separationDegrees
            && lhs.bestViewingTime == rhs.bestViewingTime
    }
}
