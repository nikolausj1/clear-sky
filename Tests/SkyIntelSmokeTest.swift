import Foundation

// Sky intelligence smoke test — MeteorShowers, Conjunctions, BestMoment
// (Sources/Sky/Astronomy/{MeteorShowers,Conjunctions,BestMoment}.swift).
//
// Build/run per the Build Guide engine-test recipe (compiled together with ISS + Aurora since
// BestMoment consumes ISSPass/AuroraOutlook):
//   T=$(mktemp -d) && xattr -cr Sources && cp Tests/SkyIntelSmokeTest.swift "$T/main.swift" && \
//     swiftc -O Sources/Sky/Astronomy/*.swift Sources/Sky/ISS/*.swift Sources/Sky/Aurora/*.swift \
//       "$T/main.swift" -o "$T/t" && "$T/t"; rm -rf "$T"
//
// Reference values for the meteor section were fetched live on 2026-07-17 from EarthSky,
// Weather.com, NASA's "Watch the Skies" blog, and Space.com (see inline citations). The
// conjunction reference value is from in-the-sky.org's published 2026-11-30 Moon-Jupiter
// conjunction bulletin.

var totalChecks = 0
var passedChecks = 0

func check(_ label: String, _ condition: @autoclosure () -> Bool, _ detail: @autoclosure () -> String = "") {
    totalChecks += 1
    let ok = condition()
    if ok { passedChecks += 1 }
    let d = detail()
    print("\(ok ? "PASS" : "FAIL")  \(label)" + (d.isEmpty ? "" : " -- \(d)"))
}

func checkClose(_ label: String, _ actual: Double, _ expected: Double, tolerance: Double, unit: String = "") {
    check(label, abs(actual - expected) <= tolerance,
          "expected \(expected)\(unit) ± \(tolerance)\(unit), got \(actual)\(unit)")
}

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

let isoFormatter: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.timeZone = TimeZone(identifier: "UTC")
    return f
}()
func iso(_ d: Date) -> String { isoFormatter.string(from: d) }

// MARK: - Location: Tomah, WI (consistent with the other Sky smoke tests)

let tomahLat = 43.98
let tomahLonEast = -90.50
let chicago = TimeZone(identifier: "America/Chicago")!

print("================================================================")
print(" Clear Sky — Sky intelligence smoke test")
print("================================================================\n")

// ================================================================
// SECTION 1: Meteor showers + Moon washout
// ================================================================

print("--- Meteor showers: active/peak detection ---")

var perseids2026Estimate: Double = 0

do {
    // Perseids 2026: peak night Aug 12-13, 2026 -- new moon (0% illuminated) per EarthSky /
    // Weather.com, moon sets before 9pm and doesn't rise again until after sunrise Aug 13.
    // Source: https://earthsky.org/astronomy-essentials/everything-you-need-to-know-perseid-meteor-shower/
    //         https://weather.com/2026/07/16/science/space/perseid-meteor-shower-2026-perfect-new-moon-to-create-ideal-conditions-for-peak
    let night = makeDate(2026, 8, 12, 0, 0, timeZoneID: "America/Chicago")
    guard let active = MeteorShowers.activeShower(on: night, timeZone: chicago) else {
        check("Perseids 2026-08-12 detected as active", false); fatalError("unreachable")
    }
    check("Perseids 2026-08-12 detected as active shower", active.shower.name == "Perseids", "got \(active.shower.name)")
    check("Perseids 2026-08-12 is peak night", active.isPeakNight)

    // Independent check of the underlying moon-phase engine against the published ~0%.
    let primeStart = makeDate(2026, 8, 13, 0, 0, timeZoneID: "America/Chicago") // local midnight -> prime window start
    let phase = SunMoon.moonPhase(date: primeStart)
    checkClose("Perseids 2026 moon illumination agrees with published ~0% (new moon)", phase.illuminatedFraction * 100, 0, tolerance: 10, unit: "%")

    guard let outlook = MeteorShowers.outlook(on: night, latitude: tomahLat, longitude: tomahLonEast, timeZone: chicago) else {
        check("Perseids 2026 outlook computed", false); fatalError("unreachable")
    }
    check("Perseids 2026 outlook: isPeakNight", outlook.isPeakNight)
    check("Perseids 2026 outlook: moon essentially down all prime window (new moon)", outlook.moonUpFraction < 0.2, "got \(outlook.moonUpFraction)")
    check("Perseids 2026 outlook: moonInterference is .none (new moon, moon down)", { if case .none = outlook.moonInterference { return true }; return false }(), "got \(outlook.moonInterference)")
    check("Perseids 2026 outlook: estimatedVisiblePerHour is a healthy fraction of ZHR (>= 40/hr of ZHR 100)", outlook.estimatedVisiblePerHour >= 40, "got \(outlook.estimatedVisiblePerHour)")
    perseids2026Estimate = outlook.estimatedVisiblePerHour
}

