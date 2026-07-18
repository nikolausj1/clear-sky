import Foundation

// Smoke test for Sources/Sky/Launches/*.swift. Build Guide engine-test recipe:
//   T=$(mktemp -d) && xattr -cr Sources && cp Tests/LaunchesSmokeTest.swift "$T/main.swift" && \
//     swiftc -O Sources/Sky/Launches/*.swift "$T/main.swift" -o "$T/t" && "$T/t"; rm -rf "$T"
//
// Three parts:
//  1. ONE live fetch against the real Launch Library 2 endpoint. `LaunchService` respects the
//     anonymous tier's ~15 req/hour limit; this harness makes exactly one network call, full
//     stop, and reuses its result for every live-data assertion below (subsequent calls in this
//     same process would hit the fresh in-memory... actually on-disk cache anyway, but we don't
//     even call it twice).
//  2. Canned-struct unit tests of the pure `LaunchSchedule` logic: status-tier mapping, T-0
//     precision flag, provider abbreviation, location-display heuristic, crewed heuristic, full
//     wire->app mapping, past-launch/status filtering, and day grouping -- no network at all.
//  3. Cache-behavior tests against a mock `URLProtocol` (no real network access): fresh cache ->
//     network never touched; stale cache + simulated HTTP 429 -> stale cache used as a fallback
//     (and the network WAS attempted, proving the fresh-cache short-circuit isn't masking a bug);
//     no cache + 429 -> throws instead of crashing; single-flight -> two concurrent fetches
//     against an empty cache issue exactly one network request.
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

/// Builds a canned `LL2Launch` fixture without going through JSON, for the pure-logic tests in
/// Part 2. Every wire model here is a plain `Codable` struct with no custom `init`, so Swift's
/// synthesized memberwise initializer is available directly.
func makeLaunch(
    id: String,
    name: String = "Test Mission",
    statusID: Int,
    net: String,
    precisionAbbrev: String? = "MIN",
    providerName: String? = "SpaceX",
    vehicleName: String = "Falcon 9",
    vehicleFullName: String = "Falcon 9 Block 5",
    missionName: String? = "Test Mission",
    missionType: String? = "Communications",
    padName: String? = "SLC-40",
    locationName: String? = "Cape Canaveral SFS, FL, USA",
    webcastLive: Bool = false,
    image: String? = nil
) -> LL2Launch {
    LL2Launch(
        id: id,
        name: name,
        status: LL2Status(id: statusID, name: "status-\(statusID)", abbrev: "S\(statusID)"),
        net: net,
        netPrecision: precisionAbbrev.map { LL2Precision(id: 1, name: "precision", abbrev: $0) },
        launchServiceProvider: providerName.map { LL2Agency(id: 1, name: $0, type: "Private") },
        rocket: LL2Rocket(configuration: LL2RocketConfiguration(id: 1, name: vehicleName, fullName: vehicleFullName)),
        mission: missionName.map { LL2Mission(name: $0, description: "test mission description", type: missionType) },
        pad: padName.map {
            LL2Pad(name: $0, latitude: "28.5", longitude: "-80.6",
                   location: LL2Location(name: locationName ?? "Unknown, USA", countryCode: "USA"))
        },
        webcastLive: webcastLive,
        image: image
    )
}

/// One-launch canned LL2 `/launch/upcoming/` page, matching the real wire shape, used by the
/// cache-behavior tests in Part 3 (which need actual JSON to feed through a mock `URLProtocol`
/// and to write as a cache-envelope payload).
let cannedJSON: Data = """
{
  "count": 1,
  "next": null,
  "previous": null,
  "results": [
    {
      "id": "canned-1",
      "name": "Canned Test Mission",
      "status": {"id": 1, "name": "Go for Launch", "abbrev": "Go", "description": ""},
      "net": "2026-08-01T12:00:00Z",
      "net_precision": {"id": 1, "name": "Minute", "abbrev": "MIN", "description": ""},
      "launch_service_provider": {"id": 1, "url": "https://example.com/1", "name": "SpaceX", "type": "Private"},
      "rocket": {"id": 1, "configuration": {"id": 1, "url": "https://example.com/r1", "name": "Falcon 9", "family": "Falcon", "full_name": "Falcon 9 Block 5", "variant": ""}},
      "mission": {"id": 1, "name": "Canned Test Mission", "description": "A canned fixture.", "launch_designator": null, "type": "Communications", "orbit": {"id": 1, "name": "Low Earth Orbit", "abbrev": "LEO"}, "agencies": [], "info_urls": [], "vid_urls": []},
      "pad": {"id": 1, "url": "https://example.com/p1", "name": "Space Launch Complex 40", "latitude": "28.56194122", "longitude": "-80.57735736", "location": {"id": 1, "name": "Cape Canaveral SFS, FL, USA", "country_code": "USA"}},
      "webcast_live": false,
      "image": "https://example.com/image.jpg"
    }
  ]
}
""".data(using: .utf8)!

