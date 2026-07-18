import Foundation

// Multi-satellite visible-pass engine smoke test (Hubble, Tiangong, Starlink
// trains) -- extends the verified ISS/SGP4 stack without touching it.
//
// Build/run per the Build Guide engine-test recipe:
//   swiftc -O Sources/Sky/ISS/*.swift Tests/SatellitesSmokeTest.swift -o /tmp/t && /tmp/t
//
// (Run Tests/ISSSmokeTest.swift the same way, separately, to confirm no
// regression to the existing ISS-only engine -- this file does not embed
// it, to avoid top-level-global collisions between the two standalone CLI
// binaries.)
//
// Sections:
//   1. Canned, offline tests for Starlink name-filtering + launch-cluster
//      grouping (StarlinkClustering) -- deterministic, no network.
//   2. Live: fetch Hubble + Tiangong TLEs via SatelliteTLEFetcher,
//      propagate to "now", sanity-check altitude/speed.
//   3. Live: fetch the Celestrak "last 30 days" launch group, cluster
//      Starlink trains, report how many were found (0 is legitimate).
//   4. Pass-prediction plausibility for Tomah, WI (43.98, -90.50), for
//      each tracked satellite via SatellitesTonight.passes.
//
// Every check prints PASS/FAIL; a final summary reports overall status and
// the process exit code reflects it (0 = all green).

var failureCount = 0
var totalCount = 0

func record(_ ok: Bool, _ label: String) {
    totalCount += 1
    if !ok { failureCount += 1 }
    print("[\(ok ? "PASS" : "FAIL")] \(label)")
}

print("==================================================================")
print(" SECTION 1: Starlink name-filtering + launch-cluster grouping")
print("==================================================================")

// -- Name filtering --
record(StarlinkClustering.isStarlink(name: "STARLINK-31234"), "isStarlink: 'STARLINK-31234' recognized")
record(StarlinkClustering.isStarlink(name: "starlink-9"), "isStarlink: lowercase 'starlink-9' recognized (case-insensitive)")
record(!StarlinkClustering.isStarlink(name: "ISS (ZARYA)"), "isStarlink: 'ISS (ZARYA)' correctly rejected")
record(!StarlinkClustering.isStarlink(name: "STARLETTE"), "isStarlink: 'STARLETTE' correctly rejected (prefix, not exact match, but not 'STARLINK')")
record(!StarlinkClustering.isStarlink(name: "ONEWEB-0123"), "isStarlink: 'ONEWEB-0123' correctly rejected")

// -- Designator prefix extraction --
record(StarlinkClustering.designatorPrefix("24101AB") == "24101", "designatorPrefix('24101AB') == '24101'")
record(StarlinkClustering.designatorPrefix("98067A") == "98067", "designatorPrefix('98067A') == '98067' (ISS designator, sanity)")
record(StarlinkClustering.designatorPrefix("24001A") == "24001", "designatorPrefix('24001A') == '24001'")

// -- Clustering: two launches, one 3-satellite train + one 2-satellite train, plus a non-Starlink object mixed in --
let cannedInputs: [StarlinkClusterInput] = [
    StarlinkClusterInput(index: 0, name: "STARLINK-31001", satelliteNumber: 60001, internationalDesignator: "24101B"),
    StarlinkClusterInput(index: 1, name: "STARLINK-31002", satelliteNumber: 60002, internationalDesignator: "24101C"),
    StarlinkClusterInput(index: 2, name: "STARLINK-31000", satelliteNumber: 60000, internationalDesignator: "24101A"),
    StarlinkClusterInput(index: 3, name: "STARLINK-30500", satelliteNumber: 59500, internationalDesignator: "24090A"),
    StarlinkClusterInput(index: 4, name: "STARLINK-30501", satelliteNumber: 59501, internationalDesignator: "24090B"),
    StarlinkClusterInput(index: 5, name: "CZ-2D DEB", satelliteNumber: 61000, internationalDesignator: "24095C"),
]
let cannedClusters = StarlinkClustering.cluster(cannedInputs)
record(cannedClusters.count == 2, "cluster(): 6 mixed inputs (2 Starlink launches + 1 debris) yield exactly 2 clusters, got \(cannedClusters.count)")