do {
    // Geminids 2026: peak Dec 13-14, 2026 (05:44 UTC Dec 14) -- waxing crescent moon, ~25%
    // illuminated, sets around 10pm local, well before the post-midnight prime window.
    // Source: https://earthsky.org/astronomy-essentials/everything-you-need-to-know-geminid-meteor-shower/
    let night = makeDate(2026, 12, 13, 0, 0, timeZoneID: "America/Chicago")
    guard let active = MeteorShowers.activeShower(on: night, timeZone: chicago) else {
        check("Geminids 2026-12-13 detected as active", false); fatalError("unreachable")
    }
    check("Geminids 2026-12-13 detected as active shower", active.shower.name == "Geminids", "got \(active.shower.name)")
    check("Geminids 2026-12-13 is peak night", active.isPeakNight)

    guard let outlook = MeteorShowers.outlook(on: night, latitude: tomahLat, longitude: tomahLonEast, timeZone: chicago) else {
        check("Geminids 2026 outlook computed", false); fatalError("unreachable")
    }
    checkClose("Geminids 2026 moon illumination agrees with published ~25% waxing crescent", outlook.moonIlluminatedPercent, 25, tolerance: 20, unit: "%")
    check("Geminids 2026 outlook: moon down for essentially the whole prime window (sets ~10pm, before midnight)", outlook.moonUpFraction < 0.15, "got \(outlook.moonUpFraction)")
    check("Geminids 2026 outlook: moonInterference is .none despite 25% illumination, because the moon is down", { if case .none = outlook.moonInterference { return true }; return false }(), "got \(outlook.moonInterference)")
    check("Geminids 2026 outlook: estimatedVisiblePerHour is a healthy fraction of ZHR (>= 45/hr of ZHR 120)", outlook.estimatedVisiblePerHour >= 45, "got \(outlook.estimatedVisiblePerHour)")
}

do {
    // Contrast case: Perseids 2025 -- bright (~80-89%) waning gibbous moon, rising a few hours
    // before midnight and staying up the rest of the night, per NASA "Watch the Skies" and
    // Space.com. This should show clearly *worse* washout than Perseids 2026's new-moon night.
    // Source: https://www.nasa.gov/blogs/watch-the-skies/2025/08/08/bright-moonlight-could-interfere-with-view-of-perseids-peak/
    //         https://www.space.com/stargazing/meteor-showers/will-the-bright-moon-ruin-the-perseid-meteor-shower-2025-or-is-it-still-worth-watching
    let night = makeDate(2025, 8, 12, 0, 0, timeZoneID: "America/Chicago")
    guard let active = MeteorShowers.activeShower(on: night, timeZone: chicago) else {
        check("Perseids 2025-08-12 detected as active", false); fatalError("unreachable")
    }
    check("Perseids 2025-08-12 detected as active shower and peak night", active.shower.name == "Perseids" && active.isPeakNight)

    guard let outlook = MeteorShowers.outlook(on: night, latitude: tomahLat, longitude: tomahLonEast, timeZone: chicago) else {
        check("Perseids 2025 outlook computed", false); fatalError("unreachable")
    }
    checkClose("Perseids 2025 moon illumination agrees with published ~80-89% waning gibbous", outlook.moonIlluminatedPercent, 84, tolerance: 15, unit: "%")
    check("Perseids 2025 outlook: moon up for essentially the whole prime window (rose before midnight)", outlook.moonUpFraction > 0.85, "got \(outlook.moonUpFraction)")
    check("Perseids 2025 outlook: moonInterference is .severe (bright moon up all night)", { if case .severe = outlook.moonInterference { return true }; return false }(), "got \(outlook.moonInterference)")
    check(
        "Washout logic moves the right direction: 2025 bright-moon estimate is well below 2026 new-moon estimate",
        outlook.estimatedVisiblePerHour < perseids2026Estimate * 0.7,
        "2025 estimate=\(outlook.estimatedVisiblePerHour), 2026 estimate=\(perseids2026Estimate)"
    )
    // Sanity vs. the widely-quoted "10-20/hour" field estimate for 2025 (loose tolerance; this
    // heuristic is explicitly documented as order-of-magnitude, not precise).
    check("Perseids 2025 estimate is in the right ballpark of the widely-quoted ~10-20/hr", outlook.estimatedVisiblePerHour >= 8 && outlook.estimatedVisiblePerHour <= 35, "got \(outlook.estimatedVisiblePerHour)")
}

