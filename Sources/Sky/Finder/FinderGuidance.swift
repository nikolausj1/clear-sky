import Foundation

/// Pure math for "how do I move the phone to find this thing" — angular separation, a 2D
/// screen-space arrow direction, on-target detection, proximity tiers, and the "where is
/// everything" pull-down ribbon strip. Everything here is a pure function of az/alt numbers;
/// it doesn't know about CoreMotion, the ISS module, or any other engine. `PointingMath.swift`
/// documents the az/alt convention (0°=N/90°=E azimuth, 0°=horizon/90°=zenith altitude) this
/// file assumes throughout.
enum FinderGuidance {

    // MARK: - Guidance delta

    /// How far current pointing is from a target, and which way to move to close the gap.
    struct GuidanceDelta {
        /// True angular separation between current and target directions on the sky sphere
        /// (great-circle-style distance, not a naive `|Δaz| + |Δalt|` sum), in degrees.
        let angularSeparationDeg: Double
        /// Direction to move the phone, as an angle in screen space: **0 = straight up on the
        /// screen, increasing clockwise** (π/2 = right, π = down, -π/2 = left), normalized to
        /// `(-π, π]`. "Up" here means "up as drawn on the screen the user is looking at right
        /// now", already corrected for device roll — see `delta(from:to:deviceRollRad:)`.
        let screenArrowAngleRad: Double
        /// `true` when `angularSeparationDeg` is under the threshold (default 5°).
        let isOnTarget: Bool
        /// Coarse distance bucket for driving guidance UI (pulsing rings, color, etc.).
        let proximityTier: ProximityTier
    }

    /// Coarse distance buckets. Boundaries are closed on the near side, open on the far side —
    /// `near` is `[5°, 15°)`, `mid` is `[15°, 45°]`, `far` is `(45°, ...)` — chosen so every
    /// separation value lands in exactly one tier with no gaps.
    enum ProximityTier: Equatable {
        case locked  // < 5°
        case near    // 5°..<15°
        case mid     // 15°...45°
        case far     // > 45°
    }

    static let defaultOnTargetThresholdDeg = 5.0

    /// Computes the guidance delta from the current pointing direction to a target direction.
    ///
    /// - Parameters:
    ///   - current: Where the phone is pointing right now (az/alt degrees).
    ///   - target: Where the target is right now (az/alt degrees). For moving targets (ISS,
    ///     planets), the caller recomputes `target` and calls this fresh every frame — this
    ///     function itself has no notion of time. See `interpolatedTargetPosition` below for
    ///     turning timestamped samples into a `target` value for a given instant.
    ///   - deviceRollRad: Rotation of the phone about its own forward (camera) axis, away from
    ///     "upright" — **radians, positive = screen rotated clockwise as the user looking at it
    ///     sees it** (the same sign convention `CMAttitude.roll` uses when the device frame's Y
    ///     axis is "up the screen" as documented in `PointingMath.swift`). Pass `0` for a
    ///     no-roll-compensation arrow (e.g. if the UI already locks portrait orientation).
    ///   - onTargetThresholdDeg: Separation below which `isOnTarget` is `true`. Defaults to 5°.
    static func delta(
        from current: (azimuthDeg: Double, altitudeDeg: Double),
        to target: (azimuthDeg: Double, altitudeDeg: Double),
        deviceRollRad: Double = 0,
        onTargetThresholdDeg: Double = defaultOnTargetThresholdDeg
    ) -> GuidanceDelta {
        let separation = angularSeparationDeg(
            az1: current.azimuthDeg, alt1: current.altitudeDeg,
            az2: target.azimuthDeg, alt2: target.altitudeDeg
        )

        // Arrow direction: treat the shortest signed azimuth offset as the "horizontal/right"
        // component and the altitude offset as the "vertical/up" component of a 2D vector in
        // az-alt space, then read its angle off the up axis the same way we read compass
        // bearings off north (atan2(right, up) — right takes the role north's atan2 partner
        // "east" plays). Both components are in degrees, so this is a direction only, not a
        // literal projected-FOV arrow — appropriate for a pointing engine with no camera model.
        let deltaAzDeg = shortestAzimuthDeltaDeg(from: current.azimuthDeg, to: target.azimuthDeg)
        let deltaAltDeg = target.altitudeDeg - current.altitudeDeg
        // atan2 is scale-invariant to a shared unit, so feeding it degrees on both axes (rather
        // than converting to radians first) doesn't change the resulting angle — only the ratio
        // of the two components matters. The result itself is in radians, per atan2's contract.
        let rawArrowRad = atan2(deltaAzDeg, deltaAltDeg)

        // Roll compensation: if the phone itself is rotated by deviceRollRad, "up" on the
        // physical screen is rotated by that same amount relative to world-up. Counter-rotate
        // the world-space arrow by -deviceRollRad so it still points at the target as drawn.
        let screenArrowRad = normalizeRadians(rawArrowRad - deviceRollRad)

        return GuidanceDelta(
            angularSeparationDeg: separation,
            screenArrowAngleRad: screenArrowRad,
            isOnTarget: separation < onTargetThresholdDeg,
            proximityTier: proximityTier(forSeparationDeg: separation)
        )
    }

