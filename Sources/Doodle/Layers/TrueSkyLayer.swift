import SwiftUI

/// The true-sky doodle: at night (and dusk), the illustrated hero scene stops being generic and
/// shows tonight's ACTUAL sky — correctly-placed bright-planet dots, a faint aurora glow on the
/// horizon when odds are fair-or-better, and (during a real ISS pass) a tiny satellite streaking
/// across the scene. Invisible to anyone who doesn't know; a quiet payoff for anyone who does —
/// the app icon already depicts exactly this (planet dots + a streak), so this layer is what
/// makes the live scene deliver on that promise.
///
/// **Z-order (see `DoodleSceneView`'s paint order):** painted right after `CelestialBody` and
/// right before `WeatherClouds`. After the moon, not before, so a planet dot never reads as
/// "behind" the moon disc for no reason; before the clouds so a cloudy/foggy scene's drifting
/// cloud puffs visually pass in front of the aurora glow/planet dots, reinforcing this layer's
/// own condition-based hide/dim logic below (belt-and-suspenders, not a substitute for it) — and
/// before `IllustratedLandscapeLayer` so that art's opaque bottom strip naturally caps the aurora
/// glow at the hill line without this layer needing to know the illustration's exact horizon
/// pixel row.
///
/// **Azimuth/altitude -> scene mapping.** The illustrated scene faces roughly south (that's how
/// the hills read: a single low ridge, not a 360° panorama). Azimuth 90° (due east) through 180°
/// (south) to 270° (due west) is mapped left-to-right across the scene's width; anything outside
/// that window is behind the viewer and gets no dot at all — see `xFractionStrict`. Altitude 0°
/// (the horizon) through 60° (high overhead, in practice the top of what's worth drawing) maps
/// bottom-of-sky to upper-sky, clamped clear of the top chrome zone using the same
/// `topInsetFraction` convention `CelestialBody` already uses (0.26) — see `yFraction`.
///
/// **Cheap-animation philosophy** (matches `TwinkleStar`/`DriftingCloud`/`FallingStreak` in the
/// sibling layer files): nothing here polls a timer. The ISS streak is a single
/// `withAnimation(.linear(duration:))` position sweep kicked off `onAppear`; everything else is
/// static per render. No internal `Date()` calls anywhere in this file — `date` is always the
/// same top-level "now" `DoodleComposer` already threads through the rest of the scene.
struct TrueSkyLayer: View {
    let timeOfDay: DoodleComposer.TimeOfDay
    let condition: DoodleComposer.ConditionCategory
    let date: Date
    let trueSky: DoodleComposer.TrueSkyScene

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                // Anchors the ZStack's own size negotiation to `proxy`'s full measured size.
                // Every other child below is `.position()`-ed, which removes it from a ZStack's
                // normal size contribution — with no plain flexible child left, a ZStack resolves
                // its OWN size to the union of its children's un-positioned natural sizes
                // (effectively zero here), and every `.position()` call is then measured against
                // that wrongly-tiny box, not the real hero — silently misplacing every dot (this
                // was caught in sim-verify: dots computed correctly but rendered nowhere on
                // screen). A plain `Color.clear`, with no `.position()`/`.frame()` of its own, is
                // greedy — it fills whatever size is proposed to it and reports that back — so
                // it alone is enough to make the ZStack resolve to the full proposed size before
                // any sibling's `.position()` is evaluated against it.
                Color.clear

                if let opacity = auroraOpacity {
                    auroraGlow
                        .frame(width: proxy.size.width, height: proxy.size.height * 0.26)
                        .position(x: proxy.size.width / 2, y: proxy.size.height * (Self.horizonFraction - 0.02))
                        .blur(radius: 8)
                        .opacity(opacity)
                }

                ForEach(resolvedDots, id: \.body) { dot in
                    Circle()
                        .fill(Self.dotColor(for: dot.body))
                        .frame(width: dot.diameter, height: dot.diameter)
                        .shadow(color: Self.dotColor(for: dot.body).opacity(0.9), radius: dot.glowRadius)
                        .opacity(dot.opacity)
                        .position(x: proxy.size.width * dot.xFraction, y: proxy.size.height * dot.yFraction)
                }