// ================================================================
// SECTION 2: Conjunctions
// ================================================================

print("\n--- Conjunctions ---")

do {
    // Published: Moon-Jupiter conjunction, 2026-11-30 09:15 UTC, separation 1°09' (1.15°),
    // both in Leo, pre-dawn visibility. Source: in-the-sky.org
    // https://in-the-sky.org/news.php?id=20261130_20_100
    let publishedInstant = makeUTCDate(2026, 11, 30, 9, 15)
    let separation = Conjunctions.separationDegrees(.moon, .planet(.jupiter), at: publishedInstant)
    checkClose("Moon-Jupiter separation at published 2026-11-30 09:15 UTC instant matches in-the-sky.org's 1°09'", separation, 1.15, tolerance: 1.5, unit: "°")

    // Same conjunction, detected via the night-level API. 09:15 UTC on Nov 30 is 03:15 CST --
    // early pre-dawn morning of the "night of Nov 29/30" -- so query with date = Nov 29.
    let night = makeDate(2026, 11, 29, 0, 0, timeZoneID: "America/Chicago")
    let pairings = Conjunctions.closePairings(on: night, latitude: tomahLat, longitude: tomahLonEast, timeZone: chicago)
    let moonJupiter = pairings.first { ($0.bodyA == .moon && $0.bodyB == .planet(.jupiter)) || ($0.bodyA == .planet(.jupiter) && $0.bodyB == .moon) }
    func describe(_ p: Conjunctions.Pairing) -> String {
        "\(p.bodyA.displayName)-\(p.bodyB.displayName): \(String(format: "%.2f", p.separationDegrees))°"
    }
    check(
        "Moon-Jupiter pairing detected on the right night (2026-11-29/30) for Tomah, WI",
        moonJupiter != nil,
        "pairings found: \(pairings.map(describe))"
    )
    if let pairing = moonJupiter {
        check("Moon-Jupiter pairing separation is under the 5° Moon-planet threshold", pairing.separationDegrees < Conjunctions.moonPlanetThresholdDegrees, "got \(pairing.separationDegrees)")
        check("Moon-Jupiter pairing best-viewing altitude clears the 10° visibility bar", pairing.altitudeAtBest >= 10, "got \(pairing.altitudeAtBest)")
    }
}

do {
    // Sanity: planet-planet threshold is tighter than Moon-planet, and a trivially "self" pair
    // never shows up (no body paired with itself).
    check("Moon-planet threshold (5°) is looser than planet-planet threshold (3°)", Conjunctions.moonPlanetThresholdDegrees > Conjunctions.planetPlanetThresholdDegrees)
    let night = makeDate(2026, 6, 17, 0, 0, timeZoneID: "America/Chicago")
    let pairings = Conjunctions.closePairings(on: night, latitude: tomahLat, longitude: tomahLonEast, timeZone: chicago)
    check("No pairing lists the same body against itself", pairings.allSatisfy { $0.bodyA != $0.bodyB })
}

// ================================================================
// SECTION 3: BestMoment
// ================================================================

print("\n--- BestMoment ---")

