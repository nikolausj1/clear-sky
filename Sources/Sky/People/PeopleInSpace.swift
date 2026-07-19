import Foundation

// Pure computation over LL2's in-space-astronauts feed. No networking, no `Date()` defaults for
// "now" -- every "now" instant is supplied by the caller so this file is deterministic and can be
// exercised entirely with canned JSON (see Tests/PeopleSmokeTest.swift), matching the split used
// by `LaunchSchedule.swift`, `AuroraLikelihood.swift`, and `PassPredictor.swift`.

// MARK: - ISO 8601 duration parsing

/// Hand-rolled parser for the ISO 8601 *duration* strings LL2 uses for `time_in_space` and
/// `eva_time` -- e.g. `"P359DT7H5M23S"`, `"P0D"`, `"PT12H53M20S"`, `"PT7H20M"`. This is a
/// different grammar from ISO 8601 *date-times* (which `Foundation.ISO8601DateFormatter` parses);
/// Foundation has no built-in parser for durations, so this is necessarily custom.
///
/// Grammar supported (matches everything observed live on 2026-07-18 against
/// `/astronaut/?in_space=true&limit=30`, across 14 astronauts' `time_in_space` + `eva_time`):
/// `P` optionally followed by `<n>D`, optionally followed by `T` and any subset of `<n>H`, `<n>M`,
/// `<n>S` in that order. Every numeric component is a non-negative integer in the observed data
/// (no fractional seconds, no `W` weeks component -- both are part of the general ISO 8601
/// duration grammar but were never seen live, so are deliberately NOT supported here; a string
/// using either fails to parse and `totalSeconds` returns `nil` rather than silently guessing).
enum ISO8601Duration {
    private static let pattern: NSRegularExpression = {
        // swiftlint:disable:next force_try
        try! NSRegularExpression(
            pattern: #"^P(?:(\d+)D)?(?:T(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)S)?)?$"#
        )
    }()

    /// Parses a duration string into total seconds, or `nil` if it doesn't match the supported
    /// grammar (including the degenerate empty match "P" with no components at all, which LL2
    /// never actually emits but which the regex would otherwise accept as "0 seconds" -- guarded
    /// against explicitly below so a genuinely malformed/empty string doesn't silently become 0).
    static func totalSeconds(from raw: String) -> Double? {
        let range = NSRange(raw.startIndex..., in: raw)
        guard let match = pattern.firstMatch(in: raw, range: range) else { return nil }

        func group(_ index: Int) -> Double {
            guard let r = Range(match.range(at: index), in: raw) else { return 0 }
            return Double(raw[r]) ?? 0
        }

        // Require at least one of D/H/M/S to actually be present -- reject bare "P" or "PT".
        let hasAnyComponent = (1...4).contains { match.range(at: $0).location != NSNotFound }
        guard hasAnyComponent else { return nil }

        let days = group(1)
        let hours = group(2)
        let minutes = group(3)
        let seconds = group(4)
        return days * 86_400 + hours * 3_600 + minutes * 60 + seconds
    }

    /// Whole days, floored, for humanized display (e.g. "371 days"). `nil` when `raw` doesn't
    /// parse.
    static func totalDays(from raw: String) -> Int? {
        totalSeconds(from: raw).map { Int($0 / 86_400) }
    }
}

// MARK: - Mapped model

/// One person currently in space, mapped from LL2's wire model down to what the app actually
/// renders.
struct SpacePerson: Equatable, Identifiable {
    /// LL2's astronaut id -- stable across fetches, safe as a SwiftUI `Identifiable` key (unlike
    /// `name`, which is not guaranteed unique).
    let id: Int
    let name: String
    /// Short agency abbreviation (e.g. "NASA", "RFSA", "CNSA", "ESA") when LL2 provides one,
    /// falling back to the full agency name, then to a placeholder if `agency` itself is missing.
    let agencyAbbrev: String
    /// Display-ready nationality: `"🇺🇸 American"` when the raw demonym is in the curated
    /// flag-lookup table (see `PeopleInSpace.nationalityFlags`), otherwise the plain demonym
    /// string unchanged (e.g. `"Earthling"` for the Starman-style edge case, or any nationality
    /// this app hasn't curated a flag for yet), and `"Unknown"` if LL2 omitted it entirely.
    let nationality: String
    /// Best-available proxy for "when did this person's current stay in space begin": LL2's
    /// `last_flight` (the most recent flight's launch date), only when it parses AND is not in
    /// the future relative to the caller's `now` (a future `last_flight` would indicate bad/stale
    /// data for someone already flagged `in_space`, so it's treated as absent rather than
    /// producing a negative day count). `nil` when `last_flight` is missing, unparsable, or in the
    /// future.
    let currentMissionStart: Date?
    /// Whole days from `currentMissionStart` to the caller's `now`. `nil` iff
    /// `currentMissionStart` is `nil`.
    let daysInSpaceCurrent: Int?
    /// Humanized cumulative time in space across this person's whole career, e.g.
    /// `"371 days across 3 flights"` (or just `"371 days"` when `flights_count` is absent/zero).
    /// `nil` when `time_in_space` is missing or fails to parse.
    let careerTimeInSpace: String?
    /// Best-effort "what craft/station are they on" label. Always `nil` in v1 -- see the
    /// exploration writeup below (`PeopleInSpace.craftLabel` doc comment) for why this genuinely
    /// cannot be derived from this endpoint without blowing the shared rate-limit budget.
    let craftLabel: String?
    /// Small circular profile-photo URL, for the People-in-Space sheet's avatar (CDN sanctioned
    /// per the PRD). `nil` when LL2 supplied neither a thumbnail nor a full profile image, or the
    /// supplied string didn't parse as a URL -- the sheet falls back to an initials circle.
    let profileImageThumbnailURL: URL?
}

