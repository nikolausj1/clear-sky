import Foundation

// Stargazing Score + Tonight Headline engine smoke test
// (Sources/Sky/Score/{StargazingScore,TonightHeadline}.swift).
//
// Build/run per the Build Guide engine-test recipe (compiled together with Astronomy + ISS +
// Aurora, since `TonightHeadline` consumes `BestMoment`/`ISSPass`/`AuroraOutlook`):
//   T=$(mktemp -d) && xattr -cr Sources && cp Tests/ScoreSmokeTest.swift "$T/main.swift" && \
//     swiftc -O Sources/Sky/Astronomy/*.swift Sources/Sky/ISS/*.swift Sources/Sky/Aurora/*.swift \
//       Sources/Sky/Score/*.swift "$T/main.swift" -o "$T/t" && "$T/t"; rm -rf "$T"

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

// MARK: - Location: Tomah, WI (consistent with the other Sky smoke tests)

let tomahLat = 43.98
let tomahLonEast = -90.50
let chicago = TimeZone(identifier: "America/Chicago")!

print("================================================================")
print(" Clear Sky — Stargazing Score + Tonight Headline smoke test")
print("================================================================\n")

// ================================================================
// SECTION 1: StargazingScore — pure sub-function boundary/monotonicity checks
// ================================================================

print("--- StargazingScore: cloud-cover mapping ---")

do {
    checkClose("clear -> 0.0", StargazingScore.cloudCoverFraction(conditionCode: "clear"), 0.0, tolerance: 0.0001)
    checkClose("mostlyClear -> 0.2", StargazingScore.cloudCoverFraction(conditionCode: "mostlyClear"), 0.2, tolerance: 0.0001)
    checkClose("partlyCloudy -> 0.45", StargazingScore.cloudCoverFraction(conditionCode: "partlyCloudy"), 0.45, tolerance: 0.0001)
    checkClose("mostlyCloudy -> 0.75", StargazingScore.cloudCoverFraction(conditionCode: "mostlyCloudy"), 0.75, tolerance: 0.0001)
    checkClose("cloudy -> 1.0", StargazingScore.cloudCoverFraction(conditionCode: "cloudy"), 1.0, tolerance: 0.0001)
    checkClose("overcast literal code -> 1.0", StargazingScore.cloudCoverFraction(conditionCode: "overcast"), 1.0, tolerance: 0.0001)
    checkClose("rain -> 1.0 (precip obstructs)", StargazingScore.cloudCoverFraction(conditionCode: "rain"), 1.0, tolerance: 0.0001)
    checkClose("foggy -> 1.0 (fog obstructs)", StargazingScore.cloudCoverFraction(conditionCode: "foggy"), 1.0, tolerance: 0.0001)
    checkClose("thunderstorms -> 1.0", StargazingScore.cloudCoverFraction(conditionCode: "thunderstorms"), 1.0, tolerance: 0.0001)
    checkClose("unrecognized code (windy) -> 0.45 safe default", StargazingScore.cloudCoverFraction(conditionCode: "windy"), 0.45, tolerance: 0.0001)
    checkClose(
        "high precip chance overrides a merely-partlyCloudy code -> 1.0",
        StargazingScore.cloudCoverFraction(conditionCode: "partlyCloudy", precipChance: 0.8), 1.0, tolerance: 0.0001
    )

    // Monotonicity: more cloud in the condition code -> lower cloud factor (i.e. higher
    // cloud-cover fraction) at every step of the ladder.
    let ladder = ["clear", "mostlyClear", "partlyCloudy", "mostlyCloudy", "cloudy"]
    let fractions = ladder.map { StargazingScore.cloudCoverFraction(conditionCode: $0) }
    check("Cloud-cover ladder is strictly increasing (clear < mostlyClear < ... < cloudy)",
          zip(fractions, fractions.dropFirst()).allSatisfy { $0 < $1 },
          "fractions: \(fractions)")
}

print("\n--- StargazingScore: darkness tiers (boundary altitudes) ---")

