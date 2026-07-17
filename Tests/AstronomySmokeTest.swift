import Foundation

// Astronomy engine smoke test — validates Sources/Sky/Astronomy against reference values
// pulled from the US Naval Observatory Astronomical Applications API (aa.usno.navy.mil),
// JPL Horizons (ssd.jpl.nasa.gov), and sunrise-sunset.org, all fetched live on 2026-07-17.
// Run via the engine-test recipe (see Project Build Guide.md):
//   T=$(mktemp -d) && xattr -cr Sources && cp Tests/AstronomySmokeTest.swift "$T/main.swift" && \
//     swiftc -O Sources/Sky/Astronomy/*.swift "$T/main.swift" -o "$T/t" && "$T/t"; rm -rf "$T"

var totalChecks = 0
var passedChecks = 0

func checkMinutes(_ label: String, expected: Date, actual: Date?, toleranceMinutes: Double) {
    totalChecks += 1
    guard let actual else {
        print("FAIL  \(label): engine returned nil")
        return
    }
    let deltaMinutes = actual.timeIntervalSince(expected) / 60.0
    let ok = abs(deltaMinutes) <= toleranceMinutes
    if ok { passedChecks += 1 }
    let status = ok ? "PASS" : "FAIL"
    print("\(status)  \(label): expected \(iso(expected)), got \(iso(actual)) (Δ\(String(format: "%+.1f", deltaMinutes)) min, tolerance ±\(toleranceMinutes) min)")
}

func checkValue(_ label: String, expected: Double, actual: Double, tolerance: Double, unit: String = "") {
    totalChecks += 1
    let ok = abs(actual - expected) <= tolerance
    if ok { passedChecks += 1 }
    let status = ok ? "PASS" : "FAIL"
    print("\(status)  \(label): expected \(fmt(expected))\(unit), got \(fmt(actual))\(unit) (Δ\(String(format: "%+.3f", actual - expected))\(unit), tolerance ±\(tolerance)\(unit))")
}

func checkBool(_ label: String, expected: Bool, actual: Bool) {
    totalChecks += 1
    let ok = expected == actual
    if ok { passedChecks += 1 }
    print("\(ok ? "PASS" : "FAIL")  \(label): expected \(expected), got \(actual)")
}

func fmt(_ x: Double) -> String { String(format: "%.3f", x) }

let isoFormatter: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.timeZone = TimeZone(identifier: "UTC")
    return f
}()
func iso(_ d: Date) -> String { isoFormatter.string(from: d) }

/// Builds a `Date` from calendar components in a named IANA time zone.
func makeDate(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int, timeZoneID: String) -> Date {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: timeZoneID)!
    var c = DateComponents()
    c.year = year; c.month = month; c.day = day; c.hour = hour; c.minute = minute
    return cal.date(from: c)!
}

func makeUTCDate(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int) -> Date {
    makeDate(year, month, day, hour, minute, timeZoneID: "UTC")
}

// MARK: - Location: Tomah, WI

let tomahLat = 43.98
let tomahLonEast = -90.50 // this engine takes longitude positive-EAST; Tomah is 90.50°W
let chicago = TimeZone(identifier: "America/Chicago")!

print("================================================================")
print(" Clear Sky — Tonight's Sky astronomy engine smoke test")
print("================================================================\n")

// MARK: 1. Sun rise/set, Tomah WI, two dates (source: USNO aa.usno.navy.mil/api/rstt/oneday)

print("--- Sun rise/set (Tomah, WI 43.98N 90.50W) ---")

do {
    // 2026-01-15, USNO: rise 07:33 CST, set 16:50 CST.
    let dayStart = makeDate(2026, 1, 15, 0, 0, timeZoneID: "America/Chicago")
    let sun = SunMoon.sunTimes(after: dayStart, lat: tomahLat, lon: tomahLonEast)
    checkMinutes("Sunrise 2026-01-15 (USNO 07:33 CST)", expected: makeDate(2026, 1, 15, 7, 33, timeZoneID: "America/Chicago"), actual: sun.sunrise, toleranceMinutes: 5)
    checkMinutes("Sunset  2026-01-15 (USNO 16:50 CST)", expected: makeDate(2026, 1, 15, 16, 50, timeZoneID: "America/Chicago"), actual: sun.sunset, toleranceMinutes: 5)
}

