import Foundation

/// Naked-eye planet positions (Mercury, Venus, Mars, Jupiter, Saturn) via Meeus "Astronomical
/// Algorithms" chapter 31's low-precision Keplerian orbital elements (Table 31.A, referred to
/// the mean equinox of date — chosen specifically because it needs no separate precession
/// step) plus a two-body Kepler solution, geocentric conversion, one light-time iteration,
/// and Meeus/Astronomical-Almanac approximate magnitude formulas (ch. 41–42).
///
/// Accuracy target (per work order): topocentric alt/az within about 1°, magnitude within
/// about 0.3 — this is a "low precision, good enough to say where to look" engine, not an
/// ephemeris-quality one. The dominant error source is the elements table itself (Meeus rates
/// this table at roughly 1 arcminute over recent decades for the inner planets, more for the
/// outer ones), not the arithmetic on top of it.
enum Planets {

    /// The five naked-eye planets. `caseIterable` order is also visual brightness-ish order,
    /// not orbital order — doesn't matter functionally, just convenient for UI lists.
    enum Body: String, CaseIterable {
        case mercury, venus, mars, jupiter, saturn

        var displayName: String {
            rawValue.prefix(1).uppercased() + rawValue.dropFirst()
        }

        /// True for the inferior planets (orbit inside Earth's), which are always near the
        /// Sun in the sky and need the twilight-based visibility rule rather than requiring
        /// full darkness.
        var isInferior: Bool {
            self == .mercury || self == .venus
        }
    }

    /// Osculating orbital elements at Julian century `T`, referred to the mean equinox of
    /// date. Angles in degrees, `semiMajorAxis` in AU.
    private struct OrbitalElements {
        var meanLongitude: Double       // L
        var semiMajorAxis: Double       // a
        var eccentricity: Double        // e
        var inclination: Double         // i
        var ascendingNode: Double       // Ω
        var perihelionLongitude: Double // ϖ (pi symbol; longitude of perihelion, not Ω)
    }

    /// Meeus Table 31.A polynomials (mean equinox of date). Coefficients are degrees/AU per
    /// power of `T` (Julian centuries from J2000), highest-confidence (linear) term first.
    private static func elements(for body: Body, T: Double) -> OrbitalElements {
        func poly(_ c0: Double, _ c1: Double, _ c2: Double = 0, _ c3: Double = 0) -> Double {
            c0 + T * (c1 + T * (c2 + T * c3))
        }
        switch body {
        case .mercury:
            return OrbitalElements(
                meanLongitude: poly(252.250906, 149472.6746358, -0.00000535, 0.000000002),
                semiMajorAxis: 0.387098310,
                eccentricity: poly(0.20563175, 0.000020407, -0.0000000283, -0.00000000018),
                inclination: poly(7.004986, -0.0059516, 0.00000081, 0.000000041),
                ascendingNode: poly(48.330893, -0.1254229, -0.00008833, -0.000000196),
                perihelionLongitude: poly(77.456119, 0.1588643, -0.00001343, 0.000000039)
            )
        case .venus:
            return OrbitalElements(
                meanLongitude: poly(181.979801, 58517.8156760, 0.00000165, -0.000000002),
                semiMajorAxis: 0.723329820,
                eccentricity: poly(0.00677188, -0.000047766, 0.0000000975, 0.00000000044),
                inclination: poly(3.394662, -0.0008568, -0.00003244, 0.000000010),
                ascendingNode: poly(76.679920, -0.2780080, -0.00014256, -0.000000198),
                perihelionLongitude: poly(131.563707, 0.0048646, -0.00138232, -0.000005332)
            )
        case .mars:
            return OrbitalElements(
                meanLongitude: poly(355.433275, 19140.2993313, 0.00000261, -0.000000003),
                semiMajorAxis: 1.523679342,
                eccentricity: poly(0.09340065, 0.000090484, -0.0000000806, -0.00000000025),
                inclination: poly(1.849726, -0.0081479, -0.00002255, -0.000000027),
                ascendingNode: poly(49.558093, -0.2949846, -0.00063993, -0.000002143),
                perihelionLongitude: poly(336.060234, 0.4438898, -0.00017321, 0.000000300)
            )
        case .jupiter:
            return OrbitalElements(
                meanLongitude: poly(34.351484, 3034.9056746, -0.00008501, 0.000000004),
                semiMajorAxis: 5.202603191 + 0.0000001913 * T,
                eccentricity: poly(0.04849793, 0.000163225, -0.0000004714, -0.00000000201),
                inclination: poly(1.303270, -0.0019872, 0.00003318, 0.000000092),
                ascendingNode: poly(100.464441, 0.1766828, 0.00090387, -0.000007032),
                perihelionLongitude: poly(14.331309, 0.2155525, 0.00072252, -0.000004590)
            )
        case .saturn:
            return OrbitalElements(
                meanLongitude: poly(50.077471, 1222.1137943, 0.00021004, -0.000000019),
                semiMajorAxis: 9.554909596 - 0.0000021389 * T,
                eccentricity: poly(0.05554814, -0.0003446641, -0.0000006436, 0.00000000340),
                inclination: poly(2.488878, 0.0025515, -0.00004903, 0.000000018),
                ascendingNode: poly(113.665524, -0.2566649, -0.00018345, 0.000000357),
                perihelionLongitude: poly(93.056787, 0.5665496, 0.00052809, 0.000004882)
            )
        }
    }