// A minimal but valid TonightSky to build synthetic scenarios on top of.
func emptySky(moonRise: Date? = nil, moonIlluminated: Double = 50, planets: [SkyTonight.PlanetVisibility] = []) -> SkyTonight.TonightSky {
    SkyTonight.TonightSky(
        sun: SkyTonight.SunInfo(sunrise: nil, sunset: nil, civilDawn: nil, civilDusk: makeDate(2026, 6, 1, 21, 0, timeZoneID: "America/Chicago"), astronomicalDawn: nil, astronomicalDusk: nil),
        moon: SkyTonight.MoonInfo(rise: moonRise, set: nil, phaseFraction: 0, illuminatedPercent: moonIlluminated, waxing: true),
        planets: planets
    )
}

func planet(_ body: Planets.Body, visible: Bool, magnitude: Double?, bestStart: Date? = nil) -> SkyTonight.PlanetVisibility {
    SkyTonight.PlanetVisibility(
        body: body, isVisibleTonight: visible, rise: nil, set: nil,
        bestViewingStart: bestStart, bestViewingEnd: bestStart?.addingTimeInterval(3600),
        bestAltitude: visible ? 45 : nil, bestAzimuth: visible ? 180 : nil,
        directionDescription: visible ? "high in the S" : nil,
        apparentMagnitude: magnitude
    )
}

let referenceMeteor = MeteorShowers.all.first { $0.name == "Perseids" }!
let refWindowStart = makeDate(2026, 8, 13, 1, 0, timeZoneID: "America/Chicago")
let refWindowEnd = refWindowStart.addingTimeInterval(3 * 3600)

func makeISSPass(brightness: ISSBrightness = .bright, peakAltitude: Double = 60) -> ISSPass {
    let start = makeDate(2026, 6, 1, 22, 0, timeZoneID: "America/Chicago")
    return ISSPass(
        startTime: start, peakTime: start.addingTimeInterval(180), endTime: start.addingTimeInterval(360),
        peakAltitudeDeg: peakAltitude, startAzimuthDeg: 270, endAzimuthDeg: 90,
        startAzimuthCompass: "W", endAzimuthCompass: "E", peakRangeKm: 500, brightness: brightness
    )
}

func makeAuroraOutlook(band: AuroraBand) -> AuroraOutlook {
    let window = DateInterval(start: makeDate(2026, 6, 1, 23, 0, timeZoneID: "America/Chicago"), duration: 3 * 3600)
    return AuroraOutlook(
        chanceNow: 40, tonightPeakKp: 6, tonightPeakKpWindow: window, bestViewingWindow: window,
        band: band, geomagneticLatitude: 53, visibilityLatitudeThreshold: 55
    )
}

func makeMeteorOutlook(estimatedVisiblePerHour: Double, isPeakNight: Bool = true) -> MeteorShowers.MeteorOutlook {
    MeteorShowers.MeteorOutlook(
        shower: referenceMeteor, isPeakNight: isPeakNight, daysFromPeak: 0,
        theoreticalZHR: referenceMeteor.zhr, estimatedVisiblePerHour: estimatedVisiblePerHour,
        moonInterference: .none, bestWindow: DateInterval(start: refWindowStart, end: refWindowEnd),
        moonIlluminatedPercent: 0, moonUpFraction: 0
    )
}

func makePairing() -> Conjunctions.Pairing {
    Conjunctions.Pairing(
        bodyA: .planet(.venus), bodyB: .moon, separationDegrees: 2.0,
        bestViewingTime: makeDate(2026, 6, 1, 21, 30, timeZoneID: "America/Chicago"),
        altitudeAtBest: 20, azimuthAtBest: 270, directionDescription: "low in the W"
    )
}

// Scenario 1: ISS pass beats an aurora .fair outlook.
do {
    let data = BestMoment.TonightData(
        sky: emptySky(),
        issPasses: [makeISSPass(brightness: .bright)],
        auroraOutlook: makeAuroraOutlook(band: .fair)
    )
    let moment = BestMoment.bestMoment(tonight: data)
    check("Scenario 1: ISS pass beats aurora .fair", {
        if case .issPass = moment?.kind { return true }; return false
    }(), "got \(String(describing: moment?.kind))")
}

