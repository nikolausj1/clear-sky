import Foundation

// Smoke test for Sources/Sky/Aurora/*.swift. Build Guide engine-test recipe:
//   T=$(mktemp -d) && xattr -cr Sources && cp Tests/AuroraSmokeTest.swift "$T/main.swift" && \
//     swiftc -O Sources/Sky/Aurora/*.swift "$T/main.swift" -o "$T/t" && "$T/t"; rm -rf "$T"
//
// Two parts:
//  1. Live fetch of both NOAA SWPC endpoints through AuroraService (exercises real networking +
//     the on-disk cache path), with parse/range validation.
//  2. Canned-JSON unit checks of the pure AuroraLikelihood math (grid lookup, geomagnetic
//     latitude, Kp visibility table, combined outlook) -- no network involved.
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

// MARK: - Part 1: live fetch

print("=== Live fetch: OVATION + Kp forecast ===")

let liveCacheDir = FileManager.default.temporaryDirectory
    .appendingPathComponent("AuroraSmokeTestCache-\(UUID().uuidString)")
defer { try? FileManager.default.removeItem(at: liveCacheDir) }

let service = AuroraService()

do {
    let (grid, isStale) = try await service.fetchOvationGrid(cacheDirectory: liveCacheDir)
    check("OVATION live fetch succeeded", true)
    check("OVATION fresh fetch is not stale", !isStale, "isStale=\(isStale)")
    check("OVATION grid point count is 360x181=65160", grid.coordinates.count == 65160,
          "actual=\(grid.coordinates.count)")
    print("  Observation Time: \(grid.observationTime)  Forecast Time: \(grid.forecastTime)")
    print("  Data Format: \(grid.dataFormat)  type: \(grid.type)")
    print("  sample points: \(grid.coordinates.prefix(3))")
    print("  parsed observationDate: \(String(describing: grid.observationDate))")

    var allInRange = true
    var maxProb = -1
    var maxPoint: [Double] = []
    for c in grid.coordinates {
        guard c.count >= 3 else { allInRange = false; continue }
        let lon = c[0], lat = c[1], prob = c[2]
        if lon < 0 || lon > 359 || lat < -90 || lat > 90 || prob < 0 || prob > 100 {
            allInRange = false
        }
        if prob > Double(maxProb) {
            maxProb = Int(prob)
            maxPoint = c
        }
    }
    check("OVATION all points in range (lon 0-359, lat -90..90, prob 0-100)", allInRange)
    print("  brightest live point: \(maxPoint)")
    check("OVATION observationDate parses", grid.observationDate != nil)
    check("OVATION forecastDate parses", grid.forecastDate != nil)

    let indexed = AuroraLikelihood.IndexedGrid(grid: grid)
    check("OVATION indexed grid built without crashing", true)
    _ = AuroraLikelihood.lookup(in: indexed, lat: 43.98, lon: -90.50)
    check("OVATION live lookup at Tomah, WI does not crash", true)
} catch {
    check("OVATION live fetch succeeded", false, "\(error)")
}

do {
    let (rows, isStale) = try await service.fetchKpForecast(cacheDirectory: liveCacheDir)
    check("Kp forecast live fetch succeeded", true)
    check("Kp forecast fresh fetch is not stale", !isStale, "isStale=\(isStale)")
    check("Kp forecast has rows", !rows.isEmpty, "count=\(rows.count)")
    print("  first rows: \(rows.prefix(3).map { ($0.timeTag, $0.kp, $0.observed) })")
    print("  last rows: \(rows.suffix(3).map { ($0.timeTag, $0.kp, $0.observed) })")

    let allRangeOK = rows.allSatisfy { $0.kp >= 0 && $0.kp <= 9.5 }
    check("Kp forecast values in sane range (0...9.5)", allRangeOK)
    let allObservedOK = rows.allSatisfy { ["observed", "estimated", "predicted"].contains($0.observed) }
    check("Kp forecast 'observed' field is one of observed/estimated/predicted", allObservedOK)
    let allDatesParse = rows.allSatisfy { $0.date != nil }
    check("Kp forecast time_tag parses for every row", allDatesParse)
} catch {
    check("Kp forecast live fetch succeeded", false, "\(error)")
}

// MARK: - Part 2a: canned OVATION grid lookup

print("\n=== Canned grid lookup ===")

