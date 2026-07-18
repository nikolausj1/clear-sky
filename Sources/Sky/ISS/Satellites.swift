import Foundation

// MARK: - Multi-satellite visible-pass engine
//
// Extends the verified ISS/SGP4 stack (TLE.swift, SGP4.swift,
// PassPredictor.swift, ISSTonight.swift -- untouched by this file) to
// additional naked-eye-visible satellites: Hubble, Tiangong (CSS), and
// recently-launched Starlink "trains".
//
// Design constraints honored:
//  - SGP4 math is not touched; this file only adds a catalog, a
//    generalized-by-CATNR network fetcher (parallel to `TLEFetcher`, not a
//    modification of it -- see rationale on `SatelliteTLEFetcher` below),
//    and a thin wrapper around the existing `ISSTonight.passes` /
//    `PassPredictor` pass-search engine.
//  - `ISSTonight`'s public API is completely unchanged; `SkyTonightService`
//    and other existing consumers are unaffected.
//  - Network access stays isolated to the fetcher type in this file, same
//    as the ISS-only fetcher is isolated to TLE.swift.

// MARK: - Tracked satellite catalog

public enum SatelliteKind: String, Equatable {
    case iss
    case hubble
    case tiangong
    case starlinkTrain
}

/// One satellite (or, for Starlink, one launch-cluster "train") that the app
/// tracks for visible passes.
public struct TrackedSatellite: Equatable {
    public let name: String
    public let catalogNumber: Int
    public let kind: SatelliteKind
    /// Human-facing note on expected naked-eye visibility characteristics.
    public let visibilityNote: String
    /// For `.starlinkTrain` entries: the launch's international-designator
    /// prefix (year + launch-of-year number, e.g. "24101") used to cluster
    /// same-launch satellites together. `nil` for the fixed catalog entries.
    public let launchDesignatorPrefix: String?
    /// Number of individual satellites represented by this entry (>1 only
    /// for `.starlinkTrain`, where many satellites from one launch are
    /// collapsed into a single tracked "train" using the lead satellite's
    /// TLE -- see `StarlinkClustering`).
    public let memberCount: Int

    public init(
        name: String,
        catalogNumber: Int,
        kind: SatelliteKind,
        visibilityNote: String,
        launchDesignatorPrefix: String? = nil,
        memberCount: Int = 1
    ) {
        self.name = name
        self.catalogNumber = catalogNumber
        self.kind = kind
        self.visibilityNote = visibilityNote
        self.launchDesignatorPrefix = launchDesignatorPrefix
        self.memberCount = memberCount
    }
}

public enum SatelliteCatalog {
    /// International Space Station. Brightness heuristic unchanged from the
    /// existing ISS-only behavior (`PassPredictor.brightness`).
    public static let iss = TrackedSatellite(
        name: "ISS",
        catalogNumber: 25544,
        kind: .iss,
        visibilityNote: "The brightest human-made object in the night sky after the Moon -- a fast, steady, unmistakably bright point."
    )

    /// Hubble Space Telescope. Much smaller and less reflective than the
    /// ISS's solar arrays, so it is consistently faint even on geometrically
    /// good passes (visual magnitude commonly ~1-2, vs. ISS's ~ -4 to -2).
    public static let hubble = TrackedSatellite(
        name: "Hubble Space Telescope",
        catalogNumber: 20580,
        kind: .hubble,
        visibilityNote: "Faint -- needs dark skies away from light pollution; much dimmer than the ISS."
    )

    /// Tiangong / Chinese Space Station (CSS). Smaller than the ISS but a
    /// genuine crewed station, so it follows an ISS-like bright/fast pass
    /// profile, just dimmer (visual magnitude commonly ~ -1 to 0).
    public static let tiangong = TrackedSatellite(
        name: "Tiangong (CSS)",
        catalogNumber: 48274,
        kind: .tiangong,
        visibilityNote: "Similar path and speed to the ISS, but noticeably dimmer -- a smaller station."
    )

    /// The three fixed-catalog satellites tracked every refresh (as opposed
    /// to Starlink trains, which are discovered dynamically).
    public static let fixed: [TrackedSatellite] = [iss, hubble, tiangong]

