import Foundation

// Smoke test for Sources/Sky/Solar/*.swift. Build Guide engine-test recipe:
//   T=$(mktemp -d) && xattr -cr Sources && cp Tests/SolarSmokeTest.swift "$T/main.swift" && \
//     swiftc -O Sources/Sky/Solar/*.swift "$T/main.swift" -o "$T/t" && "$T/t"; rm -rf "$T"
//
// Two parts:
//  1. Live fetch of all three NOAA SWPC endpoints through SolarService (exercises real networking
//     + the on-disk cache path), with parse/range validation.
//  2. Canned-JSON unit checks of the pure SolarActivity math (flare-class parsing, activity-level
//     tiers, C5 notability threshold, 24h trailing window edge, G-forecast maxima) -- no network
//     involved.
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

func scaleEntry(dateStamp: String = "2026-07-18", timeStamp: String = "03:45:00", r: Int? = nil, s: Int? = nil, g: Int?) -> NOAAScaleDayEntry {
    NOAAScaleDayEntry(
        dateStamp: dateStamp,
        timeStamp: timeStamp,
        r: .init(scale: r.map(String.init), text: nil, minorProb: nil, majorProb: nil),
        s: .init(scale: s.map(String.init), text: nil, prob: nil),
        g: .init(scale: g.map(String.init), text: nil)
    )
}

func flare(maxClass: String, maxTime: Date, beginTime: Date? = nil, endTime: Date? = nil, satellite: Int = 18) -> FlareEvent {
    let iso8601 = ISO8601DateFormatter()
    return FlareEvent(
        timeTag: iso8601.string(from: maxTime),
        beginTime: iso8601.string(from: beginTime ?? maxTime.addingTimeInterval(-300)),
        beginClass: "B1.0",
        maxTime: iso8601.string(from: maxTime),
        maxClass: maxClass,
        maxXrlong: nil,
        maxRatio: nil,
        maxRatioTime: nil,
        currentIntXrlong: nil,
        endTime: iso8601.string(from: endTime ?? maxTime.addingTimeInterval(600)),
        endClass: "B1.0",
        satellite: satellite
    )
}

// MARK: - Part 1: live fetch

print("=== Live fetch: scales + flares + sunspots ===")

let liveCacheDir = FileManager.default.temporaryDirectory
    .appendingPathComponent("SolarSmokeTestCache-\(UUID().uuidString)")
defer { try? FileManager.default.removeItem(at: liveCacheDir) }

let service = SolarService()

do {
    let (scales, isStale) = try await service.fetchScales(cacheDirectory: liveCacheDir)
    check("Scales live fetch succeeded", true)
    check("Scales fresh fetch is not stale", !isStale, "isStale=\(isStale)")
    check("Scales has the '0' (current) entry", scales["0"] != nil)
    check("Scales has '-1', '1', '2', '3' entries", scales["-1"] != nil && scales["1"] != nil && scales["2"] != nil && scales["3"] != nil,
          "keys=\(scales.keys.sorted())")
    if let current = scales["0"] {
        print("  current: DateStamp=\(current.dateStamp) TimeStamp=\(current.timeStamp) R=\(String(describing: current.r.scaleValue)) S=\(String(describing: current.s.scaleValue)) G=\(String(describing: current.g.scaleValue))")
        check("Scales '0' entry date parses", current.date != nil)
        if let rv = current.r.scaleValue {
            check("Scales '0' R scale in 0...5", (0...5).contains(rv), "R=\(rv)")
        }
        if let gv = current.g.scaleValue {
            check("Scales '0' G scale in 0...5", (0...5).contains(gv), "G=\(gv)")
        }
    }
    for key in ["1", "2", "3"] {
        if let entry = scales[key] {
            print("  forecast \(key): DateStamp=\(entry.dateStamp) G=\(String(describing: entry.g.scaleValue))")
        }
    }
} catch {
    check("Scales live fetch succeeded", false, "\(error)")
}

do {
    let (flares, isStale) = try await service.fetchFlares(cacheDirectory: liveCacheDir)
    check("Flares live fetch succeeded", true)
    check("Flares fresh fetch is not stale", !isStale, "isStale=\(isStale)")
    print("  flare count (trailing 7 days): \(flares.count)")
    print("  most recent 3: \(flares.suffix(3).map { ($0.maxClass, $0.maxTime) })")
    let allParse = flares.allSatisfy { FlareClass.parse($0.maxClass) != nil }
    check("Flares: every max_class parses as a FlareClass", allParse,
          "unparsed: \(flares.filter { FlareClass.parse($0.maxClass) == nil }.map(\.maxClass))")
    let allDatesParse = flares.allSatisfy { $0.maxDate != nil && $0.beginDate != nil && $0.endDate != nil }
    check("Flares: begin/max/end times all parse", allDatesParse)
} catch {
    check("Flares live fetch succeeded", false, "\(error)")
}

