import Foundation
import simd

/// Pure math mapping device orientation to sky coordinates (azimuth/altitude). No CoreMotion
/// import here on purpose: this engine takes plain quaternions/angles so it is CLI-testable
/// without a simulator. A thin CoreMotion adapter in the UI package is responsible for pulling
/// `CMDeviceMotion.attitude` and handing this engine a `simd_quatd`.
///
/// ## Coordinate conventions (read this before touching anything below)
///
/// **World / reference frame** — matches Apple's documented `CMAttitudeReferenceFrame
/// .xTrueNorthZVertical`: right-handed, **X = true north, Y = magnetic-free west, Z = up
/// (zenith)** ("NWU"). This is the frame every `simd_quatd` passed to `skyDirection` is
/// expressed relative to. We verified this is right-handed the boring way: X × Y = Z
/// (north × west = up), so `simd_double3x3(colX, colY, colZ)` built from three orthonormal
/// device-axis-in-world vectors is always a proper rotation (det = +1) as long as the axes
/// obey that same cyclic rule.
///
/// **Device frame** — matches Apple's documented `CMAttitude`/`CMDeviceMotion` device frame
/// for a phone in portrait: **X = right edge of the screen (as the user views it), Y = top
/// edge of the screen, Z = out of the screen face, toward the user.** The back camera —
/// the thing Sky Finder actually points at the sky — looks the opposite way, down **-Z**.
///
/// **Attitude quaternion** — `attitude` rotates a vector *from device space into world
/// space*: `worldVector = attitude.act(deviceVector)`. This is CoreMotion's own convention
/// (`CMAttitude.quaternion` expresses device orientation relative to the reference frame), so
/// the adapter can hand this engine `CMDeviceMotion.attitude.quaternion` (converted to
/// `simd_quatd`) with zero massaging for the `.xTrueNorthZVertical` case.
///
/// **`.xArbitraryCorrectedZVertical` frame** — this CoreMotion frame keeps Z vertical but its
/// X axis is whatever the device was facing when motion updates started, *not* true north.
/// The adapter is responsible for knowing the true compass bearing of that arbitrary X axis
/// (e.g. by sampling `CLHeading.trueHeading` once at the moment motion updates begin, or
/// continuously if it wants to re-anchor) and passing it in as `headingOffsetDegrees`. This
/// engine just adds that offset to the quaternion-derived azimuth before normalizing — see
/// `skyDirection(attitude:headingOffsetDegrees:)`. For `.xTrueNorthZVertical`, X already *is*
/// true north, so the adapter passes `headingOffsetDegrees: 0` (the default).
///
/// **Azimuth** — degrees clockwise from true north, `0 = N, 90 = E, 180 = S, 270 = W`,
/// normalized to `[0, 360)`.
///
/// **Altitude** — degrees above the horizon, `0 = horizon, 90 = zenith, -90 = nadir`.
enum PointingMath {

    /// A resolved sky-pointing direction plus a confidence signal for the azimuth component.
    struct HorizontalPosition {
        /// Degrees clockwise from true north, normalized to `[0, 360)`.
        let azimuthDeg: Double
        /// Degrees above the horizon; `90` = zenith, `-90` = nadir.
        let altitudeDeg: Double
        /// `1` = azimuth is well-determined, `0` = azimuth is meaningless (pointing at zenith
        /// or nadir, where infinitesimal attitude noise swings azimuth wildly). See
        /// `azimuthConfidence(altitudeDeg:)` for the exact curve. The UI should switch to an
        /// altitude-only guidance mode ("look straight up") when this drops low.
        let azimuthConfidence: Double
    }

    // MARK: - Primary entry point (full attitude quaternion)

    /// Resolves the direction the phone's back camera (-Z in device space) points, in the sky.
    ///
    /// - Parameters:
    ///   - attitude: Device attitude, device-space → world-space, world frame = NWU as
    ///     documented on the type. This is exactly `CMDeviceMotion.attitude.quaternion`
    ///     (converted to `simd_quatd`) when the motion manager was started with
    ///     `.xTrueNorthZVertical`.
    ///   - headingOffsetDegrees: True compass bearing (clockwise from true north) of the
    ///     world frame's X axis. `0` (the default) is correct for `.xTrueNorthZVertical`,
    ///     where X already means true north. For `.xArbitraryCorrectedZVertical`, pass the
    ///     true heading the adapter captured for that frame's arbitrary X axis; see the type
    ///     doc comment.
    static func skyDirection(attitude: simd_quatd, headingOffsetDegrees: Double = 0) -> HorizontalPosition {
        let cameraDevice = simd_double3(0, 0, -1)
        let cameraWorld = attitude.act(cameraDevice)
        return horizontalPosition(fromWorldVector: cameraWorld, headingOffsetDegrees: headingOffsetDegrees)
    }

