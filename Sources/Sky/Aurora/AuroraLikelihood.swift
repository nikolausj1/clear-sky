import Foundation

// Pure computation over NOAA's two aurora feeds. No networking, no `Date()` defaults — every
// "now"/"tonight" instant is supplied by the caller so this file is deterministic and can be
// exercised entirely with canned JSON (see Tests/AuroraSmokeTest.swift).

// MARK: - Qualitative band

/// Qualitative aurora-viewing outlook for tonight, from least to most promising.
enum AuroraBand: Int, Comparable, CaseIterable, CustomStringConvertible {
    case none
    case low
    case fair
    case good
    case strong

    static func < (lhs: AuroraBand, rhs: AuroraBand) -> Bool { lhs.rawValue < rhs.rawValue }

    var description: String {
        switch self {
        case .none: return "none"
        case .low: return "low"
        case .fair: return "fair"
        case .good: return "good"
        case .strong: return "strong"
        }
    }
}

// MARK: - Combined outlook

/// The result the app actually shows: a blend of the OVATION "right now" reading and the Kp
/// forecast's "tonight" outlook, for one caller-supplied location and one caller-supplied dark-
/// hours window.
struct AuroraOutlook: Equatable {
    /// OVATION probability (0-100) at the caller's location right now: the higher of the
    /// nearest-grid-point reading and the max within `AuroraLikelihood.nearbyRadiusDegrees`
    /// (see `AuroraLikelihood.lookup` for why both are reported).
    let chanceNow: Int
    /// The highest forecast Kp across all 3-hour buckets that overlap tonight's dark hours.
    let tonightPeakKp: Double
    /// The bucket(s) tied for `tonightPeakKp`, clipped to dark hours.
    let tonightPeakKpWindow: DateInterval
    /// Overlap of the caller's dark hours with the peak-Kp bucket(s). Currently identical to
    /// `tonightPeakKpWindow` (see doc on `outlook(...)`), kept as a separate field because the
    /// two are conceptually distinct and may diverge if the windowing policy changes.
    let bestViewingWindow: DateInterval
    /// See `AuroraBand` and the thresholds documented on `outlook(...)`.
    let band: AuroraBand
    /// Geomagnetic latitude of the caller's location (`AuroraLikelihood.geomagneticLatitude`).
    let geomagneticLatitude: Double
    /// The Kp-to-latitude visibility threshold used to score `band`, i.e.
    /// `visibilityLatitude(forKp: tonightPeakKp)`.
    let visibilityLatitudeThreshold: Double
}

enum AuroraLikelihood {
    // MARK: - OVATION grid lookup

    /// How far (in whole degrees, in both latitude and longitude) around the nearest grid point
    /// to search for `maxNearbyProbability`. See `lookup(in:lat:lon:)` for the rationale.
    static let nearbyRadiusDegrees = 2

    /// The OVATION grid re-indexed for O(1) point lookups: `probability[lonIndex][latIndex]`
    /// where `lonIndex` is longitude 0...359 (already wrapped to that range) and
    /// `latIndex = latitude + 90` (0...180). Built once per grid fetch; lookups against it are
    /// then just array indexing rather than a linear scan of 65,160 points.
    struct IndexedGrid {
        private let probabilityTable: [[Int]]
        let observationDate: Date?
        let forecastDate: Date?

        init(grid: OvationGrid) {
            var table = Array(repeating: Array(repeating: 0, count: 181), count: 360)
            for coord in grid.coordinates {
                guard coord.count >= 3 else { continue }
                let lon = Int(coord[0].rounded())
                let lat = Int(coord[1].rounded())
                let prob = Int(coord[2].rounded())
                let lonIdx = ((lon % 360) + 360) % 360
                let latIdx = lat + 90
                guard latIdx >= 0, latIdx <= 180 else { continue }
                table[lonIdx][latIdx] = prob
            }
            self.probabilityTable = table
            self.observationDate = grid.observationDate
            self.forecastDate = grid.forecastDate
        }

        /// Direct constructor for tests that want to build a grid from raw values rather than
        /// going through `OvationGrid`'s wire shape.
        init(probabilityTable: [[Int]], observationDate: Date? = nil, forecastDate: Date? = nil) {
            self.probabilityTable = probabilityTable
            self.observationDate = observationDate
            self.forecastDate = forecastDate
        }