if let train24101 = cannedClusters.first(where: { $0.launchDesignatorPrefix == "24101" }) {
    record(train24101.memberCount == 3, "cluster(): '24101' train has 3 members, got \(train24101.memberCount)")
    record(train24101.leadIndex == 2, "cluster(): '24101' train lead is lowest catalog number (index 2, satnum 60000), got index \(train24101.leadIndex)")
} else {
    record(false, "cluster(): expected a '24101' cluster, none found")
}

if let train24090 = cannedClusters.first(where: { $0.launchDesignatorPrefix == "24090" }) {
    record(train24090.memberCount == 2, "cluster(): '24090' train has 2 members, got \(train24090.memberCount)")
    record(train24090.leadIndex == 3, "cluster(): '24090' train lead is lowest catalog number (index 3, satnum 59500), got index \(train24090.leadIndex)")
} else {
    record(false, "cluster(): expected a '24090' cluster, none found")
}

// -- Empty input is a legitimate, non-crashing "0 clusters" answer --
let emptyClusters = StarlinkClustering.cluster([])
record(emptyClusters.isEmpty, "cluster(): empty input yields 0 clusters (no crash)")

let noStarlinksInputs: [StarlinkClusterInput] = [
    StarlinkClusterInput(index: 0, name: "CZ-2D DEB", satelliteNumber: 61000, internationalDesignator: "24095C"),
    StarlinkClusterInput(index: 1, name: "ONEWEB-0500", satelliteNumber: 61001, internationalDesignator: "24096A"),
]
let noStarlinksClusters = StarlinkClustering.cluster(noStarlinksInputs)
record(noStarlinksClusters.isEmpty, "cluster(): input with zero Starlink-named entries yields 0 clusters")

// -- parse3LE: robust 3-line-block parsing (name/line1/line2), including CRLF-ish and blank-line noise --
let sample3LE = """
STARLINK-31000
1 60000U 24101A   26198.50000000  .00001234  00000-0  12345-3 0  9991
2 60000  53.0500 100.0000 0001000  90.0000 270.0000 15.06000000    12

STARLINK-31001
1 60001U 24101B   26198.50000000  .00001234  00000-0  12345-3 0  9992
2 60001  53.0500 100.1000 0001000  91.0000 269.0000 15.06000000    13
"""
let parsed = SatelliteTLEFetcher.parse3LE(text: sample3LE)
record(parsed.count == 2, "parse3LE: parses 2 name/TLE blocks from sample text, got \(parsed.count)")
record(parsed.first?.name == "STARLINK-31000", "parse3LE: first entry name is 'STARLINK-31000'")
record(parsed.last?.line2.hasPrefix("2 60001") == true, "parse3LE: second entry line2 starts with '2 60001'")

print("")
print("==================================================================")
print(" SECTION 2: Live sanity check (Hubble + Tiangong TLEs from Celestrak)")
print("==================================================================")

let cacheDir = FileManager.default.temporaryDirectory.appendingPathComponent("satellites-sgp4-smoketest-cache")
let satFetcher = SatelliteTLEFetcher(cacheDirectory: cacheDir)
let now = Date()
let earthRadiusKm = 6378.135

struct LiveSatellite {
    let tracked: TrackedSatellite
    let tle: TLE
}

var liveSatellites: [LiveSatellite] = []

for tracked in SatelliteCatalog.fixed {
    do {
        let result = try satFetcher.fetch(catalogNumber: tracked.catalogNumber, now: now)
        print("  Fetched \(tracked.name) (CATNR \(tracked.catalogNumber)) TLE via \(result.source.rawValue)\(result.isDegraded ? " (DEGRADED - stale cache)" : "")")
        print("    \(result.tle.line1)")
        print("    \(result.tle.line2)")
        record(true, "SatelliteTLEFetcher: obtained a live/cached TLE for \(tracked.name)")
        liveSatellites.append(LiveSatellite(tracked: tracked, tle: result.tle))
    } catch {
        record(false, "SatelliteTLEFetcher: failed to obtain TLE for \(tracked.name): \(error)")
    }
}

