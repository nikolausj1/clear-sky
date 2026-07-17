import Foundation

// MARK: - Coordinate transforms, sun position, and visible-pass search.
//
// This file is pure math (no networking). It implements:
//   1. TEME -> ECEF via GMST rotation (no polar motion -- acceptable for
//      pass-prediction accuracy per the work package spec).
//   2. ECEF -> topocentric (alt/az) for an observer at (lat, lon, alt=0),
//      using WGS84 geodetic-to-ECEF for the observer position.
//   3. An internal, minimal low-precision (Meeus, ch. 25-ish) Sun-position
//      calculation, deliberately NOT depending on any sibling Astronomy
//      package (per work-package isolation constraints).
//   4. A visible-pass search: ISS altitude > 10 deg, observer twilight/dark
//      (sun elevation < -6 deg), and ISS sunlit (cylindrical Earth-shadow
//      test).

public struct GeoCoordinate {
    public let latitudeDeg: Double
    public let longitudeDeg: Double // East positive
    public let altitudeKm: Double

    public init(latitudeDeg: Double, longitudeDeg: Double, altitudeKm: Double = 0.0) {
        self.latitudeDeg = latitudeDeg
        self.longitudeDeg = longitudeDeg
        self.altitudeKm = altitudeKm
    }
}

public struct TopocentricPosition {
    public let altitudeDeg: Double
    public let azimuthDeg: Double
    public let rangeKm: Double
}

enum AstroMath {
    static let deg2rad = Double.pi / 180.0
    static let rad2deg = 180.0 / Double.pi

    /// Julian Date (UT1 ~ UTC approximation) for a given Date.
    static func julianDate(_ date: Date) -> Double {
        // Unix epoch 1970-01-01T00:00:00Z corresponds to JD 2440587.5
        return 2440587.5 + date.timeIntervalSince1970 / 86400.0
    }

    /// Greenwich Mean Sidereal Time in radians, using the standard IAU 1982
    /// polynomial (no polar motion / nutation correction -- adequate for
    /// pass-prediction accuracy per work-package spec).
    static func gmstRadians(julianDate jd: Double) -> Double {
        let t = (jd - 2451545.0) / 36525.0
        var gmstDeg = 280.46061837
            + 360.98564736629 * (jd - 2451545.0)
            + 0.000387933 * t * t
            - (t * t * t) / 38710000.0
        gmstDeg = gmstDeg.truncatingRemainder(dividingBy: 360.0)
        if gmstDeg < 0 { gmstDeg += 360.0 }
        return gmstDeg * deg2rad
    }

    /// Rotate a TEME position/velocity into ECEF using the GMST rotation
    /// (Z-axis rotation only; no polar motion).
    static func temeToECEF(_ position: Vector3, julianDate jd: Double) -> Vector3 {
        let theta = gmstRadians(julianDate: jd)
        let cosT = cos(theta)
        let sinT = sin(theta)
        let x = cosT * position.x + sinT * position.y
        let y = -sinT * position.x + cosT * position.y
        let z = position.z
        return Vector3(x, y, z)
    }

    /// WGS84 ellipsoid constants.
    static let wgs84A = 6378.137 // km
    static let wgs84F = 1.0 / 298.257223563
    static let wgs84E2 = wgs84F * (2.0 - wgs84F)

    /// Geodetic (lat, lon, alt) -> ECEF position, km, using WGS84.
    static func geodeticToECEF(_ geo: GeoCoordinate) -> Vector3 {
        let lat = geo.latitudeDeg * deg2rad
        let lon = geo.longitudeDeg * deg2rad
        let sinLat = sin(lat)
        let cosLat = cos(lat)
        let n = wgs84A / (1.0 - wgs84E2 * sinLat * sinLat).squareRoot()
        let x = (n + geo.altitudeKm) * cosLat * cos(lon)
        let y = (n + geo.altitudeKm) * cosLat * sin(lon)
        let z = (n * (1.0 - wgs84E2) + geo.altitudeKm) * sinLat
        return Vector3(x, y, z)
    }

