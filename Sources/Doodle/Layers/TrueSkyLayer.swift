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
                    // True-sky doodle QC fix (defect 4, "aurora glow imperceptible"): the data
                    // pipeline was already correct (verified via on-device logging — a forced
                    // `.good` band reliably reaches `trueSky.auroraBand`); the glow itself was
                    // just too weak to see — a `0.25`-opacity gradient that faded from fully
                    // transparent at its own top edge, further softened by an 8pt blur. Taller
                    // band + less blur + a gradient that reaches real color partway down
                    // (instead of ramping the whole height) + boosted `auroraOpacity` base values
                    // below combine to make it plainly visible while `IllustratedLandscapeLayer`
                    // (painted after this layer) still caps it at the hill line — still a hint,
                    // not a light show, just no longer an imperceptible one.
                    auroraGlow
                        .frame(width: proxy.size.width, height: proxy.size.height * 0.32)
                        .position(x: proxy.size.width / 2, y: proxy.size.height * Self.horizonFraction)
                        .blur(radius: 5)
                        .opacity(opacity)
                }

                ForEach(resolvedDots, id: \.body) { dot in
                    ZStack {
                        // True-sky doodle QC fix (defect 2, "planets indistinguishable from
                        // twinkle stars"): a miniature of `CelestialBody`'s own sun treatment —
                        // a soft `RadialGradient` halo behind the solid dot — rather than a
                        // `.shadow()`, which read as barely-there at this scale. Every planet
                        // gets one now (not just the brightest), sized/opacity'd by magnitude so
                        // Venus still reads as the star of the scene.
                        Circle()
                            .fill(
                                RadialGradient(
                                    colors: [
                                        Self.dotColor(for: dot.body).opacity(dot.haloOpacity),
                                        Self.dotColor(for: dot.body).opacity(0),
                                    ],
                                    center: .center,
                                    startRadius: 0,
                                    endRadius: dot.haloDiameter / 2
                                )
                            )
                            .frame(width: dot.haloDiameter, height: dot.haloDiameter)

                        Circle()
                            .fill(Self.dotColor(for: dot.body))
                            .frame(width: dot.diameter, height: dot.diameter)
                    }
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

                if let conjunction = conjunctionRenderData {
                    let planetPoint = CGPoint(
                        x: proxy.size.width * conjunction.planetXFraction,
                        y: proxy.size.height * conjunction.planetYFraction
                    )
                    let moonPoint = CGPoint(
                        x: planetPoint.x + conjunction.moonSide * Self.conjunctionOffset,
                        y: planetPoint.y - 6
                    )
                    let realMoonPoint = CGPoint(
                        x: proxy.size.width * Self.realNightMoonXFraction,
                        y: proxy.size.height * Self.realNightMoonYFraction
                    )
                    // "SKIP if the real geometry already places both bodies in-scene (avoid
                    // doubles)": `CelestialBody` only draws a real moon disc at night (dusk shows
                    // the setting sun instead — see that file's `isNight` gate), at a FIXED
                    // decorative position, not this pairing's real one. If the mini-moon this
                    // layer would draw lands close enough to that fixed disc, painting a second
                    // small crescent right next to it would read as a rendering glitch (two
                    // moons), not a deliberate pairing indicator — so it's skipped, and the real
                    // moon disc (already on screen) stands in for it instead.
                    let readsAsDouble = timeOfDay == .night
                        && hypot(moonPoint.x - realMoonPoint.x, moonPoint.y - realMoonPoint.y) < Self.doubleAvoidanceThresholdPoints
                    if !readsAsDouble {
                        MoonPhaseDisc(illumination: conjunction.illumination, waxing: conjunction.waxing, diameter: 13, style: .dark)
                            .position(moonPoint)
                            .opacity(conjunction.opacity)
                    }
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
    /// (a moon/sun disc still reads through haze; a magnitude-3 point of light doesn't). `static`
    /// (not just an instance method) so `TimeOfDaySkyBackground`'s twinkle-star suppression (see
    /// `planetDotFractions` below) can reuse the exact same gate without duplicating it.
    static func visibilityMultiplier(for condition: DoodleComposer.ConditionCategory) -> Double? {
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
        var haloDiameter: CGFloat
        var haloOpacity: Double
        var opacity: Double
    }

    /// A resolved planet dot's screen-fraction position and identity, minus the rendering
    /// specifics (size/color/glow) that only `TrueSkyLayer` itself needs. Exposed so
    /// `TimeOfDaySkyBackground` can compute the exact same set (true-sky doodle QC fix, defect
    /// 2: "suppress/dim any TwinkleStar within ~30pt of a planet dot") without duplicating the
    /// night/dusk + weather-condition gating or the azimuth/altitude -> fraction math — one
    /// source of truth for "where will a planet dot actually paint this frame."
    struct PlanetDotFraction {
        var body: Planets.Body
        var xFraction: CGFloat
        var yFraction: CGFloat
        var magnitude: Double
    }

    /// Planets: night + dusk only (Venus/Mercury in particular are often best just after sunset,
    /// while the sky's still dusk-blue) and condition-permitting. Azimuth outside the 90°-270°
    /// window is silently skipped (not dimmed) — that planet is behind the viewer, not obscured.
    static func planetDotFractions(
        timeOfDay: DoodleComposer.TimeOfDay,
        condition: DoodleComposer.ConditionCategory,
        trueSky: DoodleComposer.TrueSkyScene
    ) -> [PlanetDotFraction] {
        guard timeOfDay == .night || timeOfDay == .dusk, visibilityMultiplier(for: condition) != nil else { return [] }
        return trueSky.planets.compactMap { planet in
            guard let x = xFractionStrict(azimuth: planet.azimuthDegrees) else { return nil }
            return PlanetDotFraction(
                body: planet.body,
                xFraction: x,
                yFraction: yFraction(altitude: planet.altitudeDegrees),
                magnitude: planet.magnitude
            )
        }
    }

    private var resolvedDots: [ResolvedDot] {
        guard let multiplier = Self.visibilityMultiplier(for: condition) else { return [] }
        return Self.planetDotFractions(timeOfDay: timeOfDay, condition: condition, trueSky: trueSky).map { fraction in
            ResolvedDot(
                body: fraction.body,
                xFraction: fraction.xFraction,
                yFraction: fraction.yFraction,
                diameter: Self.dotDiameter(for: fraction.body),
                haloDiameter: Self.haloDiameter(for: fraction.body),
                haloOpacity: Self.haloOpacity(forMagnitude: fraction.magnitude),
                opacity: multiplier
            )
        }
    }

    /// True-sky doodle QC fix (defect 2 bar, verbatim): "Venus ~6pt, others ~4pt" — a fixed size
    /// per body rather than the previous continuous magnitude interpolation (which shrank Venus
    /// down to barely bigger than a twinkle star). Magnitude still drives `haloOpacity` below, so
    /// Saturn reads dimmer than Venus without needing a smaller dot too.
    private static func dotDiameter(for body: Planets.Body) -> CGFloat {
        body == .venus ? 6 : 4
    }

    /// The soft halo's overall size — "miniature of the sun's treatment" (`CelestialBody`'s
    /// `RadialGradient`), scaled down to planet-dot proportions. Venus gets a visibly bigger
    /// glow than the rest, matching its ~6pt vs ~4pt dot.
    private static func haloDiameter(for body: Planets.Body) -> CGFloat {
        body == .venus ? 22 : 15
    }

    /// Brighter (more negative) magnitude -> a more visible halo. Even the dimmest naked-eye
    /// planet (Saturn, ~+1) still gets a faint one — every planet dot has SOME glow now, per the
    /// defect-2 bar — just weaker than Venus's.
    private static func haloOpacity(forMagnitude magnitude: Double) -> Double {
        if magnitude < -3 { return 0.55 }
        if magnitude < -1 { return 0.4 }
        return 0.28
    }

    /// Warm tint for Mars, pale gold for Saturn, near-white for the other three (their actual
    /// naked-eye color is close enough to white/pale-yellow that a distinct tint would just read
    /// as "wrong color star" rather than a deliberate choice).
    /// Non-private (Editor's-Choice sky-surfaces elevation) so `TonightSkyCard`'s dusk-dawn
    /// timeline strip and planet-row dots can reuse these exact colors rather than duplicating
    /// them — "TrueSky planet colors" per that work package's spec.
    static func dotColor(for body: Planets.Body) -> Color {
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
        guard let multiplier = Self.visibilityMultiplier(for: condition) else { return nil }
        // True-sky doodle QC fix (defect 4): raised across the board — `.fair`'s old 0.15 base,
        // run through an 8pt blur on top, was invisible even under `.forceAuroraBand` sim-verify
        // (see `body`'s comment). Still ordered fair < good < strong so the band still reads as
        // a genuine strength signal, not just an on/off glow.
        let base: Double
        switch band {
        case .fair: base = 0.35
        case .good: base = 0.55
        case .strong: base = 0.75
        case .none, .low: base = 0
        }
        return base * multiplier
    }

    /// A hint, not a light show: pure green for `.fair`, a green-violet blend for `.good`/
    /// `.strong` (real aurorae often show a violet/red fringe above the green band at higher
    /// activity) — `auroraOpacity` above already carries the actual strength, so these color
    /// stops stay fixed regardless of band. True-sky doodle QC fix (defect 4): the gradient used
    /// to ramp from fully-`.clear` at its own top edge all the way to color only at the very
    /// bottom, so roughly half the band's height read as barely-there regardless of
    /// `auroraOpacity`'s value. Reaching solid color by the midpoint (instead of only at the
    /// bottom edge) concentrates the same opacity budget into a band that's actually visible.
    private var auroraGlow: some View {
        let green = Color(red: 0.25, green: 0.95, blue: 0.55)
        let violet = Color(red: 0.60, green: 0.40, blue: 0.95)
        let colors: [Color]
        switch trueSky.auroraBand {
        case .good, .strong:
            colors = [Color.clear, violet.opacity(0.65), green, green.opacity(0.9)]
        default:
            colors = [Color.clear, green.opacity(0.85), green]
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
        guard isNightOrDusk, let multiplier = Self.visibilityMultiplier(for: condition), let pass = trueSky.activeISSPass else { return nil }
        return ISSRenderData(
            pass: pass,
            startX: Self.xFractionClamped(azimuth: pass.startAzimuthDeg),
            endX: Self.xFractionClamped(azimuth: pass.endAzimuthDeg),
            y: Self.yFraction(altitude: pass.peakAltitudeDeg),
            opacity: multiplier
        )
    }

    // MARK: - Conjunction scene (header space-event layers)

    private struct ConjunctionRenderData {
        var planetXFraction: CGFloat
        var planetYFraction: CGFloat
        /// +1 to draw the mini-moon to the right of the planet dot, -1 to the left — derived
        /// from whether the pairing's combined azimuth sits east or west of the planet's own
        /// real azimuth (see `conjunctionRenderData`).
        var moonSide: CGFloat
        var illumination: Double
        var waxing: Bool
        var opacity: Double
    }

    /// Fixed screen-space offset between the mini-moon and the planet dot it pairs with —
    /// deliberately NOT to-scale with the pairing's real angular separation (which can be as
    /// small as a fraction of a degree, often too tight to read at this scene's size): "the
    /// pairing's separation exaggerated only enough to read," per work order.
    private static let conjunctionOffset: CGFloat = 16

    /// `CelestialBody`'s real night-moon disc sits at this fixed decorative position (xFraction
    /// 0.72, yFraction 0.26 — see that file's `xFraction`/`yFraction` for `.night`). Duplicated
    /// as constants here rather than referenced cross-type (those are private computed
    /// properties on `CelestialBody`, not exposed constants) — grep both files together if that
    /// position is ever deliberately moved.
    private static let realNightMoonXFraction: CGFloat = 0.72
    private static let realNightMoonYFraction: CGFloat = 0.26

    /// How close (in points, at this scene's rendered size) the synthetic mini-moon would need
    /// to land to `CelestialBody`'s real moon disc before this layer skips drawing it — "avoid
    /// doubles," see `body`'s comment at the call site for the full rationale.
    private static let doubleAvoidanceThresholdPoints: CGFloat = 70

    /// Which planet (if any) a pairing is "Moon + this planet" — planet-planet pairings return
    /// `nil` here on purpose. A planet-planet pairing needs no synthetic mini-anything: both
    /// bodies already get their own real-azimuth/altitude dot from the ordinary `resolvedDots`
    /// loop above, so two planets that are genuinely close together in the real sky already read
    /// as close together on screen, for free — adding a second indicator on top would just be a
    /// duplicate. Only a Moon-involving pairing needs help, since the Moon itself has no
    /// true-sky position to plot (`CelestialBody`'s moon disc is a fixed decorative spot, not
    /// derived from real ephemeris — see the constants above).
    private static func moonPairedPlanet(_ pairing: Conjunctions.Pairing) -> Planets.Body? {
        switch (pairing.bodyA, pairing.bodyB) {
        case (.moon, .planet(let body)): return body
        case (.planet(let body), .moon): return body
        default: return nil
        }
    }

    /// Resolves tonight's conjunction pairing (if any, and if it's a Moon-planet one — see
    /// `moonPairedPlanet`) into everything `body` needs to draw the mini-moon: the paired
    /// planet's own real xFraction/yFraction (looked up from `trueSky.planets`, the exact same
    /// data `resolvedDots` already draws that planet's own dot from — this never invents a
    /// planet position `TrueSkyLayer` wouldn't otherwise show), which side to offset the
    /// mini-moon to, and tonight's real Moon illumination/waxing for an accurate little crescent.
    /// `nil` whenever any required piece is missing — a pairing exists but the paired planet
    /// isn't itself in view (behind the viewer, or below the altitude bar) draws nothing rather
    /// than fabricating a position.
    private var conjunctionRenderData: ConjunctionRenderData? {
        guard isNightOrDusk, let multiplier = Self.visibilityMultiplier(for: condition) else { return nil }
        guard let pairing = trueSky.conjunctionPairing, let planetBody = Self.moonPairedPlanet(pairing) else { return nil }
        guard let illumination = trueSky.moonIlluminatedFraction, let waxing = trueSky.moonWaxing else { return nil }
        guard let planetDot = trueSky.planets.first(where: { $0.body == planetBody }),
              let planetX = Self.xFractionStrict(azimuth: planetDot.azimuthDegrees) else { return nil }

        let moonSide: CGFloat = pairing.azimuthAtBest >= planetDot.azimuthDegrees ? 1 : -1
        return ConjunctionRenderData(
            planetXFraction: planetX,
            planetYFraction: Self.yFraction(altitude: planetDot.altitudeDegrees),
            moonSide: moonSide,
            illumination: illumination,
            waxing: waxing,
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

                // True-sky doodle QC fix (defect 3): "brighten the head dot so it reads brighter
                // than any star during a pass (physically true of the ISS)" — a soft white halo
                // (same mini-radial-gradient treatment as the true-sky planet dots) plus a
                // bigger, more strongly-shadowed core than the previous plain 3pt circle, which
                // read no brighter than a twinkle star at its peak.
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [Color.white.opacity(0.75), Color.white.opacity(0)],
                            center: .center,
                            startRadius: 0,
                            endRadius: 12
                        )
                    )
                    .frame(width: 24, height: 24)

                Circle()
                    .fill(Color.white)
                    .frame(width: 4.5, height: 4.5)
                    .shadow(color: .white.opacity(0.95), radius: 4)
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
