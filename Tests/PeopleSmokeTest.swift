import Foundation

// Smoke test for Sources/Sky/People/*.swift. Build Guide engine-test recipe:
//   T=$(mktemp -d) && xattr -cr Sources && cp Tests/PeopleSmokeTest.swift "$T/main.swift" && \
//     swiftc -O Sources/Sky/People/*.swift "$T/main.swift" -o "$T/t" && "$T/t"; rm -rf "$T"
//
// Three parts, mirroring Tests/LaunchesSmokeTest.swift:
//  1. ONE live fetch against the real Launch Library 2 astronaut endpoint. `PeopleInSpaceService`
//     respects the anonymous tier's ~15 req/hour limit (SHARED with LaunchService); this harness
//     makes exactly one network call, full stop, and reuses its result for every live-data
//     assertion below.
//  2. Canned-struct unit tests of the pure `PeopleInSpace`/`ISO8601Duration` logic: duration
//     parsing (the real "PnDTnHnMnS" format observed live), days-in-space arithmetic with a fixed
//     `now`, career-time humanization, sort order, non-human filtering, and missing-fields
//     tolerance (nil agency/nationality/last_flight/flights_count) -- no network at all.
//  3. Cache-behavior tests against a mock `URLProtocol` (no real network access): fresh cache ->
//     network never touched; stale cache + simulated HTTP 429 -> stale cache used as a fallback
//     (and the network WAS attempted); no cache + 429 -> throws instead of crashing;
//     single-flight -> two concurrent fetches against an empty cache issue exactly one network
//     request.
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

/// Builds a canned `LL2Astronaut` fixture without going through JSON, for the pure-logic tests in
/// Part 2. Every wire model here is a plain `Codable` struct with no custom `init`, so Swift's
/// synthesized memberwise initializer is available directly.
func makeAstronaut(
    id: Int,
    name: String,
    statusID: Int = 1,
    statusName: String = "Active",
    typeID: Int? = 2,
    typeName: String = "Government",
    inSpace: Bool = true,
    timeInSpace: String? = "P100DT0H0M0S",
    evaTime: String? = "P0D",
    agencyName: String? = "National Aeronautics and Space Administration",
    agencyAbbrev: String? = "NASA",
    nationality: String? = "American",
    firstFlight: String? = "2024-01-01T00:00:00Z",
    lastFlight: String? = "2024-01-01T00:00:00Z",
    flightsCount: Int? = 1
) -> LL2Astronaut {
    LL2Astronaut(
        id: id,
        name: name,
        status: LL2AstronautStatus(id: statusID, name: statusName),
        type: typeID.map { LL2AstronautType(id: $0, name: typeName) },
        inSpace: inSpace,
        timeInSpace: timeInSpace,
        evaTime: evaTime,
        agency: agencyName.map { LL2AstronautAgency(id: 1, name: $0, abbrev: agencyAbbrev, countryCode: "USA") },
        nationality: nationality,
        firstFlight: firstFlight,
        lastFlight: lastFlight,
        flightsCount: flightsCount,
        profileImage: nil,
        profileImageThumbnail: nil
    )
}

/// Two-person canned LL2 `/astronaut/` page, matching the real wire shape (one real astronaut,
/// including a `type` object, `agency`, and duration fields), used by the cache-behavior tests in
/// Part 3 (which need actual JSON to feed through a mock `URLProtocol` and to write as a
/// cache-envelope payload).
let cannedJSON: Data = """
{
  "count": 1,
  "next": null,
  "previous": null,
  "results": [
    {
      "id": 573,
      "name": "Canned Astronaut",
      "status": {"id": 1, "name": "Active"},
      "type": {"id": 2, "name": "Government"},
      "in_space": true,
      "time_in_space": "P359DT7H5M23S",
      "eva_time": "P1DT5H4M",
      "agency": {"id": 44, "name": "National Aeronautics and Space Administration", "abbrev": "NASA", "country_code": "USA"},
      "nationality": "American",
      "first_flight": "2019-09-25T13:57:42Z",
      "last_flight": "2026-02-13T10:15:56Z",
      "flights_count": 2
    }
  ]
}
""".data(using: .utf8)!

