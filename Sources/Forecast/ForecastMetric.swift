import Foundation

/// The six metric-chip options for the hourly list (PRD Section 6, item 6). Selecting one
/// changes what each hourly row's positional pill shows and, per the positional-pill spec,
/// which day-scoped min/max range the pill is plotted against. `.temp` is the default on load.
enum ForecastMetric: String, CaseIterable, Identifiable {
    case temp
    case precipChance
    case precipAmount
    case feelsLike
    case wind
    case uv

    var id: String { rawValue }

    var title: String {
        switch self {
        case .temp: return "Temp"
        case .precipChance: return "Precip Chance"
        case .precipAmount: return "Precip Amount"
        case .feelsLike: return "Feels Like"
        case .wind: return "Wind"
        case .uv: return "UV"
        }
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
        }
    }
}
