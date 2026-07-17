import Foundation

// MARK: - SGP4 near-Earth propagator
//
// Port of the standard "Revisiting Spacetrack Report #3" SGP4 algorithm
// (Vallado, Crawford, Hujsak, Kelso 2006), near-Earth branch only.
//
// Deep-space satellites (orbital period >= 225 minutes, per the standard
// SGP4/SDP4 split criterion) are explicitly detected and rejected with
// `SGP4Error.deepSpaceUnsupported` rather than silently producing wrong
// answers -- this package implements SGP4 (near-Earth) only, not SDP4.
//
// Units: internally SGP4 works in "Earth radii" and "minutes" canonical
// units; inputs/outputs at the public boundary are km and km/s.

/// A simple 3-vector, used for position (km) and velocity (km/s).
public struct Vector3: Equatable {
    public var x: Double
    public var y: Double
    public var z: Double

    public init(_ x: Double, _ y: Double, _ z: Double) {
        self.x = x; self.y = y; self.z = z
    }

    public static let zero = Vector3(0, 0, 0)

    public var magnitude: Double { (x * x + y * y + z * z).squareRoot() }

    public static func - (lhs: Vector3, rhs: Vector3) -> Vector3 {
        Vector3(lhs.x - rhs.x, lhs.y - rhs.y, lhs.z - rhs.z)
    }
    public static func + (lhs: Vector3, rhs: Vector3) -> Vector3 {
        Vector3(lhs.x + rhs.x, lhs.y + rhs.y, lhs.z + rhs.z)
    }
    public static func * (lhs: Vector3, rhs: Double) -> Vector3 {
        Vector3(lhs.x * rhs, lhs.y * rhs, lhs.z * rhs)
    }

    public func dot(_ o: Vector3) -> Double { x * o.x + y * o.y + z * o.z }
}

/// TEME (True Equator, Mean Equinox) position/velocity at a given time.
public struct TEMEState {
    public let position: Vector3 // km
    public let velocity: Vector3 // km/s
}

public enum SGP4Error: Error, CustomStringConvertible {
    /// This TLE's period is >= 225 minutes, meaning it requires the deep-space
    /// (SDP4) perturbation theory, which this package does not implement.
    case deepSpaceUnsupported(periodMinutes: Double)
    /// Mean eccentricity fell outside [0, 1) during propagation.
    case invalidMeanEccentricity(Double)
    /// Semi-latus rectum went negative -- numerically degenerate orbit.
    case negativeSemiLatusRectum(Double)
    /// Satellite has decayed (below the surface of the reference ellipsoid).
    case decayed(mrt: Double)
    /// Kepler equation / perturbed eccentricity diverged out of range.
    case invalidPerturbedEccentricity(Double)
    /// Mean motion computed as non-positive.
    case invalidMeanMotion(Double)

    public var description: String {
        switch self {
        case .deepSpaceUnsupported(let p):
            return "TLE requires deep-space (SDP4) propagation (period \(p) min >= 225 min); not supported by this SGP4-only implementation."
        case .invalidMeanEccentricity(let e):
            return "mean eccentricity \(e) not within range 0.0 <= e < 1.0"
        case .negativeSemiLatusRectum(let pl):
            return "semilatus rectum \(pl) is less than zero"
        case .decayed(let mrt):
            return "mrt \(mrt) is less than 1.0 indicating the satellite has decayed"
        case .invalidPerturbedEccentricity(let e):
            return "perturbed eccentricity \(e) not within range 0.0 <= e <= 1.0"
        case .invalidMeanMotion(let n):
            return "mean motion \(n) is not positive"
        }
    }
}

/// WGS72 gravity-constant set, matching the constants used by the canonical
/// Vallado reference implementation (and the tcppver.out verification file).
public struct SGP4GravityConstants {
    public let mu: Double              // km^3/s^2
    public let radiusEarthKm: Double   // km
    public let xke: Double             // sqrt(GM) in earth-radii^1.5/min canonical units
    public let tumin: Double           // minutes per canonical time unit
    public let j2: Double
    public let j3: Double
    public let j4: Double
    public let j3oj2: Double

