import Foundation

/// Shared temperature-display helper. Every place a `Measurement<UnitTemperature>` is rendered
/// in the app routes through this so `UnitsSettings.unit` (the Settings F/C toggle) takes effect
/// everywhere, not just on the Forecast screen — see PRD Section 11 acceptance criterion
/// "changing units updates Forecast, Locations, and Rankings consistently."
enum TemperatureFormatting {
    /// Rounds and appends "°" directly rather than going through `Measurement.formatted(.measurement(...))`:
    /// that format style silently re-converts to the *locale's* preferred temperature unit for
    /// display (confirmed by direct testing — it ignores `.converted(to:)` entirely), which
    /// would make the Settings F/C toggle a no-op whenever it disagreed with the device locale.
    /// Formatting the already-converted numeric value ourselves is what actually respects
    /// `unit`.
    static func string(_ measurement: Measurement<UnitTemperature>, unit: TemperatureUnit) -> String {
        let value = measurement.converted(to: unit.unitTemperature).value
        return "\(Int(value.rounded()))\u{00B0}"
    }

    /// Formats a temperature **difference** (e.g. "6 degrees warmer than yesterday" — Phase
    /// 4's comparison line), given as an absolute Fahrenheit delta. Deliberately not routed
    /// through `Measurement<UnitTemperature>.converted(to:)`: that conversion is affine (it
    /// applies Fahrenheit's +32 offset), which is correct for an absolute temperature but
    /// wrong for a *difference* of temperatures — converting a 6°F delta that way yields a
    /// nonsense ~-14°C instead of the correct ~3°C. A temperature delta only ever needs the
    /// multiplicative part of the conversion (`\u{00D7} 5/9` from F to C).
    static func deltaString(fahrenheitDelta: Double, unit: TemperatureUnit) -> String {
        let converted = unit == .fahrenheit ? fahrenheitDelta : fahrenheitDelta * 5.0 / 9.0
        return "\(Int(converted.rounded()))\u{00B0}"
    }
}
