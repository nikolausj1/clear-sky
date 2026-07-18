import Foundation

// MARK: - Wire models

/// One day-slot of NOAA SWPC's "NOAA Scales" product — the R (radio blackout) / S (solar
/// radiation storm) / G (geomagnetic storm) 0-5 severity scales.
///
/// Shape confirmed by a live fetch on 2026-07-17/18 against
/// `https://services.swpc.noaa.gov/products/noaa-scales.json`:
/// ```
/// {
///   "0":  {"DateStamp":"2026-07-18","TimeStamp":"03:45:00",
///          "R":{"Scale":"0","Text":"none","MinorProb":null,"MajorProb":null},
///          "S":{"Scale":"0","Text":"none","Prob":null},
///          "G":{"Scale":"0","Text":"none"}},
///   "1":  {"DateStamp":"2026-07-18","TimeStamp":"03:45:00",
///          "R":{"Scale":null,"Text":null,"MinorProb":"15","MajorProb":"1"},
///          "S":{"Scale":null,"Text":null,"Prob":"1"},
///          "G":{"Scale":"0","Text":"none"}},
///   "2":  { ... same shape, DateStamp one day later ... },
///   "3":  { ... same shape, DateStamp two days later ... },
///   "-1": {"DateStamp":"2026-07-17","TimeStamp":"03:45:00",
///          "R":{"Scale":"0", ...}, "S":{"Scale":"0", ...}, "G":{"Scale":"0", ...}}
/// }
/// ```
/// The **whole response is a JSON object, not an array**, keyed by the strings `"-1"`, `"0"`,
/// `"1"`, `"2"`, `"3"`:
/// - `"-1"` = the prior 24-hour observed period.
/// - `"0"`  = the current/most-recent observed 24-hour period (this is "now" for our purposes).
/// - `"1"`, `"2"`, `"3"` = the NOAA 3-day forecast, one entry per UTC day (`DateStamp` advances
///   by one day per key).
///
/// **Doc-vs-reality surprise #1:** on `"0"`/`"-1"` (observed), `R.Scale`/`S.Scale` are populated
/// numeric strings (`"0"`...`"5"`) and `MinorProb`/`MajorProb`/`Prob` are `null`. On the forecast
/// entries (`"1"`/`"2"`/`"3"`), it's the **reverse** — `R.Scale`/`S.Scale`/`R.Text`/`S.Text` are
/// `null` and only the probability fields (`MinorProb`/`MajorProb`/`Prob`, percent-as-string) are
/// populated. NOAA's 3-day outlook for R/S is a *probability of reaching that scale*, not a
/// predicted scale value — there is no "forecast R scale" number to read directly the way one
/// might assume from the endpoint's name. `G`, by contrast, carries no probability fields at all
/// (no `GMinorProb`-equivalent) and reports `Scale`/`Text` on every entry including the forecast
/// ones — so a "3-day G forecast" *is* directly readable as a scale number, unlike R/S. (This
/// fetch happened to be an entirely quiet stretch, so it wasn't possible to confirm live whether
/// forecast `G.Scale` ever actually differs across `"1"`/`"2"`/`"3"` when a storm is expected;
/// treated as authoritative per NOAA's own product description, but flagged here since it
/// couldn't be directly observed varying.)
///
/// **Doc-vs-reality surprise #2:** every numeric-looking field (`Scale`, `MinorProb`,
/// `MajorProb`, `Prob`) is a **JSON string**, not a JSON number, when present at all — `"0"`,
/// `"15"`, etc. — and every field on this type is independently nullable. Modeled as `String?`
/// throughout and parsed to `Int?` on demand rather than assuming a shape that isn't actually on
/// the wire.
struct NOAAScaleDayEntry: Codable {
    let dateStamp: String
    let timeStamp: String
    let r: RScale
    let s: SScale
    let g: GScale

    enum CodingKeys: String, CodingKey {
        case dateStamp = "DateStamp"
        case timeStamp = "TimeStamp"
        case r = "R"
        case s = "S"
        case g = "G"
    }

