import Foundation

// MARK: - Wire models
//
// Shape confirmed by a live fetch on 2026-07-17 against
// `https://ll.thespacedevs.com/2.2.0/launch/upcoming/?limit=15&hide_recent_previous=true`.
//
// Launch Library 2 (LL2) is a large, richly-nested, paginated object. The full response looks
// like:
// ```
// {
//   "count": 362,
//   "next": "https://ll.thespacedevs.com/2.2.0/launch/upcoming/?hide_recent_previous=true&limit=15&offset=15",
//   "previous": null,
//   "results": [ { ... one launch ... }, ... ]
// }
// ```
// One `results` element (trimmed to the fields this app cares about; the live payload has many
// more — attempt counters, `program`, `infographic`, `window_start`/`window_end`, etc. — that are
// simply not declared below, so `Codable` silently ignores them):
// ```
// {
//   "id": "10fa7952-f00b-4292-80a2-4207e208844e",
//   "name": "Vikram-I | Demo Flight",
//   "status": {"id": 1, "name": "Go for Launch", "abbrev": "Go", "description": "..."},
//   "net": "2026-07-18T06:00:00Z",
//   "net_precision": {"id": 1, "name": "Minute", "abbrev": "MIN", "description": "..."},
//   "launch_service_provider": {"id": 1099, "url": "...", "name": "Skyroot Aerospace", "type": "Private"},
//   "rocket": {"id": 8799, "configuration": {"id": 532, "name": "Vikram-I", "family": "Vikram",
//                                             "full_name": "Vikram-I", "variant": ""}},
//   "mission": {"id": 7390, "name": "Demo Flight", "description": "...", "type": "Test Flight",
//               "orbit": {"id": 8, "name": "Low Earth Orbit", "abbrev": "LEO"}, ... },
//   "pad": {"id": 50, "name": "Satish Dhawan Space Centre First Launch Pad",
//           "latitude": "13.733", "longitude": "80.235",
//           "location": {"id": 14, "name": "Satish Dhawan Space Centre, India",
//                        "country_code": "IND", ...}, ...},
//   "webcast_live": false,
//   "image": "https://.../vikram-i_on_launc....jpeg"
// }
// ```
// Notable gotchas found in the live sample (15 launches spanning 6 providers/agencies):
//  - `pad.latitude` / `pad.longitude` are **strings** on the wire (e.g. `"13.733"`), not numbers.
//  - `mission` (and several of its sub-fields) is nullable in LL2's schema generally, even though
//    every launch in this particular sample had one; modeled as `Optional` defensively.
//  - `net_precision` can also be null (undetermined-precision far-future slots); modeled Optional.
//  - `status.abbrev` observed values across the sample: "Go", "TBD", "TBC". "Hold", "Success",
//    "Failure", "In Flight", "Partial Failure" are documented in LL2's publicly-known status table
//    but did not appear live (expected: this is the *upcoming* feed with
//    `hide_recent_previous=true`, so already-flown statuses are rare/absent by construction). See
//    `LaunchSchedule.swift` for the full id -> simplified-status mapping table.
//  - `net_precision.abbrev` observed values: "MIN" (Minute), "HR" (Hour), "M" (Month).

/// One page of LL2's `/launch/upcoming/` list endpoint.
struct LL2UpcomingLaunchesResponse: Codable {
    let count: Int
    let next: String?
    let previous: String?
    let results: [LL2Launch]
}

struct LL2Launch: Codable {
    let id: String
    let name: String
    let status: LL2Status
    /// T-0, ISO 8601 UTC (e.g. `"2026-07-18T06:00:00Z"`). Kept as the raw wire string; parse via
    /// `netDate`.
    let net: String
    let netPrecision: LL2Precision?
    let launchServiceProvider: LL2Agency?
    let rocket: LL2Rocket?
    let mission: LL2Mission?
    let pad: LL2Pad?
    let webcastLive: Bool
    let image: String?

    enum CodingKeys: String, CodingKey {
        case id, name, status, net
        case netPrecision = "net_precision"
        case launchServiceProvider = "launch_service_provider"
        case rocket, mission, pad
        case webcastLive = "webcast_live"
        case image
    }

    /// Parsed `net` ("...Z", standard ISO 8601 with UTC designator).
    var netDate: Date? {
        ISO8601DateFormatter().date(from: net)
    }
}

struct LL2Status: Codable {
    let id: Int
    let name: String
    let abbrev: String
}

struct LL2Precision: Codable {
    let id: Int
    let name: String
    let abbrev: String
}

struct LL2Agency: Codable {
    let id: Int
    let name: String
    let type: String?
}

struct LL2Rocket: Codable {
    let configuration: LL2RocketConfiguration
}

struct LL2RocketConfiguration: Codable {
    let id: Int
    let name: String
    let fullName: String

    enum CodingKeys: String, CodingKey {
        case id, name
        case fullName = "full_name"
    }
}

struct LL2Mission: Codable {
    let name: String?
    let description: String?
    let type: String?
}

struct LL2Pad: Codable {
    let name: String
    /// Wire type is a JSON string, not a number (see file-header note above).
    let latitude: String?
    let longitude: String?
    let location: LL2Location

    var latitudeValue: Double? { latitude.flatMap(Double.init) }
    var longitudeValue: Double? { longitude.flatMap(Double.init) }
}

struct LL2Location: Codable {
    let name: String
    let countryCode: String?

    enum CodingKeys: String, CodingKey {
        case name
        case countryCode = "country_code"
    }
}

// MARK: - Errors

enum LaunchServiceError: Error, CustomStringConvertible {
    case invalidHTTPResponse
    case httpStatus(Int)
    case rateLimited
    case decodingFailed(String)