do {
    // 2026-07-15, USNO: rise 05:33 CDT, set 20:42 CDT.
    let dayStart = makeDate(2026, 7, 15, 0, 0, timeZoneID: "America/Chicago")
    let sun = SunMoon.sunTimes(after: dayStart, lat: tomahLat, lon: tomahLonEast)
    checkMinutes("Sunrise 2026-07-15 (USNO 05:33 CDT)", expected: makeDate(2026, 7, 15, 5, 33, timeZoneID: "America/Chicago"), actual: sun.sunrise, toleranceMinutes: 5)
    checkMinutes("Sunset  2026-07-15 (USNO 20:42 CDT)", expected: makeDate(2026, 7, 15, 20, 42, timeZoneID: "America/Chicago"), actual: sun.sunset, toleranceMinutes: 5)
}

// MARK: 2. Twilight times, Tomah WI, one date
// Source: USNO for civil twilight; sunrise-sunset.org API for astronomical twilight
// (USNO's public rstt/oneday endpoint only reports civil twilight).

print("\n--- Twilight (Tomah, WI, 2026-01-15) ---")
do {
    let dayStart = makeDate(2026, 1, 15, 0, 0, timeZoneID: "America/Chicago")
    let sun = SunMoon.sunTimes(after: dayStart, lat: tomahLat, lon: tomahLonEast)
    // USNO: Begin Civil Twilight 07:01 CST, End Civil Twilight 17:22 CST.
    checkMinutes("Civil dawn 2026-01-15 (USNO 07:01 CST)", expected: makeDate(2026, 1, 15, 7, 1, timeZoneID: "America/Chicago"), actual: sun.civilDawn, toleranceMinutes: 5)
    checkMinutes("Civil dusk 2026-01-15 (USNO 17:22 CST)", expected: makeDate(2026, 1, 15, 17, 22, timeZoneID: "America/Chicago"), actual: sun.civilDusk, toleranceMinutes: 5)
    // sunrise-sunset.org (UTC): astronomical_twilight_begin 11:51:00Z = 05:51 CST;
    // astronomical_twilight_end 2026-01-16T00:31:58Z = 18:31:58 CST (previous evening).
    checkMinutes("Astronomical dawn 2026-01-15 (sunrise-sunset.org 05:51 CST)", expected: makeDate(2026, 1, 15, 5, 51, timeZoneID: "America/Chicago"), actual: sun.astronomicalDawn, toleranceMinutes: 5)
    checkMinutes("Astronomical dusk 2026-01-15 (sunrise-sunset.org 18:32 CST)", expected: makeDate(2026, 1, 15, 18, 32, timeZoneID: "America/Chicago"), actual: sun.astronomicalDusk, toleranceMinutes: 5)
}

// MARK: 3. Moon phase — known full moon and first quarter (source: USNO api/moon/phases/date)

print("\n--- Moon phase ---")
do {
    // Full Moon: 2026-01-03 10:03 UTC. At exact fullness, illumination ~100%, phase ~0.5.
    let fullMoonInstant = makeUTCDate(2026, 1, 3, 10, 3)
    let phase = SunMoon.moonPhase(date: fullMoonInstant)
    checkValue("Full moon 2026-01-03 10:03 UTC — illuminated %", expected: 100, actual: phase.illuminatedFraction * 100, tolerance: 1.0, unit: "%")
    checkValue("Full moon 2026-01-03 10:03 UTC — phase fraction", expected: 0.5, actual: phase.phaseFraction, tolerance: 0.02)
}
do {
    // First Quarter: 2026-01-26 04:47 UTC. At exact first quarter, illumination ~50%, phase ~0.25, waxing.
    let firstQuarterInstant = makeUTCDate(2026, 1, 26, 4, 47)
    let phase = SunMoon.moonPhase(date: firstQuarterInstant)
    checkValue("First quarter 2026-01-26 04:47 UTC — illuminated %", expected: 50, actual: phase.illuminatedFraction * 100, tolerance: 3.0, unit: "%")
    checkValue("First quarter 2026-01-26 04:47 UTC — phase fraction", expected: 0.25, actual: phase.phaseFraction, tolerance: 0.02)
    checkBool("First quarter 2026-01-26 — waxing", expected: true, actual: phase.waxing)
}

