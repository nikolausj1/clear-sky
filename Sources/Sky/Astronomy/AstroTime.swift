import Foundation

/// Low-level time and coordinate-frame plumbing shared by every other file in this engine:
/// Julian Day conversion, Julian centuries since J2000, mean/apparent sidereal time, nutation,
/// and the obliquity of the ecliptic. Everything here follows Jean Meeus, "Astronomical
/// Algorithms" (2nd ed.), chapters 7, 12, and 22.
///
/// All angles in this entire engine are in **degrees** unless a name says `Radians`. All time
/// is UTC `Date` in, UTC `Date` out — callers convert to the caller's time zone only for display.
enum AstroTime {

    // MARK: - Julian Day

    /// Julian Day Number (with fractional day) for a `Date`, treating the `Date`'s absolute
    /// instant as UT1 (the sub-second difference between UT1 and UTC is irrelevant at this
    /// engine's accuracy target). Meeus 7.1, but simplified using `Date`'s existing epoch
    /// (seconds since 2001-01-01 00:00:00 UTC = JD 2451910.5) rather than re-deriving from
    /// Y/M/D — this avoids a whole calendar-math round trip and is exact.
    static func julianDay(_ date: Date) -> Double {
        // JD at the Foundation reference date (2001-01-01 00:00:00 UTC).
        let jdAtReferenceDate = 2451910.5
        return jdAtReferenceDate + date.timeIntervalSinceReferenceDate / 86400.0
    }

    static func date(fromJulianDay jd: Double) -> Date {
        let jdAtReferenceDate = 2451910.5
        return Date(timeIntervalSinceReferenceDate: (jd - jdAtReferenceDate) * 86400.0)
    }

    /// Julian centuries since the J2000.0 epoch (JD 2451545.0) — the standard time argument
    /// `T` fed into every polynomial in this engine.
    static func julianCenturies(jd: Double) -> Double {
        (jd - 2451545.0) / 36525.0
    }

    // MARK: - Nutation and obliquity (Meeus ch. 22)

    /// Low-precision nutation in longitude (Δψ) and obliquity (Δε), in degrees. Meeus gives
    /// this abridged form (accurate to about 0.5″) using only the Moon's ascending node term
    /// plus the three next-largest periodic terms — full nutation is a ~63-term series that
    /// would buy nothing at this engine's ~1° / ~5 minute accuracy target.
    static func nutation(T: Double) -> (deltaPsi: Double, deltaEpsilon: Double) {
        // Mean elongation of the Moon from the Sun, mean anomalies of Sun and Moon, Moon's
        // argument of latitude, and longitude of the Moon's ascending node (all degrees).
        let omega = 125.04452 - 1934.136261 * T
        let meanLongitudeSun = 280.4665 + 36000.7698 * T
        let meanLongitudeMoon = 218.3165 + 481267.8813 * T

        let deltaPsi = -17.20 * sinDeg(omega)
            - 1.32 * sinDeg(2 * meanLongitudeSun)
            - 0.23 * sinDeg(2 * meanLongitudeMoon)
            + 0.21 * sinDeg(2 * omega)
        let deltaEpsilon = 9.20 * cosDeg(omega)
            + 0.57 * cosDeg(2 * meanLongitudeSun)
            + 0.10 * cosDeg(2 * meanLongitudeMoon)
            - 0.09 * cosDeg(2 * omega)

        // The coefficients above are in arcseconds; convert to degrees.
        return (deltaPsi / 3600.0, deltaEpsilon / 3600.0)
    }

    /// Mean obliquity of the ecliptic, Meeus 22.2 (degrees). Valid over several millennia
    /// around J2000, which is all this engine ever needs.
    static func meanObliquity(T: Double) -> Double {
        let seconds = 21.448 - T * (46.8150 + T * (0.00059 - T * 0.001813))
        return 23.0 + (26.0 + seconds / 60.0) / 60.0
    }

    /// True obliquity (mean + nutation correction), degrees.
    static func trueObliquity(T: Double) -> Double {
        meanObliquity(T: T) + nutation(T: T).deltaEpsilon
    }

    // MARK: - Sidereal time (Meeus ch. 12)