for live in liveSatellites {
    do {
        let prop = try SGP4Propagator(tle: live.tle)
        let tsince = live.tle.minutesSinceEpoch(at: now)
        let state = try prop.propagate(minutesSinceEpoch: tsince)
        let altitudeKm = state.position.magnitude - earthRadiusKm
        let speedKmS = state.velocity.magnitude
        print("  \(live.tracked.name): tsince=\(String(format: "%.2f", tsince)) min, altitude=\(String(format: "%.2f", altitudeKm)) km, speed=\(String(format: "%.4f", speedKmS)) km/s")

        switch live.tracked.kind {
        case .hubble:
            // Hubble has not been reboosted since its last servicing mission
            // (2009) and continues to decay, with the decay rate rising and
            // falling with the solar cycle's effect on atmospheric drag; a
            // wide band is used deliberately rather than the often-quoted
            // "~515-540 km" textbook figure, which is now stale.
            record(altitudeKm > 400 && altitudeKm < 570, "Hubble altitude \(String(format: "%.1f", altitudeKm)) km is in plausible range (400-570 km; historical nominal ~515-540 km, but the orbit has continued decaying since the 2009 servicing mission)")
            record(speedKmS > 7.3 && speedKmS < 7.7, "Hubble speed \(String(format: "%.4f", speedKmS)) km/s is in plausible range (7.3-7.7 km/s)")
        case .tiangong:
            record(altitudeKm > 350 && altitudeKm < 420, "Tiangong altitude \(String(format: "%.1f", altitudeKm)) km is in plausible range (350-420 km; nominal ~370-400 km)")
            record(speedKmS > 7.5 && speedKmS < 7.9, "Tiangong speed \(String(format: "%.4f", speedKmS)) km/s is in plausible range (7.5-7.9 km/s)")
        case .iss:
            record(altitudeKm > 300 && altitudeKm < 500, "ISS altitude \(String(format: "%.1f", altitudeKm)) km is in plausible range (300-500 km)")
            record(speedKmS > 7.4 && speedKmS < 7.9, "ISS speed \(String(format: "%.4f", speedKmS)) km/s is in plausible range (7.4-7.9 km/s)")
        case .starlinkTrain:
            break
        }
    } catch {
        record(false, "\(live.tracked.name): propagation to now threw \(error)")
    }
}

print("")
print("==================================================================")
print(" SECTION 3: Live sanity check (Celestrak 'last 30 days' group -> Starlink trains)")
print("==================================================================")

var starlinkTrains: [(satellite: TrackedSatellite, tle: TLE)] = []
do {
    let group = try satFetcher.fetchLast30DaysGroup(now: now)
    print("  Fetched last-30-days group via \(group.source.rawValue)\(group.isDegraded ? " (DEGRADED - stale cache)" : ""): \(group.entries.count) total tracked objects")
    record(true, "SatelliteTLEFetcher: obtained the last-30-days launch group")

    let starlinkNamedCount = group.entries.filter { StarlinkClustering.isStarlink(name: $0.name) }.count
    starlinkTrains = SatelliteCatalog.starlinkTrains(fromLast30DaysGroup: group.entries)
    print("  \(starlinkNamedCount) individual Starlink-named object(s) in the group")
    print("  Clustered into \(starlinkTrains.count) Starlink train(s):")
    for (sat, tle) in starlinkTrains {
        print("    - \(sat.name): lead CATNR \(tle.satelliteNumber), \(sat.memberCount) member(s)")
    }
    // 0 clusters is a legitimate answer in months with no recent Starlink
    // launches (or if Celestrak hasn't named the objects yet) -- the only
    // failure mode we actually check for is "did the fetch/cluster pipeline
    // run without crashing and produce a sane (non-negative, bounded) count".
    record(starlinkTrains.count >= 0 && starlinkTrains.count <= starlinkNamedCount, "Starlink train count (\(starlinkTrains.count)) is sane relative to named Starlink object count (\(starlinkNamedCount))")
} catch {
    record(false, "SatelliteTLEFetcher: failed to obtain last-30-days group: \(error)")
}