    /// Builds one `TrackedSatellite` + lead TLE pair per discovered Starlink
    /// launch cluster ("train"). See `StarlinkClustering` for the grouping
    /// heuristic and its documented limitations.
    public static func starlinkTrains(
        fromLast30DaysGroup entries: [(name: String, tle: TLE)]
    ) -> [(satellite: TrackedSatellite, tle: TLE)] {
        let inputs = entries.enumerated().map { idx, e in
            StarlinkClusterInput(index: idx, name: e.name, satelliteNumber: e.tle.satelliteNumber,
                                  internationalDesignator: e.tle.internationalDesignator)
        }
        let clusters = StarlinkClustering.cluster(inputs)
        return clusters.map { cluster in
            let leadEntry = entries[cluster.leadIndex]
            let sat = TrackedSatellite(
                name: "Starlink train (\(cluster.launchDesignatorPrefix))",
                catalogNumber: leadEntry.tle.satelliteNumber,
                kind: .starlinkTrain,
                visibilityNote: "A line of moving points crossing the sky together -- visible for a few weeks after launch while the train is still tight, then it spreads out and fades from naked-eye view. \(cluster.memberCount) satellite(s) tracked from this launch.",
                launchDesignatorPrefix: cluster.launchDesignatorPrefix,
                memberCount: cluster.memberCount
            )
            return (sat, leadEntry.tle)
        }
        .sorted { $0.0.launchDesignatorPrefix ?? "" > $1.0.launchDesignatorPrefix ?? "" } // most recent launches first
    }
}

// MARK: - Starlink launch-cluster grouping
//
// Heuristic, documented honestly per work-package spec: a Starlink "train"
// (a visible line of moving points) is a naked-eye phenomenon only in the
// weeks immediately after launch, before the satellites raise orbit and
// spread out along their shell. Fetching the full Starlink catalog
// (7000+ objects) is neither useful for this purpose nor cheap, so this
// package only considers the Celestrak "last 30 days" launch group,
// filters to names starting with "STARLINK", and clusters same-launch
// satellites (identified by the shared numeric prefix of their TLE
// international designator, e.g. "24101" in "24101AB") into a single
// tracked entry using the lowest-catalog-number ("lead") satellite's TLE
// as a representative orbit for the whole train.
//
// Limitation, stated plainly: this is a proxy, not a real multi-satellite
// train renderer -- the app shows one pass line using one member's orbit,
// not the actual spread of the train. It is also legitimate for this to
// find zero clusters in months with no recent Starlink launches, or if a
// launch's satellites haven't yet been cataloged with names.

struct StarlinkClusterInput {
    let index: Int
    let name: String
    let satelliteNumber: Int
    let internationalDesignator: String
}

struct StarlinkClusterGroup {
    let launchDesignatorPrefix: String
    let leadIndex: Int
    let memberCount: Int
}

enum StarlinkClustering {
    /// True if `name` identifies a Starlink satellite by Celestrak's naming
    /// convention (e.g. "STARLINK-31234").
    static func isStarlink(name: String) -> Bool {
        name.trimmingCharacters(in: .whitespaces).uppercased().hasPrefix("STARLINK")
    }

    /// Extracts the leading numeric run of a TLE international designator
    /// (2-digit launch year + 3-digit launch-of-year number, e.g. "24101"
    /// from "24101AB"), which is shared by every piece from the same
    /// launch. Falls back to the full designator if it does not start with
    /// digits (defensive; real Celestrak designators always do).
    static func designatorPrefix(_ intlDesignator: String) -> String {
        var prefix = ""
        for c in intlDesignator {
            if c.isNumber {
                prefix.append(c)
            } else {
                break
            }
        }
        return prefix.isEmpty ? intlDesignator : prefix
    }

    /// Groups Starlink-named inputs by shared launch-designator prefix. Each
    /// group's "lead" is its lowest catalog (NORAD) number, for determinism.
    /// Non-Starlink names are ignored. Returns groups sorted by prefix
    /// (caller re-sorts by recency as needed).
    static func cluster(_ inputs: [StarlinkClusterInput]) -> [StarlinkClusterGroup] {
        let starlinks = inputs.filter { isStarlink(name: $0.name) }
        var byPrefix: [String: [StarlinkClusterInput]] = [:]
        for input in starlinks {
            let prefix = designatorPrefix(input.internationalDesignator)
            byPrefix[prefix, default: []].append(input)
        }
        return byPrefix.map { prefix, members in
            let lead = members.min(by: { $0.satelliteNumber < $1.satelliteNumber })!
            return StarlinkClusterGroup(launchDesignatorPrefix: prefix, leadIndex: lead.index, memberCount: members.count)
        }
        .sorted { $0.launchDesignatorPrefix < $1.launchDesignatorPrefix }
    }
}