// MARK: - Part 1: ONE live fetch

print("=== Live fetch: LL2 astronauts in space (single network call for this whole harness) ===")

let liveCacheDir = FileManager.default.temporaryDirectory
    .appendingPathComponent("PeopleSmokeTestCache-\(UUID().uuidString)")
defer { try? FileManager.default.removeItem(at: liveCacheDir) }

do {
    let now = Date()
    let result = try await PeopleToday.fetch(cacheDirectory: liveCacheDir, now: now)
    check("live fetch succeeded", true)
    check("live fetch is not stale", !result.isStale, "isStale=\(result.isStale)")
    check("live fetch parsed a sane roster size (5-20 people)",
          (5...20).contains(result.summary.count), "count=\(result.summary.count)")
    print("  parsed \(result.summary.count) people currently in space")

    let allHaveNameAndAgency = result.summary.people.allSatisfy {
        !$0.name.trimmingCharacters(in: .whitespaces).isEmpty
            && !$0.agencyAbbrev.trimmingCharacters(in: .whitespaces).isEmpty
    }
    check("all live people have a non-empty name and agency", allHaveNameAndAgency)

    // ~14 months, generously covering typical ISS/CSS increment lengths plus scheduling slop.
    let fourteenMonthsAgo = now.addingTimeInterval(-14 * 30 * 86_400)
    let currentMissionDatesSane = result.summary.people
        .compactMap(\.currentMissionStart)
        .allSatisfy { $0 >= fourteenMonthsAgo && $0 <= now }
    check("all derivable current-mission-start dates are within ~14 months of now, and not in the future",
          currentMissionDatesSane)

    print("  roster (sorted by days-in-space-current desc):")
    for p in result.summary.people {
        let days = p.daysInSpaceCurrent.map(String.init) ?? "?"
        print("    \(p.name) | \(p.agencyAbbrev) | \(p.nationality) | \(days)d current | \(p.careerTimeInSpace ?? "?") | craft: \(p.craftLabel ?? "n/a")")
    }
} catch {
    check("live fetch succeeded", false, "\(error)")
}

// MARK: - Part 2a: canned ISO 8601 duration parsing

print("\n=== Canned: ISO8601Duration parsing (real formats observed live 2026-07-18) ===")

check("'P359DT7H5M23S' (days+time) parses to the right total seconds",
      ISO8601Duration.totalSeconds(from: "P359DT7H5M23S") == Double(359 * 86_400 + 7 * 3_600 + 5 * 60 + 23))
check("'P359DT7H5M23S' -> 359 whole days", ISO8601Duration.totalDays(from: "P359DT7H5M23S") == 359)
check("'P3083DT5H19M20S' (multi-year, e.g. the Starman entry) parses",
      ISO8601Duration.totalDays(from: "P3083DT5H19M20S") == 3083)
check("'P0D' (zero duration, no T section) -> 0 days", ISO8601Duration.totalDays(from: "P0D") == 0)
check("'PT12H53M20S' (no D component) parses to the right seconds",
      ISO8601Duration.totalSeconds(from: "PT12H53M20S") == Double(12 * 3_600 + 53 * 60 + 20))
check("'PT7H20M' (no seconds component) parses to the right seconds",
      ISO8601Duration.totalSeconds(from: "PT7H20M") == Double(7 * 3_600 + 20 * 60))
check("'PT6H6M20S' parses to the right seconds",
      ISO8601Duration.totalSeconds(from: "PT6H6M20S") == Double(6 * 3_600 + 6 * 60 + 20))
