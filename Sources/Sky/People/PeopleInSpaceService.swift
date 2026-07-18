import Foundation

// MARK: - Wire models
//
// Shape confirmed by a live fetch on 2026-07-18 against
// `https://ll.thespacedevs.com/2.2.0/astronaut/?in_space=true&limit=30`.
//
// This is the LL2 astronaut LIST endpoint (not a per-astronaut detail fetch -- see the important
// gotcha below about why). The full response looks like:
// ```
// { "count": 14, "next": null, "previous": null, "results": [ { ... one astronaut ... }, ... ] }
// ```
// `count` was 14 on the day of exploration (13 real people + one non-human joke entry, see
// below) -- comfortably inside the 5-20 sanity range a human-crewed ISS+CSS snapshot should have.
// `next`/`previous` were both absent/null at `limit=30`; LL2 paginates past that if the in-space
// population ever exceeds it, but this app only ever asks for one page (see `PeopleInSpace.swift`
// for why a second page is never worth the rate-limit cost).
//
// One `results` element (trimmed to the fields this app cares about; the live payload has several
// more -- `bio`, `wiki`, `twitter`, `instagram`, `landings_count`, `spacewalks_count`, `age`,
// `date_of_birth`/`date_of_death` -- that are simply not declared below, so `Codable` silently
// ignores them):
// ```
// {
//   "id": 573,
//   "name": "Jessica Meir",
//   "status": {"id": 1, "name": "Active"},
//   "type": {"id": 2, "name": "Government"},
//   "in_space": true,
//   "time_in_space": "P359DT7H5M23S",
//   "eva_time": "P1DT5H4M",
//   "agency": {"id": 44, "name": "National Aeronautics and Space Administration", "abbrev": "NASA",
//              "country_code": "USA", "spacecraft": "Orion", ...},
//   "nationality": "American",
//   "first_flight": "2019-09-25T13:57:42Z",
//   "last_flight": "2026-02-13T10:15:56Z",
//   "flights_count": 2,
//   "profile_image": "https://.../jessica_meir_image_....jpeg",
//   "profile_image_thumbnail": "https://.../....jpeg"
// }
// ```
//
// **Notable gotchas found in the live sample (14 in-space entries, 5 agencies):**
//
//  - **No `flights` array, no `mission`/`spacecraft`/`station` field, anywhere on this endpoint.**
//    LL2 only exposes a per-flight breakdown (mission name, rocket, docking program) on the
//    *per-astronaut detail* endpoint (`/astronaut/{id}/`), confirmed by fetching
//    `/astronaut/573/` directly during exploration: it has a `flights: [...]` array with
//    `flights[0].mission.name` ("Crew-12"), `flights[0].name` ("Falcon 9 Block 5 | Crew-12"), and
//    `flights[0].program` (an array including an "International Space Station" program entry for
//    ISS missions). That is exactly the kind of "which craft/station" signal the work order asked
//    about -- but it costs **one additional HTTP request per astronaut**. With 13-14 people
//    routinely in space and an anonymous-tier budget of ~15 req/hour SHARED with the Launches
//    feature, doing N+1 fetches for a single snapshot would exhaust the entire hourly budget by
//    itself. **Decision: do not fetch astronaut detail pages. `craftLabel` is `nil` for every
//    person in v1** -- see `PeopleInSpace.swift` for the full writeup of what was considered and
//    rejected.
//  - **`agency.spacecraft` is a false lead, not a per-person craft field.** The list endpoint's
//    `agency` sub-object does carry a `spacecraft` string (e.g. NASA -> "Orion", SpaceX ->
//    "Dragon", Roscosmos -> "Soyuz"), which looks tempting at first glance. It is NOT the vehicle
//    this particular person is currently aboard -- it is the agency's flagship/most-associated
//    vehicle family. Jessica Meir (NASA, ISS) would incorrectly render as "Orion" (NASA's Artemis
//    deep-space capsule, entirely unrelated to her ISS increment) if this field were used naively.
//    Deliberately NOT modeled/consumed for `craftLabel` for that reason.
//  - **LL2 includes a non-human joke entry**: "Starman" (Elon Musk's mannequin, permanently in a
//    heliocentric orbit aboard the Falcon Heavy demo's Tesla Roadster) appears in `in_space=true`
//    results with `nationality: "Earthling"`, no `date_of_birth`, and critically
//    `type: {"id": 6, "name": "Non-Human"}`. Every real astronaut observed had `type.id == 2`
//    ("Government"). `PeopleInSpace.swift` filters on `type.id != 6` to drop entries like this
//    rather than trying to enumerate every possible joke/edge entry LL2 might add later.
//  - **`status` can lag `in_space`/`last_flight`.** One live entry (Anil Menon, NASA) had
//    `last_flight` 4 days before the fetch (i.e. clearly already launched and in orbit) but
//    `status: {"id": 3, "name": "In-Training"}` rather than "Active". Don't use `status.name` to
//    gate anything; `in_space` (already filtered server-side via the query param) plus a sane
//    `last_flight` are the only fields treated as authoritative for "currently up there".
//  - **`nationality` is a demonym string** ("American", "Russian", "Chinese", "French", ...), not
//    an ISO country code -- and `agency.country_code` is NOT a substitute: ESA's astronaut had
//    `agency.country_code` as a comma-joined list of 22 member-state codes (ESA is multinational),
//    which cannot single out "France" for Sophie Adenot. Flag-emoji derivation (see
//    `PeopleInSpace.swift`) therefore keys off the `nationality` demonym via a small curated
//    lookup table, not `agency.country_code`.
//  - **`time_in_space`/`eva_time` are ISO 8601 *durations*** (not dates), observed live in these
//    exact forms: `"P359DT7H5M23S"`, `"P3083DT5H19M20S"` (multi-year Starman entry), `"P0D"`
//    (zero EVA time), `"PT12H53M20S"` (sub-day EVA, no `D` component), `"PT7H20M"` (no seconds
//    component). No `W` (weeks) or fractional-seconds component was observed. `Foundation`'s
//    `ISO8601DateFormatter` does NOT parse these (it parses date-times, not durations) -- see the
//    hand-rolled `ISO8601Duration` parser in `PeopleInSpace.swift`.
//  - **`first_flight`/`last_flight` are ISO 8601 date-times** (standard `...Z` UTC, parseable by
//    `ISO8601DateFormatter` same as `LaunchService`'s `net`). For everyone observed with
//    `flights_count == 1`, `first_flight == last_flight` (their one and only flight). This app
//    uses `last_flight` as the best-available proxy for "current mission start" (see
//    `PeopleInSpace.swift`); `first_flight` is parsed but otherwise unused in v1.
//  - Every one of the 14 live results had the exact same top-level key set -- no astronaut in the
//    sample was missing a documented field. `agency`/`nationality`/`last_flight`/`flights_count`
//    are nonetheless modeled as `Optional` defensively (LL2's schema doesn't guarantee they always
//    will be present for every astronaut LL2 ever adds), and `PeopleInSpace.swift`'s mapper is
//    tolerant of any of them being missing.