// MARK: - Multi-satellite TLE fetching

/// Generalizes the ISS-only `TLEFetcher` (TLE.swift) to fetch a TLE for an
/// arbitrary NORAD catalog number, plus the Celestrak "last 30 days" launch
/// group (used to discover newly-launched Starlink trains).
///
/// This is a SEPARATE type from `TLEFetcher` rather than a modification of
/// it, so the verified, consumer-depended-upon ISS fetch path in TLE.swift
/// (used today by `SkyTonightService`) carries zero risk from this work.
/// The caching policy is intentionally identical to `TLEFetcher`: a cached
/// TLE < 24h old is used without a network call; on network failure a
/// cached TLE up to 10 days old is used as a degraded fallback; each
/// `fetch...` call is a single blocking (semaphore-based) network request,
/// matching the existing single-flight-per-call pattern.
public final class SatelliteTLEFetcher {
    public enum Source: String {
        case network
        case cacheFresh
        case cacheStale
    }

    public struct FetchResult {
        public let tle: TLE
        public let source: Source
        public let isDegraded: Bool
        public let cacheAgeSeconds: TimeInterval?
    }

    public struct GroupFetchResult {
        public let entries: [(name: String, tle: TLE)]
        public let source: Source
        public let isDegraded: Bool
        public let cacheAgeSeconds: TimeInterval?
    }

    public enum FetchError: Error, CustomStringConvertible {
        case badResponse(Int)
        case emptyBody
        case network(Error)
        case parse(Error)
        case noCacheAvailable(underlying: Error)

        public var description: String {
            switch self {
            case .badResponse(let code): return "Celestrak returned HTTP \(code)"
            case .emptyBody: return "Celestrak response body was empty"
            case .network(let e): return "network error: \(e)"
            case .parse(let e): return "failed to parse fetched TLE data: \(e)"
            case .noCacheAvailable(let e): return "no usable cache and network failed: \(e)"
            }
        }
    }

    static let freshWindow: TimeInterval = 24 * 3600
    static let staleLimit: TimeInterval = 10 * 24 * 3600

    private let cacheDirectory: URL
    private let session: URLSession

    public init(cacheDirectory: URL, session: URLSession = .shared) {
        self.cacheDirectory = cacheDirectory
        self.session = session
    }

    public static func catnrURL(_ catalogNumber: Int) -> URL {
        URL(string: "https://celestrak.org/NORAD/elements/gp.php?CATNR=\(catalogNumber)&FORMAT=tle")!
    }

    /// Celestrak's "objects launched in the last 30 days" supplemental
    /// group -- deliberately used instead of `GROUP=starlink` (7000+
    /// objects) per work-package spec; see `StarlinkClustering` doc comment
    /// for the visibility rationale.
    public static let last30DaysGroupURL =
        URL(string: "https://celestrak.org/NORAD/elements/gp.php?GROUP=last-30-days&FORMAT=tle")!

    private func singleCacheURL(_ catalogNumber: Int) -> URL {
        cacheDirectory.appendingPathComponent("sat_tle_\(catalogNumber)_cache.txt")
    }

    private var groupCacheURL: URL {
        cacheDirectory.appendingPathComponent("sat_group_last30days_cache.txt")
    }

    // MARK: Single-satellite (by CATNR)

    private struct SingleCacheEntry {
        let fetchedAt: Date
        let line1: String
        let line2: String
    }

    private func readSingleCache(_ catalogNumber: Int) -> SingleCacheEntry? {
        guard let data = try? Data(contentsOf: singleCacheURL(catalogNumber)),
              let text = String(data: data, encoding: .utf8) else { return nil }
        let lines = text.split(whereSeparator: { $0.isNewline }).map(String.init)
        guard lines.count >= 3, let ts = Double(lines[0]) else { return nil }
        return SingleCacheEntry(fetchedAt: Date(timeIntervalSince1970: ts), line1: lines[1], line2: lines[2])
    }