do {
    let (sunspots, isStale) = try await service.fetchSunspots(cacheDirectory: liveCacheDir)
    check("Sunspots live fetch succeeded", true)
    check("Sunspots fresh fetch is not stale", !isStale, "isStale=\(isStale)")
    check("Sunspots has rows", !sunspots.isEmpty, "count=\(sunspots.count)")
    if let latest = sunspots.max(by: { ($0.date ?? .distantPast) < ($1.date ?? .distantPast) }) {
        print("  latest observed: \(latest.obsdate) ssn=\(latest.swpcSsn)")
        check("Sunspots: latest ssn in sane range (0...500)", (0...500).contains(latest.swpcSsn), "ssn=\(latest.swpcSsn)")
        check("Sunspots: latest date parses", latest.date != nil)
    }
} catch {
    check("Sunspots live fetch succeeded", false, "\(error)")
}

// MARK: - Part 2a: FlareClass parsing

print("\n=== Canned FlareClass parsing ===")

check("parse M4.2 -> letter M, magnitude 4.2", FlareClass.parse("M4.2") == FlareClass(raw: "M4.2", letter: "M", magnitude: 4.2))
check("parse X1.0 -> letter X, magnitude 1.0", FlareClass.parse("X1.0") == FlareClass(raw: "X1.0", letter: "X", magnitude: 1.0))
check("parse invalid letter 'Z5.0' -> nil", FlareClass.parse("Z5.0") == nil)
check("parse missing magnitude 'M' -> nil", FlareClass.parse("M") == nil)
check("rank order: X1.0 > M9.9 (tier dominates magnitude)", FlareClass.parse("X1.0")!.rankValue > FlareClass.parse("M9.9")!.rankValue)
check("rank order: M1.0 > C9.9 (tier dominates magnitude)", FlareClass.parse("M1.0")!.rankValue > FlareClass.parse("C9.9")!.rankValue)

// MARK: - Part 2b: activity-level tiers

print("\n=== Canned activity-level tiers ===")

let now = iso("2026-07-18T12:00:00Z")
let quietScales: NOAAScales = ["0": scaleEntry(r: 0, s: 0, g: 0), "1": scaleEntry(g: 0), "2": scaleEntry(g: 0), "3": scaleEntry(g: 0)]

do {
    // Baseline: no flares, all scales 0 -> .quiet.
    let outlook = SolarActivity.outlook(scales: quietScales, flares: [], sunspots: [], now: now)
    check("quiet baseline: no flares, R=S=G=0 -> .quiet", outlook.activityLevel == .quiet, "got \(outlook.activityLevel)")
    check("quiet baseline: no notable flare", outlook.latestNotableFlare == nil)
}

do {
    // A lone C-class flare (below the M/X activity trigger) with quiet scales stays .quiet.
    let flares = [flare(maxClass: "C3.0", maxTime: now.addingTimeInterval(-2 * 3600))]
    let outlook = SolarActivity.outlook(scales: quietScales, flares: flares, sunspots: [], now: now)
    check("C-class flare alone does not raise activity level", outlook.activityLevel == .quiet, "got \(outlook.activityLevel)")
    check("C3.0 (< C5) is not notable", outlook.latestNotableFlare == nil)
}

do {
    // M-class flare in trailing 24h -> .active, and it clears C5 notability.
    let flares = [flare(maxClass: "M4.2", maxTime: now.addingTimeInterval(-3 * 3600))]
    let outlook = SolarActivity.outlook(scales: quietScales, flares: flares, sunspots: [], now: now)
    check("M-class flare in trailing 24h -> .active", outlook.activityLevel == .active, "got \(outlook.activityLevel)")
    check("M4.2 is notable", outlook.latestNotableFlare?.classString == "M4.2", "got \(String(describing: outlook.latestNotableFlare))")
}

do {
    // R1 (no flare) -> .active.
    let scales: NOAAScales = ["0": scaleEntry(r: 1, s: 0, g: 0)]
    let outlook = SolarActivity.outlook(scales: scales, flares: [], sunspots: [], now: now)
    check("R1 (no flare) -> .active", outlook.activityLevel == .active, "got \(outlook.activityLevel)")
}

