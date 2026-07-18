import Foundation

// Almanac engine smoke test -- validates Sources/Sky/Almanac (BestNight, Eclipses, Comets,
// OnThisDay) plus the additive Sources/Sky/Astronomy/MeteorRadiant.swift extension.
//
// Build/run per the Build Guide engine-test recipe (compiled together with ISS + Aurora + Score
// since BestNight consumes StargazingScore.cloudCoverFraction, and MeteorShowers'
// activeShowers/MeteorOutlook types pull in ISS/Aurora transitively via BestMoment.swift living
// in the same Astronomy directory):
//   T=$(mktemp -d) && xattr -cr Sources && cp Tests/AlmanacSmokeTest.swift "$T/main.swift" && \
//     swiftc -O Sources/Sky/Astronomy/*.swift Sources/Sky/ISS/*.swift Sources/Sky/Aurora/*.swift \
//       Sources/Sky/Score/*.swift Sources/Sky/Almanac/*.swift "$T/main.swift" -o "$T/t" && "$T/t"; rm -rf "$T"
//
// Eclipse dates/times/regions in eclipses.json were fetched live on 2026-07-18 from NASA's
// eclipse.gsfc.nasa.gov decade tables (see eclipses.json's own per-entry `notes` for citations).
// Comet data in comets.json is from EarthSky and the Cambridge "Comet Prospects for 2026" list,
// also fetched 2026-07-18. onthisday.json was researched the same day; see that effort's own
// report for sourcing notes on individual entries.
//
// JSON-backed content (Eclipses, Comets, OnThisDay) is exercised here via each type's pure
// `decode(data:)` entry point, reading the checked-in JSON straight off disk by absolute path --
// this CLI recipe has no app `Bundle`, so `Eclipses.all`/`Comets.all`/`OnThisDay.all` (which read
// via `Bundle.main`) can't be exercised here; those bundle-loading paths mirror the same
// pattern already used untested by `SpecialDayTable`/`PhraseBank` elsewhere in this app, and are
// covered by construction (identical structure, `decode(data:)` already proven against the same
// bytes Bundle.main would hand it).

let almanacDir = "/Users/justinnikolaus/Library/CloudStorage/Dropbox/_Projects/Weather App/Sources/Sky/Almanac"

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
          "expected \(expected)\(unit) +/- \(tolerance)\(unit), got \(actual)\(unit)")
}

func makeDate(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int = 0, timeZoneID: String) -> Date {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: timeZoneID)!
    var c = DateComponents()
    c.year = year; c.month = month; c.day = day; c.hour = hour; c.minute = minute
    return cal.date(from: c)!
}

let isoParser = ISO8601DateFormatter()

let tomahLat = 43.98
let tomahLonEast = -90.50 // this engine takes longitude positive-EAST; Tomah is 90.50°W
let chicago = TimeZone(identifier: "America/Chicago")!

print("================================================================")
print(" Clear Sky — Almanac smoke test")
print("================================================================\n")

// Loaded up front (not just in Section 3) because Section 1's BestNight tests need to inject a
// real eclipse table -- `Eclipses.all` reads via `Bundle.main`, which is empty in this
// bundle-less CLI recipe (see the file-level doc comment).
let eclipsesForInjection: [Eclipses.Eclipse] = {
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: "\(almanacDir)/eclipses.json")),
          let decoded = try? Eclipses.decode(data: data) else {
        return []
    }
    return decoded
}()

// ================================================================
// SECTION 1: BestNight
// ================================================================

print("--- BestNight: mixed week (Perseids peak night vs. a cloudy night) ---")