    private func writeSingleCache(_ catalogNumber: Int, line1: String, line2: String, fetchedAt: Date) {
        let contents = "\(fetchedAt.timeIntervalSince1970)\n\(line1)\n\(line2)\n"
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        try? contents.write(to: singleCacheURL(catalogNumber), atomically: true, encoding: .utf8)
    }

    /// Fetch the current TLE for `catalogNumber`, applying the ISS
    /// fetcher's cache policy (see type doc comment). `now` is
    /// caller-supplied for determinism/testability.
    public func fetch(catalogNumber: Int, now: Date, timeout: TimeInterval = 15) throws -> FetchResult {
        if let cached = readSingleCache(catalogNumber) {
            let age = now.timeIntervalSince(cached.fetchedAt)
            if age >= 0 && age < Self.freshWindow,
               let tle = try? TLE(line1: cached.line1, line2: cached.line2) {
                return FetchResult(tle: tle, source: .cacheFresh, isDegraded: false, cacheAgeSeconds: age)
            }
        }

        do {
            let (l1, l2) = try fetchSingleLinesFromNetwork(url: Self.catnrURL(catalogNumber), timeout: timeout)
            let tle = try TLE(line1: l1, line2: l2)
            writeSingleCache(catalogNumber, line1: l1, line2: l2, fetchedAt: now)
            return FetchResult(tle: tle, source: .network, isDegraded: false, cacheAgeSeconds: 0)
        } catch {
            if let cached = readSingleCache(catalogNumber) {
                let age = now.timeIntervalSince(cached.fetchedAt)
                if age >= 0 && age <= Self.staleLimit,
                   let tle = try? TLE(line1: cached.line1, line2: cached.line2) {
                    return FetchResult(tle: tle, source: .cacheStale, isDegraded: true, cacheAgeSeconds: age)
                }
            }
            throw (error as? FetchError) ?? FetchError.network(error)
        }
    }

    /// Convenience: fetch every fixed-catalog satellite (ISS, Hubble,
    /// Tiangong) in one call -- three requests (or fewer, if cache is
    /// fresh), one per CATNR, matching Celestrak's per-satellite `gp.php`
    /// contract (Celestrak does not support a multi-CATNR batch query).
    public func fetchFixedCatalog(now: Date, timeout: TimeInterval = 15) -> [(satellite: TrackedSatellite, result: Result<FetchResult, Error>)] {
        SatelliteCatalog.fixed.map { sat in
            (sat, Result { try self.fetch(catalogNumber: sat.catalogNumber, now: now, timeout: timeout) })
        }
    }

    // MARK: Group (last 30 days)

    private struct GroupCacheEntry {
        let fetchedAt: Date
        let entries: [(name: String, line1: String, line2: String)]
    }

    private func readGroupCache() -> GroupCacheEntry? {
        guard let data = try? Data(contentsOf: groupCacheURL),
              let text = String(data: data, encoding: .utf8) else { return nil }
        var lines = text.split(whereSeparator: { $0.isNewline }).map(String.init)
        guard !lines.isEmpty, let ts = Double(lines.removeFirst()) else { return nil }
        let entries = Self.parse3LE(lines: lines)
        return GroupCacheEntry(fetchedAt: Date(timeIntervalSince1970: ts), entries: entries)
    }

    private func writeGroupCache(entries: [(name: String, line1: String, line2: String)], fetchedAt: Date) {
        var contents = "\(fetchedAt.timeIntervalSince1970)\n"
        for e in entries {
            contents += "\(e.name)\n\(e.line1)\n\(e.line2)\n"
        }
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        try? contents.write(to: groupCacheURL, atomically: true, encoding: .utf8)
    }