/// One page of LL2's `/astronaut/` list endpoint, queried with `in_space=true`.
struct LL2AstronautListResponse: Codable {
    let count: Int
    let next: String?
    let previous: String?
    let results: [LL2Astronaut]
}

struct LL2Astronaut: Codable {
    let id: Int
    let name: String
    let status: LL2AstronautStatus?
    let type: LL2AstronautType?
    let inSpace: Bool
    /// ISO 8601 duration, e.g. `"P359DT7H5M23S"`. Raw wire string; parse via `ISO8601Duration`.
    let timeInSpace: String?
    /// ISO 8601 duration, e.g. `"P1DT5H4M"` or `"P0D"`. Not surfaced on `SpacePerson` in v1 (not
    /// asked for by the work order), parsed here only because it's a field of interest worth
    /// documenting -- kept for a future "cumulative spacewalk time" feature.
    let evaTime: String?
    let agency: LL2AstronautAgency?
    let nationality: String?
    /// ISO 8601 date-time of this person's first-ever flight. Parse via `firstFlightDate`.
    let firstFlight: String?
    /// ISO 8601 date-time of this person's most recent flight -- used as the best-available proxy
    /// for "current mission start" (see `PeopleInSpace.swift`). Parse via `lastFlightDate`.
    let lastFlight: String?
    let flightsCount: Int?

    enum CodingKeys: String, CodingKey {
        case id, name, status, type
        case inSpace = "in_space"
        case timeInSpace = "time_in_space"
        case evaTime = "eva_time"
        case agency, nationality
        case firstFlight = "first_flight"
        case lastFlight = "last_flight"
        case flightsCount = "flights_count"
    }

    var firstFlightDate: Date? {
        firstFlight.flatMap { ISO8601DateFormatter().date(from: $0) }
    }

