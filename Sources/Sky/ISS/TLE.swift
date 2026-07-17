import Foundation

// MARK: - TLE parsing
//
// Parses NORAD two-line element sets (TLE format). This file is the ONLY
// place in Sources/Sky/ISS that touches the network (via `TLEFetcher`,
// below) -- SGP4.swift / PassPredictor.swift / ISSTonight.swift are pure
// math and never import networking, so they stay CLI-testable offline.

public struct TLE: Equatable {
    public let line1: String
    public let line2: String

    public let satelliteNumber: Int
    public let classification: Character
    public let internationalDesignator: String
    public let epoch: Date
    public let epochYear: Int
    public let epochDayOfYear: Double // 1-based, fractional
    /// First derivative of mean motion / 2 (rev/day^2). Parsed for
    /// completeness but NOT used by the modern SGP4 algorithm implemented
    /// here (this matches the reference "Revisiting Spacetrack Report #3"
    /// implementation, which also does not use it operationally).
    public let meanMotionDot: Double
    /// Second derivative of mean motion / 6 (rev/day^3). Parsed but unused,
    /// same rationale as `meanMotionDot`.
    public let meanMotionDDot: Double
    /// BSTAR drag term, units of (earth radii)^-1.
    public let bstar: Double
    public let ephemerisType: Int
    public let elementSetNumber: Int

    public let inclinationDeg: Double
    public let raanDeg: Double
    public let eccentricity: Double
    public let argPerigeeDeg: Double
    public let meanAnomalyDeg: Double
    public let meanMotionRevPerDay: Double
    public let revolutionNumber: Int

    public enum TLEParseError: Error, CustomStringConvertible {
        case tooShort(line: Int)
        case wrongLineNumber(expected: Int, got: String)
        case checksumMismatch(line: Int, expected: Int, got: Int)
        case badField(line: Int, field: String, value: String)
        case satelliteNumberMismatch

        public var description: String {
            switch self {
            case .tooShort(let line): return "TLE line \(line) is too short"
            case .wrongLineNumber(let expected, let got): return "expected line \(expected), got '\(got)'"
            case .checksumMismatch(let line, let expected, let got):
                return "TLE line \(line) checksum mismatch: expected \(expected), computed \(got)"
            case .badField(let line, let field, let value):
                return "TLE line \(line) field '\(field)' has unparsable value '\(value)'"
            case .satelliteNumberMismatch:
                return "satellite number differs between line 1 and line 2"
            }
        }
    }

    /// Computes the mod-10 TLE line checksum: sum of all digits, with '-'
    /// counting as 1 and all other characters (letters, '.', '+', spaces)
    /// counting as 0, over all characters except the checksum digit itself.
    public static func checksum(of line: String) -> Int {
        var sum = 0
        let chars = Array(line)
        let end = min(chars.count, 68) // checksum covers columns 1-68 (0-indexed 0..<68)
        for i in 0..<end {
            let c = chars[i]
            if let d = c.wholeNumberValue, c.isASCII, c.isNumber {
                sum += d
            } else if c == "-" {
                sum += 1
            }
        }
        return sum % 10
    }