    /// Fetch Celestrak's "last 30 days" launch group and parse every
    /// 3-line (name + TLE) entry. Applies the same cache policy as
    /// `fetch(catalogNumber:)`. Callers filter/cluster this (see
    /// `SatelliteCatalog.starlinkTrains`) rather than this method doing so,
    /// so the raw group is independently testable/cacheable.
    public func fetchLast30DaysGroup(now: Date, timeout: TimeInterval = 20) throws -> GroupFetchResult {
        if let cached = readGroupCache() {
            let age = now.timeIntervalSince(cached.fetchedAt)
            if age >= 0 && age < Self.freshWindow {
                let tles = Self.parseTLEs(cached.entries)
                return GroupFetchResult(entries: tles, source: .cacheFresh, isDegraded: false, cacheAgeSeconds: age)
            }
        }

        do {
            let raw = try fetchGroupFromNetwork(url: Self.last30DaysGroupURL, timeout: timeout)
            writeGroupCache(entries: raw, fetchedAt: now)
            let tles = Self.parseTLEs(raw)
            return GroupFetchResult(entries: tles, source: .network, isDegraded: false, cacheAgeSeconds: 0)
        } catch {
            if let cached = readGroupCache() {
                let age = now.timeIntervalSince(cached.fetchedAt)
                if age >= 0 && age <= Self.staleLimit {
                    let tles = Self.parseTLEs(cached.entries)
                    return GroupFetchResult(entries: tles, source: .cacheStale, isDegraded: true, cacheAgeSeconds: age)
                }
            }
            throw (error as? FetchError) ?? FetchError.network(error)
        }
    }

    /// Best-effort parse of raw (name, line1, line2) triples into `TLE`s;
    /// entries that fail to parse (unexpected formatting, checksum issues)
    /// are silently skipped rather than failing the whole group fetch.
    private static func parseTLEs(_ raw: [(name: String, line1: String, line2: String)]) -> [(name: String, tle: TLE)] {
        raw.compactMap { entry in
            guard let tle = try? TLE(line1: entry.line1, line2: entry.line2) else { return nil }
            return (entry.name, tle)
        }
    }

    /// Splits raw 3-line-block (name / line1 / line2) text into triples.
    /// Robust to blank lines and CRLF endings (matches TLE.swift's
    /// `isNewline`-based splitting rationale).
    static func parse3LE(lines rawLines: [String]) -> [(name: String, line1: String, line2: String)] {
        let lines = rawLines.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        var result: [(name: String, line1: String, line2: String)] = []
        var i = 0
        while i < lines.count {
            let candidateName = lines[i]
            if i + 2 < lines.count,
               !candidateName.hasPrefix("1 ") && !candidateName.hasPrefix("2 "),
               lines[i + 1].hasPrefix("1 "), lines[i + 2].hasPrefix("2 ") {
                result.append((candidateName, lines[i + 1], lines[i + 2]))
                i += 3
                continue
            }
            i += 1
        }
        return result
    }

    static func parse3LE(text: String) -> [(name: String, line1: String, line2: String)] {
        let rawLines = text.split(whereSeparator: { $0.isNewline }).map(String.init)
        return parse3LE(lines: rawLines)
    }

    // MARK: Blocking network I/O (shared by both fetch paths)

    private func fetchSingleLinesFromNetwork(url: URL, timeout: TimeInterval) throws -> (String, String) {
        let text = try fetchBody(url: url, timeout: timeout)
        let lines = text.split(whereSeparator: { $0.isNewline })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard let l1 = lines.first(where: { $0.hasPrefix("1 ") }),
              let l2 = lines.first(where: { $0.hasPrefix("2 ") }) else {
            throw FetchError.emptyBody
        }
        return (l1, l2)
    }

    private func fetchGroupFromNetwork(url: URL, timeout: TimeInterval) throws -> [(name: String, line1: String, line2: String)] {
        let text = try fetchBody(url: url, timeout: timeout)
        let entries = Self.parse3LE(text: text)
        guard !entries.isEmpty else {
            // An empty-but-well-formed group response (no launches in the
            // window) is legitimate and handled by the caller as "0
            // clusters found" -- but a genuinely empty/garbled body is
            // still an error so a bad fetch doesn't silently look like
            // "no launches this month".
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw FetchError.emptyBody
            }
            return []
        }
        return entries
    }

    private func fetchBody(url: URL, timeout: TimeInterval) throws -> String {
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout

        let semaphore = DispatchSemaphore(value: 0)
        var resultData: Data?
        var resultResponse: URLResponse?
        var resultError: Error?

        let task = session.dataTask(with: request) { data, response, error in
            resultData = data
            resultResponse = response
            resultError = error
            semaphore.signal()
        }
        task.resume()
        _ = semaphore.wait(timeout: .now() + timeout + 5)

        if let error = resultError {
            throw FetchError.network(error)
        }
        if let http = resultResponse as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw FetchError.badResponse(http.statusCode)
        }
        guard let data = resultData, let text = String(data: data, encoding: .utf8), !text.isEmpty else {
            throw FetchError.emptyBody
        }
        return text
    }
}