    /// True angular separation between two az/alt directions, via the spherical law of
    /// cosines (altitude plays the role of latitude, azimuth the role of longitude):
    /// `cos(sep) = sin(alt1)·sin(alt2) + cos(alt1)·cos(alt2)·cos(az2 - az1)`.
    /// Using `cos(az2 - az1)` directly (rather than a pre-normalized azimuth delta) gets
    /// wraparound correctness for free — `cos` is 360°-periodic, so az 350° vs az 10° gives
    /// the same result as az -10° vs az 10° (i.e. the 20° short way), with no explicit
    /// wraparound branch needed in this formula. (The `screenArrowAngleRad` computation above
    /// still needs an explicit shortest-path helper because it needs a *signed direction*, not
    /// just a distance — `cos` alone can't tell you which way is short.)
    static func angularSeparationDeg(az1: Double, alt1: Double, az2: Double, alt2: Double) -> Double {
        let alt1Rad = alt1 * degToRad
        let alt2Rad = alt2 * degToRad
        let deltaAzRad = (az2 - az1) * degToRad
        let cosSep = sin(alt1Rad) * sin(alt2Rad) + cos(alt1Rad) * cos(alt2Rad) * cos(deltaAzRad)
        return acos(cosSep.clamped(to: -1...1)) * radToDeg
    }

    /// Shortest signed azimuth offset from `from` to `to`, in `(-180, 180]` degrees. Positive
    /// means `to` is clockwise (toward higher azimuth / east) of `from` the short way; e.g.
    /// `shortestAzimuthDeltaDeg(from: 350, to: 10) == 20` (not -340).
    static func shortestAzimuthDeltaDeg(from: Double, to: Double) -> Double {
        normalizeSignedDegrees(to - from)
    }

    static func proximityTier(forSeparationDeg separation: Double) -> ProximityTier {
        if separation < 5 { return .locked }
        if separation < 15 { return .near }
        if separation <= 45 { return .mid }
        return .far
    }

    // MARK: - Moving targets

