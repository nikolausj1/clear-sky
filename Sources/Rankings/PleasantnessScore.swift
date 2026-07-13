import Foundation

/// The deterministic "composite pleasantness score" for PRD Screen C (City Power Rankings),
/// implementing PRD Section 12's default formula verbatim: a weighted average of four 0-100
/// normalized components — temperature comfort (40%), precipitation (30%), wind (15%), and
/// humidity (15%).
///
/// **Pure by construction:** every function here takes its inputs as plain values (already
/// pulled out of `CurrentConditions`) and returns a value with no dependency on `Date()`,
/// global state, or I/O. Same inputs -> same score, always — which is what lets
/// `RankingsViewModel` recompute the ranking live from whatever's in `WeatherStore`'s cache
/// without worrying about it drifting, and what makes this file unit-testable without a
/// simulator (see the Build Guide's engine-test recipe).
enum PleasantnessScore {

    // MARK: - Weights (PRD Section 12 default: 40 / 30 / 15 / 15)

    static let temperatureWeight = 0.40
    static let precipitationWeight = 0.30
    static let windWeight = 0.15
    static let humidityWeight = 0.15

    /// One component's contribution to the total, kept apart (rather than folded straight into
    /// a single `Double`) so a future "why this rank" tap — or a unit test — can inspect each
    /// curve's output and weight independently instead of only seeing the final blended score.
    struct Component: Equatable {
        let name: String
        /// 0-100, already curve-mapped (not yet weighted).
        let value: Double
        /// 0-1, this component's share of the total (PRD Section 12's 40/30/15/15).
        let weight: Double
    }

    /// The full per-location breakdown: every component plus the weighted total. `total` is
    /// exactly `components.reduce(0) { $0 + $1.value * $1.weight }`, clamped to `0...100` as a
    /// defensive measure (the individual curves are already clamped, so this should be a no-op
    /// in practice — see each curve's doc comment).
    struct Breakdown: Equatable {
        let components: [Component]
        let total: Double
    }

    /// The three-bucket pleasantness band the phrase bank's `rankingVerdict` slot is keyed to
    /// (`PhraseBank.Pleasantness`: `great` / `fine` / `rough`). PRD Section 12 leaves the exact
    /// thresholds unspecified ("Exact weights and curve shapes are tunable post-launch"), so
    /// this file picks and documents them: **>=70 great, 40-69 fine, <40 rough.** In practice:
    /// "great" needs most components close to their curve peaks simultaneously (roughly, a
    /// calm ~70-75°F day at 40-50% humidity with a mostly-dry forecast); "rough" is reserved
    /// for days where at least one component is deep in its tapering tail (near-freezing or
    /// scorching heat, a soggy forecast, sustained wind, or muggy air) rather than one merely
    /// being off-peak.
    enum Band: String {
        case great, fine, rough

        static func forScore(_ score: Double) -> Band {
            if score >= 70 { return .great }
            if score >= 40 { return .fine }
            return .rough
        }
    }

    /// Computes the full breakdown for one location's current conditions.
    ///
    /// - Parameters:
    ///   - temperature: Current temperature. Converted to Fahrenheit internally regardless of
    ///     the user's Settings F/C display unit — exactly like `PhraseBank.TempBand`, the
    ///     ranking must never change just because someone flipped a display toggle.
    ///   - precipChance: 0-1 fraction. PRD Section 12 says "precipitation (100 minus precip
    ///     probability%)" sourced from "current conditions' precip chance"; `CurrentConditions`
    ///     has no precip-chance field of its own (only `HourlyEntry` does), so callers pass in
    ///     the current-hour/next-few-hours proxy documented on
    ///     `RankingsViewModel.currentPrecipChance(for:)`.
    ///   - windSpeed: Sustained wind speed (WeatherKit's `CurrentWeather.wind.speed`, which is
    ///     already sustained, not gust). Converted to mph internally.
    ///   - humidity: 0-1 fraction relative humidity (WeatherKit's native unit for
    ///     `CurrentWeather.humidity`).
    static func breakdown(
        temperature: Measurement<UnitTemperature>,
        precipChance: Double,
        windSpeed: Measurement<UnitSpeed>,
        humidity: Double
    ) -> Breakdown {
        let components = [
            Component(name: "Temperature comfort", value: temperatureComfort(temperature), weight: temperatureWeight),
            Component(name: "Precipitation", value: precipitation(precipChance), weight: precipitationWeight),
            Component(name: "Wind", value: wind(windSpeed), weight: windWeight),
            Component(name: "Humidity", value: humidityComfort(fraction: humidity), weight: humidityWeight),
        ]
        let total = components.reduce(0.0) { $0 + $1.value * $1.weight }
        return Breakdown(components: components, total: total.clamped(to: 0...100))
    }