    var description: String {
        switch self {
        case .invalidHTTPResponse:
            return "LaunchService: response was not an HTTP response"
        case .httpStatus(let code):
            return "LaunchService: HTTP \(code)"
        case .rateLimited:
            return "LaunchService: HTTP 429 (rate limited)"
        case .decodingFailed(let detail):
            return "LaunchService: failed to decode JSON (\(detail))"
        }
    }
}

// MARK: - Fetch + cache layer

/// Networking and on-disk caching for The Space Devs' keyless Launch Library 2 "upcoming
/// launches" feed. Deliberately free of any launch-list/status-simplification logic — that lives
/// in `LaunchSchedule.swift` — so this file can change retry/caching/rate-limit behavior without
/// touching tested logic, and so the logic can be unit tested against canned JSON with no network
/// access at all. Mirrors the fetch/cache split in `Sources/Sky/Aurora/AuroraService.swift` and
/// `Sources/Sky/ISS/TLE.swift`.
///
/// **Rate-limit is the dominant design constraint here.** The anonymous LL2 tier allows roughly
/// 15 requests/hour, an order of magnitude tighter than NOAA's aurora feeds, so this cache is
/// deliberately more aggressive than `AuroraService`'s:
///  - Cache fresh for 6 hours: a fresh cache hit skips the network entirely, no exceptions.
///  - Stale cache usable up to 48 hours: if the network fetch fails (including a 429), a cache
///    up to 48h old is still returned (with `isStale == true`) rather than failing the caller —
///    a day-old launch schedule is far more useful than no schedule, and launch slips/scrubs are
///    common enough that showing slightly-stale data with a "last updated" caveat is the right
///    tradeoff over erroring.
///  - HTTP 429 specifically is treated as an ordinary "network attempt failed" case for fallback
///    purposes (never crashes, never retries in a loop) but is logged distinctly so a developer
///    reading console output can tell "we got throttled" apart from "the network was down" or
///    "the server sent us bad JSON".
///  - Single-flight: an `actor` plus an in-flight `Task` guard ensures that if two callers ask for
///    launches at nearly the same moment while the cache is not fresh, only one network request
///    is actually issued — the second caller awaits the first caller's in-flight task rather than
///    starting its own. Combined with the fresh-cache short-circuit above, this means the network
///    is only ever hit at most once per (stale-cache-window) request burst.
actor LaunchService {
    static let upcomingURL = URL(
        string: "https://ll.thespacedevs.com/2.2.0/launch/upcoming/?limit=15&hide_recent_previous=true"
    )!

    /// How long a cached response is used with no network call at all.
    static let freshInterval: TimeInterval = 6 * 60 * 60
    /// How old a cache is still allowed to be used as a degraded fallback when the network fails.
    static let staleLimit: TimeInterval = 48 * 60 * 60

    private static let cacheFileName = "ll2_launch_upcoming_cache.json"

    private let session: URLSession
    /// Guards against issuing a second network request while one is already in progress (see
    /// type-level doc). `nil` when no fetch is currently in flight.
    private var inFlightTask: Task<(LL2UpcomingLaunchesResponse, Bool), Error>?

    init(session: URLSession = .shared) {
        self.session = session
    }

    /// Fetches (or reuses a cached copy of) the upcoming-launches page. `isStale` is true when the
    /// network fetch failed (including a 429) and a past-freshness-window cache was returned
    /// instead. `now` is caller-supplied for determinism/testability, defaulting to `Date()`.
    func fetchUpcomingLaunches(cacheDirectory: URL, now: Date = Date()) async throws
        -> (response: LL2UpcomingLaunchesResponse, isStale: Bool)
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
        let task = Task<(LL2UpcomingLaunchesResponse, Bool), Error> {
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

    // MARK: Network + stale fallback (no actor isolation needed: takes everything as params)

    private static func fetchFromNetworkOrFallBackToStale(
        session: URLSession,
        cacheFile: URL,
        now: Date
    ) async throws -> (LL2UpcomingLaunchesResponse, Bool) {
        do {
            let (data, response) = try await session.data(from: upcomingURL)
            guard let http = response as? HTTPURLResponse else {
                throw LaunchServiceError.invalidHTTPResponse
            }
            if http.statusCode == 429 {
                // Documented hard requirement: never crash on 429, back off and use stale cache.
                print("LaunchService: HTTP 429 rate limited by Launch Library 2 -- backing off, using stale cache if available")
                throw LaunchServiceError.rateLimited
            }
            guard (200...299).contains(http.statusCode) else {
                throw LaunchServiceError.httpStatus(http.statusCode)
            }
            let payload: LL2UpcomingLaunchesResponse
            do {
                payload = try JSONDecoder().decode(LL2UpcomingLaunchesResponse.self, from: data)
            } catch {
                throw LaunchServiceError.decodingFailed(String(describing: error))
            }
            writeEnvelope(CacheEnvelope(fetchedAt: now, payload: payload), to: cacheFile)
            return (payload, false)
        } catch {
            // Network call, HTTP status, or decoding failed -- fall back to a stale cache if one
            // exists within the stale-usable window, rather than propagating the error.
            if let cached = readEnvelope(cacheFile) {
                let age = now.timeIntervalSince(cached.fetchedAt)
                if age >= 0 && age <= staleLimit {
                    print("LaunchService: fetch failed (\(error)); using stale cache aged \(Int(age / 60))m")
                    return (cached.payload, true)
                }
            }
            throw error
        }
    }

    // MARK: Cache envelope (plain file I/O, no actor state -- safe to call from any isolation)

    private struct CacheEnvelope: Codable {
        let fetchedAt: Date
        let payload: LL2UpcomingLaunchesResponse
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