do {
    // R2 (no flare) -> .active.
    let scales: NOAAScales = ["0": scaleEntry(r: 2, s: 0, g: 0)]
    let outlook = SolarActivity.outlook(scales: scales, flares: [], sunspots: [], now: now)
    check("R2 (no flare) -> .active", outlook.activityLevel == .active, "got \(outlook.activityLevel)")
}

do {
    // G1 (no flare) -> .active.
    let scales: NOAAScales = ["0": scaleEntry(r: 0, s: 0, g: 1)]
    let outlook = SolarActivity.outlook(scales: scales, flares: [], sunspots: [], now: now)
    check("G1 (no flare) -> .active", outlook.activityLevel == .active, "got \(outlook.activityLevel)")
}

do {
    // X-class flare in trailing 24h -> .stormy, regardless of quiet scales.
    let flares = [flare(maxClass: "X1.4", maxTime: now.addingTimeInterval(-1 * 3600))]
    let outlook = SolarActivity.outlook(scales: quietScales, flares: flares, sunspots: [], now: now)
    check("X-class flare in trailing 24h -> .stormy", outlook.activityLevel == .stormy, "got \(outlook.activityLevel)")
    check("X1.4 is notable", outlook.latestNotableFlare?.classString == "X1.4")
}

do {
    // R3 (no flare) -> .stormy.
    let scales: NOAAScales = ["0": scaleEntry(r: 3, s: 0, g: 0)]
    let outlook = SolarActivity.outlook(scales: scales, flares: [], sunspots: [], now: now)
    check("R3 (no flare) -> .stormy", outlook.activityLevel == .stormy, "got \(outlook.activityLevel)")
}

do {
    // R3 dominates even alongside an M-class flare -- still exactly .stormy, not double-counted.
    let scales: NOAAScales = ["0": scaleEntry(r: 3, s: 0, g: 0)]
    let flares = [flare(maxClass: "M2.0", maxTime: now.addingTimeInterval(-1 * 3600))]
    let outlook = SolarActivity.outlook(scales: scales, flares: flares, sunspots: [], now: now)
    check("R3 + M-class flare together -> still .stormy", outlook.activityLevel == .stormy, "got \(outlook.activityLevel)")
}

// MARK: - Part 2c: C5 notability threshold boundary

print("\n=== Canned C5 notability threshold ===")

do {
    let flares = [flare(maxClass: "C4.9", maxTime: now.addingTimeInterval(-1 * 3600))]
    let outlook = SolarActivity.outlook(scales: quietScales, flares: flares, sunspots: [], now: now)
    check("C4.9 (just below threshold) is NOT notable", outlook.latestNotableFlare == nil,
          "got \(String(describing: outlook.latestNotableFlare))")
}

do {
    let flares = [flare(maxClass: "C5.0", maxTime: now.addingTimeInterval(-1 * 3600))]
    let outlook = SolarActivity.outlook(scales: quietScales, flares: flares, sunspots: [], now: now)
    check("C5.0 (exactly at threshold) IS notable", outlook.latestNotableFlare?.classString == "C5.0",
          "got \(String(describing: outlook.latestNotableFlare))")
    check("C5.0 alone still does not raise activityLevel above .quiet", outlook.activityLevel == .quiet,
          "got \(outlook.activityLevel)")
}

// MARK: - Part 2d: 24h trailing window edge

print("\n=== Canned 24h trailing window edge ===")

do {
    // A 25h-old X flare must NOT count toward activity level or notability.
    let staleFlare = flare(maxClass: "X2.0", maxTime: now.addingTimeInterval(-25 * 3600))
    let outlook = SolarActivity.outlook(scales: quietScales, flares: [staleFlare], sunspots: [], now: now)
    check("25h-old X-flare does not raise activity level", outlook.activityLevel == .quiet, "got \(outlook.activityLevel)")
    check("25h-old X-flare is not surfaced as notable", outlook.latestNotableFlare == nil,
          "got \(String(describing: outlook.latestNotableFlare))")
}

do {
    // A flare peaking exactly 24h ago (the window's inclusive boundary) DOES count.
    let boundaryFlare = flare(maxClass: "X2.0", maxTime: now.addingTimeInterval(-24 * 3600))
    let outlook = SolarActivity.outlook(scales: quietScales, flares: [boundaryFlare], sunspots: [], now: now)
    check("exactly-24h-old X-flare (inclusive boundary) DOES count", outlook.activityLevel == .stormy, "got \(outlook.activityLevel)")
    check("exactly-24h-old X-flare is surfaced as notable", outlook.latestNotableFlare?.classString == "X2.0")
}