check("bare 'P' (no components at all) fails to parse rather than silently returning 0",
      ISO8601Duration.totalSeconds(from: "P") == nil)
check("bare 'PT' (T section present but empty) fails to parse",
      ISO8601Duration.totalSeconds(from: "PT") == nil)
check("garbage string fails to parse, no crash", ISO8601Duration.totalSeconds(from: "not-a-duration") == nil)
check("empty string fails to parse, no crash", ISO8601Duration.totalSeconds(from: "") == nil)

// MARK: - Part 2b: canned career-time humanization

print("\n=== Canned: career-time humanization ===")

check("'371 days across 3 flights' shape",
      PeopleInSpace.humanizedCareerTime(raw: "P371D", flightsCount: 3) == "371 days across 3 flights")
check("singular 'day'/'flight' grammar",
      PeopleInSpace.humanizedCareerTime(raw: "P1D", flightsCount: 1) == "1 day across 1 flight")
check("nil flightsCount falls back to just the day count",
      PeopleInSpace.humanizedCareerTime(raw: "P10D", flightsCount: nil) == "10 days")
check("zero flightsCount falls back to just the day count",
      PeopleInSpace.humanizedCareerTime(raw: "P10D", flightsCount: 0) == "10 days")
check("nil raw duration -> nil (missing-field tolerance)",
      PeopleInSpace.humanizedCareerTime(raw: nil, flightsCount: 3) == nil)
check("unparsable raw duration -> nil, no crash",
      PeopleInSpace.humanizedCareerTime(raw: "garbage", flightsCount: 3) == nil)

// MARK: - Part 2c: canned days-in-space arithmetic (fixed `now`)

print("\n=== Canned: days-in-space arithmetic (fixed now) ===")

do {
    let now = iso("2026-07-18T00:00:00Z")
    let start = iso("2026-07-14T00:00:00Z") // 4 days before `now`
    check("4-day-old mission start -> 4 days in space",
          PeopleInSpace.daysInSpace(currentMissionStart: start, now: now) == 4)
    check("nil mission start -> nil days in space",
          PeopleInSpace.daysInSpace(currentMissionStart: nil, now: now) == nil)
    let future = iso("2026-08-01T00:00:00Z")
    check("a mission start AFTER now -> nil (defensive, never negative)",
          PeopleInSpace.daysInSpace(currentMissionStart: future, now: now) == nil)
    let sameInstant = now
    check("mission start exactly equal to now -> 0 days, not nil",
          PeopleInSpace.daysInSpace(currentMissionStart: sameInstant, now: now) == 0)
}

// MARK: - Part 2d: canned non-human filter

print("\n=== Canned: non-human filter (the 'Starman' edge case) ===")

do {
    let now = iso("2026-07-18T00:00:00Z")
    let human = makeAstronaut(id: 1, name: "Real Astronaut")
    let nonHuman = makeAstronaut(id: 2, name: "Starman", typeID: 6, typeName: "Non-Human", nationality: "Earthling")
    check("type.id == 2 (Government) counts as human", PeopleInSpace.isHuman(human))
    check("type.id == 6 (Non-Human) does NOT count as human", !PeopleInSpace.isHuman(nonHuman))
    check("map() drops the non-human entry entirely", PeopleInSpace.map(nonHuman, now: now) == nil)
    check("map() keeps the human entry", PeopleInSpace.map(human, now: now) != nil)

    let summary = PeopleInSpace.summarize([human, nonHuman], now: now)
    check("summarize() excludes the non-human entry from count and roster",
          summary.count == 1 && summary.people.map(\.id) == [1])
}

// MARK: - Part 2e: canned nationality -> flag emoji

print("\n=== Canned: nationality flag-emoji derivation ===")

check("clean known demonym gets a flag prefix",
      PeopleInSpace.displayNationality("American") == "🇺🇸 American")
check("clean known demonym (French) gets a flag prefix",
      PeopleInSpace.displayNationality("French") == "🇫🇷 French")