// MARK: - Part 1: ONE live fetch

print("=== Live fetch: LL2 upcoming launches (single network call for this whole harness) ===")

let liveCacheDir = FileManager.default.temporaryDirectory
    .appendingPathComponent("LaunchesSmokeTestCache-\(UUID().uuidString)")
defer { try? FileManager.default.removeItem(at: liveCacheDir) }

do {
    let result = try await LaunchesUpcoming.fetch(cacheDirectory: liveCacheDir)
    check("live fetch succeeded", true)
    check("live fetch is not stale", !result.isStale, "isStale=\(result.isStale)")
    check("live fetch parsed at least one launch", !result.launches.isEmpty, "count=\(result.launches.count)")
    print("  parsed \(result.launches.count) launches")

    let now = Date()
    let oneYearOut = now.addingTimeInterval(366 * 86400)
    let allDatesSane = result.launches.allSatisfy { $0.net <= oneYearOut }
    let allProvidersNonEmpty = result.launches.allSatisfy { !$0.provider.trimmingCharacters(in: .whitespaces).isEmpty }
    check("all live T-0 dates are within ~1 year of now", allDatesSane)
    check("all live launches have a non-empty provider", allProvidersNonEmpty)

    print("  first 5 live launches:")
    for l in result.launches.prefix(5) {
        print("    \(l.missionName) | \(l.providerAbbrev) | \(l.vehicle) | T-0 \(l.net) (\(l.netPrecision)) | \(l.status) | \(l.locationDisplay)")
    }
} catch {
    check("live fetch succeeded", false, "\(error)")
}

// MARK: - Part 2a: canned status-id mapping

print("\n=== Canned: status-id mapping ===")

check("status id 1 (Go) simplifies to .go", LaunchStatusMapping.simplified(statusID: 1) == .go)
check("status id 2 (TBD) simplifies to .tbd", LaunchStatusMapping.simplified(statusID: 2) == .tbd)
check("status id 5 (Hold) simplifies to .hold", LaunchStatusMapping.simplified(statusID: 5) == .hold)
check("status id 8 (TBC) simplifies to .tbd", LaunchStatusMapping.simplified(statusID: 8) == .tbd)
check("unknown status id conservatively simplifies to .tbd", LaunchStatusMapping.simplified(statusID: 999) == .tbd)

check("status id 3 (Success) counts as flown", LaunchStatusMapping.isFlown(statusID: 3))
check("status id 4 (Failure) counts as flown", LaunchStatusMapping.isFlown(statusID: 4))
check("status id 6 (In Flight) counts as flown", LaunchStatusMapping.isFlown(statusID: 6))
check("status id 7 (Partial Failure) counts as flown", LaunchStatusMapping.isFlown(statusID: 7))
check("status id 1 (Go) does NOT count as flown", !LaunchStatusMapping.isFlown(statusID: 1))
check("status id 2 (TBD) does NOT count as flown", !LaunchStatusMapping.isFlown(statusID: 2))
check("status id 5 (Hold) does NOT count as flown", !LaunchStatusMapping.isFlown(statusID: 5))
check("status id 8 (TBC) does NOT count as flown", !LaunchStatusMapping.isFlown(statusID: 8))

// MARK: - Part 2b: canned T-0 precision flag

print("\n=== Canned: T-0 precision flag ===")