// Scenario 2: aurora .fair beats a peak-night meteor shower with a strong rate (no ISS pass).
do {
    let data = BestMoment.TonightData(
        sky: emptySky(),
        auroraOutlook: makeAuroraOutlook(band: .fair),
        meteorOutlook: makeMeteorOutlook(estimatedVisiblePerHour: 50)
    )
    let moment = BestMoment.bestMoment(tonight: data)
    check("Scenario 2: aurora .fair beats a strong meteor shower", {
        if case .auroraWindow = moment?.kind { return true }; return false
    }(), "got \(String(describing: moment?.kind))")
}

// Scenario 3: a peak-night meteor shower whose washed-out rate falls below the headline
// threshold loses to a bright visible planet's window.
do {
    let venus = planet(.venus, visible: true, magnitude: -4.2, bestStart: makeDate(2026, 6, 1, 21, 15, timeZoneID: "America/Chicago"))
    let data = BestMoment.TonightData(
        sky: emptySky(planets: [venus]),
        meteorOutlook: makeMeteorOutlook(estimatedVisiblePerHour: 4) // below the 10/hr headline bar
    )
    let moment = BestMoment.bestMoment(tonight: data)
    check("Scenario 3: washed-out meteor shower (4/hr) loses to bright-planet window", {
        if case .brightPlanet(let p) = moment?.kind { return p.body == .venus }; return false
    }(), "got \(String(describing: moment?.kind))")
}

// Scenario 4: a peak-night meteor shower that clears the headline bar wins over a visible planet.
do {
    let venus = planet(.venus, visible: true, magnitude: -4.2)
    let data = BestMoment.TonightData(
        sky: emptySky(planets: [venus]),
        meteorOutlook: makeMeteorOutlook(estimatedVisiblePerHour: 40)
    )
    let moment = BestMoment.bestMoment(tonight: data)
    check("Scenario 4: meteor shower clearing the headline bar (40/hr) beats a visible planet", {
        if case .meteorShower(let m) = moment?.kind { return m.shower.name == "Perseids" }; return false
    }(), "got \(String(describing: moment?.kind))")
}

// Scenario 5: a close conjunction wins over a visible planet when nothing higher-priority exists.
do {
    let venus = planet(.venus, visible: true, magnitude: -4.2)
    let data = BestMoment.TonightData(sky: emptySky(planets: [venus]), pairings: [makePairing()])
    let moment = BestMoment.bestMoment(tonight: data)
    check("Scenario 5: close conjunction beats a visible planet", {
        if case .conjunction = moment?.kind { return true }; return false
    }(), "got \(String(describing: moment?.kind))")
}

// Scenario 6: with nothing else, the brightest of several visible planets wins (lower magnitude).
do {
    let venus = planet(.venus, visible: true, magnitude: -4.2)
    let mars = planet(.mars, visible: true, magnitude: -0.5)
    let saturn = planet(.saturn, visible: true, magnitude: 0.8)
    let data = BestMoment.TonightData(sky: emptySky(planets: [mars, saturn, venus]))
    let moment = BestMoment.bestMoment(tonight: data)
    check("Scenario 6: brightest visible planet (Venus, mag -4.2) wins among several", {
        if case .brightPlanet(let p) = moment?.kind { return p.body == .venus }; return false
    }(), "got \(String(describing: moment?.kind))")
}

// Scenario 7: nothing else at all -- fall back to a full-moon rise.
do {
    let rise = makeDate(2026, 6, 1, 20, 30, timeZoneID: "America/Chicago")
    let data = BestMoment.TonightData(sky: emptySky(moonRise: rise, moonIlluminated: 99))
    let moment = BestMoment.bestMoment(tonight: data)
    check("Scenario 7: falls back to full-moon rise when nothing else qualifies", {
        if case .moonRise(let kind, _, _) = moment?.kind { return kind == .fullMoon }; return false
    }(), "got \(String(describing: moment?.kind))")
}

// Scenario 8: truly nothing qualifies -- no forced fallback, returns nil.
do {
    let data = BestMoment.TonightData(sky: emptySky(moonRise: nil, moonIlluminated: 50))
    let moment = BestMoment.bestMoment(tonight: data)
    check("Scenario 8: no qualifying moment at all returns nil (no forced fallback)", moment == nil, "got \(String(describing: moment))")
}

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