    public init(line1 rawLine1: String, line2 rawLine2: String, validateChecksum: Bool = true) throws {
        let line1 = rawLine1.trimmingCharacters(in: .whitespaces)
        let line2 = rawLine2.trimmingCharacters(in: .whitespaces)
        self.line1 = line1
        self.line2 = line2

        guard line1.count >= 69 else { throw TLEParseError.tooShort(line: 1) }
        guard line2.count >= 69 else { throw TLEParseError.tooShort(line: 2) }
        guard line1.hasPrefix("1") else { throw TLEParseError.wrongLineNumber(expected: 1, got: String(line1.prefix(1))) }
        guard line2.hasPrefix("2") else { throw TLEParseError.wrongLineNumber(expected: 2, got: String(line2.prefix(1))) }

        if validateChecksum {
            let expected1 = Int(String(line1.last!)) ?? -1
            let got1 = TLE.checksum(of: line1)
            guard expected1 == got1 else { throw TLEParseError.checksumMismatch(line: 1, expected: expected1, got: got1) }
            let expected2 = Int(String(line2.last!)) ?? -1
            let got2 = TLE.checksum(of: line2)
            guard expected2 == got2 else { throw TLEParseError.checksumMismatch(line: 2, expected: expected2, got: got2) }
        }

        func substr(_ s: String, _ range: Range<Int>) -> String {
            let chars = Array(s)
            let lo = max(0, min(range.lowerBound, chars.count))
            let hi = max(lo, min(range.upperBound, chars.count))
            return String(chars[lo..<hi]).trimmingCharacters(in: .whitespaces)
        }

        // --- Line 1 ---
        guard let satNum1 = Int(substr(line1, 2..<7)) else {
            throw TLEParseError.badField(line: 1, field: "satelliteNumber", value: substr(line1, 2..<7))
        }
        self.satelliteNumber = satNum1
        self.classification = Array(substr(line1, 7..<8)).first ?? "U"
        self.internationalDesignator = substr(line1, 9..<17)

        let epochYY = Int(substr(line1, 18..<20)) ?? 0
        guard let epochDay = Double(substr(line1, 20..<32)) else {
            throw TLEParseError.badField(line: 1, field: "epochDay", value: substr(line1, 20..<32))
        }
        self.epochYear = epochYY < 57 ? 2000 + epochYY : 1900 + epochYY
        self.epochDayOfYear = epochDay

        // ndot/2 field: signed decimal, columns 34-43 (plain decimal, not exponential).
        let ndotStr = substr(line1, 33..<43)
        self.meanMotionDot = Double(ndotStr) ?? 0.0

        // nddot/6 field: assumed decimal point + exponent, columns 45-52, e.g. " 12345-3" -> 0.12345e-3
        func parseAssumedDecimalExponential(_ raw: String) -> Double {
            let s = raw.trimmingCharacters(in: .whitespaces)
            guard !s.isEmpty else { return 0.0 }
            var sign = 1.0
            var body = s
            if body.hasPrefix("-") { sign = -1.0; body.removeFirst() }
            else if body.hasPrefix("+") { body.removeFirst() }
            // Find exponent sign (+ or -) that is not the first character.
            var mantissaStr = body
            var expStr = "0"
            if let idx = body.lastIndex(where: { $0 == "+" || $0 == "-" }) {
                mantissaStr = String(body[body.startIndex..<idx])
                expStr = String(body[idx...])
            }
            let mantissa = Double("0." + mantissaStr) ?? 0.0
            let exponent = Double(expStr) ?? 0.0
            return sign * mantissa * pow(10.0, exponent)
        }
        self.meanMotionDDot = parseAssumedDecimalExponential(substr(line1, 44..<52))
        self.bstar = parseAssumedDecimalExponential(substr(line1, 53..<61))
        self.ephemerisType = Int(substr(line1, 62..<63)) ?? 0
        self.elementSetNumber = Int(substr(line1, 64..<68)) ?? 0

        // --- Line 2 ---
        guard let satNum2 = Int(substr(line2, 2..<7)) else {
            throw TLEParseError.badField(line: 2, field: "satelliteNumber", value: substr(line2, 2..<7))
        }
        guard satNum2 == satNum1 else { throw TLEParseError.satelliteNumberMismatch }

        guard let incl = Double(substr(line2, 8..<16)) else {
            throw TLEParseError.badField(line: 2, field: "inclination", value: substr(line2, 8..<16))
        }
        guard let raan = Double(substr(line2, 17..<25)) else {
            throw TLEParseError.badField(line: 2, field: "raan", value: substr(line2, 17..<25))
        }
        let eccStr = substr(line2, 26..<33)
        guard let ecc = Double("0." + eccStr) else {
            throw TLEParseError.badField(line: 2, field: "eccentricity", value: eccStr)
        }
        guard let argp = Double(substr(line2, 34..<42)) else {
            throw TLEParseError.badField(line: 2, field: "argOfPerigee", value: substr(line2, 34..<42))
        }
        guard let ma = Double(substr(line2, 43..<51)) else {
            throw TLEParseError.badField(line: 2, field: "meanAnomaly", value: substr(line2, 43..<51))
        }
        guard let mm = Double(substr(line2, 52..<63)) else {
            throw TLEParseError.badField(line: 2, field: "meanMotion", value: substr(line2, 52..<63))
        }
        let revNum = Int(substr(line2, 63..<68)) ?? 0

        self.inclinationDeg = incl
        self.raanDeg = raan
        self.eccentricity = ecc
        self.argPerigeeDeg = argp
        self.meanAnomalyDeg = ma
        self.meanMotionRevPerDay = mm
        self.revolutionNumber = revNum

        // Epoch as a Date: Jan 1 00:00 UTC of epochYear, plus (epochDay - 1) days.
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        var comps = DateComponents()
        comps.year = self.epochYear
        comps.month = 1
        comps.day = 1
        comps.hour = 0
        comps.minute = 0
        comps.second = 0
        guard let jan1 = cal.date(from: comps) else {
            throw TLEParseError.badField(line: 1, field: "epoch", value: "\(self.epochYear)")
        }
        self.epoch = jan1.addingTimeInterval((epochDay - 1.0) * 86400.0)
    }

    /// Minutes elapsed from this TLE's epoch to `date`. Positive if `date`
    /// is after epoch.
    public func minutesSinceEpoch(at date: Date) -> Double {
        date.timeIntervalSince(epoch) / 60.0
    }
}

