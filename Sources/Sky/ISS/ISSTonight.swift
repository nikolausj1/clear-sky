import Foundation

// MARK: - Top-level "Tonight's Sky" ISS API.
//
// Deterministic: takes an explicit date/night-window and TLE, never reads
// the system clock internally. The caller (e.g. the app's Tonight's Sky
// feature) is responsible for supplying "now" / "tonight" and for calling
// `TLEFetcher` separately to obtain a `TLE`.

public enum ISSTonight {

    /// Compute tonight's visible ISS passes for an observer.
    ///
    /// - Parameters:
    ///   - tle: A parsed ISS TLE (see `TLE` / `TLEFetcher`).
    ///   - windowStart: Start of the night window to search (e.g. sunset, or
    ///     "now" if computing for the remainder of tonight).
    ///   - windowEnd: End of the night window to search (e.g. sunrise the
    ///     next morning).
    ///   - latitudeDeg: Observer geodetic latitude, degrees (+N).
    ///   - longitudeDeg: Observer geodetic longitude, degrees (+E).
    ///   - altitudeKm: Observer altitude above the WGS84 ellipsoid, km
    ///     (0 is a fine approximation for pass prediction).
    /// - Returns: Visible passes within the window, in chronological order.
    ///   Empty if no passes meet the visibility criteria (ISS altitude
    ///   > 10 deg, observer sun elevation < -6 deg, ISS sunlit).
    /// - Throws: `SGP4Error.deepSpaceUnsupported` if the supplied TLE's
    ///   orbital period requires deep-space (SDP4) propagation (should never
    ///   happen for the real ISS, but is surfaced cleanly rather than
    ///   silently producing wrong results for a malformed/wrong TLE).
    public static func passes(
        tle: TLE,
        windowStart: Date,
        windowEnd: Date,
        latitudeDeg: Double,
        longitudeDeg: Double,
        altitudeKm: Double = 0.0
    ) throws -> [ISSPass] {
        let propagator = try SGP4Propagator(tle: tle)
        let observer = GeoCoordinate(latitudeDeg: latitudeDeg, longitudeDeg: longitudeDeg, altitudeKm: altitudeKm)
        return try PassPredictor.findPasses(
            tle: tle,
            propagator: propagator,
            observer: observer,
            windowStart: windowStart,
            windowEnd: windowEnd
        )
    }
}