do {
    // Perseids 2026 peak Aug 12-13, new moon per AMS/EarthSky/Weather.com (see
    // Tests/SkyIntelSmokeTest.swift's own citation) -- reused here as a "clear + near-new-moon"
    // night, which should rate at or near the top of the 0...10 scale and carry the meteor-peak
    // bonus flag.
    let now = makeDate(2026, 8, 12, 0, 0, timeZoneID: "America/Chicago")
    var forecast: [BestNight.NightlyForecastInput] = []
    var cal = Calendar(identifier: .gregorian); cal.timeZone = chicago
    for offset in 0..<7 {
        let day = cal.date(byAdding: .day, value: offset, to: now)!
        // Day 0 (Aug 12, Perseids peak night): clear. Day 1 (Aug 13): cloudy. Rest: clear, to
        // isolate the peak-night/cloudy-night comparison from any tie-break ambiguity.
        let code = offset == 1 ? "cloudy" : "clear"
        forecast.append(BestNight.NightlyForecastInput(date: day, conditionCode: code, precipChance: 0))
    }

    let outlook = BestNight.outlook(dailyForecast: forecast, latitude: tomahLat, longitude: tomahLonEast, timeZone: chicago, now: now)
    check("BestNight returns all 7 nights", outlook.count == 7, "got \(outlook.count)")

    if let peakNight = outlook.first {
        check("Aug 12 (Perseids peak, clear, near-new-moon) rates 9 or 10", (9...10).contains(peakNight.rating), "got \(peakNight.rating)")
        check("Aug 12 flags Perseids as a peak-night special event",
              peakNight.specialEvents.contains { if case .meteorShowerPeak(let name) = $0 { return name == "Perseids" }; return false },
              "got \(peakNight.specialEvents)")
        check("Aug 12 limiting factor is .none (both factors near-ideal)", peakNight.limitingFactor == .none, "got \(peakNight.limitingFactor)")
    }

    if outlook.count > 1 {
        let cloudyNight = outlook[1]
        check("Aug 13 (cloudy) rates 0 or 1", (0...1).contains(cloudyNight.rating), "got \(cloudyNight.rating)")
        check("Aug 13 limiting factor is .clouds", cloudyNight.limitingFactor == .clouds, "got \(cloudyNight.limitingFactor)")
    }

    check("Exactly one night flagged isBestNight", outlook.filter { $0.isBestNight }.count == 1, "got \(outlook.filter { $0.isBestNight }.count)")
    check("Best night is Aug 12 (highest rating)", outlook.first?.isBestNight == true, "got isBestNight=\(String(describing: outlook.first?.isBestNight))")
}

print("\n--- BestNight: tie-break (all-cloudy week -> earliest night wins) ---")

do {
    let now = makeDate(2026, 9, 1, 0, 0, timeZoneID: "America/Chicago")
    var cal = Calendar(identifier: .gregorian); cal.timeZone = chicago
    var forecast: [BestNight.NightlyForecastInput] = []
    for offset in 0..<7 {
        let day = cal.date(byAdding: .day, value: offset, to: now)!
        forecast.append(BestNight.NightlyForecastInput(date: day, conditionCode: "cloudy", precipChance: 0))
    }
    let outlook = BestNight.outlook(dailyForecast: forecast, latitude: tomahLat, longitude: tomahLonEast, timeZone: chicago, now: now)
    check("All-cloudy week: every night rates 0", outlook.allSatisfy { $0.rating == 0 }, "ratings: \(outlook.map(\.rating))")
    check("All-cloudy week: earliest night (index 0) wins the tie-break", outlook.first?.isBestNight == true)
    check("All-cloudy week: no other night flagged best", outlook.dropFirst().allSatisfy { !$0.isBestNight })
}

print("\n--- BestNight: moon-dominated night + eclipse bonus flag ---")

do {
    // The 2026-08-27/28 partial lunar eclipse peaks 2026-08-28 04:14 UTC = 2026-08-27 23:14
    // CDT -- within the Aug 27 night window (civil dusk Aug 27 -> civil dawn Aug 28), and at
    // (very nearly) full moon, so this night should rate lower than the near-new-moon Aug 12
    // night above under the same clear sky, be moon-limited, and carry the eclipse flag on
    // BestNight's Aug-27-keyed entry (see Eclipses.eclipses(onCalendarDay:) -- it buckets by the
    // eclipse's *local calendar day*, which is Aug 27 here, not Aug 28).
    let now = makeDate(2026, 8, 27, 0, 0, timeZoneID: "America/Chicago")
    let forecast = [BestNight.NightlyForecastInput(date: now, conditionCode: "clear", precipChance: 0)]
    let outlook = BestNight.outlook(dailyForecast: forecast, latitude: tomahLat, longitude: tomahLonEast, timeZone: chicago, now: now, eclipseTable: eclipsesForInjection)
    check("Moon-dominated night outlook computed", outlook.count == 1, "got \(outlook.count)")
    if let night = outlook.first {
        check("Aug 27 moon illumination is near-full", night.moonIlluminatedPercent > 90, "got \(night.moonIlluminatedPercent)%")
        check("Aug 27 limiting factor is .moon", night.limitingFactor == .moon, "got \(night.limitingFactor)")
        check("Aug 27 flags the lunar eclipse as a special event",
              night.specialEvents.contains { if case .eclipse(let type) = $0 { return type == .partialLunar }; return false },
              "got \(night.specialEvents)")
    }
}