                if let iss = issRenderData {
                    ISSStreak(
                        pass: iss.pass,
                        now: date,
                        startXFraction: iss.startX,
                        endXFraction: iss.endX,
                        yFraction: iss.y
                    )
                    .opacity(iss.opacity)
                }
            }
        }
        .allowsHitTesting(false)
    }

    // MARK: - Shared visibility gating

    /// Planets/aurora/ISS are all real-sky elements, so they all obey the same weather gate:
    /// full strength under `.clear`, dimmed (still barely there — "a hint, not a light show")
    /// under `.cloudy`, and hidden outright under anything that would actually block the sky
    /// (`.rain`/`.snow`/`.fog`/`.storm`) — same spirit as `CelestialBody.opacity`, just simpler
    /// (a moon/sun disc still reads through haze; a magnitude-3 point of light doesn't).
    private func visibilityMultiplier(for condition: DoodleComposer.ConditionCategory) -> Double? {
        switch condition {
        case .clear: return 1.0
        case .cloudy: return 0.35
        case .rain, .snow, .fog, .storm: return nil
        }
    }

    private var isNightOrDusk: Bool { timeOfDay == .night || timeOfDay == .dusk }

    // MARK: - Planet dots

    private struct ResolvedDot {
        var body: Planets.Body
        var xFraction: CGFloat
        var yFraction: CGFloat
        var diameter: CGFloat
        var glowRadius: CGFloat
        var opacity: Double
    }

    /// Planets: night + dusk only (Venus/Mercury in particular are often best just after sunset,
    /// while the sky's still dusk-blue) and condition-permitting. Azimuth outside the 90°-270°
    /// window is silently skipped (not dimmed) — that planet is behind the viewer, not obscured.
    private var resolvedDots: [ResolvedDot] {
        guard isNightOrDusk, let multiplier = visibilityMultiplier(for: condition) else { return [] }
        return trueSky.planets.compactMap { planet in
            guard let x = Self.xFractionStrict(azimuth: planet.azimuthDegrees) else { return nil }
            return ResolvedDot(
                body: planet.body,
                xFraction: x,
                yFraction: Self.yFraction(altitude: planet.altitudeDegrees),
                diameter: Self.dotDiameter(forMagnitude: planet.magnitude),
                glowRadius: Self.glowRadius(forMagnitude: planet.magnitude),
                opacity: multiplier
            )
        }
    }

    /// Venus (brightest, ~-4 mag) renders biggest with a soft glow; Saturn (dimmest naked-eye
    /// planet, ~+1 mag) renders smallest with no glow. Linear interpolation across that range,
    /// clamped so an outlier magnitude (e.g. Mars near opposition) doesn't blow past either end.
    private static func dotDiameter(forMagnitude magnitude: Double) -> CGFloat {
        let clamped = min(max(magnitude, -4.5), 1.5)
        let t = (clamped + 4.5) / 6.0 // 0 at brightest, 1 at dimmest
        return 4.0 - CGFloat(t) * 1.5 // 4.0pt -> 2.5pt
    }

    private static func glowRadius(forMagnitude magnitude: Double) -> CGFloat {
        if magnitude < -3 { return 6 }
        if magnitude < -1 { return 3 }
        return 0
    }

    /// Warm tint for Mars, pale gold for Saturn, near-white for the other three (their actual
    /// naked-eye color is close enough to white/pale-yellow that a distinct tint would just read
    /// as "wrong color star" rather than a deliberate choice).
    private static func dotColor(for body: Planets.Body) -> Color {
        switch body {
        case .venus: return Color(red: 1.0, green: 0.98, blue: 0.90)
        case .jupiter: return Color(red: 0.97, green: 0.95, blue: 0.85)
        case .mars: return Color(red: 0.95, green: 0.55, blue: 0.40)
        case .saturn: return Color(red: 0.90, green: 0.82, blue: 0.55)
        case .mercury: return Color(red: 0.85, green: 0.85, blue: 0.85)
        }
    }

    // MARK: - Aurora glow

    /// Aurora is a genuine-darkness phenomenon — night only, no dusk exception (unlike planets/
    /// ISS, twilight glow would wash it out anyway) — and only worth drawing at `.fair` odds or
    /// better (`AuroraBand` is `Comparable`, ordered `none < low < fair < good < strong`).
    private var auroraOpacity: Double? {
        guard timeOfDay == .night, let band = trueSky.auroraBand, band >= .fair else { return nil }
        guard let multiplier = visibilityMultiplier(for: condition) else { return nil }
        let base: Double
        switch band {
        case .fair: base = 0.15
        case .good: base = 0.25
        case .strong: base = 0.40
        case .none, .low: base = 0
        }
        return base * multiplier
    }

    /// A hint, not a light show: pure green for `.fair`, a green-violet blend for `.good`/
    /// `.strong` (real aurorae often show a violet/red fringe above the green band at higher
    /// activity) — `auroraOpacity` above already carries the actual strength, so these color
    /// stops stay fixed regardless of band.
    private var auroraGlow: some View {
        let green = Color(red: 0.25, green: 0.85, blue: 0.55)
        let violet = Color(red: 0.55, green: 0.35, blue: 0.85)
        let colors: [Color]
        switch trueSky.auroraBand {
        case .good, .strong:
            colors = [Color.clear, violet.opacity(0.5), green]
        default:
            colors = [Color.clear, green]
        }
        return LinearGradient(colors: colors, startPoint: .top, endPoint: .bottom)
    }

    // MARK: - ISS streak

    private struct ISSRenderData {
        var pass: ISSPass
        var startX: CGFloat
        var endX: CGFloat
        var y: CGFloat
        var opacity: Double
    }

    /// ISS passes are visible at dusk (often the brightest, most-watched passes are right after
    /// sunset) as well as full night, per work order. `TrueSkyScene.activeISSPass` is already
    /// `nil` unless `date` falls inside a real pass window (or `-forceISSStreakNow`), so the only
    /// gating left here is time-of-day + weather.
    private var issRenderData: ISSRenderData? {
        guard isNightOrDusk, let multiplier = visibilityMultiplier(for: condition), let pass = trueSky.activeISSPass else { return nil }
        return ISSRenderData(
            pass: pass,
            startX: Self.xFractionClamped(azimuth: pass.startAzimuthDeg),
            endX: Self.xFractionClamped(azimuth: pass.endAzimuthDeg),
            y: Self.yFraction(altitude: pass.peakAltitudeDeg),
            opacity: multiplier
        )
    }

    // MARK: - Coordinate mapping

    /// The top-chrome-avoidance ceiling — same constant/rationale as `CelestialBody.
    /// topInsetFraction`: no true-sky element should wander into the status-bar/title/ellipsis
    /// band regardless of how high its altitude maps.
    private static let topInsetFraction: CGFloat = 0.26
    /// Altitude-0 floor: roughly where `IllustratedLandscapeLayer`'s illustrated hill line sits
    /// (that art's opaque strip starts around 45% down a typical hero height, but the actual
    /// rendered edge varies a few percent with device aspect ratio — this is deliberately a
    /// little above the worst-case hill line so a just-cleared-the-minimum-altitude planet still
    /// reads as "in the sky," not "behind the hill").
    private static let horizonFraction: CGFloat = 0.60

    private static func yFraction(altitude: Double) -> CGFloat {
        let clamped = min(max(altitude, 0), 60)
        let t = CGFloat(clamped / 60.0)
        return horizonFraction - t * (horizonFraction - topInsetFraction)
    }

    /// Planets: strictly skip azimuths outside the "faces south" 90°-270° window — a planet
    /// behind the viewer gets no dot at all, not a clamped one at the scene's edge.
    private static func xFractionStrict(azimuth: Double) -> CGFloat? {
        guard azimuth >= 90, azimuth <= 270 else { return nil }
        return CGFloat((azimuth - 90) / 180.0)
    }

    /// ISS: clamp instead of skip. A pass sweeping in from behind the viewer (e.g. a WNW start,
    /// azimuth 292.5°) still visibly traverses most of the scene before/after that clamp point,
    /// which reads better as "a satellite crossing the sky" than not rendering the pass at all.
    private static func xFractionClamped(azimuth: Double) -> CGFloat {
        CGFloat(min(max((azimuth - 90) / 180.0, 0), 1))
    }
}