    /// Mean sidereal time at Greenwich, in degrees, normalized to [0, 360).
    static func meanSiderealTimeGreenwich(jd: Double) -> Double {
        let T = julianCenturies(jd: jd)
        let theta0 = 280.46061837
            + 360.98564736629 * (jd - 2451545.0)
            + 0.000387933 * T * T
            - T * T * T / 38710000.0
        return normalizeDegrees(theta0)
    }

    /// Apparent sidereal time at Greenwich (mean + equation of the equinoxes, Δψ·cos ε),
    /// in degrees. This is what should be used as the basis for local sidereal time /
    /// hour-angle computations when sub-arcminute correctness matters; the mean value is
    /// within about 1 second of time of the apparent value, which is already inside this
    /// engine's error budget, so call sites are free to use either.
    static func apparentSiderealTimeGreenwich(jd: Double) -> Double {
        let T = julianCenturies(jd: jd)
        let mean = meanSiderealTimeGreenwich(jd: jd)
        let (deltaPsi, _) = nutation(T: T)
        let epsilon = trueObliquity(T: T)
        return normalizeDegrees(mean + deltaPsi * cosDeg(epsilon))
    }

    /// Local apparent sidereal time in degrees, for a site at `longitudeEast` (degrees,
    /// positive east of Greenwich — the convention this whole engine uses for longitude).
    static func localSiderealTime(jd: Double, longitudeEast: Double) -> Double {
        normalizeDegrees(apparentSiderealTimeGreenwich(jd: jd) + longitudeEast)
    }

    // MARK: - Angle helpers

    /// Normalizes a degree value into [0, 360).
    static func normalizeDegrees(_ degrees: Double) -> Double {
        var d = degrees.truncatingRemainder(dividingBy: 360.0)
        if d < 0 { d += 360.0 }
        return d
    }

    /// Normalizes a degree value into [-180, 180).
    static func normalizeDegreesSigned(_ degrees: Double) -> Double {
        var d = normalizeDegrees(degrees)
        if d >= 180 { d -= 360 }
        return d
    }

    static func sinDeg(_ degrees: Double) -> Double { sin(degrees * .pi / 180.0) }
    static func cosDeg(_ degrees: Double) -> Double { cos(degrees * .pi / 180.0) }
    static func tanDeg(_ degrees: Double) -> Double { tan(degrees * .pi / 180.0) }
    static func asinDeg(_ x: Double) -> Double { asin(max(-1, min(1, x))) * 180.0 / .pi }
    static func acosDeg(_ x: Double) -> Double { acos(max(-1, min(1, x))) * 180.0 / .pi }
    static func atan2Deg(_ y: Double, _ x: Double) -> Double { atan2(y, x) * 180.0 / .pi }
}

/// Equatorial coordinates: right ascension and declination, both in degrees, plus geocentric
/// distance in AU (0 for coordinates where distance doesn't apply, e.g. fixed stars).
struct EquatorialCoordinates {
    var rightAscension: Double
    var declination: Double
    var distanceAU: Double = 0
}

/// Ecliptic coordinates: longitude and latitude in degrees, plus distance in AU.
struct EclipticCoordinates {
    var longitude: Double
    var latitude: Double
    var distanceAU: Double = 0
}

/// Horizontal (alt/az) coordinates as seen by a specific observer at a specific moment.
/// Azimuth is measured from true north, through east, 0...360 (standard compass bearing).
struct HorizontalCoordinates {
    var altitude: Double
    var azimuth: Double
}

/// Rectangular ecliptic coordinates (AU), used internally for heliocentric/geocentric vector
/// arithmetic in `Planets.swift`.
struct EclipticRectangular {
    var x: Double
    var y: Double
    var z: Double

    static func - (lhs: EclipticRectangular, rhs: EclipticRectangular) -> EclipticRectangular {
        EclipticRectangular(x: lhs.x - rhs.x, y: lhs.y - rhs.y, z: lhs.z - rhs.z)
    }

    var magnitude: Double { sqrt(x * x + y * y + z * z) }

    /// Converts to ecliptic spherical coordinates (longitude/latitude in degrees, distance AU).
    var asEcliptic: EclipticCoordinates {
        let r = magnitude
        let longitude = AstroTime.normalizeDegrees(AstroTime.atan2Deg(y, x))
        let latitude = r > 0 ? AstroTime.asinDeg(z / r) : 0
        return EclipticCoordinates(longitude: longitude, latitude: latitude, distanceAU: r)
    }
}

