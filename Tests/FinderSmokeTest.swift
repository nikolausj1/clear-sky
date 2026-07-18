import Foundation
import simd

// Sky Finder pointing-math engine smoke test — validates Sources/Sky/Finder against hand
// derivations (see comments at each check; no external reference API for this one, it's pure
// geometry). Run via the engine-test recipe (see Project Build Guide.md):
//   T=$(mktemp -d) && xattr -cr Sources && cp Tests/FinderSmokeTest.swift "$T/main.swift" && \
//     swiftc -O Sources/Sky/Finder/*.swift "$T/main.swift" -o "$T/t" && "$T/t"; rm -rf "$T"

var totalChecks = 0
var passedChecks = 0

func checkValue(_ label: String, expected: Double, actual: Double, tolerance: Double, unit: String = "") {
    totalChecks += 1
    let ok = abs(actual - expected) <= tolerance
    if ok { passedChecks += 1 }
    let status = ok ? "PASS" : "FAIL"
    print("\(status)  \(label): expected \(fmt(expected))\(unit), got \(fmt(actual))\(unit) (Δ\(String(format: "%+.4f", actual - expected))\(unit), tolerance ±\(tolerance)\(unit))")
}

/// Same as `checkValue` but compares two *angles* in degrees via their shortest signed
/// difference, so e.g. expected 0 / actual 359.999 reads as a 0.001° miss, not a 359.999° one.
func checkAngleDeg(_ label: String, expected: Double, actual: Double, tolerance: Double) {
    totalChecks += 1
    let delta = FinderGuidance.shortestAzimuthDeltaDeg(from: expected, to: actual)
    let ok = abs(delta) <= tolerance
    if ok { passedChecks += 1 }
    let status = ok ? "PASS" : "FAIL"
    print("\(status)  \(label): expected \(fmt(expected))°, got \(fmt(actual))° (Δ\(String(format: "%+.4f", delta))°, tolerance ±\(tolerance)°)")
}

func checkBool(_ label: String, expected: Bool, actual: Bool) {
    totalChecks += 1
    let ok = expected == actual
    if ok { passedChecks += 1 }
    print("\(ok ? "PASS" : "FAIL")  \(label): expected \(expected), got \(actual)")
}

func checkEqual<T: Equatable>(_ label: String, expected: T, actual: T) {
    totalChecks += 1
    let ok = expected == actual
    if ok { passedChecks += 1 }
    print("\(ok ? "PASS" : "FAIL")  \(label): expected \(expected), got \(actual)")
}

func fmt(_ x: Double) -> String { String(format: "%.4f", x) }

// MARK: - Attitude construction helper

/// Builds a device→world rotation quaternion from the three device axes — X = screen-right,
/// Y = screen-top, Z = out-of-the-screen-toward-the-user, per `PointingMath.swift`'s device
/// frame convention — expressed as unit vectors in the world NWU frame (world x/y/z components
/// = north/west/up, per the same file's world frame convention). Asserts the three axes are
/// actually orthonormal and right-handed (X × Y == Z) so a derivation mistake in *this test
/// file* fails loudly at construction time instead of silently producing a wrong expected value
/// three lines later.
func buildAttitude(x: SIMD3<Double>, y: SIMD3<Double>, z: SIMD3<Double>) -> simd_quatd {
    let tol = 1e-9
    precondition(abs(simd_length(x) - 1) < tol, "device X axis must be unit length")
    precondition(abs(simd_length(y) - 1) < tol, "device Y axis must be unit length")
    precondition(abs(simd_length(z) - 1) < tol, "device Z axis must be unit length")
    precondition(abs(simd_dot(x, y)) < tol, "device X, Y axes must be orthogonal")
    precondition(abs(simd_dot(y, z)) < tol, "device Y, Z axes must be orthogonal")
    precondition(abs(simd_dot(x, z)) < tol, "device X, Z axes must be orthogonal")
    precondition(simd_length(simd_cross(x, y) - z) < 1e-6, "device axes must be right-handed: X × Y must equal Z")
    return simd_quatd(simd_double3x3(x, y, z))
}

