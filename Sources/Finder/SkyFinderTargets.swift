import Foundation

/// What Sky Finder can point you at, and how to resolve each kind's live az/alt. Pure math/data —
/// no CoreMotion, no SwiftUI — so it stays trivially testable and reusable between the crosshair
/// scene, the picker chips, and the ribbon.
enum SkyFinderTarget {
    /// One thing Sky Finder can guide you to. `Equatable`/`Hashable` via `id` so SwiftUI can key
    /// off it directly (picker chip selection, `ForEach` identity).
    struct Kind: Identifiable, Hashable {
        enum Base: Hashable {
            case moon
            case planet(Planets.Body)
            case satellite(catalogNumber: Int, startTime: Date)
        }

        let base: Base
        let name: String

        var id: String {
            switch base {
            case .moon: return "moon"
            case .planet(let body): return "planet-\(body.rawValue)"
            case .satellite(let catalogNumber, let startTime): return "sat-\(catalogNumber)-\(startTime.timeIntervalSince1970)"
            }
        }

        static func == (lhs: Kind, rhs: Kind) -> Bool { lhs.id == rhs.id }
        func hash(into hasher: inout Hasher) { hasher.combine(id) }

        static func moon() -> Kind { Kind(base: .moon, name: "Moon") }
        static func planet(_ body: Planets.Body) -> Kind { Kind(base: .planet(body), name: body.displayName) }
        static func satellite(_ pass: SatellitePass) -> Kind {
            Kind(base: .satellite(catalogNumber: pass.satellite.catalogNumber, startTime: pass.pass.startTime), name: pass.satellite.name)
        }
    }

    /// Resolves `kind`'s true az/alt at `date` for an observer at `location`. `nil` only when the
    /// kind carries pass data this call can't find anymore (defensive — the caller always passes
    /// back a `Kind` derived from a pass it already has in hand, so this is not expected to miss
    /// in practice unless `passes` and `kind` come from different loads).
    static func position(
        for kind: Kind,
        at date: Date,
        location: SavedLocation,
        passes: [SatellitePass]
    ) -> (azimuthDeg: Double, altitudeDeg: Double)? {
        switch kind.base {
        case .moon:
            let equatorial = SunMoon.moonEquatorial(date: date)
            let jd = AstroTime.julianDay(date)
            let horizontal = equatorialToHorizontal(equatorial, latitude: location.latitude, longitudeEast: location.longitude, jd: jd)
            return (horizontal.azimuth, horizontal.altitude)

        case .planet(let body):
            let (equatorial, _, _) = Planets.geocentric(body, date: date)
            let jd = AstroTime.julianDay(date)
            let horizontal = equatorialToHorizontal(equatorial, latitude: location.latitude, longitudeEast: location.longitude, jd: jd)
            return (horizontal.azimuth, horizontal.altitude)

        case .satellite(let catalogNumber, let startTime):
            guard let pass = passes.first(where: { $0.satellite.catalogNumber == catalogNumber && $0.pass.startTime == startTime }) else {
                return nil
            }
            return interpolatedPosition(pass: pass.pass, at: date)
        }
    }

    /// Builds a 3-point (rise/peak/set) sample track from an `ISSPass` and hands it to
    /// `FinderGuidance.interpolatedTargetPosition` — the "per-time positions via the pass's az
    /// interpolation" the work order calls for. `ISSPass` only stores start/end azimuth (not a
    /// peak azimuth), so the peak sample's azimuth is itself interpolated along the shortest arc
    /// from start to end at the peak's fractional time-through-pass — an approximation (the real
    /// track can curve), but a documented, reasonable one given what `ISSPass` actually carries.
    /// Altitude at start/end is pinned to 10° (`PassPredictor`'s own visibility floor — a pass's
    /// recorded start/end times ARE exactly the moments altitude crosses that threshold).
    /// Querying before the pass starts or after it ends clamps to the nearest endpoint (per
    /// `interpolatedTargetPosition`'s own doc comment) — which is exactly the desired "not up
    /// yet — here's the rise direction" behavior for a pass targeted before it begins.
    static func interpolatedPosition(pass: ISSPass, at date: Date) -> (azimuthDeg: Double, altitudeDeg: Double)? {
        let span = pass.endTime.timeIntervalSince(pass.startTime)
        let peakT = span > 0 ? pass.peakTime.timeIntervalSince(pass.startTime) / span : 0.5
        let azOffset = FinderGuidance.shortestAzimuthDeltaDeg(from: pass.startAzimuthDeg, to: pass.endAzimuthDeg)
        let peakAzimuth = normalizeDegrees(pass.startAzimuthDeg + azOffset * peakT)
        let samples: [(time: Date, azimuthDeg: Double, altitudeDeg: Double)] = [
            (pass.startTime, pass.startAzimuthDeg, 10.0),
            (pass.peakTime, peakAzimuth, pass.peakAltitudeDeg),
            (pass.endTime, pass.endAzimuthDeg, 10.0),
        ]
        return FinderGuidance.interpolatedTargetPosition(samples: samples, at: date)
    }

    /// True while `date` falls inside the pass's own visible window — the "moving ISS" live-
    /// tracking condition vs. a static "not up yet"/"already set" rise-direction target.
    static func isSatellitePassActive(_ pass: ISSPass, at date: Date) -> Bool {
        date >= pass.startTime && date <= pass.endTime
    }

    /// A short, object-specific fact for the lock-state card. Planets get a magnitude simile +
    /// direction; the ISS/other satellites get a "still moving" reminder; the Moon gets its
    /// phase. `magnitudeSimile`/`directionDescription`/`moon` are all optional because the
    /// underlying astronomy data can be momentarily unavailable (still loading, or the object
    /// isn't in tonight's visible set) — callers fall back to just the object's name in that case.
    static func lockFact(
        for kind: Kind,
        planets: [SkyTonight.PlanetVisibility],
        moon: SkyTonight.MoonInfo?,
        passes: [SatellitePass]
    ) -> String? {
        switch kind.base {
        case .moon:
            guard let moon else { return nil }
            let percent = Int(moon.illuminatedPercent.rounded())
            return "\(percent)% illuminated, \(moon.waxing ? "waxing" : "waning")."
        case .planet(let body):
            guard let planet = planets.first(where: { $0.body == body }) else { return nil }
            var parts: [String] = []
            if let magnitude = planet.apparentMagnitude {
                parts.append(magnitudeSimile(magnitude))
            }
            if let direction = planet.directionDescription {
                parts.append(direction)
            }
            return parts.isEmpty ? nil : parts.joined(separator: " — ")
        case .satellite:
            guard let pass = passes.first(where: { $0.satellite.name == kind.name }) else {
                return "Moving fast — keep following."
            }
            return SkyFinderTarget.isSatellitePassActive(pass.pass, at: Date())
                ? "Moving — keep following."
                : "Not up yet — this is where it rises."
        }
    }

    private static func magnitudeSimile(_ magnitude: Double) -> String {
        if magnitude < -3.5 { return "Outshines everything but the Moon" }
        if magnitude < -1.5 { return "Brighter than any star" }
        if magnitude < 0 { return "As bright as the brightest stars" }
        return "A steady, plainly visible point"
    }
}
