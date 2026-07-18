import Foundation

/// Top-level entry point the "Space" tab calls: fetch (or reuse the cache for) all three NOAA
/// SWPC feeds via `SolarService`, then run `SolarActivity`'s pure math against the caller-supplied
/// "now", returning one `SolarOutlook`.
///
/// This is the only file in `Sources/Sky/Solar/` that touches both the fetch layer and the
/// computation layer — everything else keeps them isolated so the computation stays testable with
/// canned JSON (see `SolarActivity.swift`) and the fetch/cache behavior stays testable
/// independently (see `SolarService.swift`). Mirrors `Sources/Sky/Aurora/AuroraTonight.swift`.
enum SolarToday {
    /// Everything the app needs to render a "Space Weather" card: the computed outlook, whether
    /// any of the three feeds came from a stale cache (so the UI can show a "last updated"
    /// caveat), and the raw flare list (e.g. for a small recent-flares list).
    struct Result {
        let outlook: SolarOutlook
        let scalesIsStale: Bool
        let flaresIsStale: Bool
        let sunspotsIsStale: Bool
        let flares: [FlareEvent]
    }

    /// - Parameters:
    ///   - now: the instant to evaluate activity/notability against (see
    ///     `SolarActivity.outlook(...)`'s trailing-24h window).
    ///   - cacheDirectory: directory `SolarService` may read/write its on-disk cache files in.
    ///     Caller-supplied so this stays pure Foundation with no hardcoded app-container path.
    ///   - session: injectable for testing; defaults to `.shared`.
    static func fetch(
        now: Date = Date(),
        cacheDirectory: URL,
        session: URLSession = .shared
    ) async throws -> Result {
        let service = SolarService(session: session)
        async let scalesFetch = service.fetchScales(cacheDirectory: cacheDirectory)
        async let flaresFetch = service.fetchFlares(cacheDirectory: cacheDirectory)
        async let sunspotsFetch = service.fetchSunspots(cacheDirectory: cacheDirectory)

        let (scales, scalesIsStale) = try await scalesFetch
        let (flares, flaresIsStale) = try await flaresFetch
        let (sunspots, sunspotsIsStale) = try await sunspotsFetch

        let outlook = SolarActivity.outlook(scales: scales, flares: flares, sunspots: sunspots, now: now)

        return Result(
            outlook: outlook,
            scalesIsStale: scalesIsStale,
            flaresIsStale: flaresIsStale,
            sunspotsIsStale: sunspotsIsStale,
            flares: flares
        )
    }
}