/// Everything the app needs to render a "People in Space" screen: the full mapped, sorted roster
/// plus its count.
struct PeopleInSpaceSummary: Equatable {
    let count: Int
    /// Sorted by `daysInSpaceCurrent` descending (longest-serving current crew first); people with
    /// `nil` `daysInSpaceCurrent` (no derivable current-mission start) sort last, in whatever
    /// relative order they arrived in (Swift's `sorted(by:)` is a stable sort).
    let people: [SpacePerson]
}

enum PeopleInSpace {
    // MARK: - Non-human filter

    /// LL2 astronaut `type.id` observed for non-human joke entries (e.g. "Starman", Elon Musk's
    /// mannequin permanently orbiting the sun since the Falcon Heavy demo launch) -- see
    /// `PeopleInSpaceService.swift`'s file-header gotcha for the live example. Every real
    /// astronaut in the live sample had `type.id == 2` ("Government"); this app takes the more
    /// conservative approach of excluding only the one documented non-human id rather than
    /// allow-listing "Government", in case LL2 ever adds a legitimate non-government astronaut
    /// type (e.g. a purely commercial/tourist type) that should still count as a person.
    static let nonHumanTypeID = 6

    static func isHuman(_ astronaut: LL2Astronaut) -> Bool {
        astronaut.type?.id != nonHumanTypeID
    }

    // MARK: - Nationality -> flag emoji

    /// Curated demonym -> flag-emoji table. Deliberately small and specific: LL2's `nationality`
    /// field is a free-text demonym, not an ISO country code, so this only covers demonyms that
    /// are (a) actually observed in ISS/CSS crew nationalities historically/live, and (b) clean,
    /// unambiguous single-nation strings. Anything not in this table (including edge cases like
    /// `"Earthling"`, or a demonym LL2 introduces that isn't covered yet) intentionally falls back
    /// to plain text in `displayNationality` rather than guessing -- matching the "only if clean"
    /// instruction from the work order.
    private static let nationalityFlags: [String: String] = [
        "American": "🇺🇸",
        "Russian": "🇷🇺",
        "Chinese": "🇨🇳",
        "French": "🇫🇷",
        "German": "🇩🇪",
        "Japanese": "🇯🇵",
        "Canadian": "🇨🇦",
        "Italian": "🇮🇹",
        "British": "🇬🇧",
        "Belgian": "🇧🇪",
        "Danish": "🇩🇰",
        "Swedish": "🇸🇪",
        "Emirati": "🇦🇪",
        "Indian": "🇮🇳",
        "Israeli": "🇮🇱",
        "Saudi": "🇸🇦",
        "South Korean": "🇰🇷",
        "Kazakh": "🇰🇿",
        "Polish": "🇵🇱",
        "Spanish": "🇪🇸",
    ]