do {
    var table = Array(repeating: Array(repeating: 0, count: 181), count: 360)
    // Known hotspot cluster around lon=45, lat=65 (northern hemisphere aurora oval-ish region).
    table[45][65 + 90] = 87   // nearest point for a query at (65.4, 45.4)
    table[44][65 + 90] = 50
    table[47][66 + 90] = 95   // brightest point in the neighborhood, 2 deg away in both axes
    let grid = AuroraLikelihood.IndexedGrid(probabilityTable: table)

    let result = AuroraLikelihood.lookup(in: grid, lat: 65.4, lon: 45.4)
    check("nearest grid point rounds (65.4, 45.4) -> (65, 45)",
          result.nearestGridPoint.lat == 65 && result.nearestGridPoint.lon == 45,
          "got \(result.nearestGridPoint)")
    check("nearest probability reads the hotspot (87)", result.nearestProbability == 87,
          "got \(result.nearestProbability)")
    check("max-within-2deg finds the brighter neighbor (95)", result.maxNearbyProbability == 95,
          "got \(result.maxNearbyProbability)")
}

// Longitude wraparound at 0/359.
do {
    var table = Array(repeating: Array(repeating: 0, count: 181), count: 360)
    table[359][70 + 90] = 77   // hotspot just west of the seam
    table[0][70 + 90] = 3
    let grid = AuroraLikelihood.IndexedGrid(probabilityTable: table)

    let result = AuroraLikelihood.lookup(in: grid, lat: 70.0, lon: 0.4) // rounds to lon 0
    check("wraparound: nearest point is lon 0", result.nearestGridPoint.lon == 0,
          "got \(result.nearestGridPoint)")
    check("wraparound: nearest probability is the lon-0 value (3)", result.nearestProbability == 3,
          "got \(result.nearestProbability)")
    check("wraparound: max-within-2deg reaches across the seam to lon 359 (77)",
          result.maxNearbyProbability == 77, "got \(result.maxNearbyProbability)")

    // And the mirror case: querying right at the seam from the other side.
    let result2 = AuroraLikelihood.lookup(in: grid, lat: 70.0, lon: 359.6) // rounds to lon 0 (mod 360)
    check("wraparound: 359.6 rounds through the seam to grid lon 0",
          result2.nearestGridPoint.lon == 0, "got \(result2.nearestGridPoint)")
}

// MARK: - Part 2b: geomagnetic latitude + Kp visibility table

print("\n=== Canned geomagnetic latitude / Kp visibility ===")

let tomahLat = 43.98
let tomahLon = -90.50
let tomahGeomagLat = AuroraLikelihood.geomagneticLatitude(latitude: tomahLat, longitude: tomahLon)
print("  Tomah, WI geomagnetic latitude (dipole approx): \(tomahGeomagLat)")
check("Tomah geomagnetic latitude is HIGHER than geographic latitude (N. America dipole offset)",
      tomahGeomagLat > tomahLat, "geomag=\(tomahGeomagLat) geographic=\(tomahLat)")
check("Tomah geomagnetic latitude within ~2 deg of published ~53-54 N",
      abs(tomahGeomagLat - 53.5) <= 2.0, "got \(tomahGeomagLat)")

let miamiLat = 25.7617
let miamiLon = -80.1918
let miamiGeomagLat = AuroraLikelihood.geomagneticLatitude(latitude: miamiLat, longitude: miamiLon)
print("  Miami, FL geomagnetic latitude (dipole approx): \(miamiGeomagLat)")
check("Miami geomagnetic latitude is well south of any Kp0-9 visibility threshold",
      miamiGeomagLat < AuroraLikelihood.visibilityLatitude(forKp: 9),
      "geomag=\(miamiGeomagLat) kp9 threshold=\(AuroraLikelihood.visibilityLatitude(forKp: 9))")

check("Kp visibility table: Kp5 threshold matches published ~56.3 N",
      abs(AuroraLikelihood.visibilityLatitude(forKp: 5) - 56.3) < 0.01)
check("Kp visibility table: Kp7 threshold matches published ~52.2 N",
      abs(AuroraLikelihood.visibilityLatitude(forKp: 7) - 52.2) < 0.01)
let interpolated = AuroraLikelihood.visibilityLatitude(forKp: 6.67)
check("Kp visibility table: fractional Kp 6.67 interpolates between Kp6 (54.2) and Kp7 (52.2)",
      abs(interpolated - 52.86) < 0.01, "got \(interpolated)")

// MARK: - Part 2c: combined outlook -- Tomah, WI at Kp 6.67 tonight

print("\n=== Canned outlook: Tomah, WI, Kp 6.67 at 03:00 UTC ===")

