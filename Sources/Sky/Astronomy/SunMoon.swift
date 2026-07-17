import Foundation

/// Sun and Moon position, rise/set, twilight, and lunar phase — Meeus "Astronomical
/// Algorithms" chapters 22 (obliquity/nutation, in `AstroTime.swift`), 25 (low-precision Sun),
/// and a truncated version of chapter 47 (Moon).
enum SunMoon {

    // MARK: - Sun (Meeus ch. 25, low-precision solar coordinates, ~0.01° accuracy)

    /// The Sun's true (non-apparent) geometric ecliptic longitude and Earth–Sun distance —
    /// used internally to place Earth in the heliocentric frame for `Planets.swift`, since
    /// Earth's heliocentric longitude is just the Sun's geocentric longitude + 180°.
    static func sunGeometric(T: Double) -> (trueLongitude: Double, distanceAU: Double) {
        let L0 = AstroTime.normalizeDegrees(280.46646 + 36000.76983 * T + 0.0003032 * T * T)
        let M = AstroTime.normalizeDegrees(357.52911 + 35999.05029 * T - 0.0001537 * T * T)
        let e = 0.016708634 - 0.000042037 * T - 0.0000001267 * T * T

        let C = (1.914602 - 0.004817 * T - 0.000014 * T * T) * AstroTime.sinDeg(M)
            + (0.019993 - 0.000101 * T) * AstroTime.sinDeg(2 * M)
            + 0.000289 * AstroTime.sinDeg(3 * M)

        let trueLongitude = L0 + C
        let trueAnomaly = M + C
        let R = (1.000001018 * (1 - e * e)) / (1 + e * AstroTime.cosDeg(trueAnomaly))
        return (trueLongitude, R)
    }

    /// Apparent geocentric equatorial coordinates of the Sun at `date`.
    ///
    /// Follows Meeus 25's own paired low-precision approximation: the apparent longitude
    /// correction (`-0.00569 - 0.00478 sin Ω`) already folds in aberration and the dominant
    /// nutation-in-longitude term, so it's paired with Meeus's matching obliquity correction
    /// (`ε0 + 0.00256 cos Ω`) rather than with `AstroTime.trueObliquity`, which would double
    /// count nutation. `AstroTime`'s full nutation function is used instead for sidereal time,
    /// a separate context where this shortcut doesn't apply.
    static func sunEquatorial(date: Date) -> EquatorialCoordinates {
        let jd = AstroTime.julianDay(date)
        let T = AstroTime.julianCenturies(jd: jd)
        let (trueLongitude, R) = sunGeometric(T: T)

        let omega = 125.04 - 1934.136 * T
        let apparentLongitude = trueLongitude - 0.00569 - 0.00478 * AstroTime.sinDeg(omega)
        let epsilon = AstroTime.meanObliquity(T: T) + 0.00256 * AstroTime.cosDeg(omega)

        let ecliptic = EclipticCoordinates(longitude: apparentLongitude, latitude: 0, distanceAU: R)
        return eclipticToEquatorial(ecliptic, obliquity: epsilon)
    }

    /// Public API (also used by the future ISS/aurora packages): the Sun's alt/az as seen
    /// from `lat`/`lon` (degrees; `lon` positive **east**) at `date`.
    static func sunPosition(date: Date, lat: Double, lon: Double) -> HorizontalCoordinates {
        let eq = sunEquatorial(date: date)
        let jd = AstroTime.julianDay(date)
        return equatorialToHorizontal(eq, latitude: lat, longitudeEast: lon, jd: jd)
    }

    /// Standard altitudes (degrees) for horizon-crossing events, all negative because they're
    /// below the geometric horizon. Sun/Moon include −34′ atmospheric refraction plus their
    /// own angular radius (≈16′); twilight altitudes are conventional zenith-distance bands
    /// with no radius term (defined for the Sun's center).
    enum StandardAltitude {
        static let sunriseSunset = -0.8333
        static let civilTwilight = -6.0
        static let nauticalTwilight = -12.0
        static let astronomicalTwilight = -18.0
        static let starsAndPlanets = -0.5667
    }