// World-frame unit vectors (x, y, z components = north, west, up), spelled out for readability
// in the derivations below.
let N = SIMD3<Double>(1, 0, 0)
let S = SIMD3<Double>(-1, 0, 0)
let W = SIMD3<Double>(0, 1, 0)
let E = SIMD3<Double>(0, -1, 0)
let U = SIMD3<Double>(0, 0, 1)
let D = SIMD3<Double>(0, 0, -1)
let sqrt2over2 = 0.7071067811865476

print("================================================================")
print(" Sky Finder pointing-math engine smoke test")
print("================================================================\n")

// MARK: 1. PointingMath.skyDirection — hand-derived attitudes

print("--- skyDirection: hand-derived device attitudes ---")

do {
    // Phone flat on a table, screen facing down, back camera facing straight up at the zenith.
    // Camera direction (-Z device) must equal Up. Pick device Y (top edge) = North (arbitrary,
    // since azimuth is undefined at the zenith) => device Z = -Up = Down, and by the right-hand
    // rule X = Y × Z = North × Down = West (verified: N×D = (1,0,0)×(0,0,-1) = (0,1,0) = W).
    let flatZenith = buildAttitude(x: W, y: N, z: D)
    let result = PointingMath.skyDirection(attitude: flatZenith)
    checkValue("Flat, camera-to-zenith: altitude ≈ 90°", expected: 90, actual: result.altitudeDeg, tolerance: 0.01, unit: "°")
    checkValue("Flat, camera-to-zenith: azimuth confidence ≈ 0 (pole, azimuth undefined)", expected: 0, actual: result.azimuthConfidence, tolerance: 0.01)
}

do {
    // Phone flat on a table, screen facing up, back camera facing straight down at the nadir.
    // -Z device = Down => Z device = Up. Pick Y (top edge) = North => X = Y × Z = North × Up
    // = West is wrong sign check: N×U = (1,0,0)×(0,0,1) = (0,-1,0) = East. So X = East here.
    let flatNadir = buildAttitude(x: E, y: N, z: U)
    let result = PointingMath.skyDirection(attitude: flatNadir)
    checkValue("Flat, camera-to-nadir: altitude ≈ -90°", expected: -90, actual: result.altitudeDeg, tolerance: 0.01, unit: "°")
    checkValue("Flat, camera-to-nadir: azimuth confidence ≈ 0 (pole)", expected: 0, actual: result.azimuthConfidence, tolerance: 0.01)
}

do {
    // Phone held upright in normal portrait reading position, screen facing the user, back
    // camera pointing due north and level with the horizon. Camera direction (-Z device) =
    // North => Z device = South. Y device (top edge, phone held upright/not tilted) = Up.
    // X device (screen-right as the user views it) = Y × Z = Up × South
    // = (0,0,1)×(-1,0,0) = (0,-1,0) = East — matches intuition: facing north, your right
    // hand points east.
    let uprightNorth = buildAttitude(x: E, y: U, z: S)
    let result = PointingMath.skyDirection(attitude: uprightNorth)
    checkAngleDeg("Upright portrait, facing true north: azimuth ≈ 0°", expected: 0, actual: result.azimuthDeg, tolerance: 0.01)
    checkValue("Upright portrait, facing true north: altitude ≈ 0°", expected: 0, actual: result.altitudeDeg, tolerance: 0.01, unit: "°")
    checkValue("Upright portrait, facing true north: azimuth confidence ≈ 1 (level horizon)", expected: 1, actual: result.azimuthConfidence, tolerance: 0.0001)

    // Same attitude, but through the .xArbitraryCorrectedZVertical path: the adapter tells us
    // this frame's X axis (whatever the raw quaternion measures azimuth relative to) actually
    // corresponds to a true heading of 30° — e.g. the phone's arbitrary reference happened to
    // be pointed 30° east of true north when motion updates started. Azimuth should shift by
    // exactly that offset.
    let offsetResult = PointingMath.skyDirection(attitude: uprightNorth, headingOffsetDegrees: 30)
    checkAngleDeg("Upright, facing north raw + 30° heading offset: azimuth ≈ 30°", expected: 30, actual: offsetResult.azimuthDeg, tolerance: 0.01)
}