print("\n--- BestNight: monotonicity ---")

do {
    // Cloud monotonicity: holding date (and therefore Moon) fixed, rating should be
    // non-increasing as the condition code gets cloudier.
    let day = makeDate(2026, 8, 20, 0, 0, timeZoneID: "America/Chicago")
    let codes = ["clear", "mostlyClear", "partlyCloudy", "mostlyCloudy", "cloudy"]
    let ratings = codes.map { code -> Int in
        let outlook = BestNight.outlook(
            dailyForecast: [BestNight.NightlyForecastInput(date: day, conditionCode: code, precipChance: 0)],
            latitude: tomahLat, longitude: tomahLonEast, timeZone: chicago, now: day
        )
        return outlook.first?.rating ?? -1
    }
    var nonIncreasing = true
    for i in 1..<ratings.count where ratings[i] > ratings[i - 1] { nonIncreasing = false }
    check("Rating is non-increasing as clouds worsen", nonIncreasing, "ratings for \(codes): \(ratings)")

    // Moon monotonicity spot check: a clear near-new-moon night should rate at least as high as
    // a clear near-full-moon night.
    let newMoonOutlook = BestNight.outlook(
        dailyForecast: [BestNight.NightlyForecastInput(date: makeDate(2026, 8, 12, 0, 0, timeZoneID: "America/Chicago"), conditionCode: "clear", precipChance: 0)],
        latitude: tomahLat, longitude: tomahLonEast, timeZone: chicago, now: makeDate(2026, 8, 12, 0, 0, timeZoneID: "America/Chicago")
    ).first!
    let fullMoonOutlook = BestNight.outlook(
        dailyForecast: [BestNight.NightlyForecastInput(date: makeDate(2026, 8, 27, 0, 0, timeZoneID: "America/Chicago"), conditionCode: "clear", precipChance: 0)],
        latitude: tomahLat, longitude: tomahLonEast, timeZone: chicago, now: makeDate(2026, 8, 27, 0, 0, timeZoneID: "America/Chicago")
    ).first!
    check("Clear near-new-moon night rates >= clear near-full-moon night",
          newMoonOutlook.rating >= fullMoonOutlook.rating,
          "new-moon night \(newMoonOutlook.rating) vs full-moon night \(fullMoonOutlook.rating)")
    check("Clear near-new-moon moonFactor >= clear near-full-moon moonFactor",
          newMoonOutlook.moonFactor >= fullMoonOutlook.moonFactor,
          "\(newMoonOutlook.moonFactor) vs \(fullMoonOutlook.moonFactor)")
}

// ================================================================
// SECTION 2: Meteor radiant directions
// ================================================================

print("\n--- Meteor radiant directions ---")

