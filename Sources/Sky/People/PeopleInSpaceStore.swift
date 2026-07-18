import Foundation
import Observation

/// App-wide shared "who's in space right now" store (People in Space row, Tonight's Sky card work
/// package). Unlike `SkyTonightService`'s per-(location, calendar-evening) cache, this data has
/// nothing to do with the viewer's location or the calendar day — LL2's in-space-astronaut roster
/// is the same no matter which saved city's `TonightSkyCard` asks for it. `ForecastView.pagerView`
/// mounts one `TonightSkyCard` per saved location, so without this, every one of those cards would
/// independently fetch (and separately in-memory-cache) its own copy of the same roster.
///
/// This is therefore a single `@MainActor` singleton (`.shared`), fetched via `PeopleToday.fetch`
/// **once per app launch**, and observed by every `TonightSkyCard` (via the `@Observable` macro —
/// same pattern as `ForecastViewModel`/`RankingsViewModel`/`LocationsViewModel` elsewhere in this
/// codebase, rather than Combine's older `ObservableObject`/`@Published`) — the first card to
/// appear kicks off the one fetch (`ensureLoaded()` is idempotent), every other card (this
/// location page or another) just renders whatever `state` that fetch already produced or is
/// still producing. `PeopleInSpaceService`'s own on-disk 24h-fresh/7-day-stale cache (see that
/// file's doc comment) is what keeps this fresh across separate app launches; this store only
/// avoids redundant in-process network calls within a single launch.
@MainActor
@Observable
final class PeopleInSpaceStore {
    static let shared = PeopleInSpaceStore()

    enum State {
        case loading
        case available(PeopleInSpaceSummary)
        case unavailable
    }

    private(set) var state: State = .loading

    /// Guards against a second `ensureLoaded()` call (e.g. a second `TonightSkyCard` appearing
    /// while the first is still loading) issuing a second network request.
    private var inFlight: Task<Void, Never>?

    private init() {}

    /// `sky/` subdirectory of the app's caches directory — the exact same directory
    /// `SkyTonightService` hands to the ISS/Aurora fetchers, so every LL2/NOAA-backed feed in the
    /// app shares one on-disk cache root.
    private nonisolated static var cacheDirectory: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("sky", isDirectory: true)
    }

    /// Triggers the one app-wide fetch, if (and only if) it hasn't already started. Safe to call
    /// from every `TonightSkyCard.load()` on every page — after the first call wins the race,
    /// every subsequent call this launch is a no-op; callers observe the shared `state` via
    /// `@ObservedObject` instead of awaiting a return value here.
    func ensureLoaded() {
        guard inFlight == nil, case .loading = state else { return }
        inFlight = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await PeopleToday.fetch(cacheDirectory: Self.cacheDirectory)
                self.state = .available(result.summary)
            } catch {
                // Quiet degrade, per work order: this row is supplementary, not a core feature —
                // no error surfaced, the row (and its sheet) simply don't appear.
                self.state = .unavailable
            }
            self.inFlight = nil
        }
    }
}
