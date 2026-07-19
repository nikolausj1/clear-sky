import CoreLocation
import CoreMotion
import Foundation
import Observation
import simd

/// Sky Finder's CoreMotion/CoreLocation adapter — the ONLY file in the Finder feature that
/// imports CoreMotion. Bridges live device sensors into `PointingMath`'s plain (az, alt,
/// confidence) result, published at ~30Hz, so `SkyFinderView` never touches `CMMotionManager`/
/// `CLLocationManager` directly.
///
/// ## Frame selection (see `PointingMath.swift`'s doc comment for the full frame contract)
///
/// Primary: `.xTrueNorthZVertical`. CoreMotion computes true-north-referenced attitude directly
/// (magnetometer + a location fix for magnetic declination), so `PointingMath.skyDirection
/// (attitude:)` with `headingOffsetDegrees: 0` is exact. This needs `CLLocationManager` heading
/// support AND when-in-use authorization — the app already asks for that contextually elsewhere
/// (`CurrentLocationManager`); this adapter asks too, on its own, the first time Sky Finder opens
/// with permission still `.notDetermined` — "point the phone at the sky" is as unambiguous a
/// reason to ask as it gets.
///
/// Fallback: `.xArbitraryCorrectedZVertical`, used whenever heading support/authorization isn't
/// there yet. Per `PointingMath.swift`: this frame's X axis is "whatever the device was facing
/// when motion updates started, not true north" — the adapter is responsible for knowing that
/// axis's true compass bearing. Rather than a single one-shot sample, this continuously
/// re-anchors: every fresh `CLHeading` resolves the RAW (`headingOffsetDegrees: 0`) azimuth at
/// that same instant from the last motion sample, then sets
/// `headingOffsetDegrees = trueHeading - rawAzimuth` — both an initial anchor and a running
/// drift correction for the rest of the session. If heading support never arrives at all (no
/// magnetometer), this still runs with `headingOffsetDegrees: 0` — azimuth is then relative to
/// wherever the phone happened to be facing at launch, not true north; `SkyFinderView` has no
/// way to detect that case specifically, so it isn't messaged separately (that phone also has no
/// working compass app either).
///
/// ## Calibration signal
/// `CLHeading.headingAccuracy > 25°` (or negative, i.e. invalid) surfaces `calibrationHint` —
/// cleared once accuracy improves. 25° matches Apple's own "compass needs calibration" bar.
///
/// ## Demo mode
/// `-finderDemo` (optionally `-finderDemoStage far|mid|near|locked`) substitutes a canned,
/// timer-driven az/alt sweep toward a fixed demo target for CoreMotion entirely — Simulator has
/// no motion hardware at all (`CMMotionManager.isDeviceMotionAvailable` is always false there),
/// so this is the only way to sim-verify the approach/lock UI. `-finderDemoStage` jumps straight
/// to and HOLDS one stage (deterministic screenshot); bare `-finderDemo` free-runs the whole
/// sweep on a loop (a manual, in-person demo feel). `-finderCalibrationPoor` forces
/// `calibrationHint` on regardless of path, for screenshotting that banner on demand. The demo
/// path never touches `CMMotionManager`/`CLLocationManager` at all.
@MainActor
@Observable
final class DeviceMotionAdapter: NSObject, CLLocationManagerDelegate {
    struct Reading: Equatable {
        var azimuthDeg: Double = 0
        var altitudeDeg: Double = 20
        var azimuthConfidence: Double = 1
        /// Radians, positive = screen rotated clockwise as the user looking at it sees it — same
        /// convention `FinderGuidance.delta(deviceRollRad:)` documents (and literally the same
        /// value `CMAttitude.roll` reports for a device frame with Y = "up the screen").
        var deviceRollRad: Double = 0
    }

    enum Availability: Equatable {
        case available
        case unavailable(reason: String)
    }

    enum DemoStage: String, CaseIterable {
        case far, mid, near, locked
    }

    private(set) var reading = Reading()
    private(set) var availability: Availability
    private(set) var calibrationHint: String?
    let isDemoMode: Bool

    /// Fallback demo anchor — used only until `SkyFinderView` calls `setDemoAnchor` with the
    /// actually-selected target's real az/alt (free-explore mode, or the brief window before the
    /// first target resolves, has nothing else to aim near).
    private static let fallbackDemoAnchorAzimuthDeg = 150.0
    private static let fallbackDemoAnchorAltitudeDeg = 35.0

    private static let calibrationHintText = "Wave your phone in a figure-eight to calibrate the compass."
    private static let poorHeadingAccuracyThresholdDeg = 25.0
    private static let demoStageDuration: TimeInterval = 4.0
    /// Approximate azimuth-only separation targeted per stage — see `demoReading(stage:phase:)`'s
    /// comment for why exact spherical precision doesn't matter here.
    private static let demoStageSeparationDeg: [DemoStage: Double] = [.far: 80, .mid: 28, .near: 9, .locked: 0]