check("MIN -> .exact", LaunchTimePrecision.from(abbrev: "MIN") == .exact)
check("HR -> .approximate", LaunchTimePrecision.from(abbrev: "HR") == .approximate)
check("M (month bucket) -> .approximate", LaunchTimePrecision.from(abbrev: "M") == .approximate)
check("nil precision -> .approximate", LaunchTimePrecision.from(abbrev: nil) == .approximate)

// MARK: - Part 2c: canned provider abbreviation

print("\n=== Canned: provider abbreviation ===")

check("SpaceX stays SpaceX", LaunchSchedule.providerAbbrev(for: "SpaceX") == "SpaceX")
check("NASA long form abbreviates",
      LaunchSchedule.providerAbbrev(for: "National Aeronautics and Space Administration") == "NASA")
check("ULA long form abbreviates",
      LaunchSchedule.providerAbbrev(for: "United Launch Alliance") == "ULA")
check("Blue Origin stays Blue Origin", LaunchSchedule.providerAbbrev(for: "Blue Origin") == "Blue Origin")
check("Rocket Lab stays Rocket Lab", LaunchSchedule.providerAbbrev(for: "Rocket Lab") == "Rocket Lab")
check("Arianespace stays Arianespace", LaunchSchedule.providerAbbrev(for: "Arianespace") == "Arianespace")
check("unrecognized provider passes through unchanged ('others as-is')",
      LaunchSchedule.providerAbbrev(for: "Skyroot Aerospace") == "Skyroot Aerospace")

// MARK: - Part 2d: canned location-display heuristic

print("\n=== Canned: location display heuristic ===")

check("'Vandenberg SFB, CA, USA' -> 'Vandenberg, CA'",
      LaunchSchedule.locationDisplay(fromLocationName: "Vandenberg SFB, CA, USA") == "Vandenberg, CA")
check("'Cape Canaveral SFS, FL, USA' -> 'Cape Canaveral, FL'",
      LaunchSchedule.locationDisplay(fromLocationName: "Cape Canaveral SFS, FL, USA") == "Cape Canaveral, FL")
check("'SpaceX Starbase, TX, USA' -> 'SpaceX Starbase, TX' (no base-suffix to strip)",
      LaunchSchedule.locationDisplay(fromLocationName: "SpaceX Starbase, TX, USA") == "SpaceX Starbase, TX")
check("2-part 'site, country' stays as-is (country already short)",
      LaunchSchedule.locationDisplay(fromLocationName: "Satish Dhawan Space Centre, India") == "Satish Dhawan Space Centre, India")
check("3-part non-US-state middle drops the specific pad name for 'region, country'",
      LaunchSchedule.locationDisplay(fromLocationName: "Rocket Lab Launch Complex 1, Mahia Peninsula, New Zealand")
        == "Mahia Peninsula, New Zealand")
check("long-form country name is shortened ('People's Republic of China' -> 'China')",
      LaunchSchedule.locationDisplay(fromLocationName: "Xichang Satellite Launch Center, People's Republic of China")
        == "Xichang Satellite Launch Center, China")
check("single-part location name (no comma) passes through unchanged",
      LaunchSchedule.locationDisplay(fromLocationName: "Haiyang Oriental Spaceport") == "Haiyang Oriental Spaceport")

// MARK: - Part 2e: canned crewed heuristic

print("\n=== Canned: crewed heuristic ===")

check("mission name containing 'Crew' -> true",
      LaunchSchedule.isCrewedHeuristic(missionName: "Crew-12", missionType: "Human Exploration"))
check("mission type containing 'crew' case-insensitively -> true",
      LaunchSchedule.isCrewedHeuristic(missionName: "Rotation Flight 12", missionType: "CREW ROTATION"))
check("neither field mentions crew -> false (documented best-effort limitation)",
      !LaunchSchedule.isCrewedHeuristic(missionName: "Starliner Flight Test", missionType: "Human Exploration"))
check("nil mission fields -> false, no crash",
      !LaunchSchedule.isCrewedHeuristic(missionName: nil, missionType: nil))

// MARK: - Part 2f: canned full wire -> app mapping

print("\n=== Canned: full wire -> app mapping ===")