    public static let wgs72: SGP4GravityConstants = {
        let mu = 398600.8
        let radiusEarthKm = 6378.135
        let xke = 60.0 / (radiusEarthKm * radiusEarthKm * radiusEarthKm / mu).squareRoot()
        let tumin = 1.0 / xke
        let j2 = 0.001082616
        let j3 = -0.00000253881
        let j4 = -0.00000165597
        return SGP4GravityConstants(mu: mu, radiusEarthKm: radiusEarthKm, xke: xke, tumin: tumin,
                                     j2: j2, j3: j3, j4: j4, j3oj2: j3 / j2)
    }()
}

/// Initialized SGP4 propagator state for one satellite (near-Earth only).
public struct SGP4Propagator {
    let gravity: SGP4GravityConstants

    // Mean elements at epoch (radians / rad-per-minute).
    let bstar: Double
    let ecco: Double
    let argpo: Double
    let inclo: Double
    let mo: Double
    let noKozai: Double
    let nodeo: Double

    // Derived constants from initl().
    let noUnkozai: Double
    let ao: Double
    let con41: Double
    let con42: Double
    let cosio: Double
    let sinio: Double
    let eta: Double
    let isimp: Bool
    let cc1: Double
    let cc4: Double
    let cc5: Double
    let x1mth2: Double
    let mdot: Double
    let argpdot: Double
    let nodedot: Double
    let omgcof: Double
    let xmcof: Double
    let nodecf: Double
    let t2cof: Double
    let xlcof: Double
    let aycof: Double
    let delmo: Double
    let sinmao: Double
    let x7thm1: Double
    let d2: Double
    let d3: Double
    let d4: Double
    let t3cof: Double
    let t4cof: Double
    let t5cof: Double

    public let periodMinutes: Double

