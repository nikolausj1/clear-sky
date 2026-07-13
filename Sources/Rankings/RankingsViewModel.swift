import Foundation
import Observation

/// Drives the Rankings screen (PRD Screen C: City Power Rankings), per the same "ViewModels
/// (per screen)" layer `ForecastViewModel`/`LocationsViewModel` use. Reads the same
/// `WeatherStore` cache those two already populate (no separate fetch pipeline) and the same
/// ordered `SavedLocation` list `LocationsViewModel` writes — this view model is a reader, same
/// relationship `ForecastViewModel` has to the SwiftData rows.
///
/// **Recompute-daily, computed-live:** PRD Section 6 says the ranking is "recalculated daily."
/// There's no separate persisted "today's ranking" — `rows(unit:)` recomputes the score/order
/// from whatever `WeatherStore` currently has cached every time it's read, which is equivalent
/// in practice (each location's weather itself only refreshes on the 30-minute staleness rule
/// or pull-to-refresh elsewhere, and `PhraseBank.rankingVerdict`'s date-seeded rotation is what
/// actually makes the *verdict line* change once per calendar day, not this recompute).
@MainActor
@Observable
final class RankingsViewModel {
    enum RowFetchState: Equatable {
        case loading
        case loaded(CachedWeather)
        case failed
    }

    /// One row as rendered by `RankingsView`. `rank`/`score`/`breakdown`/`verdict` are all
    /// `nil` together for a row whose weather failed to load with no usable cache — see this
    /// file's "failed-row handling" doc comment on `rows(unit:)`.
    struct RankedRow: Identifiable, Equatable {
        let id: UUID
        let location: SavedLocation
        let payload: CachedWeather?
        let rank: Int?
        let score: Double?
        let breakdown: PleasantnessScore.Breakdown?
        let band: PleasantnessScore.Band?
        let hasAlert: Bool
        /// The phrase-bank `rankingVerdict` line, pre-filled with tokens. `nil` for a failed row
        /// (which shows `failureNote` instead).
        let verdict: String?
        /// The phrase-bank `errorState(.rankingRowFailed)` line, filled only for a failed row.
        let failureNote: String?

        static func == (lhs: RankedRow, rhs: RankedRow) -> Bool {
            lhs.id == rhs.id && lhs.rank == rhs.rank && lhs.score == rhs.score && lhs.verdict == rhs.verdict
                && lhs.failureNote == rhs.failureNote && lhs.hasAlert == rhs.hasAlert
        }
    }

    enum ScreenState: Equatable {
        /// Fewer than 2 locations don't reach this state at all (see `noCities`/`needOneMore`);
        /// this is specifically "2+ locations, but at least one's first score hasn't resolved
        /// yet" — PRD Section 6's "Skeleton rows while first scores compute."
        case loading
        case noCities
        case needOneMore(cityName: String)
        case ranked
    }

    private(set) var locations: [SavedLocation] = []
    private(set) var rowFetchStates: [UUID: RowFetchState] = [:]

    private let store: WeatherStore
    /// `-forceDate` sim-verify hook, mirrored from `ForecastViewModel.phraseBankDate` — lets a
    /// screenshot pin which day's `rankingVerdict` rotation variant renders, same as the
    /// Forecast screen's phrase-bank lines.
    private let forcedDate: Date?

    init(store: WeatherStore, forcedDate: Date? = nil) {
        self.store = store
        self.forcedDate = forcedDate
    }

    var rankingDate: Date { forcedDate ?? Date() }

    /// Called by whoever owns the SwiftData-backed list (the Navigation shell at launch,
    /// `LocationsViewModel`'s `onLocationsChanged` after any add/remove/reorder) — mirrors
    /// `ForecastViewModel.applyLocations`.
    func applyLocations(_ newLocations: [SavedLocation]) {
        locations = newLocations
        let knownIds = Set(newLocations.map(\.id))
        rowFetchStates = rowFetchStates.filter { knownIds.contains($0.key) }
        Task { await loadAll() }
    }

    private func loadAll() async {
        await withTaskGroup(of: Void.self) { group in
            for location in locations {
                group.addTask { await self.load(location) }
            }
        }
    }

    private func load(_ location: SavedLocation) async {
        if let cached = store.cached(for: location.id) {
            rowFetchStates[location.id] = .loaded(cached)
        } else if rowFetchStates[location.id] == nil {
            rowFetchStates[location.id] = .loading
        }
        do {
            let payload = try await store.weather(for: location.id, coordinate: location.coordinate, forceRefresh: false)
            rowFetchStates[location.id] = .loaded(payload)
        } catch {
            if store.cached(for: location.id) == nil {
                rowFetchStates[location.id] = .failed
            }
            // Otherwise: leave the already-cached `.loaded` state in place (PRD Section 6:
            // "stale data stays visible" — a background refresh failing shouldn't blank a row
            // that already has something to show).
        }
    }

    func retry(_ location: SavedLocation) {
        rowFetchStates[location.id] = .loading
        Task { await load(location) }
    }

    var screenState: ScreenState {
        if locations.isEmpty { return .noCities }
        if locations.count == 1 { return .needOneMore(cityName: locations[0].name) }
        let allResolved = locations.allSatisfy { location in
            guard let state = rowFetchStates[location.id] else { return false }
            return state != .loading
        }
        return allResolved ? .ranked : .loading
    }