    /// ECEF satellite position -> topocentric alt/az/range as seen from an
    /// observer at `geo` (also ECEF).
    static func topocentric(satelliteECEF: Vector3, observer geo: GeoCoordinate) -> TopocentricPosition {
        let observerECEF = geodeticToECEF(geo)
        let d = satelliteECEF - observerECEF
        let lat = geo.latitudeDeg * deg2rad
        let lon = geo.longitudeDeg * deg2rad
        let sinLat = sin(lat), cosLat = cos(lat)
        let sinLon = sin(lon), cosLon = cos(lon)

        let south = sinLat * cosLon * d.x + sinLat * sinLon * d.y - cosLat * d.z
        let east = -sinLon * d.x + cosLon * d.y
        let zenith = cosLat * cosLon * d.x + cosLat * sinLon * d.y + sinLat * d.z

        let range = d.magnitude
        let elevation = asin(zenith / range) * rad2deg
        var azimuth = atan2(east, -south) * rad2deg
        if azimuth < 0 { azimuth += 360.0 }
        return TopocentricPosition(altitudeDeg: elevation, azimuthDeg: azimuth, rangeKm: range)
    }

    /// Minimal internal low-precision Sun position (Meeus, "low precision
    /// solar coordinates", good to ~0.01 deg), returned as a geocentric
    /// equatorial-of-date position vector in km. This is intentionally a
    /// self-contained, low-precision internal calculation -- NOT the
    /// sibling Astronomy package's `sunPosition` API -- to keep this
    /// package dependency-free per the work-package constraints. It
    /// approximates the TEME frame (mean-equinox-of-date vs J2000 drift is
    /// a few arcminutes over the relevant time span, negligible for
    /// twilight/shadow determination).
    static func sunPositionGeocentricEquatorial(julianDate jd: Double) -> Vector3 {
        let n = jd - 2451545.0
        var l = 280.460 + 0.9856474 * n
        var g = 357.528 + 0.9856003 * n
        l = l.truncatingRemainder(dividingBy: 360.0); if l < 0 { l += 360.0 }
        g = g.truncatingRemainder(dividingBy: 360.0); if g < 0 { g += 360.0 }
        let gRad = g * deg2rad
        var lambda = l + 1.915 * sin(gRad) + 0.020 * sin(2.0 * gRad)
        lambda = lambda.truncatingRemainder(dividingBy: 360.0); if lambda < 0 { lambda += 360.0 }
        let lambdaRad = lambda * deg2rad
        let epsilon = (23.439 - 0.0000004 * n) * deg2rad
        let rAU = 1.00014 - 0.01671 * cos(gRad) - 0.00014 * cos(2.0 * gRad)
        let auKm = 149597870.7

        let x = rAU * cos(lambdaRad)
        let y = rAU * cos(epsilon) * sin(lambdaRad)
        let z = rAU * sin(epsilon) * sin(lambdaRad)
        return Vector3(x * auKm, y * auKm, z * auKm)
    }

    /// Sun's topocentric altitude (degrees) for an observer, using the
    /// standard equatorial (RA/Dec) -> horizontal transform. Only altitude
    /// is needed for the twilight test, so azimuth is not computed.
    /// `sunEquatorial` should be in the same (TEME-approximating,
    /// geocentric equatorial-of-date) frame as `sunPositionGeocentricEquatorial`.
    static func sunAltitudeDeg(sunEquatorial: Vector3, observer geo: GeoCoordinate, julianDate jd: Double) -> Double {
        let r = sunEquatorial.magnitude
        let dec = asin(sunEquatorial.z / r)
        let ra = atan2(sunEquatorial.y, sunEquatorial.x)

        let gmst = gmstRadians(julianDate: jd)
        let lst = gmst + geo.longitudeDeg * deg2rad
        let hourAngle = lst - ra

        let lat = geo.latitudeDeg * deg2rad
        let sinAlt = sin(lat) * sin(dec) + cos(lat) * cos(dec) * cos(hourAngle)
        return asin(max(-1.0, min(1.0, sinAlt))) * rad2deg
    }