        /// Probability at an arbitrary (possibly out-of-range or wrapped) integer grid point.
        /// Longitude wraps modulo 360 (so -1 and 359 are the same column); latitude is clamped to
        /// -90...90 rather than wrapped (there's no "other side" of the pole on this grid).
        func probability(atLon lon: Int, lat: Int) -> Int {
            let lonIdx = ((lon % 360) + 360) % 360
            let latIdx = max(0, min(180, lat + 90))
            return probabilityTable[lonIdx][latIdx]
        }
    }

    struct GridLookupResult: Equatable {
        let nearestProbability: Int
        let maxNearbyProbability: Int
        let nearestGridPoint: (lon: Int, lat: Int)

        static func == (lhs: GridLookupResult, rhs: GridLookupResult) -> Bool {
            lhs.nearestProbability == rhs.nearestProbability
                && lhs.maxNearbyProbability == rhs.maxNearbyProbability
                && lhs.nearestGridPoint.lon == rhs.nearestGridPoint.lon
                && lhs.nearestGridPoint.lat == rhs.nearestGridPoint.lat
        }
    }

    /// Probability at the OVATION grid point nearest to (lat, lon), plus the max probability
    /// within `radiusDegrees` (default ~2 degrees, roughly 200 km) of it.
    ///
    /// Why "nearest + max-in-radius" instead of interpolation: OVATION's grid is a coarse
    /// 1-degree lattice, and the aurora oval's edge is sharp and moves on a timescale of tens of
    /// minutes — bilinear interpolation between grid points is just as likely to wash out a real,
    /// nearby bright cell as it is to smooth sensor noise. Reporting both numbers lets the app
    /// show "at your exact spot" (nearest) alongside "if you drove/looked toward the brightest
    /// nearby spot" (maxNearby), which is the simple, defensible choice most OVATION-based aurora
    /// apps make, rather than pretending to a false precision the grid doesn't have.
    static func lookup(
        in grid: IndexedGrid,
        lat: Double,
        lon: Double,
        radiusDegrees: Int = nearbyRadiusDegrees
    ) -> GridLookupResult {
        let nearestLat = Int(lat.rounded())
        let nearestLonRaw = Int(lon.rounded())
        let nearestLon = ((nearestLonRaw % 360) + 360) % 360
        let nearest = grid.probability(atLon: nearestLon, lat: nearestLat)

        var maxNearby = nearest
        for dLat in -radiusDegrees...radiusDegrees {
            let sampleLat = nearestLat + dLat
            guard sampleLat >= -90, sampleLat <= 90 else { continue }
            for dLon in -radiusDegrees...radiusDegrees {
                // Longitude wraparound (e.g. nearestLon 359, dLon +2 -> 361 -> wraps to 1) is
                // handled inside `probability(atLon:)`, so no special-casing is needed here.
                let sampleLon = nearestLon + dLon
                let p = grid.probability(atLon: sampleLon, lat: sampleLat)
                if p > maxNearby { maxNearby = p }
            }
        }
        return GridLookupResult(nearestProbability: nearest, maxNearbyProbability: maxNearby, nearestGridPoint: (nearestLon, nearestLat))
    }

    // MARK: - Geomagnetic latitude (centered-dipole approximation)

    /// Geographic coordinates of the north geomagnetic pole used for the centered-dipole
    /// approximation below. ~80.7 N, 72.7 W is the commonly cited current-epoch location of the
    /// geomagnetic (not magnetic-dip) pole derived from IGRF's first-order (dipole) coefficients
    /// — see e.g. NOAA NCEI's geomagnetic pole reference and the same figure reproduced by
    /// SpaceWeatherLive and other aurora-forecast background pages. The true pole drifts a small
    /// fraction of a degree per year; this is a fixed snapshot, adequate for placing a location
    /// relative to the Kp/latitude table below, not for research-grade oval modeling.
    static let geomagneticNorthPoleLatitude = 80.7
    static let geomagneticNorthPoleLongitude = -72.7