/// Converts ecliptic coordinates to equatorial (RA/Dec) using the standard obliquity rotation
/// (Meeus 13.3, solved for equatorial from ecliptic).
func eclipticToEquatorial(_ ecliptic: EclipticCoordinates, obliquity epsilon: Double) -> EquatorialCoordinates {
    let lambda = ecliptic.longitude
    let beta = ecliptic.latitude
    let sinBeta = AstroTime.sinDeg(beta)
    let cosBeta = AstroTime.cosDeg(beta)
    let sinLambda = AstroTime.sinDeg(lambda)
    let cosLambda = AstroTime.cosDeg(lambda)
    let sinEps = AstroTime.sinDeg(epsilon)
    let cosEps = AstroTime.cosDeg(epsilon)

    let y = sinLambda * cosEps - AstroTime.tanDeg(beta) * sinEps
    let ra = AstroTime.normalizeDegrees(AstroTime.atan2Deg(y, cosLambda))
    let sinDec = sinBeta * cosEps + cosBeta * sinEps * sinLambda
    let dec = AstroTime.asinDeg(sinDec)
    return EquatorialCoordinates(rightAscension: ra, declination: dec, distanceAU: ecliptic.distanceAU)
}

/// Converts equatorial (RA/Dec) coordinates to horizontal (alt/az) for an observer at
/// `latitude`/`longitudeEast` (degrees) at the sidereal time implied by `jd`. Standard
/// spherical-astronomy transform (e.g. Meeus 13.5, reformulated to give a compass azimuth
/// measured from north through east rather than Meeus's from-south convention).
func equatorialToHorizontal(_ equatorial: EquatorialCoordinates, latitude: Double, longitudeEast: Double, jd: Double) -> HorizontalCoordinates {
    let lst = AstroTime.localSiderealTime(jd: jd, longitudeEast: longitudeEast)
    let hourAngle = AstroTime.normalizeDegreesSigned(lst - equatorial.rightAscension)
    return horizontal(hourAngle: hourAngle, declination: equatorial.declination, latitude: latitude)
}

/// Core alt/az transform given an hour angle (degrees, positive west of the meridian).
func horizontal(hourAngle: Double, declination: Double, latitude: Double) -> HorizontalCoordinates {
    let sinLat = AstroTime.sinDeg(latitude)
    let cosLat = AstroTime.cosDeg(latitude)
    let sinDec = AstroTime.sinDeg(declination)
    let cosDec = AstroTime.cosDeg(declination)
    let cosH = AstroTime.cosDeg(hourAngle)
    let sinH = AstroTime.sinDeg(hourAngle)

    let sinAlt = sinDec * sinLat + cosDec * cosLat * cosH
    let altitude = AstroTime.asinDeg(sinAlt)
    let cosAlt = AstroTime.cosDeg(altitude)

    let azimuth: Double
    if abs(cosAlt) < 1e-9 {
        azimuth = 0
    } else {
        let sinAz = -cosDec * sinH / cosAlt
        let cosAz = (sinDec - sinAlt * sinLat) / (cosAlt * cosLat)
        azimuth = AstroTime.normalizeDegrees(AstroTime.atan2Deg(sinAz, cosAz))
    }
    return HorizontalCoordinates(altitude: altitude, azimuth: azimuth)
}

/// Sidereal rotation rate, degrees per mean solar day (Meeus 12: 360.98564736629°/day).
/// This is how fast local sidereal time gains on ordinary clock time.
let siderealDegreesPerDay = 360.98564736629

/// The kind of horizon-crossing event `RiseSetFinder` solves for.
enum SkyEventKind {
    case rise
    case transit
    case set
}

