import Foundation

// Smoke test for Sources/Sky/Spots/*.swift. Build Guide engine-test recipe:
//   T=$(mktemp -d) && xattr -cr Sources && cp Tests/SpotsSmokeTest.swift "$T/main.swift" && \
//     swiftc -O Sources/Sky/Astronomy/*.swift Sources/Sky/Aurora/*.swift Sources/Sky/Score/*.swift \
//       Sources/Sky/Almanac/*.swift Sources/Sky/Launches/*.swift Sources/Sky/Spots/*.swift \
//       "$T/main.swift" -o "$T/t" && "$T/t"; rm -rf "$T"
//
// Five parts, no networking at all (mirrors `Tests/LightPollutionSmokeTest.swift`'s pattern of
// loading the real bundled JSON straight off disk rather than through `Bundle.main`, which isn't
// meaningful for a bare `swiftc`-compiled binary):
//  1. Atlas: loads the real `skyspots.json` off disk, decodes it, and checks shape (count,
//     category counts, valid coordinates, non-empty blurbs, launch sites carry match keys).
//  2. Launch matching: canned `UpcomingLaunch` fixtures against `SkySpots.launchSiteNext`.
//  3. Aurora: the "flattering math" assertion -- Fairbanks vs. Miami at the same synthetic Kp.
//  4. Dark-sky moon notes: scans real Moon-phase output (no hardcoded almanac dates) to find a
//     genuine near-new and near-full night, then checks the honest note text on each.
//  5. Saved-city ranking: synthetic 3-city forecasts -> ordering + limiting factors.
//
// Every check prints PASS or FAIL; the process exits non-zero if anything failed.

var passCount = 0
var failCount = 0

func check(_ name: String, _ condition: @autoclosure () -> Bool, _ detail: @autoclosure () -> String = "") {
    if condition() {
        passCount += 1
        print("PASS: \(name)")
    } else {
        failCount += 1
        let d = detail()
        print("FAIL: \(name)" + (d.isEmpty ? "" : " -- \(d)"))
    }
}

func iso(_ s: String) -> Date {
    guard let d = ISO8601DateFormatter().date(from: s) else {
        fatalError("bad ISO8601 fixture date: \(s)")
    }
    return d
}

var utcCalendar = Calendar(identifier: .gregorian)
utcCalendar.timeZone = TimeZone(identifier: "UTC")!
let utc = TimeZone(identifier: "UTC")!

print("================================================================")
print(" Clear Sky -- Sky Spots smoke test")
print("================================================================\n")

// MARK: - Part 1: the real bundled atlas

print("--- Atlas: skyspots.json ---")

let spots: [SkySpot]
do {
    let url = URL(fileURLWithPath: "Sources/Sky/Spots/skyspots.json")
    let data = try Data(contentsOf: url)
    spots = try SkySpotsAtlas.decode(data: data)
    check("skyspots.json loads and decodes", true)
} catch {
    check("skyspots.json loads and decodes", false, "\(error)")
    spots = []
}

check("at least 24 spots", spots.count >= 24, "got \(spots.count)")

let launchSites = spots.filter { $0.category == .launchSite }
let auroraSpots = spots.filter { $0.category == .auroraSpot }
let darkSkySpots = spots.filter { $0.category == .darkSky }
check("launchSite count is 8", launchSites.count == 8, "got \(launchSites.count)")
check("auroraSpot count is 8", auroraSpots.count == 8, "got \(auroraSpots.count)")
check("darkSky count is 10", darkSkySpots.count == 10, "got \(darkSkySpots.count)")

let allValidCoords = spots.allSatisfy { $0.latitude >= -90 && $0.latitude <= 90 && $0.longitude >= -180 && $0.longitude <= 180 }
check("all spots have valid lat/lon ranges", allValidCoords)

let allHaveBlurbs = spots.allSatisfy { !$0.blurb.trimmingCharacters(in: .whitespaces).isEmpty }
check("all spots have non-empty blurbs", allHaveBlurbs)

let allHaveNames = spots.allSatisfy { !$0.name.trimmingCharacters(in: .whitespaces).isEmpty }
check("all spots have non-empty names", allHaveNames)

let uniqueIDs = Set(spots.map(\.id))
check("all spot IDs are unique", uniqueIDs.count == spots.count, "got \(uniqueIDs.count) unique of \(spots.count)")