    /// Linearly interpolates a target's az/alt at `date` from a set of timestamped samples
    /// (e.g. the topocentric az/alt the UI pulled off `PassPredictor`'s pass samples — this
    /// file deliberately doesn't import the ISS module, it just takes plain tuples so any
    /// moving-target source can feed it). Returns `nil` if `samples` is empty. `date` outside
    /// the sample range clamps to the nearest end sample rather than extrapolating.
    ///
    /// Altitude interpolates linearly. Azimuth interpolates along the *shortest* arc between
    /// the bracketing samples (via `shortestAzimuthDeltaDeg`) so a pass crossing the 360°/0°
    /// seam interpolates smoothly instead of sweeping the long way around.
    static func interpolatedTargetPosition(
        samples: [(time: Date, azimuthDeg: Double, altitudeDeg: Double)],
        at date: Date
    ) -> (azimuthDeg: Double, altitudeDeg: Double)? {
        guard !samples.isEmpty else { return nil }
        let sorted = samples.sorted { $0.time < $1.time }
        if date <= sorted.first!.time { return (sorted.first!.azimuthDeg, sorted.first!.altitudeDeg) }
        if date >= sorted.last!.time { return (sorted.last!.azimuthDeg, sorted.last!.altitudeDeg) }

        // Find the bracketing pair (sorted, so a linear scan is fine for the handful of
        // samples a pass prediction realistically has — no need for binary search here).
        for i in 0..<(sorted.count - 1) {
            let a = sorted[i]
            let b = sorted[i + 1]
            guard date >= a.time && date <= b.time else { continue }
            let span = b.time.timeIntervalSince(a.time)
            let t = span > 0 ? date.timeIntervalSince(a.time) / span : 0
            let azOffset = shortestAzimuthDeltaDeg(from: a.azimuthDeg, to: b.azimuthDeg)
            let az = normalizeDegrees(a.azimuthDeg + azOffset * t)
            let alt = a.altitudeDeg + (b.altitudeDeg - a.altitudeDeg) * t
            return (az, alt)
        }
        return (sorted.last!.azimuthDeg, sorted.last!.altitudeDeg)
    }

    /// Convenience overload for callers that already have a continuous position function
    /// (e.g. evaluating SGP4 directly at an arbitrary time rather than pre-sampling a pass) —
    /// same signature shape as the sample-based overload above, but takes `position(at:)`
    /// instead of `samples`. Trivial by design: this file stays pure and time-agnostic, the
    /// closure does the actual astronomy.
    static func interpolatedTargetPosition(
        at date: Date,
        position: (Date) -> (azimuthDeg: Double, altitudeDeg: Double)
    ) -> (azimuthDeg: Double, altitudeDeg: Double) {
        position(date)
    }

    // MARK: - Sky ribbon

    /// Coarse altitude bucket for the ribbon's vertical placement/styling.
    enum AltitudeBand: Equatable {
        case belowHorizon  // < 0°
        case low           // [0°, 30°)
        case mid           // [30°, 60°)
        case high          // [60°, 90°]

        static func of(_ altitudeDeg: Double) -> AltitudeBand {
            if altitudeDeg < 0 { return .belowHorizon }
            if altitudeDeg < 30 { return .low }
            if altitudeDeg < 60 { return .mid }
            return .high
        }
    }

    /// Maps sky objects onto the "where is everything" pull-down ribbon: a 360°-wraparound
    /// horizontal strip centered on wherever the device is currently pointed.
    ///
    /// `xFraction` is `0.5` for an object dead ahead (`azimuthDeg == deviceAzimuthDeg`), and
    /// approaches the two edges of the strip as the object approaches the point directly behind
    /// the device (`deviceAzimuthDeg + 180°`) — a strip has to cut the 360° circle somewhere,
    /// and directly-behind is the natural seam since it's the point farthest from what's on
    /// screen. Concretely: `xFraction = (offset + 180) / 360`, where `offset` is the shortest
    /// signed azimuth offset from device to object (`shortestAzimuthDeltaDeg`, range
    /// `(-180°, 180°]`). That range is asymmetric at its ends — `+180°` is reachable, `-180°`
    /// is not (it ties to `+180°`) — so in practice `xFraction` reaches exactly `1.0` for an
    /// object exactly behind the device, while `0.0` is only ever approached, never reached, by
    /// objects a hair short of directly-behind on the other side. Both ends still land back at
    /// the same seam, which is what "wraparound continuity" means here: two objects a couple
    /// degrees apart on either side of directly-behind land near opposite numeric ends of the
    /// strip (~0 and ~1), not adjacent — that's the strip's cut point, not a bug.
    static func ribbonPositions(
        objects: [(name: String, azimuthDeg: Double, altitudeDeg: Double)],
        deviceAzimuthDeg: Double
    ) -> [(name: String, xFraction: Double, altBand: AltitudeBand)] {
        objects.map { object in
            let offset = shortestAzimuthDeltaDeg(from: deviceAzimuthDeg, to: object.azimuthDeg)
            let xFraction = (offset + 180.0) / 360.0
            return (object.name, xFraction, AltitudeBand.of(object.altitudeDeg))
        }
    }
}