do {
    // Starting from upright-facing-north, rotate the phone 90° to the right (like a person
    // turning to their right while holding it) — camera direction (-Z) now points due east.
    // Z device = -East = West. Y device unchanged = Up (still upright, no tilt). X device =
    // Y × Z = Up × West = (0,0,1)×(0,1,0) = (-1,0,0) = South — matches intuition again: facing
    // east, your right hand points south.
    let facingEast = buildAttitude(x: S, y: U, z: W)
    let result = PointingMath.skyDirection(attitude: facingEast)
    checkAngleDeg("Rotated 90° right from north: azimuth ≈ 90° (E)", expected: 90, actual: result.azimuthDeg, tolerance: 0.01)
    checkValue("Rotated 90° right from north: altitude ≈ 0°", expected: 0, actual: result.altitudeDeg, tolerance: 0.01, unit: "°")
}

do {
    // Continue: rotate 90° right again from facing-east => facing south. Camera (-Z) = South
    // => Z = North. X = Y × Z = Up × North = (0,0,1)×(1,0,0) = (0,1,0) = West.
    let facingSouth = buildAttitude(x: W, y: U, z: N)
    let result = PointingMath.skyDirection(attitude: facingSouth)
    checkAngleDeg("Rotated 180° from north: azimuth ≈ 180° (S)", expected: 180, actual: result.azimuthDeg, tolerance: 0.01)
}

do {
    // And once more => facing west. Camera (-Z) = West => Z = East. X = Y × Z = Up × East
    // = (0,0,1)×(0,-1,0) = (1,0,0) = North.
    let facingWest = buildAttitude(x: N, y: U, z: E)
    let result = PointingMath.skyDirection(attitude: facingWest)
    checkAngleDeg("Rotated 270° from north: azimuth ≈ 270° (W)", expected: 270, actual: result.azimuthDeg, tolerance: 0.01)
}

do {
    // From upright-facing-north, tilt the top of the phone back (away from vertical) by 45°,
    // hinging about the device's local X axis (East, unchanged by this rotation) so the camera
    // swings up from the horizon toward the zenith. Target camera direction: 45° altitude due
    // north => (cos45, 0, sin45) in (N, W, U) components. Z device = -camera = (-cos45, 0,
    // -sin45). Y device = Z × X (cyclic: Z × X = Y) = (-cos45,0,-sin45) × (0,-1,0)
    // = (0×0 - (-sin45)×(-1), (-sin45)×0 - (-cos45)×0, (-cos45)×(-1) - 0×0) = (-sin45, 0, cos45).
    let tiltedUp45 = buildAttitude(
        x: E,
        y: SIMD3<Double>(-sqrt2over2, 0, sqrt2over2),
        z: SIMD3<Double>(-sqrt2over2, 0, -sqrt2over2)
    )
    let result = PointingMath.skyDirection(attitude: tiltedUp45)
    checkAngleDeg("Tilted up 45° from north: azimuth ≈ 0°", expected: 0, actual: result.azimuthDeg, tolerance: 0.01)
    checkValue("Tilted up 45° from north: altitude ≈ 45°", expected: 45, actual: result.altitudeDeg, tolerance: 0.01, unit: "°")
}