    struct SunTimes {
        var astronomicalDawn: Date?
        var nauticalDawn: Date?
        var civilDawn: Date?
        var sunrise: Date?
        var solarNoon: Date?
        var sunset: Date?
        var civilDusk: Date?
        var nauticalDusk: Date?
        var astronomicalDusk: Date?
    }

    /// All of the Sun's horizon events for the local calendar day containing `referenceDate`
    /// (searched forward from `referenceDate`, so pass local midnight to get "today's" times).
    static func sunTimes(after referenceDate: Date, lat: Double, lon: Double) -> SunTimes {
        func find(_ kind: SkyEventKind, _ altitude: Double) -> Date? {
            RiseSetFinder.nextEvent(kind, after: referenceDate, latitude: lat, longitudeEast: lon, standardAltitude: altitude) { t in
                sunEquatorial(date: t)
            }
        }
        return SunTimes(
            astronomicalDawn: find(.rise, StandardAltitude.astronomicalTwilight),
            nauticalDawn: find(.rise, StandardAltitude.nauticalTwilight),
            civilDawn: find(.rise, StandardAltitude.civilTwilight),
            sunrise: find(.rise, StandardAltitude.sunriseSunset),
            solarNoon: find(.transit, 0),
            sunset: find(.set, StandardAltitude.sunriseSunset),
            civilDusk: find(.set, StandardAltitude.civilTwilight),
            nauticalDusk: find(.set, StandardAltitude.nauticalTwilight),
            astronomicalDusk: find(.set, StandardAltitude.astronomicalTwilight)
        )
    }

    // MARK: - Moon (truncated Meeus ch. 47 periodic series)

    /// One term of the Moon's longitude/distance or latitude periodic series: multipliers on
    /// D (elongation), M (Sun's anomaly), M′ (Moon's anomaly), F (argument of latitude), and
    /// the term's coefficient. Longitude/distance coefficients are in 0.000001° / 0.001 km;
    /// latitude coefficients are in 0.000001°.
    private struct LunarTerm {
        let d: Double, m: Double, mPrime: Double, f: Double, coefficient: Double
        /// Terms with `m != 0` involve the Sun's mean anomaly and get scaled by the
        /// eccentricity-correction factor E or E² (Meeus ch. 47) since Earth's orbital
        /// eccentricity isn't exactly the J2000 value at other epochs.
        var eccentricityPower: Int { m == 0 ? 0 : (abs(m) == 2 ? 2 : 1) }
    }