do {
    guard let perseids = MeteorShowers.all.first(where: { $0.name == "Perseids" }) else {
        check("Perseids found in MeteorShowers.all", false); fatalError("unreachable")
    }
    // Perseids radiant (RA 48, Dec 58) is far enough north (circumpolar at 44N: 58 > 90-44) to
    // sit consistently in the NE quadrant through the pre-dawn hours on peak night, matching
    // this shower's own viewingNotes ("climbs the northeastern sky"). Verified with a hand
    // sweep (20:00-05:00) before writing this assertion: NE from ~midnight through dawn.
    let peak1am = makeDate(2026, 8, 13, 1, 0, timeZoneID: "America/Chicago")
    let dir = MeteorShowers.radiantDirection(shower: perseids, date: peak1am, lat: tomahLat, lon: tomahLonEast)
    check("Perseids radiant at 1am on peak night is in the NE", dir.compass == "NE", "got \(dir.compass) (\(dir.altitudeQualitative))")

    // Convenience wrapper should agree with the manually-constructed date above.
    if let dirConvenience = MeteorShowers.radiantDirectionOnPeakNight(shower: perseids, year: 2026, hourLocal: 1, lat: tomahLat, lon: tomahLonEast, timeZone: chicago) {
        check("radiantDirectionOnPeakNight(Perseids, 2026) agrees with manual date", dirConvenience.compass == dir.compass, "got \(dirConvenience.compass)")
    } else {
        check("radiantDirectionOnPeakNight(Perseids, 2026) returns non-nil", false)
    }

    guard let geminids = MeteorShowers.all.first(where: { $0.name == "Geminids" }) else {
        check("Geminids found in MeteorShowers.all", false); fatalError("unreachable")
    }
    // Geminids (RA 112, Dec 33) rise in the east during evening twilight and climb toward a
    // near-overhead transit around 1-2am at this latitude (consistent with this shower's own
    // viewingNotes: "unusually good even before midnight... highest [1-2am]"). A hand sweep
    // (20:00-05:00, see almanac work notes) confirms the radiant sits in the NE-E quadrant in
    // the evening before drifting through SE/S/SW toward dawn as it crosses the meridian --
    // so this checks the *evening* portion of the peak night (21:00), matching the work order's
    // "Geminids ~= NE-E" expectation, rather than 1am (where the radiant is already past
    // transit, toward SE -- also checked below as a documented, non-failing data point).
    let evening9pm = makeDate(2026, 12, 13, 21, 0, timeZoneID: "America/Chicago")
    let geminidsEvening = MeteorShowers.radiantDirection(shower: geminids, date: evening9pm, lat: tomahLat, lon: tomahLonEast)
    let expectedGeminidsCompass: Set<String> = ["NE", "ENE", "E"]
    check("Geminids radiant at 9pm on peak night is NE-E", expectedGeminidsCompass.contains(geminidsEvening.compass), "got \(geminidsEvening.compass) (\(geminidsEvening.altitudeQualitative))")

    let geminids1am = makeDate(2026, 12, 14, 1, 0, timeZoneID: "America/Chicago")
    let geminidsLate = MeteorShowers.radiantDirection(shower: geminids, date: geminids1am, lat: tomahLat, lon: tomahLonEast)
    print("INFO  Geminids radiant at 1am (past transit at this latitude): \(geminidsLate.compass) / \(geminidsLate.altitudeQualitative) -- informational, not asserted")

    // Sanity: radiant altitude should agree between the tuple API and the raw horizontal API.
    let rawHorizontal = MeteorShowers.radiantHorizontal(shower: perseids, date: peak1am, lat: tomahLat, lon: tomahLonEast)
    check("radiantDirection's compass matches compassPoint(forAzimuth:) of the raw horizontal", dir.compass == compassPoint(forAzimuth: rawHorizontal.azimuth))
}

// ================================================================
// SECTION 3: Eclipses
// ================================================================

print("\n--- Eclipses: table parses and researched dates match ---")

var eclipses: [Eclipses.Eclipse] = []
do {
    let url = URL(fileURLWithPath: "\(almanacDir)/eclipses.json")
    do {
        let data = try Data(contentsOf: url)
        eclipses = try Eclipses.decode(data: data)
        check("eclipses.json parses", true)
        check("eclipses.json has 29 entries (14 solar + 15 lunar, 2026-2031)", eclipses.count == 29, "got \(eclipses.count)")
    } catch {
        check("eclipses.json parses", false, "\(error)")
    }
}

func findEclipse(_ isoDate: String) -> Eclipses.Eclipse? {
    guard let target = isoParser.date(from: isoDate) else { return nil }
    return eclipses.first { abs($0.peakUTC.timeIntervalSince(target)) < 60 }
}

do {
    // Source: NASA eclipse.gsfc.nasa.gov "Solar Eclipses: 2021-2030" decade table, fetched
    // 2026-07-18.
    if let e = findEclipse("2026-02-17T12:13:05Z") {
        check("2026-02-17 annular solar eclipse present with correct type", e.type == .annularSolar, "got \(e.type)")
    } else {
        check("2026-02-17 annular solar eclipse present", false)
    }

    if let e = findEclipse("2026-08-12T17:47:05Z") {
        check("2026-08-12 total solar eclipse present with correct type", e.type == .totalSolar, "got \(e.type)")
    } else {
        check("2026-08-12 total solar eclipse present", false)
    }

    // The 2027-08-02 total solar eclipse's ~6m23s max totality near Luxor, Egypt is widely
    // reported as the longest total solar eclipse over easily accessible land in the 21st
    // century. Sources: Space.com "Total solar eclipse 2027: A complete guide", Sky & Telescope
    // "Luxor 2027: A Total Solar Eclipse for the Ages" -- both fetched 2026-07-18.
    if let e = findEclipse("2027-08-02T10:07:49Z") {
        check("2027-08-02 total solar eclipse present with correct type", e.type == .totalSolar, "got \(e.type)")
    } else {
        check("2027-08-02 total solar eclipse present", false)
    }

    // Source: NASA eclipse.gsfc.nasa.gov "Lunar Eclipses: 2021-2030" decade table, fetched
    // 2026-07-18.
    if let e = findEclipse("2026-03-03T11:34:52Z") {
        check("2026-03-03 total lunar eclipse present with correct type", e.type == .totalLunar, "got \(e.type)")
    } else {
        check("2026-03-03 total lunar eclipse present", false)
    }

    if let e = findEclipse("2028-12-31T16:53:15Z") {
        check("2028-12-31 total lunar eclipse present with correct type", e.type == .totalLunar, "got \(e.type)")
    } else {
        check("2028-12-31 total lunar eclipse present", false)
    }

    // Source: NASA eclipse.gsfc.nasa.gov "Solar Eclipses: 2031-2040" decade table, fetched
    // 2026-07-18 (times listed by NASA as Terrestrial Dynamical Time, within ~1 minute of UTC
    // at this epoch).
    if let e = findEclipse("2031-11-14T21:07:30Z") {
        check("2031-11-14 hybrid solar eclipse present with correct type", e.type == .hybridSolar, "got \(e.type)")
    } else {
        check("2031-11-14 hybrid solar eclipse present", false)
    }
}

