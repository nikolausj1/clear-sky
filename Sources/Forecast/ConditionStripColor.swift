import SwiftUI

/// Color mapping for the hourly-list vertical condition strip (owner request, work package
/// "the vertical condition strip" — modeled on CARROT's continuous per-hour color bar, see the
/// reference screenshot `IMG_1317.png`). Reuses the same lowercased-substring-matching
/// convention `StargazingScore.cloudCoverFraction` and `PhraseBank.conditionGroup` already use
/// for `HourlyEntry.conditionCode`, so this engine's notion of "cloudy"/"rain"/"storm" agrees
/// with the rest of the app's condition-bucketing rather than inventing a fourth classifier.
///
/// Tuned for the dark theme: the strip sits directly against the Forecast sheet's
/// `Color(.systemGroupedBackground)` (near-black in dark mode — see `ForecastPageView`'s
/// `sheetSurface`), so every color below is chosen to read clearly against that background,
/// not against a white CARROT-style sheet.
///
/// ## Mapping
/// - clear / mostlyClear -> near-white (`clearWhite`, 0.92 opacity)
/// - partlyCloudy / mostlyCloudy / cloudy / overcast / fog / haze / smoky -> slate gray
///   (`slateGray`, 0.38 opacity) — also the fallback for any unrecognized condition code, matching
///   `PhraseBank.conditionGroup`'s own "safest generic bucket" philosophy
/// - drizzle / rain / showers / sunShowers -> accent blue (`rainBlue`, `clearSkyAccent` at 0.75
///   opacity)
/// - thunderstorms / heavy rain / hail -> a DARK, deeply saturated indigo-blue (`stormBlue`),
///   deliberately darker than `rainBlue` (not just `rainBlue` dimmed further, which would read as
///   "rain but faint" rather than "worse than rain") and still clearly distinct from the
///   near-black card background
/// - snow / sleet / flurries / wintryMix -> pale ice-blue (`snowIce`), distinct from both
///   `clearWhite` and `rainBlue`
///
/// `precipChance >= 0.5` forces at least rain-blue even when `conditionCode` alone reads as
/// merely partly cloudy — the same override `StargazingScore.cloudCoverFraction` applies, and for
/// the same reason: a 60%-chance-of-rain "partlyCloudy" hour is really a passing-shower hour, not
/// a calm one.
enum ConditionStripColor {
    static func color(conditionCode: String, precipChance: Double = 0) -> Color {
        let code = conditionCode.lowercased()

        // Storm/heavy-precip codes checked first (most specific), so e.g. "thunderstorms" or
        // "heavyRain" never fall through into the plain rain bucket below.
        if code.contains("thunder") || code.contains("hail") || isHeavyRain(code) {
            return stormBlue
        }
        if code.contains("snow") || code.contains("flurries") || code.contains("sleet") || code.contains("wintry") {
            return snowIce
        }
        if code.contains("rain") || code.contains("drizzle") || code.contains("shower") {
            return rainBlue
        }
        if precipChance >= StargazingScore.precipOverridesCloudThreshold {
            return rainBlue
        }
        if code.contains("clear") {
            // Catches both "clear" and "mostlyClear".
            return clearWhite
        }
        // partlyCloudy / mostlyCloudy / cloudy / overcast / fog / haze / hazy / smoky, plus any
        // unrecognized code — one shared "sky's not clear, nothing more specific to say" bucket.
        return slateGray
    }

    private static func isHeavyRain(_ lowercasedCode: String) -> Bool {
        lowercasedCode.contains("heavyrain") || (lowercasedCode.contains("heavy") && lowercasedCode.contains("rain"))
    }

    // MARK: - Palette (tuned for the dark card background)

    static let clearWhite = Color.white.opacity(0.92)
    static let slateGray = Color.white.opacity(0.38)
    static let rainBlue = Color.clearSkyAccent.opacity(0.75)
    /// Opaque deep indigo — distinctly darker/more saturated than `rainBlue`, still legible
    /// against the near-black sheet background.
    static let stormBlue = Color(red: 0.20, green: 0.16, blue: 0.55)
    static let snowIce = Color(red: 0.72, green: 0.88, blue: 0.97)
}