    private let motionManager = CMMotionManager()
    private let locationManager = CLLocationManager()
    private let forcePoorCalibration: Bool
    /// The real az/alt of whatever `SkyFinderView` currently has selected — see `setDemoAnchor`.
    /// The canned sweep approaches THIS point, not a fixed one, so `-showFinder venus
    /// -finderDemoStage far` actually looks like approaching Venus's real tonight position
    /// rather than some unrelated fixed point (which is what a hardcoded demo target would have
    /// produced — caught in sim-verify: the very first screenshot showed "144° to go" for a
    /// stage that's supposed to read ~80°, because the demo sweep was aiming at a fixed point
    /// while `SkyFinderView`'s guidance math measured separation to the REAL selected target).
    private var demoAnchorAzimuthDeg = fallbackDemoAnchorAzimuthDeg
    private var demoAnchorAltitudeDeg = fallbackDemoAnchorAltitudeDeg
    private let demoStageOverride: DemoStage?
    private var usingTrueNorthFrame = false
    private var lastRawAzimuthDeg: Double?
    private var headingOffsetDegrees: Double = 0
    private var demoTimer: Timer?
    private var demoElapsed: TimeInterval = 0

    override init() {
        let args = CommandLine.arguments
        var stageOverride: DemoStage?
        if let idx = args.firstIndex(of: "-finderDemoStage"), idx + 1 < args.count {
            stageOverride = DemoStage(rawValue: args[idx + 1])
        }
        self.isDemoMode = args.contains("-finderDemo") || stageOverride != nil
        self.demoStageOverride = stageOverride
        self.forcePoorCalibration = args.contains("-finderCalibrationPoor")
        self.availability = .unavailable(reason: "Starting up…")
        super.init()

        if isDemoMode {
            availability = .available
            calibrationHint = forcePoorCalibration ? Self.calibrationHintText : nil
            startDemo()
        } else {
            configureAndStartRealMotion()
        }
    }

    /// `SkyFinderView` calls this from `.onDisappear` — stops whichever of the two update
    /// sources is actually running (demo timer vs. real `CMMotionManager`/`CLLocationManager`
    /// updates) so nothing keeps polling sensors/timers after the finder closes. Not done from
    /// `deinit`: this is a `@MainActor` class, and `deinit` runs nonisolated, so it can't safely
    /// touch main-actor-isolated state directly (the property accesses below would need hopping
    /// back to the main actor from a context that, by the time `deinit` runs, may not get the
    /// chance to).
    func stop() {
        demoTimer?.invalidate()
        demoTimer = nil
        motionManager.stopDeviceMotionUpdates()
        locationManager.stopUpdatingHeading()
    }

    // MARK: - Real motion

    private func configureAndStartRealMotion() {
        guard motionManager.isDeviceMotionAvailable else {
            availability = .unavailable(reason: "This device doesn't report motion — Sky Finder needs a real iPhone's sensors, not the Simulator.")
            return
        }
        availability = .available
        locationManager.delegate = self

        switch locationManager.authorizationStatus {
        case .notDetermined:
            locationManager.requestWhenInUseAuthorization()
        case .denied, .restricted:
            // Heading still isn't possible without a location fix, but pointing itself still
            // works via the arbitrary-frame fallback below — just without true north. No hard
            // failure here; `calibrationHint`-style messaging isn't right for "permission
            // denied" specifically, so this silently degrades rather than blocking the feature.
            break
        case .authorizedWhenInUse, .authorizedAlways:
            break
        @unknown default:
            break
        }

        if CLLocationManager.headingAvailable() {
            locationManager.startUpdatingHeading()
        }

        let useTrueNorth = CLLocationManager.headingAvailable()
            && (locationManager.authorizationStatus == .authorizedWhenInUse || locationManager.authorizationStatus == .authorizedAlways)
        usingTrueNorthFrame = useTrueNorth

        motionManager.deviceMotionUpdateInterval = 1.0 / 30.0
        let frame: CMAttitudeReferenceFrame = useTrueNorth ? .xTrueNorthZVertical : .xArbitraryCorrectedZVertical
        motionManager.startDeviceMotionUpdates(using: frame, to: .main) { [weak self] motion, _ in
            guard let self, let motion else { return }
            self.handleMotion(motion)
        }
    }

