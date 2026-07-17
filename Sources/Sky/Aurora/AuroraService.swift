import Foundation

// MARK: - Wire models

/// Raw OVATION aurora probability grid, decoded straight from NOAA SWPC's JSON.
///
/// Shape confirmed by a live fetch on 2026-07-17 against
/// `https://services.swpc.noaa.gov/json/ovation_aurora_latest.json`:
/// ```
/// {
///   "Observation Time": "2026-07-17T22:52:00Z",
///   "Forecast Time":    "2026-07-18T00:06:00Z",
///   "Data Format": "[Longitude, Latitude, Aurora]",
///   "coordinates": [[0, -90, 1], [0, -89, 0], ..., [359, 90, 0]],
///   "type": "MultiPoint"
/// }
/// ```
/// `coordinates` is a full, regular 360 x 181 grid (65,160 points): integer longitudes
/// 0...359 (east, no negative/wraparound values on the wire) and integer latitudes -90...90,
/// ordered longitude-major / latitude-minor (lon=0 for lat=-90...90, then lon=1, ...). The third
/// element is the aurora probability as an integer percent, 0-100.
struct OvationGrid: Codable {
    let observationTime: String
    let forecastTime: String
    let dataFormat: String
    let coordinates: [[Double]]
    let type: String

    enum CodingKeys: String, CodingKey {
        case observationTime = "Observation Time"
        case forecastTime = "Forecast Time"
        case dataFormat = "Data Format"
        case coordinates
        case type
    }

    /// Parsed `observationTime` ("...Z", standard ISO 8601 with UTC designator).
    var observationDate: Date? {
        ISO8601DateFormatter().date(from: observationTime)
    }

    /// Parsed `forecastTime` ("...Z", standard ISO 8601 with UTC designator).
    var forecastDate: Date? {
        ISO8601DateFormatter().date(from: forecastTime)
    }
}

/// One row of NOAA SWPC's planetary Kp forecast feed.
///
/// IMPORTANT — this differs from the work package's assumed shape. The spec described an
/// "array-of-arrays w/ header row" (a format NOAA does use for some other `/products/*.json`
/// feeds, e.g. the observed Kp index file). The live endpoint actually fetched on 2026-07-17
/// (`https://services.swpc.noaa.gov/products/noaa-planetary-k-index-forecast.json`) is instead a
/// **flat JSON array of objects**, no header row at all:
/// ```
/// [
///   {"time_tag":"2026-07-10T00:00:00","kp":2.00,"observed":"observed","noaa_scale":null},
///   {"time_tag":"2026-07-12T12:00:00","kp":4.67,"observed":"observed","noaa_scale":"G1"},
///   ...
///   {"time_tag":"2026-07-19T21:00:00","kp":1.67,"observed":"predicted","noaa_scale":null}
/// ]
/// ```
/// - 81 rows spanning ~10 days at 3-hour cadence (each row is the *start* of a 3h bucket).
/// - `observed` is one of `"observed"`, `"estimated"`, `"predicted"`.
/// - `noaa_scale` is a **String?** (e.g. `"G1"`), not numeric — null except on rows that crossed
///   a NOAA geomagnetic storm scale threshold.
/// - `time_tag` has no trailing `Z`/offset; SWPC's Kp forecast timestamps are UTC.
struct KpForecastRow: Codable {
    let timeTag: String
    let kp: Double
    let observed: String
    let noaaScale: String?

    enum CodingKeys: String, CodingKey {
        case timeTag = "time_tag"
        case kp
        case observed
        case noaaScale = "noaa_scale"
    }

    /// Parsed `time_tag`, interpreted as UTC (see type doc above).
    var date: Date? {
        Self.timeTagFormatter.date(from: timeTag)
    }

    private static let timeTagFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()
}

// MARK: - Errors

enum AuroraServiceError: Error, CustomStringConvertible {
    case invalidHTTPResponse
    case httpStatus(Int)
    case decodingFailed(String)

    var description: String {
        switch self {
        case .invalidHTTPResponse:
            return "AuroraService: response was not an HTTP response"
        case .httpStatus(let code):
            return "AuroraService: HTTP \(code)"
        case .decodingFailed(let detail):
            return "AuroraService: failed to decode JSON (\(detail))"
        }
    }
}

// MARK: - Fetch + cache layer

