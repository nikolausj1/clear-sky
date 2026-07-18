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

    // MARK: - Time-of-day lighting (layer 4 input)

    enum TimeOfDay: String, CaseIterable {
        case dawn, day, dusk, night

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
    }

    /// Layers 1-4 always resolve (there is no "off" state for season/condition/time-of-day —
    /// PRD Section 7's "Resolution order"). Layer 5 (`specialDay`) is `nil` on most days and
    /// renders additively only when `SpecialDayTable` has an entry for `date`.
    static func resolve(
        date: Date,
        current: CurrentConditions?,
        sunrise: Date?,
        sunset: Date?,
        forcedCondition: ConditionCategory? = nil,
        forcedTimeOfDay: TimeOfDay? = nil,
        hemisphere: Hemisphere = .northern,
        trueSkyPlanets: [SkyTonight.CurrentPlanetPosition] = [],
        trueSkyAuroraBand: AuroraBand? = nil,
        trueSkyISSPasses: [ISSPass] = [],
        forceTrueSkyPlanets: Bool = false,
        forceISSStreakNow: Bool = false
    ) -> Scene {
        let season = Season.current(for: date, hemisphere: hemisphere)
        let condition = forcedCondition ?? ConditionCategory.category(forRawCode: current?.conditionCode ?? "clear")
        let timeOfDay = forcedTimeOfDay ?? TimeOfDay.resolve(
            date: date,
            isDaylight: current?.isDaylight,
            sunrise: sunrise,
            sunset: sunset
        )
        let specialDay = SpecialDayTable.specialDay(for: date)
        let trueSky = resolveTrueSky(
            date: date,
            planets: trueSkyPlanets,
            auroraBand: trueSkyAuroraBand,
            issPasses: trueSkyISSPasses,
            forcePlanets: forceTrueSkyPlanets,
            forceISSStreakNow: forceISSStreakNow
        )
        return Scene(date: date, season: season, timeOfDay: timeOfDay, condition: condition, specialDay: specialDay, trueSky: trueSky)
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
        forceISSStreakNow: Bool
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

        return TrueSkyScene(planets: resolvedPlanets, auroraBand: auroraBand, activeISSPass: activeISSPass)
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
}