    struct RScale: Codable {
        let scale: String?
        let text: String?
        let minorProb: String?
        let majorProb: String?

        enum CodingKeys: String, CodingKey {
            case scale = "Scale"
            case text = "Text"
            case minorProb = "MinorProb"
            case majorProb = "MajorProb"
        }

        /// `scale` parsed to an `Int` (0-5), or `nil` when the wire value is `null` (observed on
        /// forecast day-slots, which report probabilities instead — see type-level doc comment).
        var scaleValue: Int? { scale.flatMap { Int($0) } }
    }

    struct SScale: Codable {
        let scale: String?
        let text: String?
        let prob: String?

        enum CodingKeys: String, CodingKey {
            case scale = "Scale"
            case text = "Text"
            case prob = "Prob"
        }

        var scaleValue: Int? { scale.flatMap { Int($0) } }
    }

    struct GScale: Codable {
        let scale: String?
        let text: String?

        enum CodingKeys: String, CodingKey {
            case scale = "Scale"
            case text = "Text"
        }

        var scaleValue: Int? { scale.flatMap { Int($0) } }
    }

    /// `DateStamp` + `TimeStamp` combined and parsed as UTC. NOAA's scales product carries no
    /// explicit UTC offset on either field (e.g. `"2026-07-18"` / `"03:45:00"`); its own product
    /// description states the data is issued in UTC, matching the convention already used for
    /// SWPC's Kp forecast feed (see `AuroraService.swift`'s `KpForecastRow`).
    var date: Date? {
        Self.formatter.date(from: "\(dateStamp)T\(timeStamp)")
    }

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()
}

/// The full `noaa-scales.json` payload: a dictionary keyed by `"-1"`, `"0"`, `"1"`, `"2"`, `"3"`
/// (see `NOAAScaleDayEntry`'s doc comment). Decoded as a plain dictionary — JSON object key order
/// isn't meaningful here since the keys themselves are the index.
typealias NOAAScales = [String: NOAAScaleDayEntry]

/// One flare event from NOAA SWPC's GOES X-ray flare event list.
///
/// Shape confirmed by a live fetch on 2026-07-17/18 against
/// `https://services.swpc.noaa.gov/json/goes/primary/xray-flares-7-day.json`:
/// ```
/// [
///   {
///     "time_tag": "2026-07-11T05:22:00Z",
///     "begin_time": "2026-07-11T05:22:00Z", "begin_class": "B5.4",
///     "max_time":   "2026-07-11T05:30:00Z", "max_class":   "B9.4",
///     "max_xrlong": 9.425932603335241e-07,
///     "max_ratio": 0.12443860132062608, "max_ratio_time": "2026-07-11T05:28:16Z",
///     "current_int_xrlong": 0.0007844122592359781,
///     "end_time": "2026-07-11T05:37:00Z", "end_class": "B7.2",
///     "satellite": 18
///   },
///   ...
/// ]
/// ```
/// - A **flat JSON array**, no wrapper object, most-recent-last (ascending `time_tag`). Over the
///   trailing 7 days fetched live, 27 discrete flare events, classes B/C/M only (no X during this
///   window) — confirms this feed carries discrete begin/peak/end flare *events*, not a raw flux
///   time series (that's the separate, much larger `xrays-7-day.json`/`xrays-1-day.json` feeds in
///   the same directory, sampled every ~minute with no event segmentation — the wrong shape for
///   "recent flares w/ class + begin/peak/end").
/// - `*_class` strings are one letter (`A`/`B`/`C`/`M`/`X`) + a decimal magnitude, e.g. `"M4.2"`.
/// - `max_ratio`/`max_ratio_time` were `null` on 2 of the 27 live rows — genuinely optional, not
///   just theoretically nullable.
/// - `satellite` is the GOES satellite number (`18` throughout this fetch); not otherwise used.
/// - Chose this over `xray-flares-latest.json` (same directory) because that feed is a single
///   "current/most-recent flare" snapshot with a `current_class` field, not a history — no good
///   for a trailing-24h notable-flare or activity-level scan. Also chose it over
///   `suvi-flares-*.json` in the same directory, which is a different instrument (SUVI extreme-
///   ultraviolet imagery flare detections) with a different, non-R/S/G-comparable classification.
struct FlareEvent: Codable {
    let timeTag: String
    let beginTime: String
    let beginClass: String
    let maxTime: String
    let maxClass: String
    let maxXrlong: Double?
    let maxRatio: Double?
    let maxRatioTime: String?
    let currentIntXrlong: Double?
    let endTime: String
    let endClass: String
    let satellite: Int