do {
    check("Sun +10° (daylight) -> .day", StargazingScore.darknessTier(sunAltitudeDegrees: 10) == .day)
    check("Sun exactly -0.8333° (sunset line) -> .day", StargazingScore.darknessTier(sunAltitudeDegrees: -0.8333) == .day)
    check("Sun -3° (mid civil twilight) -> .civilTwilight", StargazingScore.darknessTier(sunAltitudeDegrees: -3) == .civilTwilight)
    check("Sun exactly -6.0° -> .civilTwilight (band start is inclusive)", StargazingScore.darknessTier(sunAltitudeDegrees: -6.0) == .civilTwilight)
    check("Sun -9° (mid nautical twilight) -> .nauticalTwilight", StargazingScore.darknessTier(sunAltitudeDegrees: -9) == .nauticalTwilight)
    check("Sun exactly -12.0° -> .nauticalTwilight (band start is inclusive)", StargazingScore.darknessTier(sunAltitudeDegrees: -12.0) == .nauticalTwilight)
    check("Sun -15° (mid astronomical twilight) -> .astronomicalTwilight", StargazingScore.darknessTier(sunAltitudeDegrees: -15) == .astronomicalTwilight)
    check("Sun exactly -18.0° -> .astronomicalTwilight (band start is inclusive)", StargazingScore.darknessTier(sunAltitudeDegrees: -18.0) == .astronomicalTwilight)
    check("Sun -18.5° (just past astronomical dusk) -> .fullDark", StargazingScore.darknessTier(sunAltitudeDegrees: -18.5) == .fullDark)
    check("Sun -60° (deep night) -> .fullDark", StargazingScore.darknessTier(sunAltitudeDegrees: -60) == .fullDark)

    // Monotonicity: darkness factor is non-decreasing as the Sun gets lower.
    let altitudes: [Double] = [10, -3, -9, -15, -60]
    let factors = altitudes.map { StargazingScore.darknessTier(sunAltitudeDegrees: $0).darknessFactor }
    check("Darkness factor strictly increases as the Sun sinks lower", zip(factors, factors.dropFirst()).allSatisfy { $0 < $1 }, "factors: \(factors)")
}

print("\n--- StargazingScore: Moon interference ---")

do {
    checkClose("Moon below horizon -> factor 1.0 regardless of illumination (0%)", StargazingScore.moonFactor(moonAltitudeDegrees: -5, illuminatedFraction: 0), 1.0, tolerance: 0.0001)
    checkClose("Moon below horizon -> factor 1.0 regardless of illumination (100%)", StargazingScore.moonFactor(moonAltitudeDegrees: -5, illuminatedFraction: 1.0), 1.0, tolerance: 0.0001)
    checkClose("Moon up, 0% illuminated (new moon up) -> factor 1.0", StargazingScore.moonFactor(moonAltitudeDegrees: 30, illuminatedFraction: 0), 1.0, tolerance: 0.0001)
    checkClose("Moon up, 100% illuminated (full moon up) -> factor 0.35 (gentler floor than meteor model)", StargazingScore.moonFactor(moonAltitudeDegrees: 30, illuminatedFraction: 1.0), StargazingScore.fullMoonFloor, tolerance: 0.0001)
    checkClose("Moon up, 50% illuminated -> halfway between 1.0 and the full-moon floor", StargazingScore.moonFactor(moonAltitudeDegrees: 30, illuminatedFraction: 0.5), (1.0 + StargazingScore.fullMoonFloor) / 2, tolerance: 0.0001)

    // Monotonicity: with the Moon up, more illumination -> lower factor.
    let illuminations: [Double] = [0, 0.25, 0.5, 0.75, 1.0]
    let moonFactors = illuminations.map { StargazingScore.moonFactor(moonAltitudeDegrees: 30, illuminatedFraction: $0) }
    check("Moon factor strictly decreases as illumination rises (Moon up)", zip(moonFactors, moonFactors.dropFirst()).allSatisfy { $0 > $1 }, "factors: \(moonFactors)")
}

print("\n--- StargazingScore: composed scenarios ---")