    /// Builds the ranked list PRD Section 6 describes: sorted by score highest-first, ties
    /// broken alphabetically by city name (Section 12), rank/position (top/middle/bottom)
    /// assigned from that order.
    ///
    /// **Failed-row handling (this file's documented choice — PRD leaves it open, "your
    /// call"):** a location whose weather has *never* loaded (no cache to fall back on) is
    /// **excluded from scoring and position entirely** — it doesn't get a rank number, doesn't
    /// count toward `top`/`bottom` position for the rows that DID score, and is appended to the
    /// end of the returned array for display with a dry inline note instead of a verdict. This
    /// was chosen over "rank it last with a score of 0" because a failed fetch is a data
    /// problem, not a bad-weather verdict — assigning it a real rank/score would imply Rankings
    /// knows something about that city's weather that it doesn't. Rows still mid-fetch
    /// (`.loading`) are simply omitted until they resolve one way or the other; `screenState`
    /// stays `.loading` until every location has resolved, so callers never see a partially
    /// populated ranked list settle into place row-by-row.
    func rows(unit: TemperatureUnit) -> [RankedRow] {
        struct Scored {
            let location: SavedLocation
            let payload: CachedWeather
            let breakdown: PleasantnessScore.Breakdown
        }

        var scored: [Scored] = []
        var failed: [SavedLocation] = []

        for location in locations {
            switch rowFetchStates[location.id] ?? .loading {
            case .loaded(let payload):
                let breakdown = PleasantnessScore.breakdown(
                    temperature: payload.currentConditions.temperature,
                    precipChance: Self.currentPrecipChance(payload: payload),
                    windSpeed: payload.currentConditions.windSpeed,
                    humidity: payload.currentConditions.humidity
                )
                scored.append(Scored(location: location, payload: payload, breakdown: breakdown))
            case .failed:
                failed.append(location)
            case .loading:
                break
            }
        }

        scored.sort { lhs, rhs in
            if lhs.breakdown.total != rhs.breakdown.total {
                return lhs.breakdown.total > rhs.breakdown.total
            }
            // PRD Section 12: "alphabetical by city name" tie-break.
            return lhs.location.name.localizedStandardCompare(rhs.location.name) == .orderedAscending
        }

        let count = scored.count
        var result: [RankedRow] = scored.enumerated().map { index, entry in
            let position: PhraseBank.RankPosition = index == 0 ? .top : (index == count - 1 ? .bottom : .middle)
            let band = PleasantnessScore.Band.forScore(entry.breakdown.total)
            let pleasantness = PhraseBank.Pleasantness(rawValue: band.rawValue) ?? .fine
            let rank = index + 1
            let verdict = PhraseBank.rankingVerdict(
                position: position,
                pleasantness: pleasantness,
                date: rankingDate,
                locationId: entry.location.id,
                tokens: [
                    "city": entry.location.name,
                    "temp": TemperatureFormatting.string(entry.payload.currentConditions.temperature, unit: unit),
                    "rank": Self.ordinal(rank),
                    "score": "\(Int(entry.breakdown.total.rounded()))",
                ]
            )
            return RankedRow(
                id: entry.location.id,
                location: entry.location,
                payload: entry.payload,
                rank: rank,
                score: entry.breakdown.total,
                breakdown: entry.breakdown,
                band: band,
                hasAlert: !entry.payload.activeAlerts.isEmpty,
                verdict: verdict,
                failureNote: nil
            )
        }

        for location in failed {
            let note = PhraseBank.errorState(
                .rankingRowFailed,
                date: rankingDate,
                locationId: location.id,
                tokens: ["city": location.name]
            )
            result.append(
                RankedRow(
                    id: location.id,
                    location: location,
                    payload: nil,
                    rank: nil,
                    score: nil,
                    breakdown: nil,
                    band: nil,
                    hasAlert: false,
                    verdict: nil,
                    failureNote: note
                )
            )
        }

        return result
    }

    // MARK: - Precip-chance proxy

    /// PRD Section 12's formula wants "current conditions' precip chance," but
    /// `CurrentConditions` (Section 8's model) has no precip-chance field of its own — only
    /// `HourlyEntry` does. Per this phase's brief ("if you only have hourly, use the current
    /// hour / next-few-hours"), this averages the next 3 hourly entries at/after `payload`'s
    /// current-conditions timestamp (falling back to the first 3 entries in `hourly` if none
    /// are at/after that timestamp — e.g. right at a fetch boundary). Averaging a short window
    /// rather than reading a single hour smooths over "it's 0% this exact hour but 80% next
    /// hour" edge cases that would otherwise make the score jump around within a single hour of
    /// real time.
    static func currentPrecipChance(payload: CachedWeather) -> Double {
        let referenceDate = payload.currentConditions.date
        let upcoming = payload.hourly.filter { $0.date >= referenceDate }
        let window = Array((upcoming.isEmpty ? payload.hourly : upcoming).prefix(3))
        guard !window.isEmpty else { return 0 }
        return window.reduce(0.0) { $0 + $1.precipChance } / Double(window.count)
    }

    // MARK: - Ordinal formatting for the `{rank}` token

    private static func ordinal(_ n: Int) -> String {
        let suffix: String
        switch (n % 100, n % 10) {
        case (11, _), (12, _), (13, _):
            suffix = "th"
        case (_, 1):
            suffix = "st"
        case (_, 2):
            suffix = "nd"
        case (_, 3):
            suffix = "rd"
        default:
            suffix = "th"
        }
        return "\(n)\(suffix)"
    }
}