    /// Centered-dipole approximation of geomagnetic latitude from geographic (lat, lon), both in
    /// degrees. Standard spherical-triangle formula:
    /// `sin(geomagLat) = sin(lat)*sin(poleLat) + cos(lat)*cos(poleLat)*cos(lon - poleLon)`
    ///
    /// Sanity check baked into the smoke test: because the geomagnetic pole sits over northeastern
    /// Canada (west of the Greenwich meridian, like the contiguous US), locations in the north-
    /// central US end up *closer* to the geomagnetic pole than to the geographic pole along this
    /// great circle, so e.g. Tomah, WI (43.98 N, 90.50 W) comes out with a geomagnetic latitude
    /// (~52.7-53 N) noticeably *higher* than its geographic latitude — the well-known reason
    /// Upper-Midwest aurora chasers do better than their geographic latitude alone would suggest.
    /// Getting that sign/direction right is a good check that the dipole math (pole location,
    /// longitude-difference sign) isn't flipped.
    static func geomagneticLatitude(latitude: Double, longitude: Double) -> Double {
        let phi = latitude * .pi / 180
        let phiP = geomagneticNorthPoleLatitude * .pi / 180
        let dLon = (longitude - geomagneticNorthPoleLongitude) * .pi / 180
        let s = sin(phi) * sin(phiP) + cos(phi) * cos(phiP) * cos(dLon)
        return asin(min(max(s, -1), 1)) * 180 / .pi
    }

    // MARK: - Kp -> visibility latitude

    /// Kp index -> minimum geomagnetic latitude (degrees) at which the aurora becomes visible
    /// near the horizon, i.e. the equatorward edge of the auroral oval at that activity level.
    /// This is the widely reproduced table used across aurora-forecast background material
    /// (e.g. NOAA SWPC's aurora-viewing FAQ pages, the Geophysical Institute at University of
    /// Alaska Fairbanks aurora-forecast background, and secondary sources such as Wikipedia's
    /// "Aurora" article, all of which trace back to the same Feldstein/Starkov-derived oval
    /// statistics NOAA SWPC has published for decades):
    /// ```
    ///  Kp        0     1     2     3     4     5     6     7     8     9
    ///  min lat  66.5  64.5  62.4  60.4  58.3  56.3  54.2  52.2  50.1  48.1
    /// ```
    private static let kpVisibilityTable: [(kp: Double, latitude: Double)] = [
        (0, 66.5), (1, 64.5), (2, 62.4), (3, 60.4), (4, 58.3),
        (5, 56.3), (6, 54.2), (7, 52.2), (8, 50.1), (9, 48.1),
    ]

    /// Linearly interpolates the table above for fractional Kp (NOAA's forecast values are
    /// averages like 4.67 or 6.33, not integers). Clamped to the table's [0, 9] domain.
    static func visibilityLatitude(forKp kp: Double) -> Double {
        let clamped = min(max(kp, 0), 9)
        let lowerIdx = Int(clamped.rounded(.down))
        let upperIdx = min(lowerIdx + 1, kpVisibilityTable.count - 1)
        let lower = kpVisibilityTable[lowerIdx]
        let upper = kpVisibilityTable[upperIdx]
        guard upper.kp != lower.kp else { return lower.latitude }
        let fraction = (clamped - lower.kp) / (upper.kp - lower.kp)
        return lower.latitude + fraction * (upper.latitude - lower.latitude)
    }

    // MARK: - Combined outlook