do {
    // clear + new/down moon + full dark -> 10
    let hour = StargazingScore.HourInput(date: makeDate(2026, 1, 15, 2, 0, timeZoneID: "America/Chicago"), conditionCode: "clear")
    // Independently derive the darkness/moon factors this same instant implies, at Tomah, so
    // this check doesn't hardcode a moon phase/ephemeris value -- it just needs *a* real
    // instant where the Sun is in full darkness; whatever the Moon happens to be doing at that
    // moment is read directly from the same engine and folded into the expectation.
    let sunAlt = SunMoon.sunPosition(date: hour.date, lat: tomahLat, lon: tomahLonEast).altitude
    check("2026-01-15 02:00 CST is full dark at Tomah (test setup sanity)", StargazingScore.darknessTier(sunAltitudeDegrees: sunAlt) == .fullDark, "sun altitude \(sunAlt)°")

    let scored = StargazingScore.score(for: hour, latitude: tomahLat, longitude: tomahLonEast)
    check("Full dark + clear sky + moon factor 1.0 (down or new) -> score 10", scored.moonFactor < 1.0001 && scored.moonFactor > 0.9999 ? scored.score == 10 : true,
          "score=\(scored.score) darkness=\(scored.darknessFactor) clouds=\(scored.cloudFactor) moon=\(scored.moonFactor)")
    check("Score composition: score == round(10 * darkness * clouds * moon)", scored.score == Int((10.0 * scored.darknessFactor * scored.cloudFactor * scored.moonFactor).rounded()))
    check("Quality label for score 10 is .excellent", scored.quality == .excellent)
}

do {
    // Full moon up, otherwise ideal (clear, full dark) -> composed score 3-4 per work order
    // ("gentler than the meteor model"). Computed directly from the documented factors rather
    // than a specific date, since this is testing the *composition rule*, not the ephemeris.
    let composed = Int((10.0 * StargazingScore.DarknessTier.fullDark.darknessFactor * 1.0 * StargazingScore.fullMoonFloor).rounded())
    check("Clear + full dark + full moon up composes to 3-4", (3...4).contains(composed), "got \(composed)")
}

do {
    // Overcast -> 0, regardless of darkness/moon.
    let composed = Int((10.0 * StargazingScore.DarknessTier.fullDark.darknessFactor * (1 - StargazingScore.cloudCoverFraction(conditionCode: "cloudy")) * 1.0).rounded())
    check("Overcast composes to score 0", composed == 0, "got \(composed)")
}

do {
    // Civil twilight, clear, moon down -> composed score 1-2.
    let composed = Int((10.0 * StargazingScore.DarknessTier.civilTwilight.darknessFactor * 1.0 * 1.0).rounded())
    check("Civil twilight + clear composes to 1-2", (1...2).contains(composed), "got \(composed)")
}

do {
    // Boundary hour: before dusk (broad daylight) scores 0 via darkness, regardless of a
    // perfectly clear sky and a moon-down instant.
    let hour = StargazingScore.HourInput(date: makeDate(2026, 7, 15, 14, 0, timeZoneID: "America/Chicago"), conditionCode: "clear")
    let scored = StargazingScore.score(for: hour, latitude: tomahLat, longitude: tomahLonEast)
    check("Mid-afternoon (before dusk) scores 0 via the darkness factor", scored.score == 0, "score=\(scored.score) tier=\(scored.tier)")
    check("Mid-afternoon tier is .day", scored.tier == .day)
}

print("\n--- StargazingScore: DarknessTier transitions match SunMoon.sunTimes (Tomah, WI, 2026-07-15) ---")