do {
    let full = makeLaunch(id: "full-1", statusID: 1, net: "2026-08-01T12:00:00Z")
    if let mapped = LaunchSchedule.map(full) {
        check("full mapping produced a launch", true)
        check("mapped id matches", mapped.id == "full-1")
        check("mapped missionName uses mission.name", mapped.missionName == "Test Mission")
        check("mapped provider is SpaceX", mapped.provider == "SpaceX")
        check("mapped providerAbbrev is SpaceX", mapped.providerAbbrev == "SpaceX")
        check("mapped vehicle uses configuration.full_name", mapped.vehicle == "Falcon 9 Block 5")
        check("mapped locationDisplay applies the location heuristic", mapped.locationDisplay == "Cape Canaveral, FL")
        check("mapped status is .go", mapped.status == .go)
        check("mapped netPrecision is .exact", mapped.netPrecision == .exact)
        check("mapped net date matches the wire net", mapped.net == iso("2026-08-01T12:00:00Z"))
        check("mapped isCrewed is false (no crew mention)", !mapped.isCrewed)
        check("mapped webcastLive matches wire value", mapped.webcastLive == false)
    } else {
        check("full mapping produced a launch", false)
    }
}

do {
    // Missing mission/provider/pad/precision -> falls back to defaults rather than dropping the
    // whole launch (only an unparsable `net` should drop a launch -- see below).
    let sparse = makeLaunch(
        id: "sparse-1", statusID: 2, net: "2026-09-01T00:00:00Z",
        precisionAbbrev: nil, providerName: nil, missionName: nil, missionType: nil,
        padName: nil, locationName: nil
    )
    if let mapped = LaunchSchedule.map(sparse) {
        check("sparse mapping produced a launch", true)
        check("sparse missionName falls back to launch.name", mapped.missionName == "Test Mission")
        check("sparse provider falls back to a placeholder", mapped.provider == "Unknown provider")
        check("sparse padName falls back to a placeholder", mapped.padName == "Unknown pad")
        check("sparse locationDisplay falls back to a placeholder", mapped.locationDisplay == "Unknown location")
        check("sparse netPrecision defaults to .approximate when net_precision is missing",
              mapped.netPrecision == .approximate)
        check("sparse status is .tbd", mapped.status == .tbd)
    } else {
        check("sparse mapping produced a launch", false)
    }
}

do {
    // An unparsable `net` date is the one case that should drop the launch entirely.
    let bad = makeLaunch(id: "bad-net", statusID: 1, net: "not-a-date")
    check("unparsable net date -> map returns nil (launch dropped, not crashed)", LaunchSchedule.map(bad) == nil)
}

// MARK: - Part 2g: canned past-launch / status filtering

print("\n=== Canned: nextLaunches past-launch + status filtering ===")

do {
    let now = iso("2026-07-17T12:00:00Z")
    let raw: [LL2Launch] = [
        makeLaunch(id: "future-go", statusID: 1, net: "2026-07-20T00:00:00Z"),
        makeLaunch(id: "past-success", statusID: 3, net: "2026-07-10T00:00:00Z"),        // flown + past
        makeLaunch(id: "past-net-but-go", statusID: 1, net: "2026-07-01T00:00:00Z"),      // Go, but T-0 passed
        makeLaunch(id: "in-flight-future-net", statusID: 6, net: "2026-07-25T00:00:00Z"), // flown status, future net
        makeLaunch(id: "future-tbd", statusID: 2, net: "2026-07-22T00:00:00Z"),
        makeLaunch(id: "future-hold", statusID: 5, net: "2026-07-21T00:00:00Z"),
    ]

    let next = LaunchSchedule.nextLaunches(from: raw, now: now, count: 10)
    let ids = next.map(\.id)
    print("  nextLaunches ids in order: \(ids)")

    check("excludes a flown-status launch even though its net is in the past", !ids.contains("past-success"))
    check("excludes a flown-status launch even though its net is in the FUTURE (In Flight)",
          !ids.contains("in-flight-future-net"))
    check("excludes a Go-status launch whose T-0 has already passed", !ids.contains("past-net-but-go"))
    check("includes the future Go launch", ids.contains("future-go"))
    check("includes the future TBD launch", ids.contains("future-tbd"))
    check("includes the future Hold launch", ids.contains("future-hold"))
    check("result is sorted chronologically", ids == ["future-go", "future-hold", "future-tbd"], "got \(ids)")

    let limited = LaunchSchedule.nextLaunches(from: raw, now: now, count: 2)
    check("count parameter trims the result", limited.count == 2, "got \(limited.count)")
    check("count-trimmed result keeps the earliest launches",
          limited.map(\.id) == ["future-go", "future-hold"], "got \(limited.map(\.id))")
}