do {
    // Mirror image: tilt the phone forward (down) 30° from level, still facing north. Target
    // camera direction: -30° altitude due north => (cos30, 0, -sin30). By the same derivation
    // pattern as above (with -30° in place of +45°): Z = -camera = (-cos30, 0, sin30);
    // Y = Z × X with X = East = (0,-1,0): Y = (-cos30,0,sin30) × (0,-1,0)
    // = (0×0 - sin30×(-1), sin30×0 - (-cos30)×0, (-cos30)×(-1) - 0×0) = (sin30, 0, cos30).
    let cos30 = cos(30 * Double.pi / 180)
    let sin30 = sin(30 * Double.pi / 180)
    let tiltedDown30 = buildAttitude(
        x: E,
        y: SIMD3<Double>(sin30, 0, cos30),
        z: SIMD3<Double>(-cos30, 0, sin30)
    )
    let result = PointingMath.skyDirection(attitude: tiltedDown30)
    checkAngleDeg("Tilted down 30° from north: azimuth ≈ 0°", expected: 0, actual: result.azimuthDeg, tolerance: 0.01)
    checkValue("Tilted down 30° from north: altitude ≈ -30°", expected: -30, actual: result.altitudeDeg, tolerance: 0.01, unit: "°")
}

// MARK: 2. PointingMath.skyDirection — pitch/heading fallback path

print("\n--- skyDirection: pitch/heading fallback (no full attitude) ---")

do {
    let result = PointingMath.skyDirection(headingDegrees: 123, pitchDegrees: 45)
    checkAngleDeg("Fallback: heading 123°, pitch 45° => azimuth 123°", expected: 123, actual: result.azimuthDeg, tolerance: 0.001)
    checkValue("Fallback: heading 123°, pitch 45° => altitude 45°", expected: 45, actual: result.altitudeDeg, tolerance: 0.001, unit: "°")
}

do {
    // Pitch beyond vertical clamps to the pole rather than reporting a nonsensical >90° altitude.
    let result = PointingMath.skyDirection(headingDegrees: 10, pitchDegrees: 120)
    checkValue("Fallback: pitch 120° clamps to altitude 90°", expected: 90, actual: result.altitudeDeg, tolerance: 0.001, unit: "°")
}

do {
    let result = PointingMath.skyDirection(headingDegrees: 400, pitchDegrees: -10)
    checkAngleDeg("Fallback: heading 400° normalizes to 40°", expected: 40, actual: result.azimuthDeg, tolerance: 0.001)
}

// MARK: 3. PointingMath.azimuthConfidence — degradation curve near the poles

print("\n--- azimuthConfidence: degradation near zenith/nadir ---")

checkValue("Confidence at alt 0° (horizon): 1.0", expected: 1.0, actual: PointingMath.azimuthConfidence(altitudeDeg: 0), tolerance: 0.0001)
checkValue("Confidence at alt 80°: 1.0 (still full)", expected: 1.0, actual: PointingMath.azimuthConfidence(altitudeDeg: 80), tolerance: 0.0001)
checkValue("Confidence at alt 85°: 0.5 (halfway through the ramp)", expected: 0.5, actual: PointingMath.azimuthConfidence(altitudeDeg: 85), tolerance: 0.0001)
checkValue("Confidence at alt 89°: 0.1 (nearly at the pole)", expected: 0.1, actual: PointingMath.azimuthConfidence(altitudeDeg: 89), tolerance: 0.0001)
checkValue("Confidence at alt 90° (zenith): 0.0", expected: 0.0, actual: PointingMath.azimuthConfidence(altitudeDeg: 90), tolerance: 0.0001)
checkValue("Confidence at alt -90° (nadir): 0.0", expected: 0.0, actual: PointingMath.azimuthConfidence(altitudeDeg: -90), tolerance: 0.0001)
checkValue("Confidence at alt -85° (near nadir): 0.5", expected: 0.5, actual: PointingMath.azimuthConfidence(altitudeDeg: -85), tolerance: 0.0001)

// MARK: 4. FinderGuidance.delta — wraparound, separation, arrow, tiers

print("\n--- FinderGuidance.delta: azimuth wraparound ---")

