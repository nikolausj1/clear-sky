import Foundation

/// "On this day in space history" — a 366-entry (every month/day, including Feb 29), one-liner
/// bank keyed by calendar date, looked up independent of year. Content lives in
/// `onthisday.json`, researched 2026-07-18 (see that file's entries — each line names a real,
/// dated event; sourcing notes for the research pass live with the work, not per-line in the
/// JSON, to keep the bundled file lean).
///
/// Register, per work order: factual/encyclopedic (a museum-placard tone), no exclamation
/// points, each line capped at 120 characters including its "Month Day: " prefix.
enum OnThisDay {

    struct Entry: Codable, Equatable {
        var month: Int
        var day: Int
        var text: String
    }

    /// Decodes an on-this-day table from raw JSON `Data` — pure function, same testability
    /// rationale as `Eclipses.decode(data:)` and `Comets.decode(data:)`.
    static func decode(data: Data) throws -> [Entry] {
        try JSONDecoder().decode([Entry].self, from: data)
    }

    /// The bundled table, loaded once from `onthisday.json`. Empty (with a debug-build assertion)
    /// if the resource is missing or fails to decode.
    static let all: [Entry] = {
        guard let url = Bundle.main.url(forResource: "onthisday", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let decoded = try? decode(data: data) else {
            assertionFailure("onthisday.json missing or failed to decode -- check project.yml resource wiring")
            return []
        }
        return decoded
    }()

    /// Fast month/day lookup, built once from `all` and reused across calls rather than
    /// linear-scanning 366 entries on every lookup.
    private static let byMonthDay: [Int: Entry] = {
        var map: [Int: Entry] = [:]
        for entry in all {
            map[key(month: entry.month, day: entry.day)] = entry
        }
        return map
    }()

    private static func key(month: Int, day: Int) -> Int { month * 100 + day }

    /// The entry for `date`'s calendar month/day (year-independent), evaluated in `calendar`'s
    /// time zone. `nil` only if the table is missing that month/day entirely (shouldn't happen
    /// for a correctly-populated 366-entry table, including Feb 29) or the bundled table failed
    /// to load.
    static func entry(for date: Date, calendar: Calendar = Calendar(identifier: .gregorian)) -> Entry? {
        let components = calendar.dateComponents([.month, .day], from: date)
        guard let month = components.month, let day = components.day else { return nil }
        return byMonthDay[key(month: month, day: day)]
    }

    /// Direct month/day lookup, for callers that already have calendar components (e.g. a
    /// "browse the whole year" UI) rather than a `Date`.
    static func entry(month: Int, day: Int) -> Entry? {
        byMonthDay[key(month: month, day: day)]
    }
}