    /// Convenience for callers that only need the final number (e.g. sorting), not the
    /// per-component breakdown.
    static func score(
        temperature: Measurement<UnitTemperature>,
        precipChance: Double,
        windSpeed: Measurement<UnitSpeed>,
        humidity: Double
    ) -> Double {
        breakdown(
            temperature: temperature,
            precipChance: precipChance,
            windSpeed: windSpeed,
            humidity: humidity
        ).total
    }

    // MARK: - Component curves
    //
    // Each curve is a pure, piecewise-linear function clamped to `0...100` at both ends so no
    // amount of out-of-range input (a heat-wave reading, a hurricane's wind speed, etc.) can
    // push a component negative or above 100 and skew the weighted average.

    /// **Temperature comfort (weight 40).** PRD Section 12: "peak at 70-75°F, tapering to 0
    /// below 20°F or above 100°F." Piecewise-linear: 0 at/below 20°F, ramping up to 100 across
    /// 20-70°F, a flat 100 plateau across 70-75°F, then ramping back down to 0 across 75-100°F,
    /// and 0 at/above 100°F.
    static func temperatureComfort(_ measurement: Measurement<UnitTemperature>) -> Double {
        let f = measurement.converted(to: .fahrenheit).value
        switch f {
        case ..<20:
            return 0
        case 20..<70:
            return lerp(f, from: 20, to: 70, output: 0, 100)
        case 70...75:
            return 100
        case 75...100:
            return lerp(f, from: 75, to: 100, output: 100, 0)
        default: // > 100
            return 0
        }
    }

    /// **Precipitation (weight 30).** PRD Section 12: "100 minus precip probability%." A
    /// bone-dry forecast (0% chance) scores 100; a certain-rain forecast (100% chance) scores
    /// 0. `precipChance` is a 0-1 fraction, clamped before scaling so a stray out-of-range value
    /// can't invert the curve.
    static func precipitation(_ precipChance: Double) -> Double {
        (100 - precipChance.clamped(to: 0...1) * 100).clamped(to: 0...100)
    }

    /// **Wind (weight 15).** PRD Section 12: "100 at calm, tapering to 0 at 30+ mph sustained."
    /// Linear from calm (0 mph -> 100) down to 30 mph (-> 0); clamped to 0 for anything windier.
    static func wind(_ measurement: Measurement<UnitSpeed>) -> Double {
        let mph = measurement.converted(to: .milesPerHour).value
        guard mph < 30 else { return 0 }
        return lerp(mph, from: 0, to: 30, output: 100, 0).clamped(to: 0...100)
    }

    /// **Humidity (weight 15).** PRD Section 12: "100 at 40-50% RH, penalized more heavily
    /// above 60%." Implemented as: a flat 100 plateau across 40-50% RH; a *gentle* taper down
    /// to 0 by 10% RH on the too-dry side (the PRD only specifies the high-humidity penalty, so
    /// this side is a light, undocumented-by-PRD extrapolation rather than a hard requirement —
    /// bone-dry air isn't literally as ideal as 45% RH, but it's not penalized as hard as muggy
    /// air either); and, on the high side, a *shallow* taper from 50-60% RH (100 -> 70) that
    /// then steepens sharply from 60-90% RH (70 -> 0), which is what gives the "penalized more
    /// heavily above 60%" behavior the PRD calls for — the per-percentage-point score loss
    /// roughly triples once RH crosses 60%.
    static func humidityComfort(fraction: Double) -> Double {
        let percent = (fraction * 100).clamped(to: 0...100)
        switch percent {
        case ..<10:
            return 0
        case 10..<40:
            return lerp(percent, from: 10, to: 40, output: 0, 100)
        case 40...50:
            return 100
        case 50..<60:
            return lerp(percent, from: 50, to: 60, output: 100, 70)
        case 60...90:
            return lerp(percent, from: 60, to: 90, output: 70, 0)
        default: // > 90
            return 0
        }
    }

    // MARK: - Helpers

    /// Linear interpolation of `x` from the input range `[start, end]` to the output range
    /// `[startOutput, endOutput]`. Deliberately takes two plain `Double`s for the output bounds
    /// (rather than a `ClosedRange<Double>`, which requires `lowerBound <= upperBound` and would
    /// crash on this file's several descending curves, e.g. 100 -> 0).
    private static func lerp(_ x: Double, from start: Double, to end: Double, output startOutput: Double, _ endOutput: Double) -> Double {
        guard end != start else { return startOutput }
        let t = (x - start) / (end - start)
        return startOutput + t * (endOutput - startOutput)
    }
}

private extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