    var lastFlightDate: Date? {
        lastFlight.flatMap { ISO8601DateFormatter().date(from: $0) }
    }
}

struct LL2AstronautStatus: Codable {
    let id: Int
    let name: String
}

/// LL2's astronaut `type` -- observed live: `{"id": 2, "name": "Government"}` for every real
/// astronaut in the sample, and `{"id": 6, "name": "Non-Human"}` for the "Starman" joke entry.
/// `PeopleInSpace.swift` filters out `id == 6` (see `PeopleInSpace.nonHumanTypeID`).
struct LL2AstronautType: Codable {
    let id: Int
    let name: String
}

struct LL2AstronautAgency: Codable {
    let id: Int
    let name: String
    let abbrev: String?
    /// NOT reliable for per-person nationality/flag derivation -- see the file-header gotcha about
    /// ESA reporting a comma-joined list of 22 country codes. Kept only for completeness /
    /// debugging, not consumed by `PeopleInSpace.swift`.
    let countryCode: String?

    enum CodingKeys: String, CodingKey {
        case id, name, abbrev
        case countryCode = "country_code"
    }
}

// MARK: - Errors

enum PeopleInSpaceServiceError: Error, CustomStringConvertible {
    case invalidHTTPResponse
    case httpStatus(Int)
    case rateLimited
    case decodingFailed(String)

    var description: String {
        switch self {
        case .invalidHTTPResponse:
            return "PeopleInSpaceService: response was not an HTTP response"
        case .httpStatus(let code):
            return "PeopleInSpaceService: HTTP \(code)"
        case .rateLimited:
            return "PeopleInSpaceService: HTTP 429 (rate limited)"
        case .decodingFailed(let detail):
            return "PeopleInSpaceService: failed to decode JSON (\(detail))"
        }
    }
}

// MARK: - Fetch + cache layer

