import Foundation

// MARK: - Top-level "People in Space" API.
//
// Combines `PeopleInSpaceService`'s fetch/cache layer with `PeopleInSpace`'s pure mapping/sorting,
// same split as `LaunchesUpcoming.swift` for LL2 launches, `AuroraTonight.swift` for OVATION/Kp,
// and `ISSTonight.swift` for TLE/SGP4: this is the only file in `Sources/Sky/People/` that touches
// both the network and the logic, so the logic stays testable against canned JSON and the
// fetch/cache behavior stays testable independently.

enum PeopleToday {
    /// Everything the app needs to render a "People in Space" screen: the full mapped, sorted
    /// roster plus whether it came from a stale cache (so the UI can show a "last updated"
    /// caveat).
    struct Result {
        let summary: PeopleInSpaceSummary
        let isStale: Bool
    }

    /// Fetches (or reuses the cache for) LL2's in-space-astronauts list and maps/sorts it to a
    /// `PeopleInSpaceSummary`.
    ///
    /// - Parameters:
    ///   - cacheDirectory: directory `PeopleInSpaceService` may read/write its on-disk cache file
    ///     in. Caller-supplied so this stays pure Foundation with no hardcoded app-container path.
    ///   - now: caller-supplied "now" for determinism/testability -- this type never reads the
    ///     system clock itself.
    ///   - session: injectable for testing; defaults to `.shared`.
    static func fetch(cacheDirectory: URL, now: Date = Date(), session: URLSession = .shared) async throws -> Result {
        let service = PeopleInSpaceService(session: session)
        let (response, isStale) = try await service.fetchPeopleInSpace(cacheDirectory: cacheDirectory, now: now)
        return Result(summary: PeopleInSpace.summarize(response.results, now: now), isStale: isStale)
    }

    /// Cache-only, no network -- for callers that want "whatever's already cached, if fresh"
    /// without triggering a new network fetch as a side effect of rendering an unrelated screen
    /// (mirrors `LaunchesUpcoming.cachedNextLaunchesIfFresh`). Returns `nil` on a cache miss/stale
    /// cache rather than throwing.
    static func cachedIfFresh(cacheDirectory: URL, now: Date = Date()) async -> PeopleInSpaceSummary? {
        let service = PeopleInSpaceService()
        guard let response = await service.cachedPeopleInSpaceIfFresh(cacheDirectory: cacheDirectory, now: now) else {
            return nil
        }
        return PeopleInSpace.summarize(response.results, now: now)
    }
}
