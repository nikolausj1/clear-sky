import Foundation

/// Top-level entry point the "Tonight's Sky" feature calls: fetch (or reuse the cache for) both
/// NOAA SWPC feeds via `AuroraService`, then run `AuroraLikelihood`'s pure math against the
/// caller's location and tonight's dark-hours window, returning one `AuroraOutlook`.
///
/// This is the only file in `Sources/Sky/Aurora/` that touches both the fetch layer and the
/// computation layer — everything else keeps them isolated so the computation stays testable
/// with canned JSON (see `AuroraLikelihood.swift`) and the fetch/cache behavior stays testable
/// independently (see `AuroraService.swift`).
enum AuroraTonight {
    /// Everything the app needs to render the "Tonight's Sky" aurora card: the computed outlook,
    /// whether either feed came from a stale cache (so the UI can show a "last updated" caveat),
    /// the OVATION grid's own observation timestamp, and the raw Kp rows (e.g. for a small chart).
    struct Result {
        let outlook: AuroraOutlook
        let ovationIsStale: Bool
        let kpForecastIsStale: Bool
        let ovationObservationDate: Date?
        let kpForecastRows: [KpForecastRow]
    }

    /// - Parameters:
    ///   - latitude: caller's location, degrees north.
    ///   - longitude: caller's location, degrees east (negative for west), any range — wraparound
    ///     onto the OVATION grid's 0...359 convention is handled internally.
    ///   - tonightSunset: start of tonight's dark hours (typically today's sunset).
    ///   - tonightSunrise: end of tonight's dark hours (typically tomorrow's sunrise).
    ///   - cacheDirectory: directory `AuroraService` may read/write its on-disk cache files in.
    ///     Caller-supplied so this stays pure Foundation with no hardcoded app-container path.
    ///   - session: injectable for testing; defaults to `.shared`.
    static func fetch(
        latitude: Double,
        longitude: Double,
        tonightSunset: Date,
        tonightSunrise: Date,
        cacheDirectory: URL,
        session: URLSession = .shared
    ) async throws -> Result {
        let service = AuroraService(session: session)
        async let ovationFetch = service.fetchOvationGrid(cacheDirectory: cacheDirectory)
        async let kpFetch = service.fetchKpForecast(cacheDirectory: cacheDirectory)

        let (grid, ovationIsStale) = try await ovationFetch
        let (kpRows, kpIsStale) = try await kpFetch

        let indexedGrid = AuroraLikelihood.IndexedGrid(grid: grid)
        let outlook = AuroraLikelihood.outlook(
            grid: indexedGrid,
            kpForecast: kpRows,
            latitude: latitude,
            longitude: longitude,
            darkHoursStart: tonightSunset,
            darkHoursEnd: tonightSunrise
        )

        return Result(
            outlook: outlook,
            ovationIsStale: ovationIsStale,
            kpForecastIsStale: kpIsStale,
            ovationObservationDate: indexedGrid.observationDate,
            kpForecastRows: kpRows
        )
    }
}
