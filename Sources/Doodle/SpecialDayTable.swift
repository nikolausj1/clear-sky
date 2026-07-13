import Foundation

/// PRD Section 8's `SpecialDayTable`: a static, bundled, offline-computable lookup from a
/// calendar date to the special day (if any) that applies. Backs the doodle grammar's layer 5
/// (PRD Section 7).
struct SpecialDay: Equatable {
    let id: String
    let label: String
    let tier: Tier

    /// `tier: "hero"` entries are the small v1.x set slated for a unique full illustration
    /// (PRD Section 12's open question) that replaces the layered composite entirely. **No
    /// entry in `specialdays.json` is tagged `hero` for v1.0** — every special day gets the
    /// standard additive layer-5 overlay treatment. The field exists in the schema now so a
    /// later phase can flip specific entries to `.hero` without a data-model migration.
    enum Tier: String, Decodable {
        case overlay, hero
    }
}

enum SpecialDayTable {

    /// Looks up the special day (if any) that applies to `date`.
    ///
    /// **Precedence:** if a fixed-date entry (a named holiday, including the computed-weekday
    /// ones like Thanksgiving) and an astronomical entry (solstice/equinox/full moon) both
    /// match the same calendar day, the **fixed-date entry wins** — e.g. if Christmas ever
    /// coincided with a full moon, the doodle overlay shows the Christmas treatment, not a
    /// full-moon one. Rationale: fixed-date holidays are named, deliberate cultural dates a
    /// user recognizes at a glance, whereas the astronomical entries are a quieter, more
    /// ambient signal — the more legible/specific date wins when both are true.
    static func specialDay(for date: Date, calendar: Calendar = Calendar(identifier: .gregorian)) -> SpecialDay? {
        let entries = ContentStore.shared.entries
        let month = calendar.component(.month, from: date)
        let day = calendar.component(.day, from: date)

        // Fixed-date entries first (highest precedence), including the computed-weekday rule
        // (Thanksgiving's "4th Thursday of November").
        for entry in entries where entry.kind == .fixed {
            if entry.month == month && entry.day == day {
                return SpecialDay(id: entry.id, label: entry.label, tier: entry.tier)
            }
        }
        for entry in entries where entry.kind == .nthWeekdayOfMonth {
            if matchesNthWeekday(entry, date: date, calendar: calendar) {
                return SpecialDay(id: entry.id, label: entry.label, tier: entry.tier)
            }
        }

        // Astronomical entries second (lower precedence): approximate-fixed-date
        // solstices/equinoxes, then the computed full-moon rule.
        for entry in entries where entry.kind == .fixedApprox {
            if entry.month == month && entry.day == day {
                return SpecialDay(id: entry.id, label: entry.label, tier: entry.tier)
            }
        }
        for entry in entries where entry.kind == .fullMoon {
            if FullMoonCalculator.isFullMoon(on: date, calendar: calendar) {
                return SpecialDay(id: entry.id, label: entry.label, tier: entry.tier)
            }
        }

        return nil
    }

    private static func matchesNthWeekday(_ entry: RawEntry, date: Date, calendar: Calendar) -> Bool {
        guard let month = entry.month, let weekday = entry.weekday, let n = entry.n else { return false }
        let components = calendar.dateComponents([.year, .month, .day, .weekday], from: date)
        guard components.month == month, components.weekday == weekday else { return false }

        // Which occurrence of this weekday-in-month is `date`? (1st, 2nd, 3rd, 4th...)
        let occurrence = ((components.day! - 1) / 7) + 1
        return occurrence == n
    }

    // MARK: - JSON loading

    private struct RawEntry: Decodable {
        let id: String
        let kind: Kind
        let month: Int?
        let day: Int?
        let weekday: Int?
        let n: Int?
        let label: String
        let tier: SpecialDay.Tier

        enum Kind: String, Decodable {
            case fixed
            case fixedApprox
            case nthWeekdayOfMonth
            case fullMoon
        }
    }

    private final class ContentStore {
        static let shared = ContentStore()
        let entries: [RawEntry]

        private init() {
            guard let url = Bundle.main.url(forResource: "specialdays", withExtension: "json"),
                  let data = try? Data(contentsOf: url),
                  let decoded = try? JSONDecoder().decode([RawEntry].self, from: data) else {
                assertionFailure("specialdays.json missing or failed to decode — check project.yml resource wiring")
                entries = []
                return
            }
            entries = decoded
        }
    }
}