    enum CodingKeys: String, CodingKey {
        case timeTag = "time_tag"
        case beginTime = "begin_time"
        case beginClass = "begin_class"
        case maxTime = "max_time"
        case maxClass = "max_class"
        case maxXrlong = "max_xrlong"
        case maxRatio = "max_ratio"
        case maxRatioTime = "max_ratio_time"
        case currentIntXrlong = "current_int_xrlong"
        case endTime = "end_time"
        case endClass = "end_class"
        case satellite
    }

    /// Parsed `max_time` ("...Z", standard ISO 8601 with UTC designator) — the flare's peak, and
    /// the timestamp used for trailing-24h windowing in `SolarActivity`.
    var maxDate: Date? { ISO8601DateFormatter().date(from: maxTime) }
    var beginDate: Date? { ISO8601DateFormatter().date(from: beginTime) }
    var endDate: Date? { ISO8601DateFormatter().date(from: endTime) }
}

/// One row of NOAA SWPC's daily observed sunspot number series.
///
/// Shape confirmed by a live fetch on 2026-07-17/18 against
/// `https://services.swpc.noaa.gov/json/solar-cycle/swpc_observed_ssn.json`:
/// ```
/// [
///   {"Obsdate":"1996-03-12T00:00:00","swpc_ssn":0},
///   ...
///   {"Obsdate":"2026-07-17T00:00:00","swpc_ssn":26}
/// ]
/// ```
/// - Flat array, 9,789 rows live (1996-03-12 through 2026-07-17, one row per **calendar day**),
///   ascending date, most-recent-last.
/// - `Obsdate` has no trailing `Z`/offset (same no-timezone-marker convention as the Kp forecast's
///   `time_tag` — see `AuroraService.swift`); treated as UTC/civil date, since sunspot counts are
///   a whole-day observation with no meaningful sub-day component.
/// - `swpc_ssn` is a plain `Int` (whole-number daily international sunspot number), not a string.
/// - **Chose this over** `sunspots.json`/`sunspots-smoothed.json` in the same directory (monthly
///   averages, `"time-tag":"1749-01"` granularity going back to 1749 — no daily figure) and over
///   deriving an active-region count from `solar_regions.json`: this feed is already a clean,
///   single daily number with no aggregation needed, so the fallback (`solar_regions.json`) was
///   not used. `SolarOutlook.sunspotNumber` is this feed's most recent `swpc_ssn`.
struct SunspotObservation: Codable {
    let obsdate: String
    let swpcSsn: Int

    enum CodingKeys: String, CodingKey {
        case obsdate = "Obsdate"
        case swpcSsn = "swpc_ssn"
    }

    var date: Date? {
        Self.formatter.date(from: obsdate)
    }

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()
}

// MARK: - Errors

enum SolarServiceError: Error, CustomStringConvertible {
    case invalidHTTPResponse
    case httpStatus(Int)
    case decodingFailed(String)

    var description: String {
        switch self {
        case .invalidHTTPResponse:
            return "SolarService: response was not an HTTP response"
        case .httpStatus(let code):
            return "SolarService: HTTP \(code)"
        case .decodingFailed(let detail):
            return "SolarService: failed to decode JSON (\(detail))"
        }
    }
}

