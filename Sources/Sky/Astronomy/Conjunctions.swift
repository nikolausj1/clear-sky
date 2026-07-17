import Foundation

/// Close angular pairings between the Moon and the five naked-eye planets, and between planet
/// pairs, for a given night — "what's huddled together in the sky tonight."
///
/// ## Simplification (documented per work order)
/// Separations are computed from **geocentric** apparent equatorial coordinates (the same
/// `Planets.geocentric` / `SunMoon.moonEquatorial` this whole engine already uses), not
/// corrected for the Moon's topocentric parallax (up to about 1 degree near the horizon). For
/// planet-planet pairs this is negligible (parallax at planetary distances is arcseconds, not
/// degrees). For Moon-involving pairs it means a separation this file reports can differ from a
/// topocentric almanac value by up to roughly a degree — acceptable given this file's own
/// 5-degree Moon-planet threshold, but worth knowing if you're diffing against precise almanac
/// figures for a very tight (sub-degree) lunar appulse.
///
/// A second, related simplification: rather than tracking the fast-changing Moon-planet
/// separation continuously through the night, `closePairings` gates each pair's threshold check
/// against separation at a single **representative instant — the midpoint of tonight's dark-sky
/// window** (civil dusk through civil dawn the next morning), not the literal moment of closest
/// approach. The Moon moves roughly 0.5 degree/hour relative to the background sky, so a
/// conjunction whose true closest approach falls hours away from that midpoint can read a
/// degree or two wider here than an almanac's "closest approach" figure — using the window's
/// midpoint (rather than, say, a fixed evening anchor) keeps that error roughly symmetric
/// whether the true closest approach happens to fall earlier or later in the night, which
/// matters because plenty of real conjunctions peak in the pre-dawn hours, not the evening.
enum Conjunctions {

    enum Body: Hashable {
        case planet(Planets.Body)
        case moon

        var displayName: String {
            switch self {
            case .planet(let body): return body.displayName
            case .moon: return "Moon"
            }
        }
    }

    struct Pairing {
        var bodyA: Body
        var bodyB: Body
        /// Angular separation (degrees) at the representative dark-window-midpoint instant
        /// used to gate the threshold check (see the type-level doc comment).
        var separationDegrees: Double
        /// The moment within tonight's dark-sky window when both bodies are highest together
        /// (specifically: when the lower of the two altitudes is maximized) while the sky is
        /// dark — i.e. when to actually go outside and look.
        var bestViewingTime: Date
        /// The lower of the two bodies' altitudes at `bestViewingTime` — the limiting factor
        /// for whether both are comfortably clear of horizon murk.
        var altitudeAtBest: Double
        /// A single combined azimuth (circular mean of both bodies' azimuths) at
        /// `bestViewingTime` — reasonable since, by construction, anything in this list is
        /// within a few degrees on the sky, so "one direction" is a fair description of both.
        var azimuthAtBest: Double
        var directionDescription: String
    }

    /// Below this separation, a Moon-planet pairing counts as "close" (degrees).
    static let moonPlanetThresholdDegrees = 5.0
    /// Below this separation, a planet-planet pairing counts as "close" (degrees).
    static let planetPlanetThresholdDegrees = 3.0

    /// The same "is this actually visible" altitude bar `SkyTonight` uses for planets — a
    /// conjunction where both bodies are technically above the mathematical horizon but buried
    /// in trees/rooftop murk doesn't count as visible.
    private static let minimumViewingAltitude = 10.0

    // MARK: - Angular separation

    private static func equatorial(_ body: Body, at date: Date) -> EquatorialCoordinates {
        switch body {
        case .planet(let p): return Planets.geocentric(p, date: date).equatorial
        case .moon: return SunMoon.moonEquatorial(date: date)
        }
    }

    /// Great-circle angular separation (degrees) between two bodies' apparent geocentric
    /// equatorial positions at `date` (spherical law of cosines).
    static func separationDegrees(_ a: Body, _ b: Body, at date: Date) -> Double {
        let eqA = equatorial(a, at: date)
        let eqB = equatorial(b, at: date)
        let cosSeparation = AstroTime.sinDeg(eqA.declination) * AstroTime.sinDeg(eqB.declination)
            + AstroTime.cosDeg(eqA.declination) * AstroTime.cosDeg(eqB.declination) * AstroTime.cosDeg(eqA.rightAscension - eqB.rightAscension)
        return AstroTime.acosDeg(cosSeparation)
    }

    /// Circular mean of two azimuths (degrees), so averaging e.g. 350 deg and 10 deg gives 0
    /// deg rather than the naively-wrong 180 deg.
    private static func averageAzimuth(_ a: Double, _ b: Double) -> Double {
        let ax = AstroTime.cosDeg(a), ay = AstroTime.sinDeg(a)
        let bx = AstroTime.cosDeg(b), by = AstroTime.sinDeg(b)
        return AstroTime.normalizeDegrees(AstroTime.atan2Deg(ay + by, ax + bx))
    }