// MARK: - TLEFetcher (network isolated here)

/// Fetches the current ISS (NORAD catalog number 25544) TLE from Celestrak,
/// with an on-disk cache. This is the only networked type in Sources/Sky/ISS.
///
/// Cache policy:
///  - If a cached TLE exists and is < 24h old, it is used without a network
///    call (`.cacheFresh`).
///  - Otherwise a network fetch is attempted. On success the cache is
///    updated and `.network` is returned.
///  - If the network fetch fails, a cached TLE up to 10 days old is used as
///    a degraded-accuracy fallback (`.cacheStale`, `isDegraded == true`).
///  - If no usable cache exists and the network fails, an error is thrown.
public final class TLEFetcher {
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
            case .parse(let e): return "failed to parse fetched TLE: \(e)"
            case .noCacheAvailable(let e): return "no usable cache and network failed: \(e)"
            }
        }
    }

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

    public static let celestrakURL = URL(string: "https://celestrak.org/NORAD/elements/gp.php?CATNR=25544&FORMAT=tle")!
    static let freshWindow: TimeInterval = 24 * 3600
    static let staleLimit: TimeInterval = 10 * 24 * 3600

    private let cacheDirectory: URL
    private let session: URLSession
    private let cacheFileName = "iss_tle_25544_cache.txt"

    public init(cacheDirectory: URL, session: URLSession = .shared) {
        self.cacheDirectory = cacheDirectory
        self.session = session
    }

    private var cacheURL: URL { cacheDirectory.appendingPathComponent(cacheFileName) }

    private struct CacheEntry {
        let fetchedAt: Date
        let line1: String
        let line2: String
    }

    private func readCache() -> CacheEntry? {
        guard let data = try? Data(contentsOf: cacheURL),
              let text = String(data: data, encoding: .utf8) else { return nil }
        let lines = text.split(whereSeparator: { $0.isNewline }).map(String.init)
        guard lines.count >= 3 else { return nil }
        guard let ts = Double(lines[0]) else { return nil }
        return CacheEntry(fetchedAt: Date(timeIntervalSince1970: ts), line1: lines[1], line2: lines[2])
    }

    private func writeCache(line1: String, line2: String, fetchedAt: Date) {
        let contents = "\(fetchedAt.timeIntervalSince1970)\n\(line1)\n\(line2)\n"
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        try? contents.write(to: cacheURL, atomically: true, encoding: .utf8)
    }

    /// Fetch the current ISS TLE, applying the cache policy described above.
    /// `now` is supplied by the caller for determinism/testability.
    public func fetch(now: Date, timeout: TimeInterval = 15) throws -> FetchResult {
        if let cached = readCache() {
            let age = now.timeIntervalSince(cached.fetchedAt)
            if age >= 0 && age < TLEFetcher.freshWindow {
                if let tle = try? TLE(line1: cached.line1, line2: cached.line2) {
                    return FetchResult(tle: tle, source: .cacheFresh, isDegraded: false, cacheAgeSeconds: age)
                }
            }
        }

        do {
            let (line1, line2) = try fetchFromNetwork(timeout: timeout)
            let tle = try TLE(line1: line1, line2: line2)
            writeCache(line1: line1, line2: line2, fetchedAt: now)
            return FetchResult(tle: tle, source: .network, isDegraded: false, cacheAgeSeconds: 0)
        } catch {
            if let cached = readCache() {
                let age = now.timeIntervalSince(cached.fetchedAt)
                if age >= 0 && age <= TLEFetcher.staleLimit,
                   let tle = try? TLE(line1: cached.line1, line2: cached.line2) {
                    return FetchResult(tle: tle, source: .cacheStale, isDegraded: true, cacheAgeSeconds: age)
                }
            }
            throw (error as? FetchError) ?? FetchError.network(error)
        }
    }

    /// Blocking network fetch (uses a semaphore so this works from a plain
    /// synchronous CLI without needing Swift concurrency machinery).
    private func fetchFromNetwork(timeout: TimeInterval) throws -> (String, String) {
        var request = URLRequest(url: TLEFetcher.celestrakURL)
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

        // NOTE: split on `Character.isNewline` rather than separator: "\n" --
        // Celestrak (and many servers) send CRLF line endings, and Swift's
        // grapheme-cluster-aware String treats "\r\n" as a single Character,
        // so separator: "\n" silently fails to split at all.
        let lines = text.split(whereSeparator: { $0.isNewline })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard let l1 = lines.first(where: { $0.hasPrefix("1 ") }),
              let l2 = lines.first(where: { $0.hasPrefix("2 ") }) else {
            throw FetchError.emptyBody
        }
        return (l1, l2)
    }
}