    /// Builds tonight's `AuroraOutlook` from an OVATION grid, the Kp forecast, a location, and
    /// caller-supplied dark hours (typically tonight's sunset -> tomorrow's sunrise).
    ///
    /// **Windowing:** each `KpForecastRow` is the start of a 3-hour forecast bucket. A bucket
    /// "overlaps tonight" if `[row.date, row.date + 3h)` intersects `[darkHoursStart,
    /// darkHoursEnd)`. Among the overlapping buckets, `tonightPeakKp` is the max `kp`;
    /// `tonightPeakKpWindow` is the union of the bucket(s) tied for that max, clipped to dark
    /// hours. `bestViewingWindow` is that same clipped window — since the peak-Kp buckets are
    /// already intersected with dark hours, "overlap of dark hours with peak-Kp hours" and
    /// "peak-Kp window" are the same interval by construction here. If no forecast bucket
    /// overlaps dark hours at all (e.g. a stale/short forecast), the outlook falls back to
    /// `chanceNow` alone with `tonightPeakKp == 0` and the window set to the full dark-hours span.
    ///
    /// **Band thresholds:** primarily driven by `margin = geomagneticLatitude - visibilityLatitude
    /// (forKp: tonightPeakKp)` — how far poleward (positive) or equatorward (negative) the
    /// location sits relative to tonight's forecast oval edge:
    /// ```
    ///  margin < -3      -> .none
    ///  -3  <= margin < 0 -> .low     (near miss; possible faint glow on the horizon)
    ///   0  <= margin < 3 -> .fair    (should be visible low in the sky)
    ///   3  <= margin < 8 -> .good    (should be visible well up in the sky)
    ///  margin >= 8       -> .strong  (likely overhead / high overall activity)
    /// ```
    /// `chanceNow` (OVATION, a live nowcast) can only *raise* the band, never lower it, because it
    /// describes a different instant (now) than the Kp-based band (tonight's forecast peak) — a
    /// currently-quiet OVATION reading doesn't disprove a forecast Kp spike hours from now, but a
    /// currently-bright OVATION reading is real signal worth surfacing immediately:
    /// ```
    ///  chanceNow >= 50 -> band raised to at least .good
    ///  chanceNow >= 25 -> band raised to at least .fair
    ///  chanceNow >= 10 -> band raised to at least .low
    /// ```
    static func outlook(
        grid: IndexedGrid,
        kpForecast: [KpForecastRow],
        latitude: Double,
        longitude: Double,
        darkHoursStart: Date,
        darkHoursEnd: Date
    ) -> AuroraOutlook {
        let gridLookup = lookup(in: grid, lat: latitude, lon: longitude)
        let chanceNow = max(gridLookup.nearestProbability, gridLookup.maxNearbyProbability)
        let geomagLat = geomagneticLatitude(latitude: latitude, longitude: longitude)
        let darkInterval = DateInterval(start: darkHoursStart, end: darkHoursEnd)

        let bucketSeconds: TimeInterval = 3 * 60 * 60
        let overlapping: [(row: KpForecastRow, window: DateInterval)] = kpForecast.compactMap { row in
            guard let start = row.date else { return nil }
            let bucket = DateInterval(start: start, end: start.addingTimeInterval(bucketSeconds))
            guard let overlap = darkInterval.intersection(with: bucket), overlap.duration > 0 else { return nil }
            return (row, overlap)
        }

        guard !overlapping.isEmpty else {
            let threshold = visibilityLatitude(forKp: 0)
            let band = bandFromChanceNow(chanceNow, floor: .none)
            return AuroraOutlook(
                chanceNow: chanceNow,
                tonightPeakKp: 0,
                tonightPeakKpWindow: darkInterval,
                bestViewingWindow: darkInterval,
                band: band,
                geomagneticLatitude: geomagLat,
                visibilityLatitudeThreshold: threshold
            )
        }

        let peakKp = overlapping.map(\.row.kp).max()!
        let peakBuckets = overlapping.filter { $0.row.kp == peakKp }
        let windowStart = peakBuckets.map(\.window.start).min()!
        let windowEnd = peakBuckets.map(\.window.end).max()!
        let peakWindow = DateInterval(start: windowStart, end: windowEnd)

        let threshold = visibilityLatitude(forKp: peakKp)
        let margin = geomagLat - threshold
        let kpBand: AuroraBand
        switch margin {
        case ..<(-3): kpBand = .none
        case -3..<0: kpBand = .low
        case 0..<3: kpBand = .fair
        case 3..<8: kpBand = .good
        default: kpBand = .strong
        }
        let band = bandFromChanceNow(chanceNow, floor: kpBand)

        return AuroraOutlook(
            chanceNow: chanceNow,
            tonightPeakKp: peakKp,
            tonightPeakKpWindow: peakWindow,
            bestViewingWindow: peakWindow,
            band: band,
            geomagneticLatitude: geomagLat,
            visibilityLatitudeThreshold: threshold
        )
    }

    private static func bandFromChanceNow(_ chanceNow: Int, floor: AuroraBand) -> AuroraBand {
        var band = floor
        if chanceNow >= 50 { band = max(band, .good) }
        else if chanceNow >= 25 { band = max(band, .fair) }
        else if chanceNow >= 10 { band = max(band, .low) }
        return band
    }
}