    static func displayNationality(_ raw: String?) -> String {
        guard let raw = raw?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return "Unknown" }
        if let flag = nationalityFlags[raw] {
            return "\(flag) \(raw)"
        }
        return raw
    }

    // MARK: - Career time humanization

    /// Humanizes `time_in_space` (e.g. `"P359DT7H5M23S"`) into e.g. `"359 days across 2 flights"`.
    /// Falls back to just `"359 days"` when `flightsCount` is absent or zero (defensive; every
    /// live in-space person had `flights_count >= 1`). Returns `nil` when `raw` is `nil` or fails
    /// to parse as an ISO 8601 duration (see `ISO8601Duration`).
    static func humanizedCareerTime(raw: String?, flightsCount: Int?) -> String? {
        guard let raw, let days = ISO8601Duration.totalDays(from: raw) else { return nil }
        let dayWord = days == 1 ? "day" : "days"
        if let flights = flightsCount, flights > 0 {
            let flightWord = flights == 1 ? "flight" : "flights"
            return "\(days) \(dayWord) across \(flights) \(flightWord)"
        }
        return "\(days) \(dayWord)"
    }

    // MARK: - Days in current mission

    /// Whole days from `currentMissionStart` to `now`, or `nil` if there's no start date (mirrors
    /// `SpacePerson.daysInSpaceCurrent`'s doc). Floors rather than rounds, consistent with
    /// `ISO8601Duration.totalDays`.
    static func daysInSpace(currentMissionStart: Date?, now: Date) -> Int? {
        guard let start = currentMissionStart, start <= now else { return nil }
        return Int(now.timeIntervalSince(start) / 86_400)
    }

    // MARK: - Craft/station label
    //
    // **Exploration finding, documented per the work order's "document what's actually derivable"
    // instruction:** the `/astronaut/?in_space=true` LIST endpoint this service fetches has NO
    // field that identifies which spacecraft or station a person is currently aboard -- no
    // `flights` array, no `mission`, no `spacecraft`/`station` field of any kind. That data only
    // exists on the per-astronaut DETAIL endpoint (`/astronaut/{id}/`), confirmed live during
    // exploration (see `PeopleInSpaceService.swift`'s header comment for the exact shape found:
    // `flights[0].mission.name` and `flights[0].program`), which would require one extra HTTP
    // request PER PERSON -- 13-14 extra requests for a single "who's in space right now" snapshot,
    // against a shared anonymous-tier budget of ~15 requests/hour. That's not a reasonable
    // trade for a "nice to have" label, so it was rejected.
    //
    // Two alternatives were considered and also rejected:
    //  1. `agency.spacecraft` (present on the list endpoint's `agency` sub-object) -- rejected
    //     because it names the agency's flagship vehicle family, not this person's actual current
    //     craft (documented in `PeopleInSpaceService.swift` with the concrete Jessica
    //     Meir/"Orion" counterexample: she's an ISS crew member, not aboard Orion).
    //  2. A static agency -> station guess table (e.g. "NASA/RFSA/ESA astronauts are probably on
    //     ISS, CNSA astronauts are probably on Tiangong/CSS") -- rejected as too fragile to ship
    //     silently: it isn't actually derived from any API field, would need to be manually kept
    //     in sync with real-world station assignments (private stations, future Artemis
    //     surface/orbit stays, agency partnerships shifting), and would render a confident-looking
    //     label that is sometimes just wrong with no way for the data itself to catch that.
    //
    // `craftLabel` is therefore `nil` for every `SpacePerson` in v1. Flagged in the final report as
    // a possible v2 addition IF the product is willing to pay for either (a) a slow, infrequent
    // background job that walks the roster's detail endpoints on a much longer cadence than the
    // 24h list refresh (e.g. once a week, well under budget), or (b) a hand-maintained
    // agency/mission-era -> station table treated explicitly as a heuristic in the UI (e.g. an
    // "estimated" affordance) rather than presented as fact.

    // MARK: - Wire -> app model

    /// Maps one `LL2Astronaut` to a `SpacePerson`, or `nil` if it's a non-human entry (see
    /// `isHuman`). Every other field is defaulted rather than dropping the person, since only the
    /// human/non-human distinction is treated as disqualifying -- a real astronaut with sparse
    /// data (missing agency, missing nationality, missing `last_flight`) should still show up with
    /// placeholder text rather than vanish from the roster.
    static func map(_ astronaut: LL2Astronaut, now: Date) -> SpacePerson? {
        guard isHuman(astronaut) else { return nil }

        let currentMissionStart: Date? = {
            guard let date = astronaut.lastFlightDate, date <= now else { return nil }
            return date
        }()

        return SpacePerson(
            id: astronaut.id,
            name: astronaut.name,
            agencyAbbrev: astronaut.agency?.abbrev ?? astronaut.agency?.name ?? "Unknown agency",
            nationality: displayNationality(astronaut.nationality),
            currentMissionStart: currentMissionStart,
            daysInSpaceCurrent: daysInSpace(currentMissionStart: currentMissionStart, now: now),
            careerTimeInSpace: humanizedCareerTime(raw: astronaut.timeInSpace, flightsCount: astronaut.flightsCount),
            craftLabel: nil,
            profileImageThumbnailURL: astronaut.avatarImageURL
        )
    }

    /// Maps and filters a full in-space roster, sorted by `daysInSpaceCurrent` descending (`nil`
    /// values last, stable order otherwise -- see `PeopleInSpaceSummary.people`'s doc).
    static func summarize(_ astronauts: [LL2Astronaut], now: Date) -> PeopleInSpaceSummary {
        let people = astronauts
            .compactMap { map($0, now: now) }
            .sorted { lhs, rhs in
                switch (lhs.daysInSpaceCurrent, rhs.daysInSpaceCurrent) {
                case let (l?, r?):
                    return l > r
                case (nil, nil):
                    return false
                case (nil, _):
                    return false
                case (_, nil):
                    return true
                }
            }
        return PeopleInSpaceSummary(count: people.count, people: people)
    }
}