/// Networking and on-disk caching for The Space Devs' keyless Launch Library 2 "astronauts
/// currently in space" feed. Deliberately free of any duration-parsing/humanization/sort logic --
/// that lives in `PeopleInSpace.swift` -- mirroring the fetch/cache split in
/// `Sources/Sky/Launches/LaunchService.swift`, `Sources/Sky/Aurora/AuroraService.swift`, and
/// `Sources/Sky/ISS/TLE.swift`.
///
/// **Rate-limit is the dominant design constraint here, same as `LaunchService`.** The anonymous
/// LL2 tier allows roughly 15 requests/hour, SHARED across every LL2-backed feature in this app
/// (Launches included) -- so this cache is deliberately even more aggressive than `LaunchService`'s
/// 6h/48h window, per the work order's explicit instruction ("cache HARD... crew changes are rare
/// and non-urgent"):
///  - Cache fresh for 24 hours: a fresh cache hit skips the network entirely, no exceptions.
///  - Stale cache usable up to 7 days (168 hours): if the network fetch fails (including a 429), a
///    cache up to 7 days old is still returned (with `isStale == true`) rather than failing the
///    caller. Crew rotations happen on the order of months, not days, so a week-old "who's in
///    space" snapshot is still almost certainly accurate, and far more useful than an error.
///  - HTTP 429 specifically is treated as an ordinary "network attempt failed" case for fallback
///    purposes (never crashes, never retries in a loop) but is logged distinctly so a developer
///    reading console output can tell "we got throttled" apart from "the network was down" or
///    "the server sent us bad JSON".
///  - Single-flight: an `actor` plus an in-flight `Task` guard ensures that if two callers ask for
///    the in-space roster at nearly the same moment while the cache is not fresh, only one network
///    request is actually issued -- the second caller awaits the first caller's in-flight task
///    rather than starting its own.
actor PeopleInSpaceService {
    static let inSpaceURL = URL(
        string: "https://ll.thespacedevs.com/2.2.0/astronaut/?in_space=true&limit=30"
    )!

    /// How long a cached response is used with no network call at all.
    static let freshInterval: TimeInterval = 24 * 60 * 60
    /// How old a cache is still allowed to be used as a degraded fallback when the network fails.
    static let staleLimit: TimeInterval = 7 * 24 * 60 * 60

    private static let cacheFileName = "ll2_astronaut_in_space_cache.json"

    private let session: URLSession
    /// Guards against issuing a second network request while one is already in progress (see
    /// type-level doc). `nil` when no fetch is currently in flight.
    private var inFlightTask: Task<(LL2AstronautListResponse, Bool), Error>?

    init(session: URLSession = .shared) {
        self.session = session
    }

    /// Fetches (or reuses a cached copy of) the in-space astronaut list. `isStale` is true when
    /// the network fetch failed (including a 429) and a past-freshness-window cache was returned
    /// instead. `now` is caller-supplied for determinism/testability, defaulting to `Date()`.
    func fetchPeopleInSpace(cacheDirectory: URL, now: Date = Date()) async throws
        -> (response: LL2AstronautListResponse, isStale: Bool)
    {
        let cacheFile = cacheDirectory.appendingPathComponent(Self.cacheFileName)

        // 1. Fresh cache hit -> use it, skip the network (and the single-flight machinery)
        //    entirely. This check and the `inFlightTask` assignment below both happen with no
        //    `await` in between, so there is no reentrancy window where two concurrent callers
        //    could both fall through past a "cache is fresh" state.
        if let cached = Self.readEnvelope(cacheFile),
           now.timeIntervalSince(cached.fetchedAt) < Self.freshInterval {
            return (cached.payload, false)
        }

        // 2. Single flight: if a fetch is already in progress, await its result instead of
        //    issuing a second network request.
        if let existing = inFlightTask {
            return try await existing.value
        }

        let session = self.session
        let task = Task<(LL2AstronautListResponse, Bool), Error> {
            try await Self.fetchFromNetworkOrFallBackToStale(
                session: session,
                cacheFile: cacheFile,
                now: now
            )
        }
        inFlightTask = task
        defer { inFlightTask = nil }
        return try await task.value
    }

    /// Cache-only read, no network attempt ever -- for callers that want "whatever's already
    /// cached, if fresh" without triggering a new network fetch as a side effect (mirrors
    /// `LaunchService.cachedUpcomingLaunchesIfFresh`). Returns `nil` on a cache miss OR a cache
    /// older than `freshInterval`.
    func cachedPeopleInSpaceIfFresh(cacheDirectory: URL, now: Date = Date()) -> LL2AstronautListResponse? {
        let cacheFile = cacheDirectory.appendingPathComponent(Self.cacheFileName)
        guard let cached = Self.readEnvelope(cacheFile), now.timeIntervalSince(cached.fetchedAt) < Self.freshInterval else {
            return nil
        }
        return cached.payload
    }

    // MARK: Network + stale fallback (no actor isolation needed: takes everything as params)

    private static func fetchFromNetworkOrFallBackToStale(
        session: URLSession,
        cacheFile: URL,
        now: Date
    ) async throws -> (LL2AstronautListResponse, Bool) {
        do {
            let (data, response) = try await session.data(from: inSpaceURL)
            guard let http = response as? HTTPURLResponse else {
                throw PeopleInSpaceServiceError.invalidHTTPResponse
            }
            if http.statusCode == 429 {
                // Documented hard requirement: never crash on 429, back off and use stale cache.
                print("PeopleInSpaceService: HTTP 429 rate limited by Launch Library 2 -- backing off, using stale cache if available")
                throw PeopleInSpaceServiceError.rateLimited
            }
            guard (200...299).contains(http.statusCode) else {
                throw PeopleInSpaceServiceError.httpStatus(http.statusCode)
            }
            let payload: LL2AstronautListResponse
            do {
                payload = try JSONDecoder().decode(LL2AstronautListResponse.self, from: data)
            } catch {
                throw PeopleInSpaceServiceError.decodingFailed(String(describing: error))
            }
            writeEnvelope(CacheEnvelope(fetchedAt: now, payload: payload), to: cacheFile)
            return (payload, false)
        } catch {
            // Network call, HTTP status, or decoding failed -- fall back to a stale cache if one
            // exists within the stale-usable window, rather than propagating the error.
            if let cached = readEnvelope(cacheFile) {
                let age = now.timeIntervalSince(cached.fetchedAt)
                if age >= 0 && age <= staleLimit {
                    print("PeopleInSpaceService: fetch failed (\(error)); using stale cache aged \(Int(age / 3600))h")
                    return (cached.payload, true)
                }
            }
            throw error
        }
    }

    // MARK: Cache envelope (plain file I/O, no actor state -- safe to call from any isolation)

    private struct CacheEnvelope: Codable {
        let fetchedAt: Date
        let payload: LL2AstronautListResponse
    }

    private static func readEnvelope(_ file: URL) -> CacheEnvelope? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(CacheEnvelope.self, from: data)
    }

    private static func writeEnvelope(_ envelope: CacheEnvelope, to file: URL) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(envelope) else { return }
        try? FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: file, options: .atomic)
    }
}