    // Truncated to the largest-amplitude terms of Meeus Table 47.A (longitude, distance) and
    // 47.B (latitude) — this keeps the engine's Moon position within roughly 1–2 arcminutes,
    // comfortably inside this package's ~1° / ~5 minute accuracy target, without hand-carrying
    // the full ~60-row tables.
    private static let longitudeDistanceTerms: [LunarTerm] = [
        LunarTerm(d: 0, m: 0, mPrime: 1, f: 0, coefficient: 6288774),
        LunarTerm(d: 2, m: 0, mPrime: -1, f: 0, coefficient: 1274027),
        LunarTerm(d: 2, m: 0, mPrime: 0, f: 0, coefficient: 658314),
        LunarTerm(d: 0, m: 0, mPrime: 2, f: 0, coefficient: 213618),
        LunarTerm(d: 0, m: 1, mPrime: 0, f: 0, coefficient: -185116),
        LunarTerm(d: 0, m: 0, mPrime: 0, f: 2, coefficient: -114332),
        LunarTerm(d: 2, m: 0, mPrime: -2, f: 0, coefficient: 58793),
        LunarTerm(d: 2, m: -1, mPrime: -1, f: 0, coefficient: 57066),
        LunarTerm(d: 2, m: 0, mPrime: 1, f: 0, coefficient: 53322),
        LunarTerm(d: 2, m: -1, mPrime: 0, f: 0, coefficient: 45758),
        LunarTerm(d: 0, m: 1, mPrime: -1, f: 0, coefficient: -40923),
        LunarTerm(d: 1, m: 0, mPrime: 0, f: 0, coefficient: -34720),
        LunarTerm(d: 0, m: 1, mPrime: 1, f: 0, coefficient: -30383),
        LunarTerm(d: 2, m: 0, mPrime: 0, f: -2, coefficient: 15327),
        LunarTerm(d: 0, m: 0, mPrime: 1, f: 2, coefficient: -12528),
        LunarTerm(d: 0, m: 0, mPrime: 1, f: -2, coefficient: 10980),
        LunarTerm(d: 4, m: 0, mPrime: -1, f: 0, coefficient: 10675),
        LunarTerm(d: 0, m: 0, mPrime: 3, f: 0, coefficient: 10034),
        LunarTerm(d: 4, m: 0, mPrime: -2, f: 0, coefficient: 8548),
        LunarTerm(d: 2, m: 1, mPrime: -1, f: 0, coefficient: -7888),
        LunarTerm(d: 2, m: 1, mPrime: 0, f: 0, coefficient: -6766),
    ]

    private static let latitudeTerms: [LunarTerm] = [
        LunarTerm(d: 0, m: 0, mPrime: 0, f: 1, coefficient: 5128122),
        LunarTerm(d: 0, m: 0, mPrime: 1, f: 1, coefficient: 280602),
        LunarTerm(d: 0, m: 0, mPrime: 1, f: -1, coefficient: 277693),
        LunarTerm(d: 2, m: 0, mPrime: 0, f: -1, coefficient: 173237),
        LunarTerm(d: 2, m: 0, mPrime: -1, f: 1, coefficient: 55413),
        LunarTerm(d: 2, m: 0, mPrime: -1, f: -1, coefficient: 46271),
        LunarTerm(d: 2, m: 0, mPrime: 0, f: 1, coefficient: 32573),
        LunarTerm(d: 0, m: 0, mPrime: 2, f: 1, coefficient: 17198),
        LunarTerm(d: 2, m: 0, mPrime: 1, f: -1, coefficient: 9266),
        LunarTerm(d: 0, m: 0, mPrime: 2, f: -1, coefficient: 8822),
    ]

