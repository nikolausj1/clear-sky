import Foundation

// MARK: - Top-level "Upcoming Launches" API.
//
// Combines `LaunchService`'s fetch/cache layer with `LaunchSchedule`'s pure mapping/filtering,
// same split as `Sources/Sky/Aurora/AuroraTonight.swift` for OVATION/Kp and
// `Sources/Sky/ISS/ISSTonight.swift` for TLE/SGP4: this is the only file in
// `Sources/Sky/Launches/` that touches both the network and the logic, so the logic stays
// testable against canned JSON and the fetch/cache behavior stays testable independently.

enum LaunchesUpcoming {
    /// Everything the app needs to render a "Rocket Launches" screen: the full mapped page (up to
    /// 15 launches, per the endpoint's `limit=15`) plus whether it came from a stale cache (so the
    /// UI can show a "last updated" caveat).
    struct Result {
        let launches: [UpcomingLaunch]
        let isStale: Bool
    }

    /// Fetches (or reuses the cache for) LL2's upcoming-launches page and maps it to
    /// `[UpcomingLaunch]`, in the order the feed returned it (LL2's `/launch/upcoming/` is already
    /// chronological, but callers that specifically want a filtered/sorted/trimmed "next N" list
    /// should use `nextLaunches(cacheDirectory:from:count:session:)` below instead, which also
    /// drops already-flown launches).
    ///
    /// - Parameters:
    ///   - cacheDirectory: directory `LaunchService` may read/write its on-disk cache file in.
    ///     Caller-supplied so this stays pure Foundation with no hardcoded app-container path.
    ///   - session: injectable for testing; defaults to `.shared`.
    static func fetch(cacheDirectory: URL, session: URLSession = .shared) async throws -> Result {
        let service = LaunchService(session: session)
        let (response, isStale) = try await service.fetchUpcomingLaunches(cacheDirectory: cacheDirectory)
        return Result(launches: LaunchSchedule.map(response.results), isStale: isStale)
    }

    /// Fetches and returns the next `count` upcoming launches, chronologically, with already-flown
    /// launches filtered out (see `LaunchSchedule.nextLaunches(from:now:count:)`).
    ///
    /// - Parameters:
    ///   - cacheDirectory: see `fetch(cacheDirectory:session:)`.
    ///   - now: caller-supplied "now" for determinism/testability -- this type never reads the
    ///     system clock itself.
    ///   - count: max number of launches to return (the underlying feed itself is capped at 15).
    ///   - session: injectable for testing; defaults to `.shared`.
    static func nextLaunches(
        cacheDirectory: URL,
        from now: Date,
        count: Int = 5,
        session: URLSession = .shared
    ) async throws -> (launches: [UpcomingLaunch], isStale: Bool) {
        let service = LaunchService(session: session)
        let (response, isStale) = try await service.fetchUpcomingLaunches(cacheDirectory: cacheDirectory)
        let launches = LaunchSchedule.nextLaunches(from: response.results, now: now, count: count)
        return (launches, isStale)
    }
}