print("\n--- Eclipses: lunar visibility logic ---")

do {
    guard let marchEclipse = findEclipse("2026-03-03T11:34:52Z") else {
        check("2026-03-03 eclipse found for visibility test", false); fatalError("unreachable")
    }
    // At 11:34 UTC, London (51.5N, 0.12W) is near local midday -- during a (near-)full moon,
    // the Moon sits near lower culmination at local midday, below the horizon. Verified
    // numerically before writing this assertion (altitude negative at this instant/location).
    let londonVisible = Eclipses.isVisible(marchEclipse, latitude: 51.5, longitude: -0.12)
    check("2026-03-03 total lunar eclipse NOT visible from London at peak (local midday, Moon below horizon)", londonVisible == false)

    // Tomah, at 11:34 UTC = 05:34 CST, is still well before sunrise -- Moon above horizon.
    let tomahVisible = Eclipses.isVisible(marchEclipse, latitude: tomahLat, longitude: tomahLonEast)
    check("2026-03-03 total lunar eclipse IS visible from Tomah at peak (local pre-dawn, Moon above horizon)", tomahVisible == true)
}

print("\n--- Eclipses: solar visibility (coarse region boxes) ---")

do {
    guard let augustEclipse = findEclipse("2026-08-12T17:47:05Z") else {
        check("2026-08-12 eclipse found for visibility test", false); fatalError("unreachable")
    }
    // Reykjavik sits inside this eclipse's bundled Greenland/Iceland/Spain totality-corridor box.
    check("2026-08-12 total solar eclipse visible from Reykjavik (64.1N, 21.9W)", Eclipses.isVisible(augustEclipse, latitude: 64.1, longitude: -21.9))
    // Sydney is nowhere near this eclipse's path.
    check("2026-08-12 total solar eclipse NOT visible from Sydney (33.9S, 151.2E)", !Eclipses.isVisible(augustEclipse, latitude: -33.9, longitude: 151.2))
}

print("\n--- Eclipses: nextEclipse lookup ---")

do {
    let now = makeDate(2026, 7, 18, 0, 0, timeZoneID: "UTC")
    guard let next = Eclipses.nextEclipse(visibleFrom: tomahLat, longitude: tomahLonEast, after: now, in: eclipses) else {
        check("nextEclipse(after: 2026-07-18) returns a result", false); fatalError("unreachable")
    }
    check("Next eclipse after 2026-07-18 is the 2026-08-12 total solar eclipse", next.eclipse.type == .totalSolar, "got \(next.eclipse.type) on \(next.eclipse.peakUTC)")
    check("Next eclipse daysUntil is positive and roughly 25", next.daysUntil > 0 && next.daysUntil < 30, "got \(next.daysUntil)")
    check("Next eclipse visibilityDescription is non-empty", !next.visibilityDescription.isEmpty)

    // Far-future anchor: nothing after the table's last entry.
    let farFuture = makeDate(2032, 1, 1, 0, 0, timeZoneID: "UTC")
    check("nextEclipse(after: 2032-01-01) returns nil (past the table's coverage)", Eclipses.nextEclipse(visibleFrom: tomahLat, longitude: tomahLonEast, after: farFuture, in: eclipses) == nil)
}

// ================================================================
// SECTION 4: Comets
// ================================================================

print("\n--- Comets: table parses ---")

