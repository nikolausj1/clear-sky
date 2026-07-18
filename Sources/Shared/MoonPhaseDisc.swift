import SwiftUI

/// A rendered lunar-phase disc — the same "bright disc + a same-size dark circle slid across it"
/// approach `CelestialBody` (`Sources/Doodle/Layers/TimeOfDayLightingLayer.swift`) uses for the
/// doodle hero's night moon, factored out into a small, sizeable, reusable view (Editor's-Choice
/// sky-surfaces elevation work package) so `TonightSkyCard`'s moon row and the Space tab's Sky
/// Calendar full/new-moon glyphs can both render a phase-accurate disc without duplicating that
/// math. `CelestialBody` itself is left untouched — this is a new, independent view, not a
/// refactor of the doodle hero's already-verified rendering.
///
/// Flat-illustration approximation, not an astronomically exact terminator: at `illumination` 0
/// the shadow circle fully overlaps the disc (all-dark, "new"); at `illumination` 1 it's slid a
/// full diameter clear (all-lit, "full"); `waxing` picks which side it slides toward.
struct MoonPhaseDisc: View {
    /// 0 (new) ... 1 (full) illuminated fraction — note this is a *fraction*, not the
    /// `SkyTonight.MoonInfo.illuminatedPercent` 0...100 scale callers usually have on hand;
    /// divide by 100 at the call site.
    let illumination: Double
    let waxing: Bool
    var diameter: CGFloat = 28
    /// `.dark` renders a cool bone-white disc suited to the inverted night panel's near-black
    /// background; `.light` matches `CelestialBody`'s original off-white/near-black pair, suited
    /// to an ordinary white/paper card (the Sky Calendar's use).
    var style: Style = .dark
    /// A faint rim stroke — mainly for a near-new disc on a light card, where an all-dark circle
    /// would otherwise have no visible edge against a white background.
    var showsRim: Bool = false

    enum Style {
        case dark
        case light
    }

    private var litColor: Color {
        switch style {
        case .dark: return Color(red: 0.96, green: 0.97, blue: 0.99)
        case .light: return Color(red: 0.93, green: 0.94, blue: 0.90)
        }
    }

    private var shadowColor: Color { Color(red: 0.05, green: 0.06, blue: 0.16).opacity(0.92) }

    var body: some View {
        ZStack {
            Circle().fill(litColor)
            // Two faint craters, same proportions as `CelestialBody`'s 30pt reference disc.
            Circle()
                .fill(Color.black.opacity(0.06))
                .frame(width: diameter * (10.0 / 30.0), height: diameter * (10.0 / 30.0))
                .offset(x: -diameter * 0.2, y: diameter * (4.0 / 30.0))
            Circle()
                .fill(Color.black.opacity(0.05))
                .frame(width: diameter * (7.0 / 30.0), height: diameter * (7.0 / 30.0))
                .offset(x: diameter * (5.0 / 30.0), y: -diameter * 0.2)

            Circle()
                .fill(shadowColor)
                .frame(width: diameter, height: diameter)
                .offset(x: (waxing ? -1 : 1) * illumination * diameter)
        }
        .frame(width: diameter, height: diameter)
        .clipShape(Circle())
        .overlay {
            if showsRim {
                Circle().strokeBorder(Color.primary.opacity(0.3), lineWidth: 1)
            }
        }
        .shadow(color: .white.opacity(style == .dark ? 0.25 : 0.4), radius: diameter * 0.35)
    }
}