    /// Reduced-accuracy fallback for callers that only have a compass heading and a pitch
    /// angle (no full attitude quaternion — e.g. a coarse sensor path, or a unit test that
    /// wants to sanity-check without building a quaternion). Assumes the phone is held with
    /// **zero roll** (screen's top edge pointing straight up away from gravity, not tilted
    /// sideways); if that assumption doesn't hold the real answer can be off by a lot, which
    /// is exactly why this is a fallback and not the primary path.
    ///
    /// - Parameters:
    ///   - headingDegrees: True compass heading (0...360, clockwise from N) the phone's back
    ///     is pointing, projected onto the horizontal plane.
    ///   - pitchDegrees: Tilt of the back camera away from horizontal; `0` = camera points at
    ///     the horizon, `90` = camera points at the zenith, `-90` = camera points at the nadir.
    static func skyDirection(headingDegrees: Double, pitchDegrees: Double) -> HorizontalPosition {
        let altitude = pitchDegrees.clamped(to: -90...90)
        let azimuth = normalizeDegrees(headingDegrees)
        return HorizontalPosition(
            azimuthDeg: azimuth,
            altitudeDeg: altitude,
            azimuthConfidence: azimuthConfidence(altitudeDeg: altitude)
        )
    }

    // MARK: - Shared math

    /// Converts a world-space direction vector (NWU components, need not be pre-normalized to
    /// unit length — this normalizes) into azimuth/altitude.
    ///
    /// Derivation: with the world frame's `(x, y, z) = (north, west, up)` components,
    /// `altitude = asin(up)`. For azimuth, decompose into compass components: the north
    /// component is `cos(alt)·cos(az)` and the east component is `cos(alt)·sin(az)`; east is
    /// just `-west` in this frame, i.e. `east = -y`. So `az = atan2(east, north) = atan2(-y, x)`
    /// — the same `atan2(x-component, y-component)` shape used for compass bearings generally.
    static func horizontalPosition(fromWorldVector v: simd_double3, headingOffsetDegrees: Double) -> HorizontalPosition {
        let unit = simd_length(v) > 0 ? simd_normalize(v) : simd_double3(0, 0, 1)
        let north = unit.x
        let west = unit.y
        let up = unit.z

        let altitude = asin(up.clamped(to: -1...1)) * radToDeg
        let rawAzimuth = atan2(-west, north) * radToDeg
        let azimuth = normalizeDegrees(rawAzimuth + headingOffsetDegrees)

        return HorizontalPosition(
            azimuthDeg: azimuth,
            altitudeDeg: altitude,
            azimuthConfidence: azimuthConfidence(altitudeDeg: altitude)
        )
    }

    /// Azimuth confidence, `1` down to `0` as altitude approaches the poles of the sky sphere.
    /// Azimuth is exactly the "longitude" of the horizontal coordinate system, so like any
    /// longitude it degenerates at the poles (zenith/nadir): a tiny attitude wobble there
    /// swings the computed azimuth across the full 360°. We hold confidence at `1` out to
    /// ±80° altitude (comfortably away from the pole, matches the work order's "degrades near
    /// ~80°"), then ramp linearly to `0` at the pole itself (±90°), so the UI has room to fade
    /// out azimuth-based guidance before it goes numerically meaningless.
    static func azimuthConfidence(altitudeDeg: Double) -> Double {
        let distanceFromPole = 90 - abs(altitudeDeg)
        if distanceFromPole >= 10 { return 1.0 }
        if distanceFromPole <= 0 { return 0.0 }
        return distanceFromPole / 10.0
    }
}

// MARK: - Shared angle helpers (used by FinderGuidance too)

let degToRad = Double.pi / 180.0
let radToDeg = 180.0 / Double.pi

/// Normalizes an angle in degrees to `[0, 360)`.
func normalizeDegrees(_ deg: Double) -> Double {
    let m = deg.truncatingRemainder(dividingBy: 360.0)
    return m < 0 ? m + 360.0 : m
}

/// Normalizes an angle in degrees to `(-180, 180]` — the "signed shortest offset" form used
/// for azimuth deltas (359° → 1° reads as +2°, not -358° or +358°).
func normalizeSignedDegrees(_ deg: Double) -> Double {
    let m = normalizeDegrees(deg + 180.0) - 180.0
    return m == -180.0 ? 180.0 : m
}

/// Normalizes an angle in radians to `(-π, π]`.
func normalizeRadians(_ rad: Double) -> Double {
    normalizeSignedDegrees(rad * radToDeg) * degToRad
}

// `private` so this file-local helper can't collide with the several other private
// `clamped(to:)` copies across the app (a non-private version here broke the whole-app
// build via ambiguity — caught by the notifications work package's build).
private extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