    /// Initialize the SGP4 propagator from a parsed TLE's mean elements.
    /// Throws `SGP4Error.deepSpaceUnsupported` if the orbital period requires
    /// deep-space (SDP4) theory (period >= 225 minutes).
    public init(tle: TLE, gravity: SGP4GravityConstants = .wgs72) throws {
        self.gravity = gravity
        let deg2rad = Double.pi / 180.0

        self.bstar = tle.bstar
        self.ecco = tle.eccentricity
        self.argpo = tle.argPerigeeDeg * deg2rad
        self.inclo = tle.inclinationDeg * deg2rad
        self.mo = tle.meanAnomalyDeg * deg2rad
        self.noKozai = tle.meanMotionRevPerDay * 2.0 * Double.pi / 1440.0
        self.nodeo = tle.raanDeg * deg2rad

        let x2o3 = 2.0 / 3.0
        let xke = gravity.xke
        let j2 = gravity.j2
        let j3oj2 = gravity.j3oj2
        let j4 = gravity.j4

        let eccsq = ecco * ecco
        let omeosq = 1.0 - eccsq
        let rteosq = omeosq.squareRoot()
        let cosioTmp = cos(inclo)
        let cosio2 = cosioTmp * cosioTmp

        let ak = pow(xke / noKozai, x2o3)
        let d1 = 0.75 * j2 * (3.0 * cosio2 - 1.0) / (rteosq * omeosq)
        var delPrime = d1 / (ak * ak)
        let adel = ak * (1.0 - delPrime * delPrime - delPrime * (1.0 / 3.0 + 134.0 * delPrime * delPrime / 81.0))
        delPrime = d1 / (adel * adel)
        let noUnkozai = noKozai / (1.0 + delPrime)

        let ao = pow(xke / noUnkozai, x2o3)
        let sinioTmp = sin(inclo)
        let po = ao * (1.0 - eccsq)
        let con42 = 1.0 - 5.0 * cosio2
        let con41 = -con42 - cosio2 - cosio2
        let posq = po * po
        let rp = ao * (1.0 - ecco)

        // Deep-space vs near-Earth split: standard SGP4 criterion.
        let period = 2.0 * Double.pi / noUnkozai
        self.periodMinutes = period
        if period >= 225.0 {
            throw SGP4Error.deepSpaceUnsupported(periodMinutes: period)
        }

        self.noUnkozai = noUnkozai
        self.ao = ao
        self.con41 = con41
        self.con42 = con42
        self.cosio = cosioTmp
        self.sinio = sinioTmp

        let isimp = rp < (220.0 / gravity.radiusEarthKm + 1.0)
        self.isimp = isimp

        let ss = 78.0 / gravity.radiusEarthKm + 1.0
        let qzms2t = pow((120.0 - 78.0) / gravity.radiusEarthKm, 4.0)
        var sfour = ss
        var qzms24 = qzms2t
        let perigeKm = (rp - 1.0) * gravity.radiusEarthKm

        if perigeKm < 156.0 {
            sfour = perigeKm - 78.0
            if perigeKm < 98.0 {
                sfour = 20.0
            }
            qzms24 = pow((120.0 - sfour) / gravity.radiusEarthKm, 4.0)
            sfour = sfour / gravity.radiusEarthKm + 1.0
        }

        let pinvsq = 1.0 / posq
        let tsi = 1.0 / (ao - sfour)
        let eta = ao * ecco * tsi
        self.eta = eta
        let etasq = eta * eta
        let eeta = ecco * eta
        let psisq = abs(1.0 - etasq)
        let coef = qzms24 * pow(tsi, 4.0)
        let coef1 = coef / pow(psisq, 3.5)
        let cc2 = coef1 * noUnkozai * (ao * (1.0 + 1.5 * etasq + eeta * (4.0 + etasq)) +
                    0.375 * j2 * tsi / psisq * con41 * (8.0 + 3.0 * etasq * (8.0 + etasq)))
        self.cc1 = bstar * cc2
        var cc3 = 0.0
        if ecco > 1.0e-4 {
            cc3 = -2.0 * coef * tsi * j3oj2 * noUnkozai * sinioTmp / ecco
        }
        let x1mth2 = 1.0 - cosio2
        self.x1mth2 = x1mth2
        self.cc4 = 2.0 * noUnkozai * coef1 * ao * omeosq * (eta * (2.0 + 0.5 * etasq) +
                    ecco * (0.5 + 2.0 * etasq) - j2 * tsi / (ao * psisq) *
                    (-3.0 * con41 * (1.0 - 2.0 * eeta + etasq * (1.5 - 0.5 * eeta)) +
                     0.75 * x1mth2 * (2.0 * etasq - eeta * (1.0 + etasq)) * cos(2.0 * argpo)))
        self.cc5 = 2.0 * coef1 * ao * omeosq * (1.0 + 2.75 * (etasq + eeta) + eeta * etasq)

        let cosio4 = cosio2 * cosio2
        let temp1 = 1.5 * j2 * pinvsq * noUnkozai
        let temp2 = 0.5 * temp1 * j2 * pinvsq
        let temp3 = -0.46875 * j4 * pinvsq * pinvsq * noUnkozai
        self.mdot = noUnkozai + 0.5 * temp1 * rteosq * con41 + 0.0625 * temp2 * rteosq * (13.0 - 78.0 * cosio2 + 137.0 * cosio4)
        self.argpdot = -0.5 * temp1 * con42 + 0.0625 * temp2 * (7.0 - 114.0 * cosio2 + 395.0 * cosio4) +
                        temp3 * (3.0 - 36.0 * cosio2 + 49.0 * cosio4)
        let xhdot1 = -temp1 * cosioTmp
        self.nodedot = xhdot1 + (0.5 * temp2 * (4.0 - 19.0 * cosio2) + 2.0 * temp3 * (3.0 - 7.0 * cosio2)) * cosioTmp

        self.omgcof = bstar * cc3 * cos(argpo)
        self.xmcof = ecco > 1.0e-4 ? (-x2o3 * coef * bstar / eeta) : 0.0
        self.nodecf = 3.5 * omeosq * xhdot1 * cc1
        self.t2cof = 1.5 * cc1

        let temp4 = 1.5e-12
        if abs(cosioTmp + 1.0) > 1.5e-12 {
            self.xlcof = -0.25 * j3oj2 * sinioTmp * (3.0 + 5.0 * cosioTmp) / (1.0 + cosioTmp)
        } else {
            self.xlcof = -0.25 * j3oj2 * sinioTmp * (3.0 + 5.0 * cosioTmp) / temp4
        }
        self.aycof = -0.5 * j3oj2 * sinioTmp

        let delmotemp = 1.0 + eta * cos(mo)
        self.delmo = delmotemp * delmotemp * delmotemp
        self.sinmao = sin(mo)
        self.x7thm1 = 7.0 * cosio2 - 1.0

        if !isimp {
            let cc1sq = cc1 * cc1
            let d2 = 4.0 * ao * tsi * cc1sq
            self.d2 = d2
            let temp = d2 * tsi * cc1 / 3.0
            let d3 = (17.0 * ao + sfour) * temp
            self.d3 = d3
            self.d4 = 0.5 * temp * ao * tsi * (221.0 * ao + 31.0 * sfour) * cc1
            self.t3cof = d2 + 2.0 * cc1sq
            self.t4cof = 0.25 * (3.0 * d3 + cc1 * (12.0 * d2 + 10.0 * cc1sq))
            self.t5cof = 0.2 * (3.0 * self.d4 + 12.0 * cc1 * d3 + 6.0 * d2 * d2 + 15.0 * cc1sq * (2.0 * d2 + cc1sq))
        } else {
            self.d2 = 0.0
            self.d3 = 0.0
            self.d4 = 0.0
            self.t3cof = 0.0
            self.t4cof = 0.0
            self.t5cof = 0.0
        }
    }

