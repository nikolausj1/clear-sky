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
}