/// Generic rise/transit/set solver (Meeus ch. 15) that works for the Sun, Moon, or any
/// planet alike: the caller supplies a `position(at:)` closure that returns the body's
/// true equatorial coordinates at an arbitrary instant, and this iterates Meeus's
/// standard Δm correction to converge on the exact crossing time.
///
/// **Departure from Meeus's book recipe, noted for anyone diffing against the text:** Meeus
/// interpolates RA/Dec from three once-a-day tabulated positions (because when the book was
/// written, generating a fresh position was expensive). Here, generating a position is just a
/// function call, so each iteration recomputes the body's *exact* position at its current
/// best-guess time instead of interpolating — simpler to get right and slightly more accurate,
/// at the cost of a few extra trig calls. The convergence formulas (Δm for rise/set/transit,
/// the standard-altitude horizon crossing) are unchanged from the book.
enum RiseSetFinder {

    /// The next time (at or after `date`) that `body` crosses the given event, or `nil` if
    /// the body is circumpolar (never crosses `standardAltitude` — always above it, or
    /// always below it) at this latitude on this date.
    static func nextEvent(
        _ kind: SkyEventKind,
        after date: Date,
        latitude: Double,
        longitudeEast: Double,
        standardAltitude: Double,
        position: (Date) -> EquatorialCoordinates
    ) -> Date? {
        let jd0 = AstroTime.julianDay(date)
        let eq0 = position(date)
        let lst0 = AstroTime.localSiderealTime(jd: jd0, longitudeEast: longitudeEast)
        let hourAngleNow = AstroTime.normalizeDegreesSigned(lst0 - eq0.rightAscension)

        let targetHourAngle: Double
        if kind == .transit {
            targetHourAngle = 0
        } else {
            let cosH0 = (AstroTime.sinDeg(standardAltitude) - AstroTime.sinDeg(latitude) * AstroTime.sinDeg(eq0.declination))
                / (AstroTime.cosDeg(latitude) * AstroTime.cosDeg(eq0.declination))
            guard cosH0 >= -1 && cosH0 <= 1 else { return nil }
            let semiDiurnalArc = AstroTime.acosDeg(cosH0)
            targetHourAngle = kind == .rise ? -semiDiurnalArc : semiDiurnalArc
        }

        // Fraction of a day (> 0) until hour angle first reaches targetHourAngle.
        var deltaDegrees = (targetHourAngle - hourAngleNow).truncatingRemainder(dividingBy: 360)
        if deltaDegrees <= 0 { deltaDegrees += 360 }
        var m = deltaDegrees / siderealDegreesPerDay

        for _ in 0..<4 {
            let t = date.addingTimeInterval(m * 86400)
            let eq = position(t)
            let jd = AstroTime.julianDay(t)
            let lst = AstroTime.localSiderealTime(jd: jd, longitudeEast: longitudeEast)
            let H = AstroTime.normalizeDegreesSigned(lst - eq.rightAscension)

            let deltaM: Double
            if kind == .transit {
                deltaM = -H / siderealDegreesPerDay
            } else {
                let altitude = horizontal(hourAngle: H, declination: eq.declination, latitude: latitude).altitude
                let denominator = siderealDegreesPerDay * AstroTime.cosDeg(eq.declination) * AstroTime.cosDeg(latitude) * AstroTime.sinDeg(H)
                guard abs(denominator) > 1e-9 else { break }
                deltaM = (altitude - standardAltitude) / denominator
            }
            m += deltaM
            if abs(deltaM) < 1e-7 { break } // ~0.01 seconds; converged
        }
        return date.addingTimeInterval(m * 86400)
    }
}

/// Renders a compass azimuth (degrees, 0 = N) as one of the 16 standard compass points.
func compassPoint(forAzimuth azimuth: Double) -> String {
    let points = ["N", "NNE", "NE", "ENE", "E", "ESE", "SE", "SSE",
                  "S", "SSW", "SW", "WSW", "W", "WNW", "NW", "NNW"]
    let normalized = AstroTime.normalizeDegrees(azimuth)
    let index = Int((normalized / 22.5).rounded()) % 16
    return points[index]
}

/// Builds a human-readable phrase like "low in the WSW" or "high overhead in the SE",
/// per the product requirement for a plain-language direction string.
func directionPhrase(altitude: Double, azimuth: Double) -> String {
    let point = compassPoint(forAzimuth: azimuth)
    switch altitude {
    case ..<10: return "very low in the \(point)"
    case 10..<30: return "low in the \(point)"
    case 30..<60: return "in the \(point)"
    default: return "high in the \(point)"
    }
}