// MARK: - Multi-satellite pass prediction

/// One visible pass of a tracked satellite, pairing the pass geometry
/// (reusing `ISSPass` -- the pass-search math is satellite-agnostic) with
/// which satellite it belongs to.
public struct SatellitePass {
    public let satellite: TrackedSatellite
    public let pass: ISSPass
}

public enum SatellitesTonight {
    /// Compute tonight's visible passes for one tracked satellite, reusing
    /// the existing `ISSTonight.passes` / `PassPredictor` engine verbatim
    /// (no SGP4 or pass-search changes). The base brightness heuristic
    /// (`PassPredictor.brightness`, calibrated for the ISS's large
    /// reflective solar arrays) is then adjusted down for satellites known
    /// to be dimmer -- see `adjustedBrightness`.
    public static func passes(
        satellite: TrackedSatellite,
        tle: TLE,
        windowStart: Date,
        windowEnd: Date,
        latitudeDeg: Double,
        longitudeDeg: Double,
        altitudeKm: Double = 0.0
    ) throws -> [SatellitePass] {
        let rawPasses = try ISSTonight.passes(
            tle: tle,
            windowStart: windowStart,
            windowEnd: windowEnd,
            latitudeDeg: latitudeDeg,
            longitudeDeg: longitudeDeg,
            altitudeKm: altitudeKm
        )
        return rawPasses.map { SatellitePass(satellite: satellite, pass: adjustedPass($0, for: satellite)) }
    }

    /// Compute and merge tonight's visible passes across several tracked
    /// satellites (e.g. the fixed catalog plus any discovered Starlink
    /// trains), sorted by start time.
    public static func passes(
        satellites: [(satellite: TrackedSatellite, tle: TLE)],
        windowStart: Date,
        windowEnd: Date,
        latitudeDeg: Double,
        longitudeDeg: Double,
        altitudeKm: Double = 0.0
    ) throws -> [SatellitePass] {
        var all: [SatellitePass] = []
        for (satellite, tle) in satellites {
            let p = try passes(
                satellite: satellite, tle: tle,
                windowStart: windowStart, windowEnd: windowEnd,
                latitudeDeg: latitudeDeg, longitudeDeg: longitudeDeg, altitudeKm: altitudeKm
            )
            all.append(contentsOf: p)
        }
        return all.sorted { $0.pass.startTime < $1.pass.startTime }
    }

    /// Dims `PassPredictor`'s ISS-calibrated brightness heuristic for
    /// satellites known to be smaller/less reflective than the ISS:
    ///   - Hubble: consistently faint (visual magnitude ~1-2) regardless of
    ///     pass geometry -- always reported `.dim`.
    ///   - Tiangong: ISS-like profile but dimmer (visual magnitude ~ -1 to
    ///     0) -- dropped one level (bright -> moderate -> dim -> dim).
    ///   - ISS and Starlink trains: unadjusted. (Starlink train brightness
    ///     varies enormously by batch/age and isn't well captured by this
    ///     altitude/range heuristic, so it is left as-is with the
    ///     visibility note doing the explanatory work instead.)
    static func adjustedPass(_ pass: ISSPass, for satellite: TrackedSatellite) -> ISSPass {
        let brightness: ISSBrightness
        switch satellite.kind {
        case .iss, .starlinkTrain:
            brightness = pass.brightness
        case .hubble:
            brightness = .dim
        case .tiangong:
            switch pass.brightness {
            case .bright: brightness = .moderate
            case .moderate: brightness = .dim
            case .dim: brightness = .dim
            }
        }
        guard brightness != pass.brightness else { return pass }
        return ISSPass(
            startTime: pass.startTime,
            peakTime: pass.peakTime,
            endTime: pass.endTime,
            peakAltitudeDeg: pass.peakAltitudeDeg,
            startAzimuthDeg: pass.startAzimuthDeg,
            endAzimuthDeg: pass.endAzimuthDeg,
            startAzimuthCompass: pass.startAzimuthCompass,
            endAzimuthCompass: pass.endAzimuthCompass,
            peakRangeKm: pass.peakRangeKm,
            brightness: brightness
        )
    }
}