    /// Solves Kepler's equation E − e·sin E = M for the eccentric anomaly E (degrees), given
    /// mean anomaly `M` (degrees) and eccentricity `e`. Newton–Raphson; for the eccentricities
    /// involved here (< 0.21) this converges to double precision in well under 10 iterations.
    private static func eccentricAnomaly(meanAnomalyDegrees M: Double, eccentricity e: Double) -> Double {
        let mRad = M * .pi / 180.0
        var E = mRad + e * sin(mRad) // good starting guess
        for _ in 0..<12 {
            let delta = (E - e * sin(E) - mRad) / (1 - e * cos(E))
            E -= delta
            if abs(delta) < 1e-12 { break }
        }
        return E * 180.0 / .pi
    }

    /// Heliocentric ecliptic rectangular coordinates (mean equinox of date, AU) for `body`
    /// at Julian century `T`.
    private static func heliocentricRectangular(for body: Body, T: Double) -> EclipticRectangular {
        let el = elements(for: body, T: T)
        let omega = el.ascendingNode
        let argOfPerihelion = el.perihelionLongitude - omega // ω = ϖ − Ω
        let M = AstroTime.normalizeDegrees(el.meanLongitude - el.perihelionLongitude)
        let E = eccentricAnomaly(meanAnomalyDegrees: M, eccentricity: el.eccentricity)

        // Position in the orbital plane (perifocal frame).
        let xOrbit = el.semiMajorAxis * (AstroTime.cosDeg(E) - el.eccentricity)
        let yOrbit = el.semiMajorAxis * sqrt(1 - el.eccentricity * el.eccentricity) * AstroTime.sinDeg(E)

        // Perifocal-to-ecliptic rotation via the standard P/Q unit vectors (equivalent to the
        // 3-1-3 Euler rotation R_z(-Ω) R_x(-i) R_z(-ω); Meeus 33.7).
        let cosO = AstroTime.cosDeg(omega), sinO = AstroTime.sinDeg(omega)
        let cosW = AstroTime.cosDeg(argOfPerihelion), sinW = AstroTime.sinDeg(argOfPerihelion)
        let cosI = AstroTime.cosDeg(el.inclination), sinI = AstroTime.sinDeg(el.inclination)

        let Px = cosW * cosO - sinW * sinO * cosI
        let Py = cosW * sinO + sinW * cosO * cosI
        let Pz = sinW * sinI
        let Qx = -sinW * cosO - cosW * sinO * cosI
        let Qy = -sinW * sinO + cosW * cosO * cosI
        let Qz = cosW * sinI

        return EclipticRectangular(
            x: xOrbit * Px + yOrbit * Qx,
            y: xOrbit * Py + yOrbit * Qy,
            z: xOrbit * Pz + yOrbit * Qz
        )
    }

    /// Earth's heliocentric ecliptic rectangular coordinates, derived from the Sun's
    /// geocentric geometric position already computed in `SunMoon.swift` (Earth's
    /// heliocentric longitude is the Sun's geocentric longitude + 180°; Earth's heliocentric
    /// ecliptic latitude is ~0 by definition of the ecliptic plane).
    private static func earthHeliocentricRectangular(T: Double) -> EclipticRectangular {
        let (sunTrueLongitude, R) = SunMoon.sunGeometric(T: T)
        let earthLongitude = sunTrueLongitude + 180
        return EclipticRectangular(
            x: R * AstroTime.cosDeg(earthLongitude),
            y: R * AstroTime.sinDeg(earthLongitude),
            z: 0
        )
    }

