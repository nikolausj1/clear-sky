import SwiftUI

/// Doodle layer 4, "Time-of-day lighting" (PRD Section 7): "a color-grade gradient and sun/
/// moon position reflecting dawn, day, dusk, or night." Split into two view structs so the
/// composited scene can sandwich the weather-condition and season layers between them (sky
/// behind the hills, celestial body behind the clouds) — see `DoodleSceneView` for the actual
/// paint order and why it deliberately isn't a literal "layer 4 fully on top of 1-3" stack
/// (that would just paint over the whole scene with an opaque rectangle).
///
/// `TimeOfDaySkyBackground` is the gradient + night stars (always the back-most element).
/// `CelestialBody` draws the sun or moon disc, dimmed/hidden under heavier weather condition
/// categories (a sunny disc doesn't make sense under `.storm`), which is why it also takes
/// `condition`.
struct TimeOfDaySkyBackground: View {
    let timeOfDay: DoodleComposer.TimeOfDay
    /// True-sky doodle QC fix (defect 2, "planets indistinguishable from twinkle stars"): needed
    /// only so a decorative `TwinkleStar` can be suppressed when it would otherwise land within
    /// ~30pt of a real `TrueSkyLayer` planet dot — see `nearbyPlanetPoints`. Defaulted so every
    /// existing call site (previews, and any future one that doesn't care about true-sky planets)
    /// keeps compiling unchanged; `DoodleSceneView` is the only site that passes real values.
    var condition: DoodleComposer.ConditionCategory = .clear
    var trueSky: DoodleComposer.TrueSkyScene = DoodleComposer.TrueSkyScene()

    private static let starPositions: [(CGFloat, CGFloat, CGFloat)] = [
        (0.08, 0.15, 1.6), (0.18, 0.35, 1.1), (0.30, 0.10, 1.3), (0.42, 0.28, 1.0),
        (0.58, 0.12, 1.4), (0.68, 0.32, 1.0), (0.80, 0.08, 1.2), (0.90, 0.22, 1.5),
        (0.50, 0.40, 0.9), (0.14, 0.05, 1.0),
    ]

    /// Suppression radius, matching the defect-2 bar exactly ("suppress/dim any TwinkleStar
    /// within ~30pt of a planet dot").
    private static let planetClearanceRadius: CGFloat = 30

    var body: some View {
        ZStack {
            LinearGradient(colors: skyColors, startPoint: .top, endPoint: .bottom)

            if timeOfDay == .night {
                GeometryReader { proxy in
                    // Reuses `TrueSkyLayer`'s exact gating + azimuth/altitude -> fraction math
                    // (`planetDotFractions`) rather than guessing independently whether/where a
                    // planet dot will paint this frame — one source of truth, so this can never
                    // drift out of sync with what `TrueSkyLayer` actually renders.
                    let planetPoints = TrueSkyLayer.planetDotFractions(
                        timeOfDay: timeOfDay, condition: condition, trueSky: trueSky
                    ).map { CGPoint(x: proxy.size.width * $0.xFraction, y: proxy.size.height * $0.yFraction) }

                    ForEach(Array(Self.starPositions.enumerated()), id: \.offset) { index, star in
                        let starPoint = CGPoint(x: proxy.size.width * star.0, y: proxy.size.height * star.1)
                        if !planetPoints.contains(where: { hypot($0.x - starPoint.x, $0.y - starPoint.y) < Self.planetClearanceRadius }) {
                            TwinkleStar(baseSize: star.2 * 2.2, phaseOffset: Double(index) * 0.6)
                                .position(x: starPoint.x, y: starPoint.y)
                        }
                    }
                }
            }
        }
        .allowsHitTesting(false)
    }

    private var skyColors: [Color] {
        switch timeOfDay {
        case .dawn:
            return [
                Color(red: 0.42, green: 0.38, blue: 0.58),
                Color(red: 0.87, green: 0.58, blue: 0.55),
                Color(red: 0.99, green: 0.80, blue: 0.62),
            ]
        case .day:
            return [
                Color(red: 0.27, green: 0.58, blue: 0.92),
                Color(red: 0.52, green: 0.76, blue: 0.95),
                Color(red: 0.80, green: 0.90, blue: 0.98),
            ]
        case .dusk:
            return [
                Color(red: 0.15, green: 0.14, blue: 0.32),
                Color(red: 0.56, green: 0.28, blue: 0.38),
                Color(red: 0.90, green: 0.53, blue: 0.35),
            ]
        case .night:
            return [
                Color(red: 0.02, green: 0.03, blue: 0.11),
                Color(red: 0.05, green: 0.07, blue: 0.19),
                Color(red: 0.10, green: 0.12, blue: 0.24),
            ]
        }
    }
}

/// A single twinkling star: a very slow, cheap opacity loop (Core-Animation-driven via
/// `withAnimation(repeatForever)`, not a per-frame timer) — "subtle looped transforms" per the
/// performance guidance, not a `TimelineView` redraw loop.
private struct TwinkleStar: View {
    let baseSize: CGFloat
    let phaseOffset: Double
    @State private var bright = false