// MARK: - Part 2h: canned day grouping

print("\n=== Canned: launchesByDay grouping ===")

do {
    let utc = TimeZone(identifier: "UTC")!
    let launches = [
        LaunchSchedule.map(makeLaunch(id: "day1-late", statusID: 1, net: "2026-07-20T23:00:00Z"))!,
        LaunchSchedule.map(makeLaunch(id: "day1-early", statusID: 1, net: "2026-07-20T01:00:00Z"))!,
        LaunchSchedule.map(makeLaunch(id: "day2-only", statusID: 1, net: "2026-07-21T05:00:00Z"))!,
    ]
    let grouped = LaunchSchedule.launchesByDay(launches, timeZone: utc)
    check("groups into 2 distinct calendar days", grouped.count == 2, "got \(grouped.count)")
    if grouped.count == 2 {
        check("days are sorted ascending", grouped[0].day < grouped[1].day)
        check("day 1 has both same-day launches, sorted chronologically within the day",
              grouped[0].launches.map(\.id) == ["day1-early", "day1-late"], "got \(grouped[0].launches.map(\.id))")
        check("day 2 has the one remaining launch", grouped[1].launches.map(\.id) == ["day2-only"])
    }
}

// MARK: - Part 3: cache-behavior tests via mock URLProtocol (no real network access)

/// Always fails immediately. Used to prove a code path never actually attempts a network request.
final class FailingURLProtocol: URLProtocol {
    static var wasCalled = false
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        FailingURLProtocol.wasCalled = true
        client?.urlProtocol(self, didFailWithError: NSError(domain: "LaunchesSmokeTest", code: -1))
    }
    override func stopLoading() {}
}

/// Always responds HTTP 429 with an empty body. Used to exercise the rate-limit fallback path.
final class RateLimitedURLProtocol: URLProtocol {
    static var callCount = 0
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        RateLimitedURLProtocol.callCount += 1
        let response = HTTPURLResponse(url: request.url!, statusCode: 429, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data())
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

/// Always responds HTTP 200 with `responseData`, counting how many times it was invoked. Used for
/// the single-flight test.
final class CountingSuccessURLProtocol: URLProtocol {
    static var callCount = 0
    static var responseData = Data()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        CountingSuccessURLProtocol.callCount += 1
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: CountingSuccessURLProtocol.responseData)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

/// Mirrors `LaunchService`'s private on-disk cache-envelope shape (`fetchedAt` + `payload`, plain
/// `Codable` synthesis, `.iso8601` date strategy) so this test can write a cache file that
/// `LaunchService` will read back, without that type being exposed outside `LaunchService.swift`.
struct TestCacheEnvelope: Codable {
    let fetchedAt: Date
    let payload: LL2UpcomingLaunchesResponse
}

/// Must match `LaunchService`'s private `cacheFileName` exactly (documented in
/// `LaunchService.swift`'s cache-envelope section).
let ll2CacheFileName = "ll2_launch_upcoming_cache.json"

func writeCacheEnvelope(fetchedAt: Date, payload: LL2UpcomingLaunchesResponse, to directory: URL) throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let data = try encoder.encode(TestCacheEnvelope(fetchedAt: fetchedAt, payload: payload))
    try data.write(to: directory.appendingPathComponent(ll2CacheFileName))
}

print("\n=== Cache behavior: fresh cache skips the network entirely ===")