let allLaunchSitesHaveKeys = launchSites.allSatisfy { !$0.matchKeys.isEmpty }
check("every launchSite spot has at least one matchKey", allLaunchSitesHaveKeys)

let noNonLaunchSiteHasKeys = (auroraSpots + darkSkySpots).allSatisfy { $0.matchKeys.isEmpty }
check("no auroraSpot/darkSky entry carries matchKeys", noNonLaunchSiteHasKeys)

// MARK: - Part 2: launch matching

print("\n--- Launch matching ---")

func makeUpcomingLaunch(id: String, padName: String, rawLocationName: String, net: Date) -> UpcomingLaunch {
    UpcomingLaunch(
        id: id,
        missionName: "Test Mission",
        provider: "Test Provider",
        providerAbbrev: "Test",
        vehicle: "Test Vehicle",
        padName: padName,
        locationDisplay: LaunchSchedule.locationDisplay(fromLocationName: rawLocationName),
        net: net,
        netPrecision: .exact,
        status: .go,
        isCrewed: false,
        webcastLive: false,
        imageURL: nil,
        missionDescription: nil
    )
}

guard let capeSpot = spots.first(where: { $0.id == "cape-canaveral" }) else {
    fatalError("fixture assumption broken: cape-canaveral spot missing from atlas")
}
guard let starbaseSpot = spots.first(where: { $0.id == "starbase" }) else {
    fatalError("fixture assumption broken: starbase spot missing from atlas")
}
guard let baikonurSpot = spots.first(where: { $0.id == "baikonur" }) else {
    fatalError("fixture assumption broken: baikonur spot missing from atlas")
}

let capeLaunchEarly = makeUpcomingLaunch(
    id: "1", padName: "SLC-40", rawLocationName: "Cape Canaveral SFS, FL, USA", net: iso("2026-08-01T00:00:00Z")
)
let capeLaunchLate = makeUpcomingLaunch(
    id: "2", padName: "LC-39A", rawLocationName: "Kennedy Space Center, FL, USA", net: iso("2026-08-15T00:00:00Z")
)
let starbaseLaunch = makeUpcomingLaunch(
    id: "3", padName: "Pad A", rawLocationName: "SpaceX Starbase, TX, USA", net: iso("2026-08-05T00:00:00Z")
)
let jiuquanLaunch = makeUpcomingLaunch(
    id: "4", padName: "SLS-2", rawLocationName: "Jiuquan Satellite Launch Center, People's Republic of China",
    net: iso("2026-08-03T00:00:00Z")
)

check(
    "Cape Canaveral spot matches a 'Cape Canaveral SFS, FL, USA' pad",
    SkySpots.launchSiteNext(spot: capeSpot, launches: [capeLaunchEarly])?.id == "1"
)
check(
    "Cape Canaveral spot matches earliest of two matching launches",
    SkySpots.launchSiteNext(spot: capeSpot, launches: [capeLaunchLate, capeLaunchEarly])?.id == "1"
)
check(
    "Starbase spot matches a 'SpaceX Starbase, TX, USA' pad",
    SkySpots.launchSiteNext(spot: starbaseSpot, launches: [starbaseLaunch])?.id == "3"
)
check(
    "Cape Canaveral spot does NOT match a Jiuquan pad",
    SkySpots.launchSiteNext(spot: capeSpot, launches: [jiuquanLaunch]) == nil
)
check(
    "Baikonur spot does NOT match a Jiuquan pad (no false cross-matches)",
    SkySpots.launchSiteNext(spot: baikonurSpot, launches: [jiuquanLaunch]) == nil
)
check(
    "Baikonur spot with no launches at all -> nil",
    SkySpots.launchSiteNext(spot: baikonurSpot, launches: []) == nil
)
check(
    "Starbase spot does NOT match a Cape Canaveral pad",
    SkySpots.launchSiteNext(spot: starbaseSpot, launches: [capeLaunchEarly]) == nil
)

// MARK: - Part 3: aurora "flattering math" assertion

print("\n--- Aurora spots ---")

func makeZeroGrid() -> AuroraLikelihood.IndexedGrid {
    let table = Array(repeating: Array(repeating: 0, count: 181), count: 360)
    return AuroraLikelihood.IndexedGrid(probabilityTable: table)
}