print("")
print("==================================================================")
print(" SECTION 4: Pass-prediction plausibility, Tomah, WI (43.98, -90.50)")
print("==================================================================")

var allTracked: [(satellite: TrackedSatellite, tle: TLE)] = liveSatellites.map { ($0.tracked, $0.tle) }
allTracked.append(contentsOf: starlinkTrains)

if allTracked.isEmpty {
    print("  SKIPPED (no live TLEs available)")
} else {
    do {
        let windowStart = now
        let windowEnd = now.addingTimeInterval(48 * 3600)
        let allPasses = try SatellitesTonight.passes(
            satellites: allTracked,
            windowStart: windowStart,
            windowEnd: windowEnd,
            latitudeDeg: 43.98,
            longitudeDeg: -90.50
        )
        print("  Search window: \(windowStart) .. \(windowEnd) (48h from now)")
        print("  Found \(allPasses.count) visible pass(es) across \(allTracked.count) tracked satellite(s).")
        record(true, "SatellitesTonight.passes: multi-satellite search completed without throwing")

        // Sorted by start time.
        let sortedCorrectly = zip(allPasses, allPasses.dropFirst()).allSatisfy { $0.pass.startTime <= $1.pass.startTime }
        record(sortedCorrectly, "SatellitesTonight.passes: results are sorted by start time")

        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm:ss"
        df.timeZone = TimeZone(identifier: "America/Chicago")

        for (idx, sp) in allPasses.enumerated() {
            let p = sp.pass
            let durationSec = p.endTime.timeIntervalSince(p.startTime)
            print("""
              Pass \(idx + 1) [\(sp.satellite.name)]: \(df.string(from: p.startTime)) CT start (\(p.startAzimuthCompass)) -> \
            peak \(df.string(from: p.peakTime)) CT alt=\(String(format: "%.1f", p.peakAltitudeDeg))deg range=\(String(format: "%.0f", p.peakRangeKm))km -> \
            end \(df.string(from: p.endTime)) CT (\(p.endAzimuthCompass)); duration=\(String(format: "%.0f", durationSec))s; brightness=\(p.brightness.rawValue)
            """)
            // A pass that only barely clears the 10deg visibility floor can
            // legitimately last just a few seconds (a brief graze near the
            // horizon), so the lower bound here is intentionally generous
            // rather than assuming every pass is a multi-minute overhead
            // arc like the ISS's brightest passes.
            record(durationSec >= 5 && durationSec <= 600, "Pass \(idx + 1) [\(sp.satellite.name)] duration \(String(format: "%.0f", durationSec))s is in plausible range (5s-10min)")
            record(p.peakAltitudeDeg > 10 && p.peakAltitudeDeg <= 90, "Pass \(idx + 1) [\(sp.satellite.name)] peak altitude \(String(format: "%.1f", p.peakAltitudeDeg))deg is in plausible range (10-90 deg)")
        }

        // Per-satellite pass count sanity, mirroring ISSSmokeTest's "0-6 over 48h" bound.
        for tracked in liveSatellites.map({ $0.tracked }) {
            let count = allPasses.filter { $0.satellite.catalogNumber == tracked.catalogNumber }.count
            record(count >= 0 && count <= 6, "\(tracked.name) pass count \(count) over 48h is in plausible range (0-6)")
        }
    } catch {
        record(false, "Multi-satellite pass prediction for Tomah WI: threw \(error)")
    }
}

print("")
print("==================================================================")
print(" SUMMARY: \(totalCount - failureCount)/\(totalCount) checks passed")
print("==================================================================")
if failureCount > 0 {
    print(" OVERALL: FAIL (\(failureCount) failing check(s))")
    exit(1)
} else {
    print(" OVERALL: PASS")
}