    /// Geocentric equatorial coordinates of `body` at `date`, with one light-time iteration
    /// (the planet's position is evaluated at `T`, then re-evaluated at `T` minus the light
    /// travel time implied by the first-pass distance — one pass is enough for our accuracy;
    /// Meeus notes a second iteration changes results by well under an arcsecond).
    /// Also returns heliocentric distance `r` and geocentric distance `delta` (both AU),
    /// needed by the magnitude formula.
    static func geocentric(_ body: Body, date: Date) -> (equatorial: EquatorialCoordinates, r: Double, delta: Double) {
        let jd = AstroTime.julianDay(date)
        let T = AstroTime.julianCenturies(jd: jd)
        let earth = earthHeliocentricRectangular(T: T)

        func geocentricVector(planetT: Double) -> (EclipticRectangular, Double) {
            let helio = heliocentricRectangular(for: body, T: planetT)
            let geo = helio - earth
            return (geo, helio.magnitude)
        }

        var (geoVector, r) = geocentricVector(planetT: T)
        var delta = geoVector.magnitude
        // Light-time correction: τ (days) = 0.0057755183 * Δ(AU); one iteration.
        let tau = 0.0057755183 * delta
        (geoVector, r) = geocentricVector(planetT: T - tau / 36525.0)
        delta = geoVector.magnitude

        let epsilon = AstroTime.trueObliquity(T: T)
        let ecliptic = geoVector.asEcliptic
        var equatorial = eclipticToEquatorial(ecliptic, obliquity: epsilon)
        equatorial.distanceAU = delta
        return (equatorial, r, delta)
    }

    /// Apparent visual magnitude (Astronomical Almanac / Meeus ch. 41–42 approximate
    /// formulas), given heliocentric distance `r` (AU), geocentric distance `delta` (AU), and
    /// Sun–planet–Earth phase angle `phaseAngleDegrees`. For Saturn, pass `saturnRingTiltDegrees`
    /// (see `saturnRingTilt(date:)`) to include the ring-brightness term — Saturn's rings can
    /// swing its magnitude by over a full step across its ~29.5-year tilt cycle, so this
    /// matters far more for Saturn than the omission would for any other body. If `nil`
    /// (default), the plain body-only term is used, which is only right when the rings
    /// happen to be near their mean tilt.
    static func apparentMagnitude(_ body: Body, r: Double, delta: Double, phaseAngleDegrees i: Double, saturnRingTiltDegrees: Double? = nil) -> Double {
        let distanceTerm = 5 * log10(r * delta)
        switch body {
        case .mercury: return -0.42 + distanceTerm + 0.0380 * i - 0.000273 * i * i + 0.000002 * i * i * i
        case .venus: return -4.40 + distanceTerm + 0.0009 * i + 0.000239 * i * i - 0.00000065 * i * i * i
        case .mars: return -1.52 + distanceTerm + 0.016 * i
        case .jupiter: return -9.40 + distanceTerm + 0.005 * i
        case .saturn:
            guard let B = saturnRingTiltDegrees else { return -8.88 + distanceTerm + 0.044 * i }
            return -8.88 + distanceTerm + 0.044 * i - 2.60 * AstroTime.sinDeg(abs(B)) + 1.25 * pow(AstroTime.sinDeg(B), 2)
        }
    }

    /// Saturnicentric ring-plane tilt `B` (degrees) as seen from Earth at `date` — Meeus ch.
    /// 42's `sin B = sin i_r cos β sin(λ−Ω_r) − cos i_r sin β`, where `i_r`/`Ω_r` are the ring
    /// plane's own slowly-precessing inclination/node (Meeus 42.1–42.2) and `λ`/`β` are
    /// Saturn's geocentric ecliptic longitude/latitude. Ranges roughly ±27°; 0° means the
    /// rings are edge-on (and briefly invisible/no brightness contribution), which happens
    /// close to Saturn's equinoxes (about every 15 years).
    static func saturnRingTilt(date: Date) -> Double {
        let jd = AstroTime.julianDay(date)
        let T = AstroTime.julianCenturies(jd: jd)
        let earth = earthHeliocentricRectangular(T: T)
        let helio = heliocentricRectangular(for: .saturn, T: T)
        let ecliptic = (helio - earth).asEcliptic

        let ringInclination = 28.075216 - 0.012998 * T + 0.000004 * T * T
        let ringNode = 169.508470 + 1.394681 * T + 0.000412 * T * T

        let sinB = AstroTime.sinDeg(ringInclination) * AstroTime.cosDeg(ecliptic.latitude) * AstroTime.sinDeg(ecliptic.longitude - ringNode)
            - AstroTime.cosDeg(ringInclination) * AstroTime.sinDeg(ecliptic.latitude)
        return AstroTime.asinDeg(sinB)
    }

    /// Phase angle (Sun–body–Earth, degrees) from the law of cosines on the Sun–Earth (`R`),
    /// Sun–body (`r`), and Earth–body (`delta`) distances (Meeus 48.3 applied to a planet).
    static func phaseAngle(r: Double, delta: Double, sunEarthDistance R: Double) -> Double {
        let cosI = (r * r + delta * delta - R * R) / (2 * r * delta)
        return AstroTime.acosDeg(cosI)
    }
}
