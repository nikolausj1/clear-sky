import Foundation

/// The metric-chip options for the hourly list (PRD Section 6, item 6, extended by the
/// Forecast-surface overhaul work package with two trailing chips). Selecting one changes what
/// each hourly row's positional pill shows and, per the positional-pill spec, which day-scoped
/// min/max range the pill is plotted against. `.temp` is the default on load.
///
/// `.sky` and `.events` are deliberately last (per work order: "two new chips at the END of the
/// chip row") and deliberately don't participate in `numericValue`/`displayString`/
/// `flooredMinimumCeiling` the way the six weather metrics do — a Stargazing Score and an
/// event-presence row aren't positional-pill data at all (see `HourlyPillRow`'s `.sky`/`.events`
/// branches, which read `StargazingScore.HourScore`/`HourlySkyEvents.Bucket` directly rather than
/// calling into this enum for their content). `numericValue`/`displayString` are never actually
/// rendered for these two cases — they return harmless neutral
/// values (rather than trapping) purely so callers that iterate `ForecastMetric.allCases`/every
/// hour generically (e.g. `PositionalPillTrack.positions`, computed for whatever `metric` is
/// currently selected even before the view layer branches on `isSkyIntelligenceChip`) stay total
/// functions and never crash.
enum ForecastMetric: String, CaseIterable, Identifiable {
    // Header/chrome refinements (work package "five UI refinements", item 4): new chip order —
    // Temp · Stargazing · Precip Chance · Events · Precip Amount · Feels Like · Wind · UV.
    // `CaseIterable`'s `allCases` follows declaration order, so reordering the cases below is
    // the whole change; every case's `rawValue` is untouched, so `-forceMetric sky` (and any
    // other launch-arg reference to the raw case name) keeps working — only display order/label
    // moved. The case is still named `sky` internally; only its `title` below reads
    // "Stargazing" now.
    case temp
    case sky
    case precipChance
    case events
    case precipAmount
    case feelsLike
    case wind
    case uv

    var id: String { rawValue }

    /// UX polish package ("Data-mark discipline" / chips): a tiny leading SF Symbol per metric
    /// chip, so the chip row reads faster than text alone.
    var symbolName: String {
        switch self {
        case .temp: return "thermometer"
        case .precipChance: return "drop"
        case .precipAmount: return "drop.fill"
        case .feelsLike: return "thermometer.sun"
        case .wind: return "wind"
        case .uv: return "sun.max"
        case .sky: return "sparkles"
        case .events: return "calendar.badge.clock"
        }
    }

    var title: String {
        switch self {
        case .temp: return "Temp"
        case .precipChance: return "Precip Chance"
        case .precipAmount: return "Precip Amount"
        case .feelsLike: return "Feels Like"
        case .wind: return "Wind"
        case .uv: return "UV"
        case .sky: return "Stargazing"
        case .events: return "Events"
        }
    }

    /// True for `.sky`/`.events` — see the type-level doc comment on why those two chips don't
    /// use `numericValue`/`displayString`/`flooredMinimumCeiling` at all.
    var isSkyIntelligenceChip: Bool {
        self == .sky || self == .events
    }

    /// The raw numeric value used for positional-pill placement (PRD Section 6, "Positional
    /// pill spec"). Always in the unit the pill's `displayString` renders, so the two stay
    /// consistent.
    func numericValue(for hour: HourlyEntry) -> Double {
        switch self {
        case .temp:
            return hour.temperature.converted(to: .fahrenheit).value
        case .precipChance:
            return hour.precipChance * 100
        case .precipAmount:
            return hour.precipAmount.converted(to: .inches).value
        case .feelsLike:
            return hour.feelsLike.converted(to: .fahrenheit).value
        case .wind:
            return hour.windSpeed.converted(to: .milesPerHour).value
        case .uv:
            return Double(hour.uvIndexValue)
        case .sky, .events:
            return 0
        }
    }

    /// PRD Section 6: "the track floor is 0 and the ceiling is the day's actual maximum ... or
    /// a small non-zero minimum ceiling (e.g. 10% / 0.01") to avoid a degenerate all-zero
    /// track." Only precip metrics use a floored track; other metrics use the day's true
    /// min/max. Returns `nil` for non-precip metrics.
    var flooredMinimumCeiling: Double? {
        switch self {
        case .precipChance: return 10 // 10%
        case .precipAmount: return 0.01 // inches
        default: return nil
        }
    }

    /// `unit` drives the Settings F/C toggle (PRD Screen D) for the two temperature-based
    /// metrics; the other metrics don't have a units preference to route through.
    func displayString(for hour: HourlyEntry, unit: TemperatureUnit) -> String {
        switch self {
        case .temp:
            return TemperatureFormatting.string(hour.temperature, unit: unit)
        case .precipChance:
            return "\(Int((hour.precipChance * 100).rounded()))%"
        case .precipAmount:
            return hour.precipAmount.converted(to: .inches)
                .formatted(.measurement(width: .narrow, numberFormatStyle: .number.precision(.fractionLength(2))))
        case .feelsLike:
            return TemperatureFormatting.string(hour.feelsLike, unit: unit)
        case .wind:
            return hour.windSpeed.converted(to: .milesPerHour)
                .formatted(.measurement(width: .narrow, numberFormatStyle: .number.precision(.fractionLength(0))))
        case .uv:
            return "\(hour.uvIndexValue)"
        case .sky, .events:
            return ""
        }
    }
}