do {
    // Classic case from the work order: current az 350°, target az 10° — the short way around
    // the compass is +20° (350 -> 360/0 -> 10), not the naive -340°.
    let d = FinderGuidance.delta(from: (azimuthDeg: 350, altitudeDeg: 0), to: (azimuthDeg: 10, altitudeDeg: 0))
    checkValue("Wraparound 350°->10°: separation ≈ 20°", expected: 20, actual: d.angularSeparationDeg, tolerance: 0.01, unit: "°")
    // Short way is clockwise/toward increasing azimuth, i.e. "right" on screen: arrow ≈ +π/2.
    checkValue("Wraparound 350°->10°: arrow points right (short way), ≈ +π/2 rad", expected: .pi / 2, actual: d.screenArrowAngleRad, tolerance: 0.01)
    checkBool("Wraparound 350°->10°: not on-target (20° > 5° threshold)", expected: false, actual: d.isOnTarget)
}

do {
    // Reverse direction: current az 10°, target az 350° — short way is -20° (counter-clockwise
    // / "left"), same 20° separation.
    let d = FinderGuidance.delta(from: (azimuthDeg: 10, altitudeDeg: 0), to: (azimuthDeg: 350, altitudeDeg: 0))
    checkValue("Wraparound 10°->350°: separation ≈ 20°", expected: 20, actual: d.angularSeparationDeg, tolerance: 0.01, unit: "°")
    checkValue("Wraparound 10°->350°: arrow points left (short way), ≈ -π/2 rad", expected: -.pi / 2, actual: d.screenArrowAngleRad, tolerance: 0.01)
}

print("\n--- FinderGuidance.delta: combined az+alt separation ---")

do {
    // current (az 0, alt 0), target (az 90, alt 45). Spherical law of cosines:
    // cos(sep) = sin(0)·sin(45) + cos(0)·cos(45)·cos(90) = 0 + 1·0.7071·0 = 0 => sep = 90°.
    let d = FinderGuidance.delta(from: (azimuthDeg: 0, altitudeDeg: 0), to: (azimuthDeg: 90, altitudeDeg: 45))
    checkValue("Combined az+alt (0,0)->(90,45): separation ≈ 90° (spherical law of cosines)", expected: 90, actual: d.angularSeparationDeg, tolerance: 0.01, unit: "°")
}

do {
    // Same altitude both sides, but NOT the equator (alt 0) — a fixed azimuth difference away
    // from the horizon covers *less* true angular separation than the azimuth number itself,
    // same reason a degree of longitude is shorter at higher latitude ("small-circle
    // contraction"). Hand check via the spherical law of cosines: alt1=alt2=20°, Δaz=30°:
    // cos(sep) = sin(20)·sin(20) + cos(20)·cos(20)·cos(30)
    //          = 0.3420·0.3420 + 0.9397·0.9397·0.8660 = 0.1170 + 0.7645 = 0.8815
    //          => sep = acos(0.8815) ≈ 28.15° (visibly less than the naive 30°).
    let d = FinderGuidance.delta(from: (azimuthDeg: 200, altitudeDeg: 20), to: (azimuthDeg: 230, altitudeDeg: 20))
    checkValue("Same-altitude (off-equator) separation (200,20)->(230,20): ≈ 28.15° (< 30°, small-circle contraction)", expected: 28.15, actual: d.angularSeparationDeg, tolerance: 0.01, unit: "°")
}

print("\n--- FinderGuidance.delta: on-target threshold at the boundary ---")

do {
    let d = FinderGuidance.delta(from: (azimuthDeg: 0, altitudeDeg: 0), to: (azimuthDeg: 4.9, altitudeDeg: 0))
    checkValue("Separation at 4.9°", expected: 4.9, actual: d.angularSeparationDeg, tolerance: 0.001, unit: "°")
    checkBool("4.9° is on-target (< 5° default threshold)", expected: true, actual: d.isOnTarget)
    checkEqual("4.9° => proximityTier .locked", expected: FinderGuidance.ProximityTier.locked, actual: d.proximityTier)
}

do {
    let d = FinderGuidance.delta(from: (azimuthDeg: 0, altitudeDeg: 0), to: (azimuthDeg: 5.1, altitudeDeg: 0))
    checkValue("Separation at 5.1°", expected: 5.1, actual: d.angularSeparationDeg, tolerance: 0.001, unit: "°")
    checkBool("5.1° is NOT on-target (> 5° default threshold)", expected: false, actual: d.isOnTarget)
    checkEqual("5.1° => proximityTier .near", expected: FinderGuidance.ProximityTier.near, actual: d.proximityTier)
}