let zeroGrid = makeZeroGrid()
let auroraNightStart = iso("2026-01-15T02:00:00Z")
let auroraNightEnd = iso("2026-01-15T10:00:00Z")
let kp3Forecast = [
    KpForecastRow(timeTag: "2026-01-15T00:00:00", kp: 3.0, observed: "predicted", noaaScale: nil),
    KpForecastRow(timeTag: "2026-01-15T03:00:00", kp: 3.0, observed: "predicted", noaaScale: nil),
    KpForecastRow(timeTag: "2026-01-15T06:00:00", kp: 3.0, observed: "predicted", noaaScale: nil),
    KpForecastRow(timeTag: "2026-01-15T09:00:00", kp: 3.0, observed: "predicted", noaaScale: nil),
]

guard let fairbanksSpot = spots.first(where: { $0.id == "fairbanks" }) else {
    fatalError("fixture assumption broken: fairbanks spot missing from atlas")
}
let miamiSpot = SkySpot(
    id: "miami-test-fixture", name: "Miami (test fixture)", category: .auroraSpot,
    blurb: "Not a real atlas entry -- a synthetic low-latitude contrast case for the smoke test.",
    latitude: 25.7617, longitude: -80.1918
)

let fairbanksOutlook = SkySpots.auroraSpotOutlook(
    spot: fairbanksSpot, grid: zeroGrid, kpForecast: kp3Forecast,
    darkHoursStart: auroraNightStart, darkHoursEnd: auroraNightEnd
)
let miamiOutlook = SkySpots.auroraSpotOutlook(
    spot: miamiSpot, grid: zeroGrid, kpForecast: kp3Forecast,
    darkHoursStart: auroraNightStart, darkHoursEnd: auroraNightEnd
)

check(
    "Fairbanks geomagnetic latitude is ~64+ N",
    fairbanksOutlook.geomagneticLatitude >= 64.0,
    "got \(fairbanksOutlook.geomagneticLatitude)"
)
check(
    "Fairbanks at synthetic Kp 3 reads at least .fair",
    fairbanksOutlook.band >= .fair,
    "got \(fairbanksOutlook.band)"
)
check(
    "Miami at the same synthetic Kp 3 reads .none",
    miamiOutlook.band == .none,
    "got \(miamiOutlook.band)"
)
check(
    "Fairbanks reads a meaningfully higher band than Miami at identical Kp (the flattering-math point)",
    fairbanksOutlook.band > miamiOutlook.band
)

// MARK: - Part 4: dark-sky moon notes (scans real Moon-phase output, no hardcoded almanac dates)

print("\n--- Dark-sky moon notes ---")

guard let cherrySpringsSpot = spots.first(where: { $0.id == "cherry-springs" }) else {
    fatalError("fixture assumption broken: cherry-springs spot missing from atlas")
}

// Scan noon-UTC instants over ~90 days for the real min/max illuminated-fraction days, so this
// test exercises actual Moon geometry rather than a hardcoded (and error-prone) almanac date.
var scanDates: [(date: Date, illum: Double)] = []
var scanDay = iso("2026-01-01T12:00:00Z")
for _ in 0..<90 {
    let illum = SunMoon.moonPhase(date: scanDay).illuminatedFraction
    scanDates.append((scanDay, illum))
    scanDay = utcCalendar.date(byAdding: .day, value: 1, to: scanDay)!
}
let ascendingByIllum = scanDates.sorted { $0.illum < $1.illum }
let descendingByIllum = scanDates.sorted { $0.illum > $1.illum }

var newMoonResult: SkySpots.DarkSkyTonight?
for candidate in ascendingByIllum.prefix(10) {
    let result = SkySpots.darkSkyTonight(spot: cherrySpringsSpot, date: candidate.date)
    if result.moonIlluminationPct <= SkySpots.newMoonIlluminationThreshold {
        newMoonResult = result
        break
    }
}
check("found a near-new-moon night within the 90-day scan", newMoonResult != nil)
if let newMoonResult {
    check(
        "near-new-moon night gets the 'prime conditions' note",
        newMoonResult.note == "New moon week — prime conditions",
        "got '\(newMoonResult.note)' at \(newMoonResult.moonIlluminationPct)% illuminated"
    )
}