check("unmapped/unclean demonym falls back to plain text ('Earthling')",
      PeopleInSpace.displayNationality("Earthling") == "Earthling")
check("nil nationality -> 'Unknown', no crash", PeopleInSpace.displayNationality(nil) == "Unknown")
check("empty-string nationality -> 'Unknown'", PeopleInSpace.displayNationality("") == "Unknown")

// MARK: - Part 2f: canned full wire -> app mapping + missing-fields tolerance

print("\n=== Canned: full wire -> app mapping ===")

do {
    let now = iso("2026-07-18T00:00:00Z")
    let full = makeAstronaut(
        id: 100, name: "Full Fixture", timeInSpace: "P100D",
        agencyName: "National Aeronautics and Space Administration",
        agencyAbbrev: "NASA", nationality: "American",
        lastFlight: "2026-07-14T00:00:00Z", flightsCount: 2
    )
    if let mapped = PeopleInSpace.map(full, now: now) {
        check("full mapping produced a person", true)
        check("mapped id matches", mapped.id == 100)
        check("mapped name matches", mapped.name == "Full Fixture")
        check("mapped agencyAbbrev uses agency.abbrev", mapped.agencyAbbrev == "NASA")
        check("mapped nationality has a flag prefix", mapped.nationality == "🇺🇸 American")
        check("mapped currentMissionStart matches last_flight", mapped.currentMissionStart == iso("2026-07-14T00:00:00Z"))
        check("mapped daysInSpaceCurrent is 4", mapped.daysInSpaceCurrent == 4)
        check("mapped careerTimeInSpace is humanized", mapped.careerTimeInSpace == "100 days across 2 flights")
        check("mapped craftLabel is nil (documented v1 limitation)", mapped.craftLabel == nil)
    } else {
        check("full mapping produced a person", false)
    }
}

do {
    // Missing agency/nationality/last_flight/flights_count -> falls back to placeholders/nil
    // rather than dropping the person (only a non-human `type` should drop someone).
    let sparse = makeAstronaut(
        id: 101, name: "Sparse Fixture", timeInSpace: nil, agencyName: nil, agencyAbbrev: nil,
        nationality: nil, firstFlight: nil, lastFlight: nil, flightsCount: nil
    )
    if let mapped = PeopleInSpace.map(sparse, now: iso("2026-07-18T00:00:00Z")) {
        check("sparse mapping produced a person (missing-fields tolerance)", true)
        check("sparse agencyAbbrev falls back to a placeholder", mapped.agencyAbbrev == "Unknown agency")
        check("sparse nationality falls back to 'Unknown'", mapped.nationality == "Unknown")
        check("sparse currentMissionStart is nil (no last_flight)", mapped.currentMissionStart == nil)
        check("sparse daysInSpaceCurrent is nil", mapped.daysInSpaceCurrent == nil)
        check("sparse careerTimeInSpace is nil (no time_in_space)", mapped.careerTimeInSpace == nil)
        check("sparse craftLabel is nil", mapped.craftLabel == nil)
    } else {
        check("sparse mapping produced a person (missing-fields tolerance)", false)
    }
}

do {
    // agency.abbrev missing but agency.name present -> falls back to the full name, not the
    // generic placeholder.
    let noAbbrev = makeAstronaut(id: 102, name: "No Abbrev Fixture", agencyName: "Some New Agency", agencyAbbrev: nil)
    if let mapped = PeopleInSpace.map(noAbbrev, now: iso("2026-07-18T00:00:00Z")) {
        check("missing agency.abbrev falls back to agency.name (not the generic placeholder)",
              mapped.agencyAbbrev == "Some New Agency")
    } else {
        check("missing agency.abbrev falls back to agency.name (not the generic placeholder)", false)
    }
}

// MARK: - Part 2g: canned sort order

print("\n=== Canned: summarize() sort order (days-in-space-current desc, nils last) ===")