var comets: [Comets.Comet] = []
do {
    let url = URL(fileURLWithPath: "\(almanacDir)/comets.json")
    do {
        let data = try Data(contentsOf: url)
        comets = try Comets.decode(data: data)
        check("comets.json parses", true)
        check("comets.json has at least 1 entry", comets.count >= 1, "got \(comets.count)")
    } catch {
        check("comets.json parses", false, "\(error)")
    }
    check("Every comet entry has a non-empty name/magnitude/window/note", comets.allSatisfy {
        !$0.name.isEmpty && !$0.expectedMagnitudeRange.isEmpty && !$0.visibilityWindow.isEmpty && !$0.viewingNote.isEmpty
    })
    check("Every comet entry's perihelionDate parses", comets.allSatisfy { $0.perihelionUTCDate != nil })

    let now = makeDate(2026, 7, 18, 0, 0, timeZoneID: "UTC")
    let upcoming = Comets.upcoming(after: now, in: comets)
    check("upcoming(after: 2026-07-18) returns entries in perihelion order", zip(upcoming, upcoming.dropFirst()).allSatisfy { $0.perihelionUTCDate! <= $1.perihelionUTCDate! })
}

// ================================================================
// SECTION 5: On-this-day
// ================================================================

print("\n--- OnThisDay: 366/366 coverage and register ---")

var onThisDayEntries: [OnThisDay.Entry] = []
do {
    let url = URL(fileURLWithPath: "\(almanacDir)/onthisday.json")
    do {
        let data = try Data(contentsOf: url)
        onThisDayEntries = try OnThisDay.decode(data: data)
        check("onthisday.json parses", true)
    } catch {
        check("onthisday.json parses", false, "\(error)")
    }

    check("onthisday.json has exactly 366 entries", onThisDayEntries.count == 366, "got \(onThisDayEntries.count)")

    let daysInMonth: [Int: Int] = [1: 31, 2: 29, 3: 31, 4: 30, 5: 31, 6: 30, 7: 31, 8: 31, 9: 30, 10: 31, 11: 30, 12: 31]
    var expectedPairs = Set<Int>()
    for month in 1...12 {
        for day in 1...(daysInMonth[month] ?? 31) {
            expectedPairs.insert(month * 100 + day)
        }
    }
    let actualPairs = Set(onThisDayEntries.map { $0.month * 100 + $0.day })
    check("Every (month, day) pair from Jan 1 through Dec 31 (incl. Feb 29) is covered exactly once",
          actualPairs == expectedPairs,
          "missing: \(expectedPairs.subtracting(actualPairs).sorted()), unexpected: \(actualPairs.subtracting(expectedPairs).sorted())")
    check("No duplicate (month, day) pairs", onThisDayEntries.count == actualPairs.count, "got \(onThisDayEntries.count) entries for \(actualPairs.count) unique pairs")

    let overLength = onThisDayEntries.filter { $0.text.count > 120 }
    check("Every entry's text is <= 120 characters", overLength.isEmpty, "\(overLength.count) over budget, e.g. \(overLength.first.map { "\($0.month)/\($0.day): \($0.text.count) chars" } ?? "")")

    let withExclamation = onThisDayEntries.filter { $0.text.contains("!") }
    check("No entry contains an exclamation point", withExclamation.isEmpty, "\(withExclamation.count) entries, e.g. \(withExclamation.first?.text ?? "")")

    let empty = onThisDayEntries.filter { $0.text.trimmingCharacters(in: .whitespaces).isEmpty }
    check("No entry has empty text", empty.isEmpty)

    // Content sanity on the decoded entries directly (the bundle-backed `OnThisDay.entry(...)`
    // lookups read via `Bundle.main`, which is empty in this CLI recipe -- see the file-level
    // doc comment; the lookup layer is a trivial dictionary over these same decoded entries).
    if let apollo = onThisDayEntries.first(where: { $0.month == 7 && $0.day == 20 }) {
        check("July 20 entry mentions Apollo 11", apollo.text.contains("Apollo 11"), "got: \(apollo.text)")
    } else {
        check("July 20 entry exists", false)
    }
    if let leapDay = onThisDayEntries.first(where: { $0.month == 2 && $0.day == 29 }) {
        check("Feb 29 (leap day) entry is non-empty", !leapDay.text.isEmpty, "got: \(leapDay.text)")
    } else {
        check("Feb 29 (leap day) entry exists", false)
    }
}

// ================================================================
// Summary
// ================================================================

print("\n================================================================")
print(" \(passedChecks)/\(totalChecks) checks passed")
print("================================================================")
if passedChecks != totalChecks {
    exit(1)
}