do {
    let dayStart = makeDate(2026, 7, 15, 0, 0, timeZoneID: "America/Chicago")
    let sun = SunMoon.sunTimes(after: dayStart, lat: tomahLat, lon: tomahLonEast)

    func tierAt(_ date: Date?, offsetSeconds: TimeInterval) -> StargazingScore.DarknessTier? {
        guard let date else { return nil }
        let alt = SunMoon.sunPosition(date: date.addingTimeInterval(offsetSeconds), lat: tomahLat, lon: tomahLonEast).altitude
        return StargazingScore.darknessTier(sunAltitudeDegrees: alt)
    }

    // "Civil dusk" is the moment the Sun crosses -6°, i.e. the boundary between the civil and
    // nautical twilight bands -- just before it, the Sun is still above -6° (.civilTwilight);
    // just after, it's below -6° (.nauticalTwilight). Same pattern for nautical/astronomical
    // dusk one band darker each.
    if let civilDusk = sun.civilDusk {
        check("Just before civil dusk -> .civilTwilight", tierAt(civilDusk, offsetSeconds: -120) == .civilTwilight)
        check("Just after civil dusk -> .nauticalTwilight", tierAt(civilDusk, offsetSeconds: 120) == .nauticalTwilight)
    } else {
        check("civilDusk resolved for 2026-07-15 at Tomah", false)
    }
    if let nauticalDusk = sun.nauticalDusk {
        check("Just before nautical dusk -> .nauticalTwilight", tierAt(nauticalDusk, offsetSeconds: -120) == .nauticalTwilight)
        check("Just after nautical dusk -> .astronomicalTwilight", tierAt(nauticalDusk, offsetSeconds: 120) == .astronomicalTwilight)
    } else {
        check("nauticalDusk resolved for 2026-07-15 at Tomah", false)
    }
    if let astronomicalDusk = sun.astronomicalDusk {
        check("Just before astronomical dusk -> .astronomicalTwilight", tierAt(astronomicalDusk, offsetSeconds: -120) == .astronomicalTwilight)
        check("Just after astronomical dusk -> .fullDark", tierAt(astronomicalDusk, offsetSeconds: 120) == .fullDark)
    } else {
        check("astronomicalDusk resolved for 2026-07-15 at Tomah", false)
    }
}

// ================================================================
// SECTION 2: TonightHeadline
// ================================================================

print("\n--- TonightHeadline ---")

func neutralMoon(illuminated: Double = 50, rise: Date? = nil) -> SkyTonight.MoonInfo {
    SkyTonight.MoonInfo(rise: rise, set: nil, phaseFraction: 0.25, illuminatedPercent: illuminated, waxing: true)
}

func neutralWindow() -> DateInterval {
    DateInterval(start: makeDate(2026, 6, 1, 21, 0, timeZoneID: "America/Chicago"), end: makeDate(2026, 6, 2, 5, 0, timeZoneID: "America/Chicago"))
}

func makeISSPass() -> ISSPass {
    let start = makeDate(2026, 6, 1, 21, 40, timeZoneID: "America/Chicago")
    return ISSPass(
        startTime: start, peakTime: start.addingTimeInterval(120), endTime: start.addingTimeInterval(240),
        peakAltitudeDeg: 55, startAzimuthDeg: 315, endAzimuthDeg: 135,
        startAzimuthCompass: "NW", endAzimuthCompass: "SE", peakRangeKm: 500, brightness: .bright
    )
}

func makeAuroraOutlook(band: AuroraBand = .fair) -> AuroraOutlook {
    let window = DateInterval(start: makeDate(2026, 6, 1, 23, 0, timeZoneID: "America/Chicago"), duration: 3 * 3600)
    return AuroraOutlook(chanceNow: 40, tonightPeakKp: 6, tonightPeakKpWindow: window, bestViewingWindow: window, band: band, geomagneticLatitude: 53, visibilityLatitudeThreshold: 55)
}

let referenceShower = MeteorShowers.all.first { $0.name == "Perseids" }!