    /// Cylindrical Earth-shadow test: returns true if the satellite (TEME
    /// position, km) is sunlit given the Sun's position (same-frame vector,
    /// km). This is a simplified model (no penumbra/umbra cone, ignores
    /// atmospheric effects) -- adequate for naked-eye visibility screening.
    static func isSunlit(satelliteTEME: Vector3, sunTEME: Vector3, earthRadiusKm: Double = 6378.137) -> Bool {
        let sunDistance = sunTEME.magnitude
        let sunHat = Vector3(sunTEME.x / sunDistance, sunTEME.y / sunDistance, sunTEME.z / sunDistance)
        let dotProduct = satelliteTEME.dot(sunHat)
        if dotProduct > 0 {
            // Satellite is on the sun-facing hemisphere relative to Earth's
            // center -- always sunlit.
            return true
        }
        // On the anti-sun side: check perpendicular distance from the
        // Earth-Sun line to decide umbral shadow.
        let perp = satelliteTEME - sunHat * dotProduct
        return perp.magnitude > earthRadiusKm
    }
}

/// Compass point string (16-point) for an azimuth in degrees.
public func compassPointString(forAzimuthDeg az: Double) -> String {
    let points = ["N", "NNE", "NE", "ENE", "E", "ESE", "SE", "SSE",
                  "S", "SSW", "SW", "WSW", "W", "WNW", "NW", "NNW"]
    var a = az.truncatingRemainder(dividingBy: 360.0)
    if a < 0 { a += 360.0 }
    let idx = Int((a / 22.5).rounded()) % 16
    return points[idx]
}

public enum ISSBrightness: String {
    case bright, moderate, dim
}

public struct ISSPass {
    public let startTime: Date
    public let peakTime: Date
    public let endTime: Date
    public let peakAltitudeDeg: Double
    public let startAzimuthDeg: Double
    public let endAzimuthDeg: Double
    public let startAzimuthCompass: String
    public let endAzimuthCompass: String
    public let peakRangeKm: Double
    public let brightness: ISSBrightness
}

public enum PassPredictor {

    /// A single evaluated sample point during the search.
    struct Sample {
        let date: Date
        let issAlt: Double
        let issAz: Double
        let issRange: Double
        let sunAlt: Double
        let sunlit: Bool

        var isVisible: Bool { issAlt > 10.0 && sunAlt < -6.0 && sunlit }
    }

    static func evaluate(propagator: SGP4Propagator, tle: TLE, observer: GeoCoordinate, at date: Date) throws -> Sample {
        let tsince = tle.minutesSinceEpoch(at: date)
        let state = try propagator.propagate(minutesSinceEpoch: tsince)
        let jd = AstroMath.julianDate(date)
        let issECEF = AstroMath.temeToECEF(state.position, julianDate: jd)
        let topo = AstroMath.topocentric(satelliteECEF: issECEF, observer: observer)
        let sunTEME = AstroMath.sunPositionGeocentricEquatorial(julianDate: jd)
        let sunAlt = AstroMath.sunAltitudeDeg(sunEquatorial: sunTEME, observer: observer, julianDate: jd)
        let sunlit = AstroMath.isSunlit(satelliteTEME: state.position, sunTEME: sunTEME)
        return Sample(date: date, issAlt: topo.altitudeDeg, issAz: topo.azimuthDeg, issRange: topo.rangeKm,
                      sunAlt: sunAlt, sunlit: sunlit)
    }

    /// Rough brightness heuristic, documented per work-package spec: ISS
    /// visual magnitude in reality depends on phase angle, range, and
    /// atmospheric extinction near the horizon. As a simplified proxy we
    /// use peak altitude (higher = less atmospheric extinction, generally
    /// closer overhead pass) combined with the range at peak (closer =
    /// brighter, since the ISS is a fixed-size reflector). Thresholds below
    /// are a coarse heuristic, not a photometric model.
    static func brightness(peakAltitudeDeg: Double, peakRangeKm: Double) -> ISSBrightness {
        if peakAltitudeDeg >= 45.0 && peakRangeKm <= 700.0 {
            return .bright
        }
        if peakAltitudeDeg >= 20.0 && peakRangeKm <= 1200.0 {
            return .moderate
        }
        if peakAltitudeDeg >= 40.0 {
            return .moderate
        }
        return .dim
    }