print("\n--- FinderGuidance.delta: proximity tier boundaries ---")
// Tested directly against FinderGuidance.proximityTier(forSeparationDeg:) with exact separation
// values, rather than deriving separation from az/alt through delta()'s trig pipeline — at
// exact tier boundaries (15.0, 45.0) a sin/cos/acos round trip can land a hair off the
// mathematical value (e.g. 14.999999999999998 instead of 15.0), which would flip the tier and
// fail the test for a floating-point reason that has nothing to do with tier-boundary logic.
// The 4.9°/5.1° on-target checks above don't have this problem since they're comfortably off
// any power-of-two-ish rounding edge, so those stay expressed through the full delta() pipeline.

checkEqual("14.9° => .near", expected: FinderGuidance.ProximityTier.near, actual: FinderGuidance.proximityTier(forSeparationDeg: 14.9))
checkEqual("15.0° => .mid", expected: FinderGuidance.ProximityTier.mid, actual: FinderGuidance.proximityTier(forSeparationDeg: 15.0))
checkEqual("45.0° => .mid", expected: FinderGuidance.ProximityTier.mid, actual: FinderGuidance.proximityTier(forSeparationDeg: 45.0))
checkEqual("45.1° => .far", expected: FinderGuidance.ProximityTier.far, actual: FinderGuidance.proximityTier(forSeparationDeg: 45.1))
checkEqual("4.99° => .locked", expected: FinderGuidance.ProximityTier.locked, actual: FinderGuidance.proximityTier(forSeparationDeg: 4.99))
checkEqual("5.0° => .near", expected: FinderGuidance.ProximityTier.near, actual: FinderGuidance.proximityTier(forSeparationDeg: 5.0))
checkEqual("0.0° (on target) => .locked", expected: FinderGuidance.ProximityTier.locked, actual: FinderGuidance.proximityTier(forSeparationDeg: 0.0))

print("\n--- FinderGuidance.delta: screen-space arrow, roll compensation, and custom threshold ---")

do {
    // Target straight "up" in az-alt space (no azimuth change, +10° altitude): arrow should
    // point straight up on an unrolled screen, i.e. 0 rad.
    let d = FinderGuidance.delta(from: (azimuthDeg: 0, altitudeDeg: 0), to: (azimuthDeg: 0, altitudeDeg: 10))
    checkValue("No roll: target straight up in alt => arrow ≈ 0 rad (up)", expected: 0, actual: d.screenArrowAngleRad, tolerance: 0.001)
}

do {
    // Same target, but the phone is physically rolled 90° clockwise (π/2 rad). What reads as
    // "up" in the world now sits to the *left* on the rolled screen, since the screen's own
    // up-vector rotated clockwise with the phone: counter-rotating the arrow by -π/2 turns
    // "0 rad (up)" into "-π/2 rad (left)".
    let d = FinderGuidance.delta(
        from: (azimuthDeg: 0, altitudeDeg: 0),
        to: (azimuthDeg: 0, altitudeDeg: 10),
        deviceRollRad: .pi / 2
    )
    checkValue("90° CW roll: same target now reads as arrow ≈ -π/2 rad (left)", expected: -.pi / 2, actual: d.screenArrowAngleRad, tolerance: 0.001)
}

do {
    // Custom (tighter) on-target threshold: 3° threshold, 4° separation should now read false.
    let d = FinderGuidance.delta(
        from: (azimuthDeg: 0, altitudeDeg: 0),
        to: (azimuthDeg: 4, altitudeDeg: 0),
        onTargetThresholdDeg: 3
    )
    checkBool("4° separation with a custom 3° threshold: not on-target", expected: false, actual: d.isOnTarget)
}

// MARK: 5. FinderGuidance.interpolatedTargetPosition — moving targets (ISS-style samples)