    var body: some View {
        Circle()
            .fill(Color.white.opacity(bright ? 0.95 : 0.45))
            .frame(width: baseSize, height: baseSize)
            .onAppear {
                withAnimation(
                    .easeInOut(duration: 2.6).repeatForever(autoreverses: true).delay(phaseOffset)
                ) {
                    bright = true
                }
            }
    }
}

/// The sun or moon disc. Dimmed/scaled down under obscuring weather so it reads as "behind
/// clouds" without needing real cloud-occlusion masking.
struct CelestialBody: View {
    let timeOfDay: DoodleComposer.TimeOfDay
    let condition: DoodleComposer.ConditionCategory
    /// Feeds `FullMoonCalculator.moonPhase(on:)` so ordinary nights show a waxing/waning
    /// crescent rather than an identical full disc every night — see that doc comment.
    /// `SpecialDayOverlayLayer`'s `fullMoon` case brightens/rings this on genuine full-moon
    /// nights (when this same calculation is already near-full on its own).
    let date: Date

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            disc
                .frame(width: diameter(in: size), height: diameter(in: size))
                .opacity(opacity)
                .position(x: size.width * xFraction, y: size.height * yFraction)
        }
        .allowsHitTesting(false)
    }

    private var isNight: Bool { timeOfDay == .night }

    private var moonPhase: (illumination: Double, waxing: Bool) {
        FullMoonCalculator.moonPhase(on: date)
    }

    /// Matches `diameter(in:)`'s fixed night-time value — kept as an explicit constant here
    /// (rather than re-measured via a nested `GeometryReader`) so the waxing/waning shadow
    /// circle below is guaranteed the same size as the moon disc it's clipped against.
    private static let nightMoonDiameter: CGFloat = 30

    @ViewBuilder
    private var disc: some View {
        if isNight {
            ZStack {
                Circle()
                    .fill(Color(red: 0.93, green: 0.94, blue: 0.90))
                Circle()
                    .fill(Color.black.opacity(0.06))
                    .frame(width: 10, height: 10)
                    .offset(x: -6, y: 4)
                Circle()
                    .fill(Color.black.opacity(0.05))
                    .frame(width: 7, height: 7)
                    .offset(x: 5, y: -6)

                // Waxing/waning shadow: a dark circle the same size as the moon, slid across
                // it — 0 offset (fully covering, "new") at low illumination, a full diameter
                // away (no coverage, "full") at high illumination. A flat-illustration
                // approximation of a lunar phase, not an astronomically exact terminator.
                Circle()
                    .fill(Color(red: 0.05, green: 0.06, blue: 0.16).opacity(0.92))
                    .frame(width: Self.nightMoonDiameter, height: Self.nightMoonDiameter)
                    .offset(x: (moonPhase.waxing ? -1 : 1) * moonPhase.illumination * Self.nightMoonDiameter)
            }
            .frame(width: Self.nightMoonDiameter, height: Self.nightMoonDiameter)
            .clipShape(Circle())
            .shadow(color: .white.opacity(0.5), radius: 12)
        } else {
            Circle()
                .fill(
                    RadialGradient(
                        colors: [sunCoreColor, sunCoreColor.opacity(0.0)],
                        center: .center,
                        startRadius: 1,
                        endRadius: 46
                    )
                )
                .overlay(Circle().fill(sunCoreColor).scaleEffect(0.55))
        }
    }

    private var sunCoreColor: Color {
        switch timeOfDay {
        case .dawn, .dusk: return Color(red: 0.99, green: 0.70, blue: 0.42)
        default: return Color(red: 1.0, green: 0.92, blue: 0.55)
        }
    }

    private func diameter(in size: CGSize) -> CGFloat {
        isNight ? 30 : min(72, size.width * 0.18)
    }

    /// Hero-chrome avoidance (UX redesign, lead fix): in the full-bleed hero the top band is
    /// crowded chrome — status bar/Dynamic Island across the top, the centered city title, and
    /// the ellipsis button pinned top-RIGHT — and the temperature group owns the horizontal
    /// center. Clamping the y position alone can't clear the ellipsis because the day sun's
    /// disc + glow is ~86pt wide; any top-right placement collides. So the day sun lives in
    /// the upper-LEFT quadrant (the one quiet region), the night moon sits right-of-center but
    /// below the chrome band, and dawn/dusk stay low on the horizon as before. The y floor is
    /// a safety net so no future raw position can wander back into the chrome band.
    private var xFraction: CGFloat {
        switch timeOfDay {
        case .dawn: return 0.20
        case .day: return 0.18
        case .dusk: return 0.78
        case .night: return 0.72
        }
    }

    private static let topInsetFraction: CGFloat = 0.26

    private var yFraction: CGFloat {
        let raw: CGFloat
        switch timeOfDay {
        case .dawn: raw = 0.62
        case .day: raw = 0.34
        case .dusk: raw = 0.58
        case .night: raw = 0.26
        }
        return max(raw, Self.topInsetFraction)
    }

    /// Obscured (but not erased) under cloud-bearing conditions — a sun/moon still peeking
    /// through reads more true-to-life than hiding it outright.
    private var opacity: Double {
        switch condition {
        case .clear: return 1.0
        case .cloudy: return 0.55
        case .fog: return 0.30
        case .rain, .snow: return 0.35
        case .storm: return 0.18
        }
    }
}