// MARK: 4. Planets — three checks against JPL Horizons ephemeris
// (ssd.jpl.nasa.gov/api/horizons.api, geodetic site 43.98N 90.50W 0.3km, airless apparent
// Azi/Elev + APmag, 5-minute steps, horizon crossing found by linear interpolation of the
// bracketing samples printed in the research notes below.)

print("\n--- Planets (Tomah, WI) ---")

do {
    // Venus, evening of 2026-07-20: Horizons shows Elev crossing zero (setting) between
    // 2026-07-21 03:30 UTC (+0.49°) and 03:35 UTC (-0.40°) => set ≈ 03:33 UTC = 22:33 CDT.
    // Azimuth at crossing ≈ 280.5° (due W, just shy of WNW). APmag ≈ -4.20.
    // USNO sunset 2026-07-20 = 20:38 CDT, so Venus sets roughly 1h55m after sunset.
    let dayStart = makeDate(2026, 7, 20, 0, 0, timeZoneID: "America/Chicago")
    let sky = SkyTonight.compute(date: dayStart, latitude: tomahLat, longitude: tomahLonEast, timeZone: chicago)
    guard let venus = sky.planets.first(where: { $0.body == .venus }) else {
        print("FAIL  Venus: not found in planet list"); totalChecks += 1
        fatalError("unreachable")
    }
    checkMinutes("Venus set, evening of 2026-07-20 (Horizons ≈22:33 CDT)", expected: makeDate(2026, 7, 20, 22, 33, timeZoneID: "America/Chicago"), actual: venus.set, toleranceMinutes: 10)
    if let mag = venus.apparentMagnitude {
        checkValue("Venus apparent magnitude near set (Horizons -4.20)", expected: -4.20, actual: mag, tolerance: 0.3)
    } else {
        print("FAIL  Venus magnitude: engine returned nil"); totalChecks += 1
    }
    if let setTime = venus.set {
        let eq = Planets.geocentric(.venus, date: setTime).equatorial
        let az = equatorialToHorizontal(eq, latitude: tomahLat, longitudeEast: tomahLonEast, jd: AstroTime.julianDay(setTime)).azimuth
        checkValue("Venus azimuth at set (Horizons ≈280.5°, W)", expected: 280.5, actual: az, tolerance: 5, unit: "°")
    }
}