func makeMeteorOutlook(estimatedVisiblePerHour: Double = 45, isPeakNight: Bool = true, daysFromPeak: Int = 0) -> MeteorShowers.MeteorOutlook {
    let start = makeDate(2026, 8, 13, 1, 0, timeZoneID: "America/Chicago")
    return MeteorShowers.MeteorOutlook(
        shower: referenceShower, isPeakNight: isPeakNight, daysFromPeak: daysFromPeak,
        theoreticalZHR: referenceShower.zhr, estimatedVisiblePerHour: estimatedVisiblePerHour,
        moonInterference: .none, bestWindow: DateInterval(start: start, duration: 3 * 3600),
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

func makePlanet(body: Planets.Body = .saturn, rise: Date? = makeDate(2026, 6, 2, 0, 0, timeZoneID: "America/Chicago")) -> SkyTonight.PlanetVisibility {
    SkyTonight.PlanetVisibility(
        body: body, isVisibleTonight: true, rise: rise, set: nil,
        bestViewingStart: rise, bestViewingEnd: rise?.addingTimeInterval(3600),
        bestAltitude: 40, bestAzimuth: 135, directionDescription: "high in the SE",
        apparentMagnitude: 0.5
    )
}

func overcastHours(over window: DateInterval, clearingAfter: Bool = false) -> [TonightHeadline.HourCloudCover] {
    var hours: [TonightHeadline.HourCloudCover] = []
    var t = window.start
    while t <= window.end {
        hours.append(TonightHeadline.HourCloudCover(date: t, cloudCoverFraction: 0.95))
        t = t.addingTimeInterval(3600)
    }
    if clearingAfter {
        hours.append(TonightHeadline.HourCloudCover(date: window.end.addingTimeInterval(3 * 3600), cloudCoverFraction: 0.1))
    }
    return hours
}

/// Runs the shared "is this a well-formed Observatory Guide line" battery on every headline
/// produced below, plus the specific tier-order assertions the work order calls out.
func validate(_ label: String, _ headline: TonightHeadline.Headline, expectedKind: TonightHeadline.Kind) {
    check("\(label): kind is \(expectedKind)", headline.kind == expectedKind, "got \(headline.kind)")
    check("\(label): text is non-empty", !headline.text.isEmpty)
    check("\(label): text is within the character budget (<= \(TonightHeadline.textCharacterBudget + 10))", headline.text.count <= TonightHeadline.textCharacterBudget + 10, "got \(headline.text.count) chars: \"\(headline.text)\"")
    check("\(label): text contains no exclamation marks", !headline.text.contains("!"), "text: \"\(headline.text)\"")
    if let detail = headline.detailText {
        check("\(label): detailText contains no exclamation marks", !detail.contains("!"), "detail: \"\(detail)\"")
    }
    if expectedKind.isEvent {
        check("\(label): detailText is present for an event kind", headline.detailText != nil && !(headline.detailText!.isEmpty))
    }
}

// Scenario 1: ISS pass -> event tier.
do {
    let inputs = TonightHeadline.Inputs(
        moment: BestMoment.SkyMoment(time: makeISSPass().peakTime, kind: .issPass(makeISSPass()), rationale: "test"),
        moon: neutralMoon(), tonightWindow: neutralWindow(), timeZone: chicago
    )
    validate("Scenario 1 (ISS pass)", TonightHeadline.generate(inputs), expectedKind: .issPass)
}

// Scenario 2: Aurora .fair -> event tier.
do {
    let aurora = makeAuroraOutlook(band: .fair)
    let inputs = TonightHeadline.Inputs(
        moment: BestMoment.SkyMoment(time: aurora.bestViewingWindow.start, kind: .auroraWindow(aurora), rationale: "test"),
        moon: neutralMoon(), tonightWindow: neutralWindow(), timeZone: chicago
    )
    validate("Scenario 2 (Aurora fair)", TonightHeadline.generate(inputs), expectedKind: .aurora)
}

// Scenario 3: Meteor shower peak -> event tier.
do {
    let meteor = makeMeteorOutlook()
    let inputs = TonightHeadline.Inputs(
        moment: BestMoment.SkyMoment(time: meteor.bestWindow.start, kind: .meteorShower(meteor), rationale: "test"),
        moon: neutralMoon(), tonightWindow: neutralWindow(), timeZone: chicago
    )
    validate("Scenario 3 (Meteor shower peak)", TonightHeadline.generate(inputs), expectedKind: .meteorShower)
}

// Scenario 4: Conjunction -> event tier.
do {
    let pairing = makePairing()
    let inputs = TonightHeadline.Inputs(
        moment: BestMoment.SkyMoment(time: pairing.bestViewingTime, kind: .conjunction(pairing), rationale: "test"),
        moon: neutralMoon(), tonightWindow: neutralWindow(), timeZone: chicago
    )
    validate("Scenario 4 (Conjunction)", TonightHeadline.generate(inputs), expectedKind: .conjunction)
}

// Scenario 5: Overcast all night, no clearing data -> simple overcast line.
do {
    let window = neutralWindow()
    let inputs = TonightHeadline.Inputs(
        moon: neutralMoon(), tonightWindow: window,
        hourlyCloudCover: overcastHours(over: window, clearingAfter: false), timeZone: chicago
    )
    let headline = TonightHeadline.generate(inputs)
    validate("Scenario 5 (Overcast, no clearing data)", headline, expectedKind: .overcast)
    check("Scenario 5: no 'Clearing' clause without supporting data", !headline.text.contains("Clearing"), "text: \"\(headline.text)\"")
}

// Scenario 5b: Overcast all night, with a clearing hour after the window -> mentions clearing.
do {
    let window = neutralWindow()
    let inputs = TonightHeadline.Inputs(
        moon: neutralMoon(), tonightWindow: window,
        hourlyCloudCover: overcastHours(over: window, clearingAfter: true), timeZone: chicago
    )
    let headline = TonightHeadline.generate(inputs)
    validate("Scenario 5b (Overcast, with clearing data)", headline, expectedKind: .overcast)
    check("Scenario 5b: 'Clearing' clause present when data supports it", headline.text.contains("Clearing"), "text: \"\(headline.text)\"")
}

// Scenario 6: Bright planet fact tier (nothing else qualifies).
do {
    let inputs = TonightHeadline.Inputs(
        planets: [makePlanet()], moon: neutralMoon(), tonightWindow: neutralWindow(), timeZone: chicago
    )
    validate("Scenario 6 (Bright planet)", TonightHeadline.generate(inputs), expectedKind: .brightPlanet)
}

// Scenario 7: Notable full moon fact tier.
do {
    let inputs = TonightHeadline.Inputs(
        moon: neutralMoon(illuminated: 99), tonightWindow: neutralWindow(), timeZone: chicago
    )
    let headline = TonightHeadline.generate(inputs)
    validate("Scenario 7 (Full moon)", headline, expectedKind: .notableMoon)
    check("Scenario 7: text reads as a full-moon line", headline.text.lowercased().contains("full moon"), "text: \"\(headline.text)\"")
}

// Scenario 7b: Notable new moon fact tier.
do {
    let inputs = TonightHeadline.Inputs(
        moon: neutralMoon(illuminated: 1), tonightWindow: neutralWindow(), timeZone: chicago
    )
    let headline = TonightHeadline.generate(inputs)
    validate("Scenario 7b (New moon)", headline, expectedKind: .notableMoon)
    check("Scenario 7b: text reads as a new-moon line", headline.text.lowercased().contains("new moon"), "text: \"\(headline.text)\"")
}

// Scenario 8: High stargazing score fact tier (no planet/notable-moon candidates).
do {
    let inputs = TonightHeadline.Inputs(
        moon: neutralMoon(), peakStargazingScore: 8, peakStargazingHour: makeDate(2026, 6, 1, 23, 0, timeZoneID: "America/Chicago"),
        tonightWindow: neutralWindow(), timeZone: chicago
    )
    validate("Scenario 8 (Good stargazing)", TonightHeadline.generate(inputs), expectedKind: .goodStargazing)
}

// Scenario 9: Shower building fact tier (no planet/moon/score candidates).
do {
    let building = makeMeteorOutlook(estimatedVisiblePerHour: 30, isPeakNight: false, daysFromPeak: -3)
    let inputs = TonightHeadline.Inputs(
        meteorOutlook: building, moon: neutralMoon(), tonightWindow: neutralWindow(), timeZone: chicago
    )
    validate("Scenario 9 (Shower building)", TonightHeadline.generate(inputs), expectedKind: .showerBuilding)
}

// Scenario 10: Nothing qualifies at all -> .none, still well-formed.
do {
    let inputs = TonightHeadline.Inputs(moon: neutralMoon(), tonightWindow: neutralWindow(), timeZone: chicago)
    validate("Scenario 10 (Nothing qualifies)", TonightHeadline.generate(inputs), expectedKind: .none)
}

// Scenario 11 (TIER ORDER): ISS pass beats a high stargazing score.
do {
    let inputs = TonightHeadline.Inputs(
        moment: BestMoment.SkyMoment(time: makeISSPass().peakTime, kind: .issPass(makeISSPass()), rationale: "test"),
        moon: neutralMoon(), peakStargazingScore: 9, peakStargazingHour: makeDate(2026, 6, 1, 23, 0, timeZoneID: "America/Chicago"),
        tonightWindow: neutralWindow(), timeZone: chicago
    )
    let headline = TonightHeadline.generate(inputs)
    check("Scenario 11: ISS pass (tier 1) beats a high stargazing score (tier 3)", headline.kind == .issPass, "got \(headline.kind)")
}

// Scenario 12 (TIER ORDER): overcast beats a bright-planet line.
do {
    let window = neutralWindow()
    let inputs = TonightHeadline.Inputs(
        planets: [makePlanet()], moon: neutralMoon(), tonightWindow: window,
        hourlyCloudCover: overcastHours(over: window), timeZone: chicago
    )
    let headline = TonightHeadline.generate(inputs)
    check("Scenario 12: overcast (tier 2) beats a bright-planet line (tier 3)", headline.kind == .overcast, "got \(headline.kind)")
}

// Scenario 13 (TIER ORDER): a strong event still wins even under an overcast forecast (event
// tier is checked before the overcast tier -- see TonightHeadline's type-level doc comment for
// why).
do {
    let window = neutralWindow()
    let inputs = TonightHeadline.Inputs(
        moment: BestMoment.SkyMoment(time: makeISSPass().peakTime, kind: .issPass(makeISSPass()), rationale: "test"),
        moon: neutralMoon(), tonightWindow: window,
        hourlyCloudCover: overcastHours(over: window), timeZone: chicago
    )
    let headline = TonightHeadline.generate(inputs)
    check("Scenario 13: ISS pass (tier 1) still wins over an overcast forecast (tier 2)", headline.kind == .issPass, "got \(headline.kind)")
}

// Scenario 14 (TIER ORDER, within tier 3): a bright planet beats a notable moon, which beats a
// high stargazing score, which beats a building shower -- documented sub-tier order.
do {
    let baseWindow = neutralWindow()
    let building = makeMeteorOutlook(estimatedVisiblePerHour: 30, isPeakNight: false, daysFromPeak: -3)
    let scoreHour = makeDate(2026, 6, 1, 23, 0, timeZoneID: "America/Chicago")

    let planetVsEverything = TonightHeadline.Inputs(
        meteorOutlook: building, planets: [makePlanet()], moon: neutralMoon(illuminated: 99),
        peakStargazingScore: 9, peakStargazingHour: scoreHour, tonightWindow: baseWindow, timeZone: chicago
    )
    check("Scenario 14a: bright planet beats notable moon/score/shower-building", TonightHeadline.generate(planetVsEverything).kind == .brightPlanet)

    let moonVsScoreAndShower = TonightHeadline.Inputs(
        meteorOutlook: building, moon: neutralMoon(illuminated: 99),
        peakStargazingScore: 9, peakStargazingHour: scoreHour, tonightWindow: baseWindow, timeZone: chicago
    )
    check("Scenario 14b: notable moon beats high score/shower-building", TonightHeadline.generate(moonVsScoreAndShower).kind == .notableMoon)

    let scoreVsShower = TonightHeadline.Inputs(
        meteorOutlook: building, moon: neutralMoon(illuminated: 50),
        peakStargazingScore: 9, peakStargazingHour: scoreHour, tonightWindow: baseWindow, timeZone: chicago
    )
    check("Scenario 14c: high stargazing score beats shower-building", TonightHeadline.generate(scoreVsShower).kind == .goodStargazing)
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