do {
    let now = iso("2026-07-18T00:00:00Z")
    let astronauts: [LL2Astronaut] = [
        makeAstronaut(id: 1, name: "Short Timer", lastFlight: "2026-07-16T00:00:00Z"),   // 2 days
        makeAstronaut(id: 2, name: "Long Timer", lastFlight: "2026-01-01T00:00:00Z"),    // ~198 days
        makeAstronaut(id: 3, name: "No Last Flight", lastFlight: nil),                   // nil
        makeAstronaut(id: 4, name: "Mid Timer", lastFlight: "2026-06-01T00:00:00Z"),     // 47 days
        makeAstronaut(id: 5, name: "Future Last Flight (bad data)", lastFlight: "2026-08-01T00:00:00Z"), // nil (future)
    ]
    let summary = PeopleInSpace.summarize(astronauts, now: now)
    let names = summary.people.map(\.name)
    print("  order: \(names)")

    check("summarize() keeps all 5 human entries", summary.count == 5, "got \(summary.count)")
    check("descending by daysInSpaceCurrent, nils last",
          names == ["Long Timer", "Mid Timer", "Short Timer", "No Last Flight", "Future Last Flight (bad data)"],
          "got \(names)")
}

// MARK: - Part 3: cache-behavior tests via mock URLProtocol (no real network access)

/// Always fails immediately. Used to prove a code path never actually attempts a network request.
final class FailingURLProtocol: URLProtocol {
    static var wasCalled = false
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        FailingURLProtocol.wasCalled = true
        client?.urlProtocol(self, didFailWithError: NSError(domain: "PeopleSmokeTest", code: -1))
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

/// Mirrors `PeopleInSpaceService`'s private on-disk cache-envelope shape (`fetchedAt` + `payload`,
/// plain `Codable` synthesis, `.iso8601` date strategy) so this test can write a cache file that
/// `PeopleInSpaceService` will read back, without that type being exposed outside
/// `PeopleInSpaceService.swift`.
struct TestCacheEnvelope: Codable {
    let fetchedAt: Date
    let payload: LL2AstronautListResponse
}

/// Must match `PeopleInSpaceService`'s private `cacheFileName` exactly (documented in
/// `PeopleInSpaceService.swift`'s cache-envelope section).
let ll2CacheFileName = "ll2_astronaut_in_space_cache.json"

func writeCacheEnvelope(fetchedAt: Date, payload: LL2AstronautListResponse, to directory: URL) throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let data = try encoder.encode(TestCacheEnvelope(fetchedAt: fetchedAt, payload: payload))
    try data.write(to: directory.appendingPathComponent(ll2CacheFileName))
}

print("\n=== Cache behavior: fresh cache (< 24h) skips the network entirely ===")