do {
    // Jupiter, evening of 2026-07-05: Horizons shows Elev crossing zero (setting) between
    // 2026-07-06 02:40 UTC (+0.58°) and 02:45 UTC (-0.21°) => set ≈ 02:44 UTC = 21:44 CDT.
    // Azimuth at crossing ≈ 298.6° (WNW). APmag ≈ -1.80.
    //
    // Jupiter is 24 days from solar conjunction (2026-07-29) on this date, so per this
    // engine's twilight rule (full nautical darkness required for the outer three planets)
    // it correctly reports isVisibleTonight == false — real-world sources (earthsky.org)
    // independently describe Jupiter as "very low in the glow of dusk... dropping below the
    // horizon" this week, i.e. a twilight object for this particular apparition even though
    // it's nominally a superior planet. That's a product-level visibility judgment call, not
    // a physics error, so this check goes straight to the low-level Planets API (the same
    // rise/set solver and magnitude formula `SkyTonight` uses internally) rather than through
    // the high-level struct's visibility gate.
    let dayStart = makeDate(2026, 7, 5, 0, 0, timeZoneID: "America/Chicago")
    let setTime = RiseSetFinder.nextEvent(.set, after: dayStart, latitude: tomahLat, longitudeEast: tomahLonEast, standardAltitude: SunMoon.StandardAltitude.starsAndPlanets) { t in
        Planets.geocentric(.jupiter, date: t).equatorial
    }
    checkMinutes("Jupiter set, evening of 2026-07-05 (Horizons ≈21:44 CDT)", expected: makeDate(2026, 7, 5, 21, 44, timeZoneID: "America/Chicago"), actual: setTime, toleranceMinutes: 10)
    if let setTime {
        let (_, r, delta) = Planets.geocentric(.jupiter, date: setTime)
        let T = AstroTime.julianCenturies(jd: AstroTime.julianDay(setTime))
        let (_, sunEarthDistance) = SunMoon.sunGeometric(T: T)
        let phaseAngle = Planets.phaseAngle(r: r, delta: delta, sunEarthDistance: sunEarthDistance)
        let mag = Planets.apparentMagnitude(.jupiter, r: r, delta: delta, phaseAngleDegrees: phaseAngle)
        checkValue("Jupiter apparent magnitude near set (Horizons -1.80)", expected: -1.80, actual: mag, tolerance: 0.3)
        let eq = Planets.geocentric(.jupiter, date: setTime).equatorial
        let az = equatorialToHorizontal(eq, latitude: tomahLat, longitudeEast: tomahLonEast, jd: AstroTime.julianDay(setTime)).azimuth
        checkValue("Jupiter azimuth at set (Horizons ≈298.6°, WNW)", expected: 298.6, actual: az, tolerance: 5, unit: "°")
    } else {
        print("FAIL  Jupiter magnitude: engine returned nil set time"); totalChecks += 1
    }
}

do {
    // Saturn, night of 2026-07-14/15: Horizons shows Elev crossing zero (rising) between
    // 2026-07-15 05:10 UTC (-0.68°) and 05:15 UTC (+0.22°) => rise ≈ 05:14 UTC = 00:14 CDT.
    // Azimuth at crossing ≈ 84.9° (E, just shy of ENE). APmag ≈ +0.71.
    let dayStart = makeDate(2026, 7, 14, 0, 0, timeZoneID: "America/Chicago")
    let sky = SkyTonight.compute(date: dayStart, latitude: tomahLat, longitude: tomahLonEast, timeZone: chicago)
    guard let saturn = sky.planets.first(where: { $0.body == .saturn }) else {
        print("FAIL  Saturn: not found in planet list"); totalChecks += 1
        fatalError("unreachable")
    }
    checkMinutes("Saturn rise, night of 2026-07-14/15 (Horizons ≈00:14 CDT Jul 15)", expected: makeDate(2026, 7, 15, 0, 14, timeZoneID: "America/Chicago"), actual: saturn.rise, toleranceMinutes: 10)
    if let mag = saturn.apparentMagnitude {
        checkValue("Saturn apparent magnitude near rise (Horizons +0.71, ring-tilt term included)", expected: 0.71, actual: mag, tolerance: 0.3)
    } else {
        print("FAIL  Saturn magnitude: engine returned nil"); totalChecks += 1
    }
    if let riseTime = saturn.rise {
        let eq = Planets.geocentric(.saturn, date: riseTime).equatorial
        let az = equatorialToHorizontal(eq, latitude: tomahLat, longitudeEast: tomahLonEast, jd: AstroTime.julianDay(riseTime)).azimuth
        checkValue("Saturn azimuth at rise (Horizons ≈84.9°, E)", expected: 84.9, actual: az, tolerance: 5, unit: "°")
    }
}

// MARK: - Summary

print("\n================================================================")
print(" Summary: \(passedChecks)/\(totalChecks) checks passed")
print("================================================================")

if passedChecks == totalChecks {
    print(" ALL CHECKS PASSED")
} else {
    print(" \(totalChecks - passedChecks) CHECK(S) FAILED — see FAIL lines above")
}
