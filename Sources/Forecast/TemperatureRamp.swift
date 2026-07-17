import SwiftUI

/// UX polish package ("data-mark discipline"): a single perceptual temperature -> color ramp.
/// Every place a Fahrenheit temperature maps to a color (currently the daily range bar) routes
/// through this ONE ramp instead of an arbitrary blue-to-orange gradient, so a genuinely cool day
/// reads cool and a genuinely hot day reads hot, consistently, rather than every bar spanning the
/// same two hues regardless of its actual temperatures.
///
/// Stops chosen per the locked design spec: teal ~40°F, soft green ~55°F, amber ~72°F, warm
/// orange ~85°F, deep orange-red ~95°F+. A cold-end stop at 20°F is added (not in the spec's
/// list, but needed so genuinely cold winter days don't all flatten to the same 40° teal) —
/// everything at/below 20°F or at/above 95°F clamps to the nearest end stop rather than
/// extrapolating further.
enum TemperatureRamp {
    private static let stops: [(fahrenheit: Double, r: Double, g: Double, b: Double)] = [
        (20, 0.20, 0.47, 0.62),   // deep cold blue-teal
        (40, 0.20, 0.68, 0.64),   // teal
        (55, 0.45, 0.75, 0.45),   // soft green
        (72, 0.94, 0.72, 0.20),   // amber
        (85, 0.95, 0.52, 0.14),   // warm orange
        (95, 0.83, 0.24, 0.15),   // deep orange-red
    ]

    /// The ramp color for a given Fahrenheit value, linearly interpolated in RGB between the
    /// nearest two stops (clamped to the end stops outside 20...95).
    static func color(forFahrenheit value: Double) -> Color {
        guard let first = stops.first, let last = stops.last else { return .gray }

        if value <= first.fahrenheit {
            return Color(red: first.r, green: first.g, blue: first.b)
        }
        if value >= last.fahrenheit {
            return Color(red: last.r, green: last.g, blue: last.b)
        }

        for index in 1..<stops.count {
            let lower = stops[index - 1]
            let upper = stops[index]
            guard value <= upper.fahrenheit else { continue }
            let t = (value - lower.fahrenheit) / (upper.fahrenheit - lower.fahrenheit)
            return Color(
                red: lower.r + (upper.r - lower.r) * t,
                green: lower.g + (upper.g - lower.g) * t,
                blue: lower.b + (upper.b - lower.b) * t
            )
        }

        return Color(red: last.r, green: last.g, blue: last.b)
    }
}