print("\n--- interpolatedTargetPosition: moving targets ---")

let refDate = Date(timeIntervalSinceReferenceDate: 0)

do {
    let samples: [(time: Date, azimuthDeg: Double, altitudeDeg: Double)] = [
        (refDate, 0, 10),
        (refDate.addingTimeInterval(60), 20, 30),
    ]
    let midpoint = FinderGuidance.interpolatedTargetPosition(samples: samples, at: refDate.addingTimeInterval(30))
    checkValue("Interpolation midpoint azimuth ≈ 10°", expected: 10, actual: midpoint?.azimuthDeg ?? .nan, tolerance: 0.01, unit: "°")
    checkValue("Interpolation midpoint altitude ≈ 20°", expected: 20, actual: midpoint?.altitudeDeg ?? .nan, tolerance: 0.01, unit: "°")
}

do {
    // Pass crossing the 0°/360° seam: 350° -> 10° is a 20° swing the short way, not a
    // 340°-the-long-way sweep. Midpoint should land at az ≈ 0° (i.e. 360°), not az ≈ 180°.
    let samples: [(time: Date, azimuthDeg: Double, altitudeDeg: Double)] = [
        (refDate, 350, 5),
        (refDate.addingTimeInterval(60), 10, 15),
    ]
    let midpoint = FinderGuidance.interpolatedTargetPosition(samples: samples, at: refDate.addingTimeInterval(30))
    checkAngleDeg("Seam-crossing interpolation midpoint azimuth ≈ 0°/360°", expected: 0, actual: midpoint?.azimuthDeg ?? .nan, tolerance: 0.01)
    checkValue("Seam-crossing interpolation midpoint altitude ≈ 10°", expected: 10, actual: midpoint?.altitudeDeg ?? .nan, tolerance: 0.01, unit: "°")
}

do {
    let samples: [(time: Date, azimuthDeg: Double, altitudeDeg: Double)] = [
        (refDate, 100, 20),
        (refDate.addingTimeInterval(60), 120, 40),
    ]
    let before = FinderGuidance.interpolatedTargetPosition(samples: samples, at: refDate.addingTimeInterval(-10))
    checkValue("Date before sample range clamps to first sample azimuth", expected: 100, actual: before?.azimuthDeg ?? .nan, tolerance: 0.001, unit: "°")
    let after = FinderGuidance.interpolatedTargetPosition(samples: samples, at: refDate.addingTimeInterval(9999))
    checkValue("Date after sample range clamps to last sample azimuth", expected: 120, actual: after?.azimuthDeg ?? .nan, tolerance: 0.001, unit: "°")
}

do {
    let empty: [(time: Date, azimuthDeg: Double, altitudeDeg: Double)] = []
    let result = FinderGuidance.interpolatedTargetPosition(samples: empty, at: refDate)
    checkBool("Empty sample array returns nil", expected: true, actual: result == nil)
}

do {
    // Closure overload: a continuous position(at:) function (e.g. SGP4 evaluated directly)
    // should just pass through untouched.
    let result = FinderGuidance.interpolatedTargetPosition(at: refDate) { _ in (azimuthDeg: 123, altitudeDeg: 45) }
    checkValue("Closure overload passes through azimuth", expected: 123, actual: result.azimuthDeg, tolerance: 0.001, unit: "°")
    checkValue("Closure overload passes through altitude", expected: 45, actual: result.altitudeDeg, tolerance: 0.001, unit: "°")
}

// MARK: 6. FinderGuidance.ribbonPositions — sky ribbon projection

print("\n--- ribbonPositions: sky ribbon projection ---")