var fullMoonResult: SkySpots.DarkSkyTonight?
for candidate in descendingByIllum.prefix(10) {
    let result = SkySpots.darkSkyTonight(spot: cherrySpringsSpot, date: candidate.date)
    if result.moonIlluminationPct >= SkySpots.fullMoonIlluminationThreshold && result.moonUpDuringDarkHours {
        fullMoonResult = result
        break
    }
}
check("found a near-full-moon (up during dark hours) night within the 90-day scan", fullMoonResult != nil)
if let fullMoonResult {
    check(
        "near-full-moon night (Moon up) gets the 'bright skies even here' note",
        fullMoonResult.note == "Full moon tonight — bright skies even here",
        "got '\(fullMoonResult.note)' at \(fullMoonResult.moonIlluminationPct)% illuminated, up=\(fullMoonResult.moonUpDuringDarkHours)"
    )
}

// A mid-illumination day should get neither extreme's exact note.
if let midCandidate = scanDates.first(where: { $0.illum > 0.35 && $0.illum < 0.65 }) {
    let midResult = SkySpots.darkSkyTonight(spot: cherrySpringsSpot, date: midCandidate.date)
    check(
        "a ~50%-illuminated night gets neither extreme note",
        midResult.note != "New moon week — prime conditions" && midResult.note != "Full moon tonight — bright skies even here",
        "got '\(midResult.note)'"
    )
}

// MARK: - Part 5: saved-city ranking, tonight only

print("\n--- Saved-city ranking ---")

// Use the same near-new-moon date found above so Moon interference is ~nil for every city --
// isolates the ranking/limiting-factor result to the cloud/precip inputs, which is what this
// section is actually testing.
let rankingDate = newMoonResult != nil
    ? ascendingByIllum.first(where: { SkySpots.darkSkyTonight(spot: cherrySpringsSpot, date: $0.date).moonIlluminationPct <= SkySpots.newMoonIlluminationThreshold })!.date
    : iso("2026-01-01T12:00:00Z")

let cityInputs = [
    SkySpots.CityForecastInput(name: "Clearville", latitude: 39.0, longitude: -104.9, conditionCode: "clear", precipChance: 0),
    SkySpots.CityForecastInput(name: "Partlytown", latitude: 41.8, longitude: -87.6, conditionCode: "partlyCloudy", precipChance: 0),
    SkySpots.CityForecastInput(name: "Stormville", latitude: 29.7, longitude: -95.4, conditionCode: "rain", precipChance: 0.9),
]

let ranking = SkySpots.savedCityRanking(cities: cityInputs, timeZone: utc, now: rankingDate)

check("ranking returns all 3 cities", ranking.count == 3, "got \(ranking.count)")
if ranking.count == 3 {
    check("Clearville ranks first", ranking[0].city == "Clearville", "order: \(ranking.map(\.city))")
    check("Partlytown ranks second", ranking[1].city == "Partlytown", "order: \(ranking.map(\.city))")
    check("Stormville ranks last", ranking[2].city == "Stormville", "order: \(ranking.map(\.city))")
    check(
        "scores are strictly descending",
        ranking[0].tonightScore >= ranking[1].tonightScore && ranking[1].tonightScore >= ranking[2].tonightScore,
        "scores: \(ranking.map(\.tonightScore))"
    )
    check("Clearville's score is a near-perfect 9 or 10", ranking[0].tonightScore >= 9, "got \(ranking[0].tonightScore)")
    check("Stormville's score is 0 (fully rained out)", ranking[2].tonightScore == 0, "got \(ranking[2].tonightScore)")
    check(
        "Partlytown is limited by clouds",
        ranking[1].limitingFactor == .clouds,
        "got \(ranking[1].limitingFactor)"
    )
    check(
        "Stormville is limited by clouds",
        ranking[2].limitingFactor == .clouds,
        "got \(ranking[2].limitingFactor)"
    )
    check(
        "Clearville has no meaningfully limiting factor",
        ranking[0].limitingFactor == .none,
        "got \(ranking[0].limitingFactor)"
    )
}

// MARK: - Summary

print("\n================================================================")
print(" \(passCount) passed, \(failCount) failed")
print("================================================================")
exit(failCount == 0 ? 0 : 1)