do {
    // OVATION grid with ~no signal at Tomah's location, so the band below is driven purely by
    // the Kp/geomagnetic-latitude margin, not bumped up by a coincidentally bright OVATION read.
    var table = Array(repeating: Array(repeating: 0, count: 181), count: 360)
    table[270][44 + 90] = 2 // lon -90 -> 270; a low OVATION reading near Tomah
    let grid = AuroraLikelihood.IndexedGrid(probabilityTable: table)

    let kpForecast: [KpForecastRow] = [
        KpForecastRow(timeTag: "2026-01-14T21:00:00", kp: 3.0, observed: "estimated", noaaScale: nil),
        KpForecastRow(timeTag: "2026-01-15T00:00:00", kp: 4.0, observed: "estimated", noaaScale: nil),
        KpForecastRow(timeTag: "2026-01-15T03:00:00", kp: 6.67, observed: "predicted", noaaScale: "G1"),
        KpForecastRow(timeTag: "2026-01-15T06:00:00", kp: 5.0, observed: "predicted", noaaScale: nil),
        KpForecastRow(timeTag: "2026-01-15T09:00:00", kp: 2.0, observed: "predicted", noaaScale: nil),
    ]
    let darkStart = iso("2026-01-15T01:00:00Z")
    let darkEnd = iso("2026-01-15T09:00:00Z")

    let outlook = AuroraLikelihood.outlook(
        grid: grid,
        kpForecast: kpForecast,
        latitude: tomahLat,
        longitude: tomahLon,
        darkHoursStart: darkStart,
        darkHoursEnd: darkEnd
    )

    print("  outlook: \(outlook)")
    check("Tomah outlook: tonightPeakKp is 6.67 (the 03:00 bucket, not the 06:00 or earlier ones)",
          outlook.tonightPeakKp == 6.67, "got \(outlook.tonightPeakKp)")
    check("Tomah outlook: peak window starts at 03:00 UTC",
          outlook.tonightPeakKpWindow.start == iso("2026-01-15T03:00:00Z"),
          "got \(outlook.tonightPeakKpWindow.start)")
    check("Tomah outlook: peak window ends at 06:00 UTC",
          outlook.tonightPeakKpWindow.end == iso("2026-01-15T06:00:00Z"),
          "got \(outlook.tonightPeakKpWindow.end)")
    check("Tomah outlook: bestViewingWindow matches the peak window",
          outlook.bestViewingWindow == outlook.tonightPeakKpWindow)
    check("Tomah outlook: visibilityLatitudeThreshold matches Kp 6.67 interpolation (~52.86)",
          abs(outlook.visibilityLatitudeThreshold - 52.86) < 0.01, "got \(outlook.visibilityLatitudeThreshold)")
    // Hand computation: geomagLat(Tomah) ~52.75, threshold(6.67) ~52.86 -> margin ~ -0.11,
    // which falls in the [-3, 0) "near miss" bucket -> .low.
    let margin = outlook.geomagneticLatitude - outlook.visibilityLatitudeThreshold
    print("  hand-check margin = \(margin) (expect in [-3, 0) -> .low)")
    check("Tomah outlook band is .low (margin ~ -0.11, just south of the forecast oval edge)",
          outlook.band == .low, "got \(outlook.band), margin=\(margin)")
}

// MARK: - Part 2d: edge case -- Miami entirely below the oval at Kp 3

print("\n=== Canned outlook edge case: Miami, FL, Kp 3 ===")

do {
    let table = Array(repeating: Array(repeating: 0, count: 181), count: 360) // no OVATION signal
    let grid = AuroraLikelihood.IndexedGrid(probabilityTable: table)
    let kpForecast: [KpForecastRow] = [
        KpForecastRow(timeTag: "2026-01-15T03:00:00", kp: 3.0, observed: "predicted", noaaScale: nil),
    ]
    let darkStart = iso("2026-01-15T01:00:00Z")
    let darkEnd = iso("2026-01-15T09:00:00Z")

    let outlook = AuroraLikelihood.outlook(
        grid: grid,
        kpForecast: kpForecast,
        latitude: miamiLat,
        longitude: miamiLon,
        darkHoursStart: darkStart,
        darkHoursEnd: darkEnd
    )
    print("  outlook: \(outlook)")
    check("Miami at Kp3 is far south of the visibility threshold (margin << 0)",
          outlook.geomagneticLatitude - outlook.visibilityLatitudeThreshold < -20)
    check("Miami at Kp3 outlook band is .none", outlook.band == .none, "got \(outlook.band)")
}

// MARK: - Summary

print("\n\(passCount) passed, \(failCount) failed")
exit(failCount == 0 ? EXIT_SUCCESS : EXIT_FAILURE)