    /// The Moon's geocentric ecliptic coordinates (longitude/latitude in degrees, distance
    /// in AU) at `date`.
    static func moonEcliptic(date: Date) -> EclipticCoordinates {
        let jd = AstroTime.julianDay(date)
        let T = AstroTime.julianCenturies(jd: jd)

        let Lp = AstroTime.normalizeDegrees(218.3164477 + 481267.88123421 * T - 0.0015786 * T * T + T * T * T / 538841)
        let D = AstroTime.normalizeDegrees(297.8501921 + 445267.1114034 * T - 0.0018819 * T * T + T * T * T / 545868)
        let M = AstroTime.normalizeDegrees(357.5291092 + 35999.0502909 * T - 0.0001536 * T * T)
        let Mp = AstroTime.normalizeDegrees(134.9633964 + 477198.8675055 * T + 0.0087414 * T * T + T * T * T / 69699)
        let F = AstroTime.normalizeDegrees(93.2720950 + 483202.0175233 * T - 0.0036539 * T * T - T * T * T / 3526000)

        let E = 1 - 0.002516 * T - 0.0000074 * T * T

        func eccentricityFactor(_ power: Int) -> Double {
            switch power {
            case 0: return 1
            case 2: return E * E
            default: return E
            }
        }

        var sigmaL = 0.0   // Σl, units of 1e-6 degree
        var sigmaR = 0.0   // Σr, units of 1e-3 km (unused here beyond distance; kept for completeness)
        for term in longitudeDistanceTerms {
            let argument = term.d * D + term.m * M + term.mPrime * Mp + term.f * F
            let factor = eccentricityFactor(term.eccentricityPower)
            sigmaL += term.coefficient * factor * AstroTime.sinDeg(argument)
        }
        // A compact distance term set (dominant cosine terms, same arguments/eccentricity
        // handling as above) — Meeus Table 47.A's Σr column, top rows.
        let distanceTerms: [(LunarTerm, Double)] = [
            (LunarTerm(d: 0, m: 0, mPrime: 1, f: 0, coefficient: 0), -20905355),
            (LunarTerm(d: 2, m: 0, mPrime: -1, f: 0, coefficient: 0), -3699111),
            (LunarTerm(d: 2, m: 0, mPrime: 0, f: 0, coefficient: 0), -2955968),
            (LunarTerm(d: 0, m: 0, mPrime: 2, f: 0, coefficient: 0), -569925),
            (LunarTerm(d: 0, m: 1, mPrime: 0, f: 0, coefficient: 0), 48888),
            (LunarTerm(d: 2, m: 0, mPrime: -2, f: 0, coefficient: 0), 246158),
            (LunarTerm(d: 2, m: -1, mPrime: -1, f: 0, coefficient: 0), -152138),
            (LunarTerm(d: 2, m: 0, mPrime: 1, f: 0, coefficient: 0), -170733),
            (LunarTerm(d: 2, m: -1, mPrime: 0, f: 0, coefficient: 0), -204586),
            (LunarTerm(d: 0, m: 1, mPrime: -1, f: 0, coefficient: 0), -129620),
            (LunarTerm(d: 1, m: 0, mPrime: 0, f: 0, coefficient: 0), 108743),
            (LunarTerm(d: 0, m: 1, mPrime: 1, f: 0, coefficient: 0), 104755),
        ]
        for (term, rCoefficient) in distanceTerms {
            let argument = term.d * D + term.m * M + term.mPrime * Mp + term.f * F
            let factor = eccentricityFactor(term.eccentricityPower)
            sigmaR += rCoefficient * factor * AstroTime.cosDeg(argument)
        }

        var sigmaB = 0.0   // Σb, units of 1e-6 degree
        for term in latitudeTerms {
            let argument = term.d * D + term.m * M + term.mPrime * Mp + term.f * F
            let factor = eccentricityFactor(term.eccentricityPower)
            sigmaB += term.coefficient * factor * AstroTime.sinDeg(argument)
        }

        let longitude = AstroTime.normalizeDegrees(Lp + sigmaL / 1_000_000)
        let latitude = sigmaB / 1_000_000
        let distanceKm = 385000.56 + sigmaR / 1000.0
        let distanceAU = distanceKm / 149597870.7

        return EclipticCoordinates(longitude: longitude, latitude: latitude, distanceAU: distanceAU)
    }

    /// Geocentric equatorial coordinates of the Moon at `date`.
    static func moonEquatorial(date: Date) -> EquatorialCoordinates {
        let jd = AstroTime.julianDay(date)
        let T = AstroTime.julianCenturies(jd: jd)
        let epsilon = AstroTime.trueObliquity(T: T)
        return eclipticToEquatorial(moonEcliptic(date: date), obliquity: epsilon)
    }