    /// Search the window [windowStart, windowEnd] for visible ISS passes.
    /// `coarseStepSeconds` controls the initial scan resolution; pass
    /// boundaries are then refined via bisection.
    public static func findPasses(
        tle: TLE,
        propagator: SGP4Propagator,
        observer: GeoCoordinate,
        windowStart: Date,
        windowEnd: Date,
        coarseStepSeconds: Double = 10.0
    ) throws -> [ISSPass] {
        guard windowEnd > windowStart else { return [] }

        var samples: [Sample] = []
        var t = windowStart
        while t <= windowEnd {
            samples.append(try evaluate(propagator: propagator, tle: tle, observer: observer, at: t))
            t = t.addingTimeInterval(coarseStepSeconds)
        }
        if samples.last?.date != windowEnd {
            samples.append(try evaluate(propagator: propagator, tle: tle, observer: observer, at: windowEnd))
        }

        var passes: [ISSPass] = []
        var i = 0
        while i < samples.count {
            if samples[i].isVisible {
                var j = i
                while j + 1 < samples.count && samples[j + 1].isVisible {
                    j += 1
                }
                // [i, j] is a visible run of coarse samples. Refine boundaries.
                let rawStart = i > 0 ? samples[i - 1].date : samples[i].date
                let rawStartVisible = i > 0 ? samples[i].date : samples[i].date
                let refinedStart = i > 0
                    ? try refineBoundary(propagator: propagator, tle: tle, observer: observer,
                                          from: rawStart, to: rawStartVisible, wantVisible: true)
                    : samples[i].date

                let rawEndVisible = samples[j].date
                let rawEndInvisible = j + 1 < samples.count ? samples[j + 1].date : samples[j].date
                let refinedEnd = j + 1 < samples.count
                    ? try refineBoundary(propagator: propagator, tle: tle, observer: observer,
                                          from: rawEndInvisible, to: rawEndVisible, wantVisible: true)
                    : samples[j].date

                // Find peak altitude within [refinedStart, refinedEnd] via fine sampling.
                var peakSample = samples[i]
                var fineT = refinedStart
                let fineStep = 2.0
                while fineT <= refinedEnd {
                    let s = try evaluate(propagator: propagator, tle: tle, observer: observer, at: fineT)
                    if s.issAlt > peakSample.issAlt { peakSample = s }
                    fineT = fineT.addingTimeInterval(fineStep)
                }
                let endSample = try evaluate(propagator: propagator, tle: tle, observer: observer, at: refinedEnd)
                let startSample = try evaluate(propagator: propagator, tle: tle, observer: observer, at: refinedStart)

                let b = brightness(peakAltitudeDeg: peakSample.issAlt, peakRangeKm: peakSample.issRange)
                passes.append(ISSPass(
                    startTime: refinedStart,
                    peakTime: peakSample.date,
                    endTime: refinedEnd,
                    peakAltitudeDeg: peakSample.issAlt,
                    startAzimuthDeg: startSample.issAz,
                    endAzimuthDeg: endSample.issAz,
                    startAzimuthCompass: compassPointString(forAzimuthDeg: startSample.issAz),
                    endAzimuthCompass: compassPointString(forAzimuthDeg: endSample.issAz),
                    peakRangeKm: peakSample.issRange,
                    brightness: b
                ))
                i = j + 1
            } else {
                i += 1
            }
        }
        return passes
    }

    /// Bisection refinement of a visible/invisible transition to ~1 second
    /// resolution. `from` should be the non-visible endpoint, `to` the
    /// visible endpoint.
    private static func refineBoundary(
        propagator: SGP4Propagator, tle: TLE, observer: GeoCoordinate,
        from: Date, to: Date, wantVisible: Bool, tolerance: Double = 1.0
    ) throws -> Date {
        var lo = from
        var hi = to
        // Ensure hi is the visible side, lo is the non-visible side.
        while abs(hi.timeIntervalSince(lo)) > tolerance {
            let mid = lo.addingTimeInterval(hi.timeIntervalSince(lo) / 2.0)
            let s = try evaluate(propagator: propagator, tle: tle, observer: observer, at: mid)
            if s.isVisible {
                hi = mid
            } else {
                lo = mid
            }
        }
        return hi
    }
}
