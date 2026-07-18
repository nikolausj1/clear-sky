import SwiftUI

/// UX polish package ("Editor's-Choice polish"): the app's single accent hue, defined once so
/// every tint/selection/link/badge color across the app reads as one consistent color system
/// rather than a mix of scattered `.blue` and `.accentColor` references (there is no
/// `AccentColor` entry in `Assets.xcassets`, so `Color.accentColor` was silently falling back to
/// system blue everywhere it was used). Applied app-wide via `.tint(.clearSkyAccent)` at the
/// root (`ClearSkyApp`) plus explicit call sites (chips, tab bar, rankings badges/score bars)
/// that read the raw `Color` value rather than relying on tint inheritance.
extension Color {
    static let clearSkyAccent = Color(red: 0.16, green: 0.47, blue: 0.93)

    /// A lightened variant of `clearSkyAccent` for use against the "night panel" (Editor's-Choice
    /// sky-surfaces elevation: `TonightSkyCard`'s deep-indigo inverted card) — the base accent's
    /// saturated blue reads muddy/low-contrast against a near-black background, so the dusk-dawn
    /// timeline strip's "now" cursor uses this instead, same hue family, lifted luminance.
    static let clearSkyAccentOnDark = Color(red: 0.55, green: 0.75, blue: 1.0)
}