/// A tiny bright dot with a short fading trail, sweeping from `startXFraction` to
/// `endXFraction` at a fixed `yFraction` (the pass's peak altitude — a straight-line
/// approximation of the real rise/peak/set arc, in keeping with the "single linear animation,
/// no timer" cheap-animation rule). Reflects whatever fraction of the real pass has already
/// elapsed at `now` (rather than always restarting from the beginning), so a pass opened
/// mid-transit shows the satellite already partway across, still moving for the remainder of
/// its real duration.
private struct ISSStreak: View {
    let pass: ISSPass
    let now: Date
    let startXFraction: CGFloat
    let endXFraction: CGFloat
    let yFraction: CGFloat

    @State private var xFraction: CGFloat

    init(pass: ISSPass, now: Date, startXFraction: CGFloat, endXFraction: CGFloat, yFraction: CGFloat) {
        self.pass = pass
        self.now = now
        self.startXFraction = startXFraction
        self.endXFraction = endXFraction
        self.yFraction = yFraction
        let total = pass.endTime.timeIntervalSince(pass.startTime)
        let elapsed = min(max(now.timeIntervalSince(pass.startTime), 0), max(total, 0.001))
        let progress = total > 0 ? elapsed / total : 0
        _xFraction = State(initialValue: startXFraction + (endXFraction - startXFraction) * CGFloat(progress))
    }

    var body: some View {
        GeometryReader { proxy in
            let movingRight = endXFraction >= startXFraction
            ZStack {
                LinearGradient(
                    colors: [Color.white.opacity(0), Color.white.opacity(0.55)],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .frame(width: 24, height: 1.6)
                .rotationEffect(.degrees(movingRight ? 0 : 180))
                .offset(x: movingRight ? -14 : 14)

                Circle()
                    .fill(Color.white)
                    .frame(width: 3, height: 3)
                    .shadow(color: .white.opacity(0.85), radius: 3)
            }
            .position(x: proxy.size.width * xFraction, y: proxy.size.height * yFraction)
            .onAppear {
                let remaining = max(pass.endTime.timeIntervalSince(now), 0.1)
                withAnimation(.linear(duration: remaining)) {
                    xFraction = endXFraction
                }
            }
        }
    }
}