do {
    let objects: [(name: String, azimuthDeg: Double, altitudeDeg: Double)] = [
        ("Dead ahead", 100, 20),
        ("Directly behind", 280, 20), // deviceAz(100) + 180
        ("Quarter turn right", 190, 20), // deviceAz + 90
        ("Quarter turn left", 10, 20), // deviceAz - 90
    ]
    let positions = FinderGuidance.ribbonPositions(objects: objects, deviceAzimuthDeg: 100)
    let byName = Dictionary(uniqueKeysWithValues: positions.map { ($0.name, $0) })

    checkValue("Ribbon: object at deviceAz => xFraction ≈ 0.5 (dead center)", expected: 0.5, actual: byName["Dead ahead"]!.xFraction, tolerance: 0.001)
    // deviceAz + 180 lands exactly at the reachable edge of the strip (see ribbonPositions doc
    // comment: +180 offset resolves to xFraction 1.0 under this engine's tie-break convention).
    checkValue("Ribbon: object at deviceAz+180 => xFraction ≈ 1.0 (edge)", expected: 1.0, actual: byName["Directly behind"]!.xFraction, tolerance: 0.001)
    checkValue("Ribbon: object at deviceAz+90 => xFraction ≈ 0.75", expected: 0.75, actual: byName["Quarter turn right"]!.xFraction, tolerance: 0.001)
    checkValue("Ribbon: object at deviceAz-90 => xFraction ≈ 0.25", expected: 0.25, actual: byName["Quarter turn left"]!.xFraction, tolerance: 0.001)
}

do {
    // Wraparound continuity at the seam: two objects just a couple degrees apart on either side
    // of "directly behind" the device should land near opposite numeric ends of the strip
    // (~0 and ~1), not adjacent to each other numerically — that's the strip's cut point, not a
    // discontinuity bug. deviceAz = 0, so directly-behind = 180°.
    let objects: [(name: String, azimuthDeg: Double, altitudeDeg: Double)] = [
        ("Just short of behind, going one way", 179.9),
        ("Just short of behind, going the other way", -179.9), // == 180.1
    ].map { (name: $0.0, azimuthDeg: $0.1, altitudeDeg: 0) }
    let positions = FinderGuidance.ribbonPositions(objects: objects, deviceAzimuthDeg: 0)
    let byName = Dictionary(uniqueKeysWithValues: positions.map { ($0.name, $0) })
    checkValue("Ribbon seam: 179.9° lands near the high edge (≈ 0.9997)", expected: 0.9997, actual: byName["Just short of behind, going one way"]!.xFraction, tolerance: 0.001)
    checkValue("Ribbon seam: -179.9°(=180.1°) lands near the low edge (≈ 0.0003)", expected: 0.0003, actual: byName["Just short of behind, going the other way"]!.xFraction, tolerance: 0.001)
}

print("\n--- ribbonPositions: altitude bands ---")

checkEqual("alt -5° => .belowHorizon", expected: FinderGuidance.AltitudeBand.belowHorizon, actual: FinderGuidance.AltitudeBand.of(-5))
checkEqual("alt 0° => .low", expected: FinderGuidance.AltitudeBand.low, actual: FinderGuidance.AltitudeBand.of(0))
checkEqual("alt 29.9° => .low", expected: FinderGuidance.AltitudeBand.low, actual: FinderGuidance.AltitudeBand.of(29.9))
checkEqual("alt 30° => .mid", expected: FinderGuidance.AltitudeBand.mid, actual: FinderGuidance.AltitudeBand.of(30))
checkEqual("alt 59.9° => .mid", expected: FinderGuidance.AltitudeBand.mid, actual: FinderGuidance.AltitudeBand.of(59.9))
checkEqual("alt 60° => .high", expected: FinderGuidance.AltitudeBand.high, actual: FinderGuidance.AltitudeBand.of(60))
checkEqual("alt 90° => .high", expected: FinderGuidance.AltitudeBand.high, actual: FinderGuidance.AltitudeBand.of(90))

// MARK: - Summary

print("\n================================================================")
print(" Summary: \(passedChecks)/\(totalChecks) checks passed")
print("================================================================")

if passedChecks == totalChecks {
    print(" ALL CHECKS PASSED")
} else {
    print(" \(totalChecks - passedChecks) CHECK(S) FAILED — see FAIL lines above")
    exit(1)
}