    /// Propagate to `tsince` minutes since the TLE epoch, returning TEME
    /// position (km) and velocity (km/s).
    public func propagate(minutesSinceEpoch tsince: Double) throws -> TEMEState {
        let x2o3 = 2.0 / 3.0
        let xke = gravity.xke
        let j2 = gravity.j2
        let radiusEarthKm = gravity.radiusEarthKm

        let xmdf = mo + mdot * tsince
        let argpdf = argpo + argpdot * tsince
        let nodedf = nodeo + nodedot * tsince
        var argpm = argpdf
        var mm = xmdf
        let t2 = tsince * tsince
        var nodem = nodedf + nodecf * t2
        var tempa = 1.0 - cc1 * tsince
        var tempe = bstar * cc4 * tsince
        var templ = t2cof * t2

        if !isimp {
            let delomg = omgcof * tsince
            let delmtemp = 1.0 + eta * cos(xmdf)
            let delm = xmcof * (delmtemp * delmtemp * delmtemp - delmo)
            let temp = delomg + delm
            mm = xmdf + temp
            argpm = argpdf - temp
            let t3 = t2 * tsince
            let t4 = t3 * tsince
            tempa = tempa - d2 * t2 - d3 * t3 - d4 * t4
            tempe = tempe + bstar * cc5 * (sin(mm) - sinmao)
            templ = templ + t3cof * t3 + t4 * (t4cof + tsince * t5cof)
        }

        let nm0 = noUnkozai
        var em = ecco

        if nm0 <= 0.0 {
            throw SGP4Error.invalidMeanMotion(nm0)
        }

        let am = pow(xke / nm0, x2o3) * tempa * tempa
        let nm = xke / pow(am, 1.5)
        em = em - tempe

        if em >= 1.0 || em < -0.001 {
            throw SGP4Error.invalidMeanEccentricity(em)
        }
        if em < 1.0e-6 { em = 1.0e-6 }

        mm = mm + nm0 * templ
        var xlm = mm + argpm + nodem
        let emsq = em * em

        let twopi = 2.0 * Double.pi
        nodem = nodem.truncatingRemainder(dividingBy: twopi)
        argpm = argpm.truncatingRemainder(dividingBy: twopi)
        xlm = xlm.truncatingRemainder(dividingBy: twopi)
        mm = (xlm - argpm - nodem).truncatingRemainder(dividingBy: twopi)

        // Solve Kepler's equation.
        let axnl = em * cos(argpm)
        let tempKepler = 1.0 / (am * (1.0 - emsq))
        let aynl = em * sin(argpm) + tempKepler * aycof
        let xl = mm + argpm + nodem + tempKepler * xlcof * axnl

        let u = (xl - nodem).truncatingRemainder(dividingBy: twopi)
        var eo1 = u
        var tem5 = 9999.9
        var ktr = 1
        var sineo1 = 0.0
        var coseo1 = 0.0
        while abs(tem5) >= 1.0e-12 && ktr <= 10 {
            sineo1 = sin(eo1)
            coseo1 = cos(eo1)
            tem5 = 1.0 - coseo1 * axnl - sineo1 * aynl
            tem5 = (u - aynl * coseo1 + axnl * sineo1 - eo1) / tem5
            if abs(tem5) >= 0.95 {
                tem5 = tem5 > 0 ? 0.95 : -0.95
            }
            eo1 = eo1 + tem5
            ktr += 1
        }

        // Short period preliminary quantities.
        let ecose = axnl * coseo1 + aynl * sineo1
        let esine = axnl * sineo1 - aynl * coseo1
        let el2 = axnl * axnl + aynl * aynl
        let pl = am * (1.0 - el2)
        if pl < 0.0 {
            throw SGP4Error.negativeSemiLatusRectum(pl)
        }

        let rl = am * (1.0 - ecose)
        let rdotl = am.squareRoot() * esine / rl
        let rvdotl = pl.squareRoot() / rl
        let betal = (1.0 - el2).squareRoot()
        let tempEl = esine / (1.0 + betal)
        let sinu = am / rl * (sineo1 - aynl - axnl * tempEl)
        let cosu = am / rl * (coseo1 - axnl + aynl * tempEl)
        var su = atan2(sinu, cosu)
        let sin2u = (cosu + cosu) * sinu
        let cos2u = 1.0 - 2.0 * sinu * sinu
        let temp = 1.0 / pl
        let temp1 = 0.5 * j2 * temp
        let temp2 = temp1 * temp

        let mrt = rl * (1.0 - 1.5 * temp2 * betal * con41) + 0.5 * temp1 * x1mth2 * cos2u
        su = su - 0.25 * temp2 * x7thm1 * sin2u
        let xnode = nodem + 1.5 * temp2 * cosio * sin2u
        let xinc = inclo + 1.5 * temp2 * cosio * sinio * cos2u
        // NOTE: inclm (used above for xinc) equals inclo for the near-Earth
        // branch since there is no secular inclination perturbation applied
        // outside of deep-space theory.
        let mvt = rdotl - nm * temp1 * x1mth2 * sin2u / xke
        let rvdot = rvdotl + nm * temp1 * (x1mth2 * sin2u + 1.5 * con41 * cos2u) / xke

        if mrt < 1.0 {
            throw SGP4Error.decayed(mrt: mrt)
        }

        let sinsu = sin(su)
        let cossu = cos(su)
        let snod = sin(xnode)
        let cnod = cos(xnode)
        let sini = sin(xinc)
        let cosi = cos(xinc)
        let xmx = -snod * cosi
        let xmy = cnod * cosi
        let ux = xmx * sinsu + cnod * cossu
        let uy = xmy * sinsu + snod * cossu
        let uz = sini * sinsu
        let vx = xmx * cossu - cnod * sinsu
        let vy = xmy * cossu - snod * sinsu
        let vz = sini * cossu

        let mr = mrt * radiusEarthKm
        let position = Vector3(mr * ux, mr * uy, mr * uz)
        let velFactor = radiusEarthKm * xke / 60.0
        let velocity = Vector3((mvt * ux + rvdot * vx) * velFactor,
                                (mvt * uy + rvdot * vy) * velFactor,
                                (mvt * uz + rvdot * vz) * velFactor)
        return TEMEState(position: position, velocity: velocity)
    }
}