    // MARK: - Joint visibility scan

    private struct JointVisibility {
        var time: Date
        var minAltitude: Double
        var azimuth: Double
    }

    /// Steps through `[windowStart, windowEnd]` (tonight's dark-sky window) looking for the
    /// moment both bodies clear `minimumViewingAltitude` together, keeping the moment where the
    /// lower of the two altitudes is highest. Fixed-step brute force, same rationale as
    /// `SkyTonight.scanForBestViewing`: cheap, and simpler to get right than an analytic
    /// two-body-threshold solve. Returns `nil` if there's no moment in the window both bodies
    /// are simultaneously above the bar — i.e. this pairing isn't actually visible tonight.
    private static func scanForJointVisibility(_ a: Body, _ b: Body, windowStart: Date, windowEnd: Date, latitude: Double, longitude: Double) -> JointVisibility? {
        guard windowEnd > windowStart else { return nil }
        let step: TimeInterval = 10 * 60
        var t = windowStart
        var best: JointVisibility?
        while t <= windowEnd {
            let jd = AstroTime.julianDay(t)
            let hA = equatorialToHorizontal(equatorial(a, at: t), latitude: latitude, longitudeEast: longitude, jd: jd)
            let hB = equatorialToHorizontal(equatorial(b, at: t), latitude: latitude, longitudeEast: longitude, jd: jd)
            let minAlt = min(hA.altitude, hB.altitude)
            if minAlt >= minimumViewingAltitude, best == nil || minAlt > best!.minAltitude {
                best = JointVisibility(time: t, minAltitude: minAlt, azimuth: averageAzimuth(hA.azimuth, hB.azimuth))
            }
            t = t.addingTimeInterval(step)
        }
        return best
    }

    // MARK: - Public entry point

    /// All Moon-planet and planet-planet pairings under this file's thresholds for the calendar
    /// night (in `timeZone`) containing `date`, filtered to pairings that are actually visible
    /// (both bodies simultaneously above `minimumViewingAltitude`, in the dark) at some point
    /// during the night — a conjunction nobody can see doesn't count. Sorted by tightest
    /// separation first.
    static func closePairings(on date: Date, latitude: Double, longitude: Double, timeZone: TimeZone) -> [Pairing] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let dayStart = calendar.startOfDay(for: date)

        let sunTonight = SunMoon.sunTimes(after: dayStart, lat: latitude, lon: longitude)
        // Fall back to a plain evening/morning band if civil dusk/dawn don't resolve (polar
        // day/night), same fallback spirit as `SkyTonight.compute`.
        let windowStart = sunTonight.civilDusk ?? dayStart.addingTimeInterval(20 * 3600)
        let nightAnchor = sunTonight.civilDusk ?? dayStart
        let windowEnd = RiseSetFinder.nextEvent(
            .rise, after: nightAnchor, latitude: latitude, longitudeEast: longitude,
            standardAltitude: SunMoon.StandardAltitude.civilTwilight
        ) { SunMoon.sunEquatorial(date: $0) } ?? dayStart.addingTimeInterval(30 * 3600)

        guard windowEnd > windowStart else { return [] }
        let representativeTime = windowStart.addingTimeInterval(windowEnd.timeIntervalSince(windowStart) / 2)

        let allBodies: [Body] = Planets.Body.allCases.map { .planet($0) } + [.moon]
        var pairs: [(Body, Body)] = []
        for i in 0..<allBodies.count {
            for j in (i + 1)..<allBodies.count {
                pairs.append((allBodies[i], allBodies[j]))
            }
        }

        var results: [Pairing] = []
        for (a, b) in pairs {
            let isMoonPair = (a == .moon || b == .moon)
            let threshold = isMoonPair ? moonPlanetThresholdDegrees : planetPlanetThresholdDegrees
            let separation = separationDegrees(a, b, at: representativeTime)
            guard separation < threshold else { continue }
            guard let joint = scanForJointVisibility(a, b, windowStart: windowStart, windowEnd: windowEnd, latitude: latitude, longitude: longitude) else { continue }
            results.append(Pairing(
                bodyA: a, bodyB: b,
                separationDegrees: separation,
                bestViewingTime: joint.time,
                altitudeAtBest: joint.minAltitude,
                azimuthAtBest: joint.azimuth,
                directionDescription: directionPhrase(altitude: joint.minAltitude, azimuth: joint.azimuth)
            ))
        }
        return results.sorted { $0.separationDegrees < $1.separationDegrees }
    }
}
