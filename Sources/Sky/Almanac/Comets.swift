import Foundation

/// Bundled table of currently-known comet apparitions worth mentioning to a stargazer, seeded
/// from research done 2026-07-18 (see per-entry `viewingNote` sources in `comets.json`).
///
/// ## Why this table doesn't have a "great comet" in it right now
/// Naked-eye-bright comets (roughly magnitude 6 or brighter) are genuinely rare -- most years
/// have none, and the ones that do appear are usually discovered only months ahead, not
/// predictable years out. As of this research pass, no comet is forecast to reach naked-eye
/// brightness for the remainder of 2026: the one apparition that had a real shot,
/// C/2025 R3 (PanSTARRS), already passed its best viewing window in mid-April 2026 (perihelion
/// April 19; forecasts for its peak brightness ranged wildly, from magnitude ~2.5 -- naked-eye
/// -- down to a telescope-only magnitude ~8, and its actual outcome isn't re-litigated here since
/// that window has already closed by this table's research date). What's left on the 2026
/// calendar -- 10P/Tempel 2 and 210P/Christensen below -- are real, dated, binocular/telescope
/// targets, included because they're the best genuinely upcoming prospects, not because either
/// is expected to be naked-eye visible. Per the work order: this is documented rather than
/// papered over, and the table is expected to be refreshed in future app releases as new comets
/// are discovered or forecasts firm up.
enum Comets {

    struct Comet: Codable, Identifiable {
        var name: String
        /// ISO calendar date (yyyy-MM-dd, UTC) of perihelion passage.
        var perihelionDate: String
        /// Free-text magnitude forecast, deliberately a range/string rather than a single Double
        /// -- comet brightness predictions are notoriously unreliable (can be off by several
        /// magnitudes either direction), so a false-precision single number would misrepresent
        /// the underlying uncertainty documented in each entry's `viewingNote`.
        var expectedMagnitudeRange: String
        var visibilityWindow: String
        var viewingNote: String

        var id: String { name }

        /// Parses `perihelionDate` as a UTC calendar date, or `nil` if the string is malformed.
        var perihelionUTCDate: Date? {
            let formatter = DateFormatter()
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.timeZone = TimeZone(identifier: "UTC")
            formatter.dateFormat = "yyyy-MM-dd"
            return formatter.date(from: perihelionDate)
        }
    }

    /// Decodes a comet table from raw JSON `Data` -- pure function, same testability rationale as
    /// `Eclipses.decode(data:)`.
    static func decode(data: Data) throws -> [Comet] {
        try JSONDecoder().decode([Comet].self, from: data)
    }

    /// The bundled table, loaded once from `comets.json`. Empty (with a debug-build assertion) if
    /// the resource is missing or fails to decode. An empty result here is also the intentional,
    /// documented fallback if a future refresh genuinely has nothing to report -- see the
    /// type-level doc comment.
    static let all: [Comet] = {
        guard let url = Bundle.main.url(forResource: "comets", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let decoded = try? decode(data: data) else {
            assertionFailure("comets.json missing or failed to decode -- check project.yml resource wiring")
            return []
        }
        return decoded
    }()

    /// Comets whose perihelion is at or after `date`, soonest first -- the "what's coming up"
    /// list for a UI to render. Entries with an unparseable `perihelionDate` are dropped rather
    /// than crashing (defensive against a future hand-edited JSON typo).
    static func upcoming(after date: Date, in comets: [Comet] = Comets.all) -> [Comet] {
        comets
            .compactMap { comet -> (Comet, Date)? in
                guard let d = comet.perihelionUTCDate else { return nil }
                return (comet, d)
            }
            .filter { $0.1 >= date }
            .sorted { $0.1 < $1.1 }
            .map { $0.0 }
    }
}