/// Networking and on-disk caching for NOAA SWPC's two keyless aurora feeds. Deliberately free of
/// any probability/visibility math — that lives in `AuroraLikelihood.swift` — so this file can
/// change retry/caching behavior without touching tested logic, and so the logic can be unit
/// tested against canned JSON with no network access at all.
///
/// Cache policy: each feed is cached to its own file under a caller-supplied directory, wrapped
/// in a small envelope carrying `fetchedAt`. A fresh cache hit skips the network entirely. On a
/// network failure, a *stale* cache is still returned (with `isStale == true`) rather than
/// failing the caller outright — aurora data degrades gracefully; an hour-old OVATION reading is
/// far more useful than no reading. Only if there is no cache at all does the network error
/// propagate.
final class AuroraService {
    static let ovationURL = URL(string: "https://services.swpc.noaa.gov/json/ovation_aurora_latest.json")!
    static let kpForecastURL = URL(string: "https://services.swpc.noaa.gov/products/noaa-planetary-k-index-forecast.json")!

    /// OVATION is a short-term "now-ish" nowcast; NOAA regenerates it roughly every few minutes,
    /// so 30 minutes keeps the app from re-fetching on every screen visit while staying close to
    /// current conditions.
    static let ovationFreshInterval: TimeInterval = 30 * 60
    /// The Kp forecast changes much more slowly (3-hour forecast buckets, updated a few times a
    /// day), so 3 hours avoids needless refetching without going stale relative to the data's own
    /// resolution.
    static let kpForecastFreshInterval: TimeInterval = 3 * 60 * 60

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    /// Fetches (or reuses a cached copy of) the OVATION grid. `isStale` is true when the network
    /// fetch failed and a past-freshness-window cache was returned instead.
    func fetchOvationGrid(cacheDirectory: URL) async throws -> (grid: OvationGrid, isStale: Bool) {
        try await fetchCached(
            url: Self.ovationURL,
            cacheFile: cacheDirectory.appendingPathComponent("ovation_aurora_latest.json"),
            freshInterval: Self.ovationFreshInterval
        )
    }

    /// Fetches (or reuses a cached copy of) the Kp forecast rows. `isStale` is true when the
    /// network fetch failed and a past-freshness-window cache was returned instead.
    func fetchKpForecast(cacheDirectory: URL) async throws -> (rows: [KpForecastRow], isStale: Bool) {
        try await fetchCached(
            url: Self.kpForecastURL,
            cacheFile: cacheDirectory.appendingPathComponent("noaa_planetary_k_index_forecast.json"),
            freshInterval: Self.kpForecastFreshInterval
        )
    }

    // MARK: Generic cache-then-fetch

    private struct CacheEnvelope<T: Codable>: Codable {
        let fetchedAt: Date
        let payload: T
    }

    private func fetchCached<T: Codable>(
        url: URL,
        cacheFile: URL,
        freshInterval: TimeInterval
    ) async throws -> (T, Bool) {
        // 1. Fresh cache hit -> use it, skip the network entirely.
        if let cached = readEnvelope(cacheFile, as: T.self),
           Date().timeIntervalSince(cached.fetchedAt) < freshInterval {
            return (cached.payload, false)
        }

        // 2. Try the network.
        do {
            let (data, response) = try await session.data(from: url)
            guard let http = response as? HTTPURLResponse else {
                throw AuroraServiceError.invalidHTTPResponse
            }
            guard (200...299).contains(http.statusCode) else {
                throw AuroraServiceError.httpStatus(http.statusCode)
            }
            let payload: T
            do {
                payload = try JSONDecoder().decode(T.self, from: data)
            } catch {
                throw AuroraServiceError.decodingFailed(String(describing: error))
            }
            writeEnvelope(CacheEnvelope(fetchedAt: Date(), payload: payload), to: cacheFile)
            return (payload, false)
        } catch {
            // 3. Network/decoding failed -> fall back to a stale cache if one exists at all.
            if let cached = readEnvelope(cacheFile, as: T.self) {
                return (cached.payload, true)
            }
            throw error
        }
    }

    private func readEnvelope<T: Codable>(_ file: URL, as type: T.Type) -> CacheEnvelope<T>? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(CacheEnvelope<T>.self, from: data)
    }

    private func writeEnvelope<T: Codable>(_ envelope: CacheEnvelope<T>, to file: URL) {
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