do {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("LaunchesSmokeTestCache-fresh-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }

    let now = iso("2026-07-17T12:00:00Z")
    let canned = try JSONDecoder().decode(LL2UpcomingLaunchesResponse.self, from: cannedJSON)
    try writeCacheEnvelope(fetchedAt: now.addingTimeInterval(-60 * 60), payload: canned, to: dir) // 1h old: fresh

    FailingURLProtocol.wasCalled = false
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [FailingURLProtocol.self]
    let session = URLSession(configuration: config)

    let service = LaunchService(session: session)
    let (response, isStale) = try await service.fetchUpcomingLaunches(cacheDirectory: dir, now: now)

    check("fresh cache: the network protocol was never invoked", !FailingURLProtocol.wasCalled)
    check("fresh cache: isStale is false", !isStale)
    check("fresh cache: returned the cached payload", response.results.first?.id == canned.results.first?.id)
} catch {
    check("fresh cache test ran without throwing", false, "\(error)")
}

print("\n=== Cache behavior: stale cache + HTTP 429 falls back rather than crashing ===")

do {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("LaunchesSmokeTestCache-stale-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }

    let now = iso("2026-07-17T12:00:00Z")
    let canned = try JSONDecoder().decode(LL2UpcomingLaunchesResponse.self, from: cannedJSON)
    // 10h old: past the 6h fresh window, well within the 48h stale-usable window.
    try writeCacheEnvelope(fetchedAt: now.addingTimeInterval(-10 * 60 * 60), payload: canned, to: dir)

    RateLimitedURLProtocol.callCount = 0
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [RateLimitedURLProtocol.self]
    let session = URLSession(configuration: config)

    let service = LaunchService(session: session)
    let (response, isStale) = try await service.fetchUpcomingLaunches(cacheDirectory: dir, now: now)

    check("stale-cache path: the network WAS attempted (cache wasn't fresh)",
          RateLimitedURLProtocol.callCount == 1, "callCount=\(RateLimitedURLProtocol.callCount)")
    check("HTTP 429 does not throw -- falls back to the stale cache", true)
    check("stale-cache path: isStale is true", isStale)
    check("stale-cache path: returned the cached payload", response.results.first?.id == canned.results.first?.id)
} catch {
    check("HTTP 429 does not throw -- falls back to the stale cache", false, "unexpectedly threw: \(error)")
}

print("\n=== Cache behavior: no cache at all + HTTP 429 throws instead of crashing ===")

do {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("LaunchesSmokeTestCache-nocache-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    // Deliberately do not create the directory or write any cache file.

    RateLimitedURLProtocol.callCount = 0
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [RateLimitedURLProtocol.self]
    let session = URLSession(configuration: config)
    let service = LaunchService(session: session)

    do {
        _ = try await service.fetchUpcomingLaunches(cacheDirectory: dir, now: iso("2026-07-17T12:00:00Z"))
        check("no cache + 429 throws rather than returning a bogus result", false, "expected an error, got a result")
    } catch {
        check("no cache + 429 throws rather than returning a bogus result", true)
        print("  threw as expected: \(error)")
    }
}

print("\n=== Cache behavior: single-flight -- two concurrent fetches issue exactly one network call ===")

do {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("LaunchesSmokeTestCache-singleflight-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    // No cache present, so both concurrent callers must go through the network path -- but the
    // single-flight guard means only one of them should actually issue a request.

    CountingSuccessURLProtocol.callCount = 0
    CountingSuccessURLProtocol.responseData = cannedJSON
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [CountingSuccessURLProtocol.self]
    let session = URLSession(configuration: config)
    let service = LaunchService(session: session)
    let now = iso("2026-07-17T12:00:00Z")

    async let first = service.fetchUpcomingLaunches(cacheDirectory: dir, now: now)
    async let second = service.fetchUpcomingLaunches(cacheDirectory: dir, now: now)
    let (r1, r2) = try await (first, second)

    check("single-flight: exactly one network call for two concurrent fetches",
          CountingSuccessURLProtocol.callCount == 1, "got \(CountingSuccessURLProtocol.callCount)")
    check("single-flight: both callers got a non-stale result", !r1.isStale && !r2.isStale)
    check("single-flight: both callers got matching payloads",
          r1.response.results.first?.id == r2.response.results.first?.id)
} catch {
    check("single-flight test ran without throwing", false, "\(error)")
}

// MARK: - Summary

print("\n\(passCount) passed, \(failCount) failed")
exit(failCount == 0 ? EXIT_SUCCESS : EXIT_FAILURE)
