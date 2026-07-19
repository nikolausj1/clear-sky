import SwiftUI

/// Night Vision work package: a single app-wide toggle that converts every surface — hero art,
/// text, chips, sheets, the works — to deep-red-on-black, preserving an astronomer's
/// dark-adapted vision. No exceptions: purity beats prettiness here (see this type's call sites'
/// doc comments for the one place that's tempting to special-case, the True-Sky hero, and why it
/// doesn't get one).
///
/// Backed directly by `UserDefaults` rather than a per-View `@AppStorage`, same rationale as
/// `UnitsSettings`: this needs to be readable from a global `.shared` singleton (see
/// `nightVisionAware()` below) rather than threaded through the environment to every sheet, since
/// this codebase's own sheets (`NavigationShell`'s Locations/Settings sheets) already show that a
/// custom `.environment(_:)` value applied to a sibling view tree does NOT automatically reach
/// `.sheet` content — it has to be re-applied at each sheet's own root. A singleton read directly
/// inside a shared `ViewModifier` sidesteps that entirely: every call site of `.nightVisionAware()`
/// picks up the current state with no explicit plumbing, and `@Observable` still gives every one
/// of those views automatic invalidation when the toggle flips.
@Observable
final class NightVisionMode {
    static let storageKey = "nightVisionEnabled"
    static let shared = NightVisionMode()

    var enabled: Bool {
        didSet {
            guard enabled != oldValue else { return }
            userDefaults.set(enabled, forKey: Self.storageKey)
        }
    }

    private let userDefaults: UserDefaults

    /// `-nightVision` (sim-verify only, see `NavigationShell`'s launch-arg hook doc comment):
    /// forces the mode on at launch regardless of the persisted preference, so a screenshot
    /// doesn't depend on the toggle already being on from a prior run.
    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        if CommandLine.arguments.contains("-nightVision") {
            enabled = true
        } else {
            enabled = userDefaults.bool(forKey: Self.storageKey)
        }
    }
}

/// The deep-red tint every surface multiplies toward when Night Vision is on. Chosen per the
/// work order: saturated, low-green/blue so white text and light chrome read as red, not pink.
private let nightVisionTintColor = Color(red: 1.0, green: 0.08, blue: 0.05)

/// The compositing technique, decided empirically by screenshotting both against the live
/// Forecast page (`-nightVision` vs. a since-removed `-nvMultiplyOnly` comparison flag) side by
/// side: **desaturate, then multiply** — not multiply alone. `colorMultiply` alone was fine for
/// already-white/gray chrome, but it broke every place this app uses `Color.clearSkyAccent`
/// (a saturated blue): the selected Forecast tab pill and the "Now" hourly-row temperature chip
/// both went nearly indistinguishable from the black background, because blue's green/blue
/// channels are exactly what the red tint multiplies toward zero. Desaturating FIRST converts
/// that same blue to a mid-gray by luminance, and only then multiplying by red recovers a
/// legible, evenly-lit red pill — matching how a real red-light astronomy headlamp reads a
/// colored surface by brightness, not hue. Accepted tradeoff, exactly as the work order
/// anticipated: the timeline strip's per-planet color coding collapses to intensity-only.
struct NightVisionModifier: ViewModifier {
    private var mode: NightVisionMode { NightVisionMode.shared }

    func body(content: Content) -> some View {
        content
            .saturation(mode.enabled ? 0.0 : 1.0)
            .colorMultiply(mode.enabled ? nightVisionTintColor : .white)
            // Owner note: animate the filter itself so the whole app doesn't strobe when the
            // quick toggle or the Settings toggle flips — ~0.3s ease, per work order.
            .animation(.easeInOut(duration: 0.3), value: mode.enabled)
    }
}

extension View {
    /// Applied at the app root (`ClearSkyApp`) AND, separately, at the root of every `.sheet(...)`
    /// presentation (`.sheet` content is a fresh presentation, not a rendering-tree descendant of
    /// the root's `.colorMultiply`/`.saturation`, so it does not inherit those automatically —
    /// unlike `.tint`/`.preferredColorScheme`, which are environment-propagated and DO reach
    /// sheets from the root alone). Grep `.sheet(` across `Sources/` before adding a new sheet:
    /// every existing call site applies this at its own sheet content's root.
    func nightVisionAware() -> some View {
        modifier(NightVisionModifier())
    }
}