do {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("PeopleSmokeTestCache-fresh-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }

    let now = iso("2026-07-18T12:00:00Z")
    let canned = try JSONDecoder().decode(LL2AstronautListResponse.self, from: cannedJSON)
    try writeCacheEnvelope(fetchedAt: now.addingTimeInterval(-6 * 60 * 60), payload: canned, to: dir) // 6h old: fresh

    FailingURLProtocol.wasCalled = false
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [FailingURLProtocol.self]
    let session = URLSession(configuration: config)

    let service = PeopleInSpaceService(session: session)
    let (response, isStale) = try await service.fetchPeopleInSpace(cacheDirectory: dir, now: now)

    check("fresh cache: the network protocol was never invoked", !FailingURLProtocol.wasCalled)
    check("fresh cache: isStale is false", !isStale)
    check("fresh cache: returned the cached payload", response.results.first?.id == canned.results.first?.id)
} catch {
    check("fresh cache test ran without throwing", false, "\(error)")
}

print("\n=== Cache behavior: stale cache (>24h, <7d) + HTTP 429 falls back rather than crashing ===")

do {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("PeopleSmokeTestCache-stale-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }

    let now = iso("2026-07-18T12:00:00Z")
    let canned = try JSONDecoder().decode(LL2AstronautListResponse.self, from: cannedJSON)
    // 3 days old: past the 24h fresh window, well within the 7-day stale-usable window.
    try writeCacheEnvelope(fetchedAt: now.addingTimeInterval(-3 * 24 * 60 * 60), payload: canned, to: dir)

    RateLimitedURLProtocol.callCount = 0
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [RateLimitedURLProtocol.self]
    let session = URLSession(configuration: config)

    let service = PeopleInSpaceService(session: session)
    let (response, isStale) = try await service.fetchPeopleInSpace(cacheDirectory: dir, now: now)

    check("stale-cache path: the network WAS attempted (cache wasn't fresh)",
          RateLimitedURLProtocol.callCount == 1, "callCount=\(RateLimitedURLProtocol.callCount)")
    check("HTTP 429 does not throw -- falls back to the stale cache", true)
    check("stale-cache path: isStale is true", isStale)
    check("stale-cache path: returned the cached payload", response.results.first?.id == canned.results.first?.id)
} catch {
    check("HTTP 429 does not throw -- falls back to the stale cache", false, "unexpectedly threw: \(error)")
}

print("\n=== Cache behavior: cache older than the 7-day stale limit is NOT used ===")

do {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("PeopleSmokeTestCache-toostale-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }

    let now = iso("2026-07-18T12:00:00Z")
    let canned = try JSONDecoder().decode(LL2AstronautListResponse.self, from: cannedJSON)
    // 8 days old: past the 7-day stale-usable window entirely.
    try writeCacheEnvelope(fetchedAt: now.addingTimeInterval(-8 * 24 * 60 * 60), payload: canned, to: dir)

    RateLimitedURLProtocol.callCount = 0
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [RateLimitedURLProtocol.self]
    let session = URLSession(configuration: config)
    let service = PeopleInSpaceService(session: session)

    do {
        _ = try await service.fetchPeopleInSpace(cacheDirectory: dir, now: now)
        check("cache older than 7 days is rejected -- fetch should throw, not return stale data", false, "expected an error, got a result")
    } catch {
        check("cache older than 7 days is rejected -- fetch should throw, not return stale data", true)
        print("  threw as expected: \(error)")
    }
}

print("\n=== Cache behavior: no cache at all + HTTP 429 throws instead of crashing ===")

do {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("PeopleSmokeTestCache-nocache-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    // Deliberately do not create the directory or write any cache file.

    RateLimitedURLProtocol.callCount = 0
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [RateLimitedURLProtocol.self]
    let session = URLSession(configuration: config)
    let service = PeopleInSpaceService(session: session)

    do {
        _ = try await service.fetchPeopleInSpace(cacheDirectory: dir, now: iso("2026-07-18T12:00:00Z"))
        check("no cache + 429 throws rather than returning a bogus result", false, "expected an error, got a result")
    } catch {
        check("no cache + 429 throws rather than returning a bogus result", true)
        print("  threw as expected: \(error)")
    }
}

print("\n=== Cache behavior: single-flight -- two concurrent fetches issue exactly one network call ===")

do {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("PeopleSmokeTestCache-singleflight-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    // No cache present, so both concurrent callers must go through the network path -- but the
    // single-flight guard means only one of them should actually issue a request.

    CountingSuccessURLProtocol.callCount = 0
    CountingSuccessURLProtocol.responseData = cannedJSON
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [CountingSuccessURLProtocol.self]
    let session = URLSession(configuration: config)
    let service = PeopleInSpaceService(session: session)
    let now = iso("2026-07-18T12:00:00Z")

    async let first = service.fetchPeopleInSpace(cacheDirectory: dir, now: now)
    async let second = service.fetchPeopleInSpace(cacheDirectory: dir, now: now)
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
