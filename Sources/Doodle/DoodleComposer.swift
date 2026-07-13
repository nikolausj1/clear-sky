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

    // MARK: - Resolved scene

    /// Everything the five layers need to render, resolved once per header render.
    struct Scene: Equatable {
        var date: Date
        var season: Season
        var timeOfDay: TimeOfDay
        var condition: ConditionCategory
        var specialDay: SpecialDay?
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
        hemisphere: Hemisphere = .northern
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
        return Scene(date: date, season: season, timeOfDay: timeOfDay, condition: condition, specialDay: specialDay)
    }
}