    private func handleMotion(_ motion: CMDeviceMotion) {
        let q = motion.attitude.quaternion
        let quat = simd_quatd(ix: q.x, iy: q.y, iz: q.z, r: q.w)

        if !usingTrueNorthFrame {
            // Cached so the next `CLHeading` sample (see `applyHeading`) can solve
            // `headingOffsetDegrees` against the raw azimuth at the same instant.
            lastRawAzimuthDeg = PointingMath.skyDirection(attitude: quat, headingOffsetDegrees: 0).azimuthDeg
        }
        let offset = usingTrueNorthFrame ? 0 : headingOffsetDegrees
        let position = PointingMath.skyDirection(attitude: quat, headingOffsetDegrees: offset)

        reading = Reading(
            azimuthDeg: position.azimuthDeg,
            altitudeDeg: position.altitudeDeg,
            azimuthConfidence: position.azimuthConfidence,
            deviceRollRad: motion.attitude.roll
        )
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        Task { @MainActor in
            self.applyHeading(newHeading)
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        // Deliberately not restarting `CMMotionManager` on a permission flip mid-session — the
        // arbitrary-frame + continuous-heading-reanchor fallback already converges to a correct
        // azimuth once headings start arriving, so a restart would just add complexity/thrash
        // for no accuracy gain.
    }

    private func applyHeading(_ heading: CLHeading) {
        if !forcePoorCalibration {
            let accuracy = heading.headingAccuracy
            calibrationHint = (accuracy < 0 || accuracy > Self.poorHeadingAccuracyThresholdDeg) ? Self.calibrationHintText : nil
        }
        guard !usingTrueNorthFrame, let lastRawAzimuthDeg, heading.trueHeading >= 0 else { return }
        headingOffsetDegrees = normalizeDegrees(heading.trueHeading - lastRawAzimuthDeg)
    }

    // MARK: - Demo mode

    /// `SkyFinderView` calls this whenever its selected target (or the target's resolved
    /// position) changes, so the canned sweep always approaches wherever the REAL target
    /// actually is tonight rather than an arbitrary fixed point — see `demoAnchorAzimuthDeg`'s
    /// doc comment. A no-op outside demo mode. Immediately refreshes `reading` when a stage
    /// override is active (that path is otherwise static/timer-free — see `startDemo`) so
    /// switching the picker chip mid-screenshot-session still reflects the new anchor at once.
    func setDemoAnchor(azimuthDeg: Double, altitudeDeg: Double) {
        guard isDemoMode else { return }
        demoAnchorAzimuthDeg = azimuthDeg
        demoAnchorAltitudeDeg = altitudeDeg
        if let demoStageOverride {
            reading = demoReading(stage: demoStageOverride, phase: 0)
        }
    }

    private func startDemo() {
        if let demoStageOverride {
            reading = demoReading(stage: demoStageOverride, phase: 0)
            return
        }
        demoTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tickDemo() }
        }
    }

    private func tickDemo() {
        demoElapsed += 1.0 / 30.0
        let cycle = Self.demoStageDuration * Double(DemoStage.allCases.count)
        let t = demoElapsed.truncatingRemainder(dividingBy: cycle)
        let stageIndex = min(Int(t / Self.demoStageDuration), DemoStage.allCases.count - 1)
        let stage = DemoStage.allCases[stageIndex]
        let withinStage = (t - Double(stageIndex) * Self.demoStageDuration) / Self.demoStageDuration
        reading = demoReading(stage: stage, phase: withinStage * 4 * .pi)
    }

    /// A canned reading at EXACTLY `demoStageSeparationDeg[stage]` true angular separation from
    /// `demoAnchorAzimuthDeg`/`demoAnchorAltitudeDeg` (the real selected target's position, kept
    /// current via `setDemoAnchor`), with a small sinusoidal wobble (dies out at `.locked`) so a
    /// free-running demo doesn't look frozen mid-approach.
    ///
    /// Walks EXACTLY `demoStageSeparationDeg[stage]` degrees along the anchor's own meridian
    /// (fixed azimuth, varying altitude) — a meridian is a great circle, so moving along one by
    /// angle `D` covers true angular distance `D` exactly, with no spherical-contraction
    /// correction needed regardless of how high or low the anchor sits. Works in co-altitude
    /// (`phi = 90 - altitude`, i.e. angle from the zenith, `0...180`) so "walking past the
    /// nadir" falls out as a plain wraparound (`phi > 180`) rather than needing a special case:
    /// past the nadir you're heading back UP on the opposite azimuth, which is exactly
    /// `phi' = 360 - phi`, `azimuth + 180`.
    ///
    /// An earlier version offset azimuth AND altitude by a fixed amount instead, which is only
    /// approximately the intended separation for a near-equatorial anchor — for a real target
    /// sitting far from the horizon's midpoint (a low evening planet, say), that approximation
    /// was off by 50%+ (caught in sim-verify: `.far`'s intended 80° separation measured 144°,
    /// then a first fix attempt that clamped/reflected raw altitude directly still measured
    /// 120° — both wrong for the same underlying reason: neither was actually the co-altitude
    /// parametrization a great-circle walk requires). This version's arithmetic is verified by
    /// hand against `FinderGuidance.angularSeparationDeg`'s spherical law of cosines in the
    /// class doc comment's derivation notes.
    private func demoReading(stage: DemoStage, phase: Double) -> Reading {
        let targetAz = demoAnchorAzimuthDeg
        let targetAlt = demoAnchorAltitudeDeg
        let baseSeparation = Self.demoStageSeparationDeg[stage] ?? 80
        let wobble = stage == .locked ? 0 : sin(phase) * min(baseSeparation * 0.12, 5)
        let separation = baseSeparation + wobble

        let phi = 90 - targetAlt
        let phiNew = phi + separation
        let alt: Double
        let az: Double
        if phiNew <= 180 {
            alt = 90 - phiNew
            az = targetAz
        } else {
            alt = 90 - (360 - phiNew)
            az = normalizeDegrees(targetAz + 180)
        }
        return Reading(azimuthDeg: az, altitudeDeg: alt, azimuthConfidence: 1, deviceRollRad: 0)
    }
}