do {
    // A flare 1 minute past the 24h boundary must NOT count.
    let justOutside = flare(maxClass: "X2.0", maxTime: now.addingTimeInterval(-24 * 3600 - 60))
    let outlook = SolarActivity.outlook(scales: quietScales, flares: [justOutside], sunspots: [], now: now)
    check("24h-1min-old X-flare does not raise activity level", outlook.activityLevel == .quiet, "got \(outlook.activityLevel)")
    check("24h-1min-old X-flare is not surfaced as notable", outlook.latestNotableFlare == nil)
}

do {
    // The strongest flare within the window should be picked even when an older, weaker, and a
    // newer, weaker flare are both also present.
    let flares = [
        flare(maxClass: "C2.0", maxTime: now.addingTimeInterval(-23 * 3600)),
        flare(maxClass: "X3.5", maxTime: now.addingTimeInterval(-10 * 3600)),
        flare(maxClass: "M1.0", maxTime: now.addingTimeInterval(-1 * 3600)),
    ]
    let outlook = SolarActivity.outlook(scales: quietScales, flares: flares, sunspots: [], now: now)
    check("strongest-in-window (X3.5) is picked over weaker earlier/later flares",
          outlook.latestNotableFlare?.classString == "X3.5", "got \(String(describing: outlook.latestNotableFlare))")
    check("activity level reflects the strongest flare (.stormy)", outlook.activityLevel == .stormy, "got \(outlook.activityLevel)")
}

// MARK: - Part 2e: G-forecast maxima extraction

print("\n=== Canned G-forecast maxima ===")

do {
    let scales: NOAAScales = [
        "0": scaleEntry(r: 0, s: 0, g: 0),
        "1": scaleEntry(dateStamp: "2026-07-18", g: 1),
        "2": scaleEntry(dateStamp: "2026-07-19", g: 3),
        "3": scaleEntry(dateStamp: "2026-07-20", g: 2),
    ]
    let outlook = SolarActivity.outlook(scales: scales, flares: [], sunspots: [], now: now)
    check("gScaleNow reads the '0' entry (0), independent of the forecast", outlook.gScaleNow == 0, "got \(outlook.gScaleNow)")
    check("gScaleForecastMax is the max across '1'/'2'/'3' (3)", outlook.gScaleForecastMax == 3, "got \(outlook.gScaleForecastMax)")
    // A high forecast G alone (current G still 0) should not by itself force .active -- only
    // gScaleNow feeds the activity-level mapping, per the work order.
    check("high forecast G does not, by itself, raise activityLevel (only current G does)",
          outlook.activityLevel == .quiet, "got \(outlook.activityLevel)")
}

do {
    // Missing forecast keys entirely -> forecast max defaults to 0, not a crash.
    let scales: NOAAScales = ["0": scaleEntry(r: 0, s: 0, g: 0)]
    let outlook = SolarActivity.outlook(scales: scales, flares: [], sunspots: [], now: now)
    check("missing forecast entries -> gScaleForecastMax defaults to 0", outlook.gScaleForecastMax == 0, "got \(outlook.gScaleForecastMax)")
}

// MARK: - Part 2f: sunspot number extraction

print("\n=== Canned sunspot number extraction ===")

do {
    // Out-of-order rows -- must pick the truly-latest date's ssn, not the last array element.
    let sunspots = [
        SunspotObservation(obsdate: "2026-07-15T00:00:00", swpcSsn: 40),
        SunspotObservation(obsdate: "2026-07-17T00:00:00", swpcSsn: 26),
        SunspotObservation(obsdate: "2026-07-16T00:00:00", swpcSsn: 47),
    ]
    let outlook = SolarActivity.outlook(scales: quietScales, flares: [], sunspots: sunspots, now: now)
    check("sunspotNumber picks the latest-dated row (26 on 07-17), not the last array element",
          outlook.sunspotNumber == 26, "got \(String(describing: outlook.sunspotNumber))")
    check("sunspotObservationDate matches the 07-17 row", outlook.sunspotObservationDate == iso("2026-07-17T00:00:00Z"))
}

do {
    let outlook = SolarActivity.outlook(scales: quietScales, flares: [], sunspots: [], now: now)
    check("empty sunspot feed -> sunspotNumber nil, not a crash", outlook.sunspotNumber == nil)
}

// MARK: - Summary

print("\n\(passCount) passed, \(failCount) failed")
exit(failCount == 0 ? EXIT_SUCCESS : EXIT_FAILURE)