    /// The Moon's rise/transit/set for the local calendar day containing `referenceDate`
    /// (pass local midnight for "today's" moon times). Uses the Moon's own standard altitude,
    /// which — unlike the Sun's fixed −0.8333° — varies with the Moon's actual horizontal
    /// parallax (Meeus 15, h0 = 0.7275·π − 34′, π = arcsin(6378.14 / distance)).
    static func moonTimes(after referenceDate: Date, lat: Double, lon: Double) -> (rise: Date?, transit: Date?, set: Date?) {
        func standardAltitude(at date: Date) -> Double {
            let eq = moonEquatorial(date: date)
            let horizontalParallax = AstroTime.asinDeg(6378.14 / (eq.distanceAU * 149597870.7))
            return 0.7275 * horizontalParallax - 34.0 / 60.0
        }
        // The parallax-derived altitude barely changes over a day; evaluate once at the
        // reference instant rather than re-deriving it inside every solver iteration.
        let h0 = standardAltitude(at: referenceDate)

        func find(_ kind: SkyEventKind) -> Date? {
            RiseSetFinder.nextEvent(kind, after: referenceDate, latitude: lat, longitudeEast: lon, standardAltitude: h0) { t in
                moonEquatorial(date: t)
            }
        }
        return (find(.rise), find(.transit), find(.set))
    }

    struct MoonPhase {
        /// 0 = new moon, 0.25 = first quarter, 0.5 = full moon, 0.75 = last quarter.
        var phaseFraction: Double
        var illuminatedFraction: Double
        var waxing: Bool
    }

    /// Precise phase and illumination via the actual Sun–Earth–Moon geometry (elongation
    /// and phase angle), rather than the simple mean-synodic-cycle cosine approximation in
    /// `Sources/Doodle/FullMoonCalculator.swift`. Divergence from that file, documented per
    /// the work order: `FullMoonCalculator` treats the synodic month as constant and drives
    /// illumination from a pure `(1-cos(2π·phase))/2` curve keyed off a fixed reference full
    /// moon — good to about half a day per decade, fine for a decorative "is it a full-moon
    /// night" overlay. This engine instead computes the Moon's and Sun's actual ecliptic
    /// positions for the given date and derives the true phase angle (Meeus ch. 48), which
    /// tracks the Moon's real elliptical, perturbed motion — accurate to a few minutes near
    /// quarter phases and effectively exact (illumination symmetric) at new/full. The two
    /// should usually agree to within an hour or so; if they visibly disagree on a given
    /// night, trust this engine's value.
    static func moonPhase(date: Date) -> MoonPhase {
        let jd = AstroTime.julianDay(date)
        let T = AstroTime.julianCenturies(jd: jd)
        let moon = moonEcliptic(date: date)
        let (sunTrueLongitude, sunDistanceAU) = sunGeometric(T: T)

        // Geocentric elongation of the Moon from the Sun (Meeus 48.2, ignoring the Moon's
        // small ecliptic latitude term for phase-angle purposes — sub-0.1% effect on
        // illuminated fraction).
        let elongation = AstroTime.acosDeg(AstroTime.cosDeg(moon.latitude) * AstroTime.cosDeg(moon.longitude - sunTrueLongitude))

        // Phase angle i (Meeus 48.3), using mean Earth-Moon distance ratio.
        let earthMoonDistanceKm = moon.distanceAU * 149597870.7
        let sunEarthDistanceKm = sunDistanceAU * 149597870.7
        let phaseAngle = AstroTime.atan2Deg(
            sunEarthDistanceKm * AstroTime.sinDeg(elongation),
            earthMoonDistanceKm - sunEarthDistanceKm * AstroTime.cosDeg(elongation)
        )
        let illuminatedFraction = (1 + AstroTime.cosDeg(phaseAngle)) / 2

        // Waxing vs waning: the Moon moves eastward (increasing ecliptic longitude) faster
        // than the Sun, so the Moon-minus-Sun longitude difference, taken in 0..<360 and
        // divided by 360, is exactly the phase fraction — 0 at new moon, 0.5 at full moon,
        // growing (waxing) for the first half of the cycle and shrinking (waning) is
        // equivalent to "past the halfway point" for the second half.
        let unsignedElongation = AstroTime.normalizeDegrees(moon.longitude - sunTrueLongitude)
        let phaseFraction = unsignedElongation / 360.0
        let isWaxing = unsignedElongation < 180

        return MoonPhase(phaseFraction: phaseFraction, illuminatedFraction: illuminatedFraction, waxing: isWaxing)
    }
}