// MARK: - Fetch + cache layer

/// Networking and on-disk caching for NOAA SWPC's three keyless solar-activity feeds. Deliberately
/// free of any activity-level/notability math — that lives in `SolarActivity.swift` — mirroring
/// `Sources/Sky/Aurora/AuroraService.swift`'s fetch/logic split, for the same reasons: this file
/// can change retry/caching behavior without touching tested logic, and the logic can be unit
/// tested against canned JSON with no network access at all.
///
/// Cache policy: each feed is cached to its own file under a caller-supplied directory, wrapped in
/// a small envelope carrying `fetchedAt`. A fresh cache hit skips the network entirely. On a
/// network failure, a *stale* cache is still returned (with `isStale == true`) rather than failing
/// the caller outright. Only if there is no cache at all does the network error propagate.
final class SolarService {
    static let scalesURL = URL(string: "https://services.swpc.noaa.gov/products/noaa-scales.json")!
    static let flaresURL = URL(string: "https://services.swpc.noaa.gov/json/goes/primary/xray-flares-7-day.json")!
    static let sunspotURL = URL(string: "https://services.swpc.noaa.gov/json/solar-cycle/swpc_observed_ssn.json")!

    /// R/S/G scales update a handful of times a day as new observed 24-hour periods roll in; an
    /// hour keeps re-fetches infrequent without drifting far from current conditions.
    static let scalesFreshInterval: TimeInterval = 60 * 60
    /// The flare list only grows when a new flare completes; an hour is the same cadence as
    /// scales and is frequent enough to catch a new notable flare promptly.
    static let flaresFreshInterval: TimeInterval = 60 * 60
    /// The daily sunspot number is, per its name, updated at most once a day (and often a day or
    /// more in arrears while NOAA finalizes the count) — 12 hours avoids needless re-fetching of a
    /// feed that realistically never changes twice in one calling session.
    static let sunspotFreshInterval: TimeInterval = 12 * 60 * 60

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    /// Fetches (or reuses a cached copy of) the current + recent + 3-day-forecast R/S/G scales.
    /// `isStale` is true when the network fetch failed and a past-freshness-window cache was
    /// returned instead.
    func fetchScales(cacheDirectory: URL) async throws -> (scales: NOAAScales, isStale: Bool) {
        try await fetchCached(
            url: Self.scalesURL,
            cacheFile: cacheDirectory.appendingPathComponent("noaa_scales.json"),
            freshInterval: Self.scalesFreshInterval
        )
    }

    /// Fetches (or reuses a cached copy of) the trailing-7-day GOES X-ray flare event list.
    /// `isStale` is true when the network fetch failed and a past-freshness-window cache was
    /// returned instead.
    func fetchFlares(cacheDirectory: URL) async throws -> (flares: [FlareEvent], isStale: Bool) {
        try await fetchCached(
            url: Self.flaresURL,
            cacheFile: cacheDirectory.appendingPathComponent("xray_flares_7_day.json"),
            freshInterval: Self.flaresFreshInterval
        )
    }

    /// Fetches (or reuses a cached copy of) the full daily observed-sunspot-number history.
    /// `isStale` is true when the network fetch failed and a past-freshness-window cache was
    /// returned instead.
    func fetchSunspots(cacheDirectory: URL) async throws -> (observations: [SunspotObservation], isStale: Bool) {
        try await fetchCached(
            url: Self.sunspotURL,
            cacheFile: cacheDirectory.appendingPathComponent("swpc_observed_ssn.json"),
            freshInterval: Self.sunspotFreshInterval
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
                throw SolarServiceError.invalidHTTPResponse
            }
            guard (200...299).contains(http.statusCode) else {
                throw SolarServiceError.httpStatus(http.statusCode)
            }
            let payload: T
            do {
                payload = try JSONDecoder().decode(T.self, from: data)
            } catch {
                throw SolarServiceError.decodingFailed(String(describing: error))
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
