import Foundation

// Pure computation over LL2's upcoming-launches feed. No networking, no `Date()` defaults for
// "now" — every "now"/grouping instant is supplied by the caller so this file is deterministic
// and can be exercised entirely with canned JSON (see Tests/LaunchesSmokeTest.swift), matching
// the split used by `Sources/Sky/Aurora/AuroraLikelihood.swift` and `Sources/Sky/ISS/PassPredictor.swift`.

// MARK: - Simplified status

/// LL2's `status` is a rich object (`id`/`name`/`abbrev`/`description`) with far more states than
/// the app needs to render. This collapses it to three actionable buckets.
enum LaunchStatus: Equatable {
    case go
    case tbd
    case hold
}

/// LL2 status-id -> simplified-status mapping, plus the "already flown" set used to filter the
/// upcoming list.
///
/// LL2's status ids are a small, stable, publicly-documented table (mirrored by essentially every
/// third-party LL2 client). Only ids 1 ("Go"), 2 ("TBD"), and 8 ("TBC") were actually observed in
/// the live sample fetched on 2026-07-17 (expected: this is the `/launch/upcoming/` endpoint with
/// `hide_recent_previous=true`, so flown/failed/in-flight launches are rare-to-absent by
/// construction) — the remaining ids below are documented from LL2's known schema rather than
/// independently re-verified against a live response, and are included so the filter is correct
/// even on a launch that slips into one of those states between fetches:
/// ```
///  id  abbrev            simplified          notes
///  1   Go                .go
///  2   TBD               .tbd
///  3   Success           (flown, filtered)   already happened
///  4   Failure           (flown, filtered)   already happened
///  5   Hold               .hold
///  6   In Flight         (flown, filtered)   currently/already flying -- not "upcoming"
///  7   Partial Failure   (flown, filtered)   already happened
///  8   TBC               .tbd                "To Be Confirmed" -- treated same as TBD
///  other/unknown         .tbd                conservative default for any future LL2 status id
/// ```
enum LaunchStatusMapping {
    private static let flownStatusIDs: Set<Int> = [3, 4, 6, 7]

    /// True if this status id means the launch already happened (or is currently in flight) --
    /// used by `LaunchSchedule.nextLaunches` to drop it from an "upcoming" list.
    static func isFlown(statusID: Int) -> Bool {
        flownStatusIDs.contains(statusID)
    }

    static func simplified(statusID: Int) -> LaunchStatus {
        switch statusID {
        case 1: return .go
        case 5: return .hold
        default: return .tbd // covers 2 (TBD), 8 (TBC), and any unrecognized id
        }
    }
}

// MARK: - T-0 precision

/// Whether a launch's `net` (T-0) date should be presented as a specific moment or a rough
/// placeholder. Derived from LL2's `net_precision.abbrev`.
///
/// Observed live abbrevs: "MIN" (Minute), "HR" (Hour), "M" (Month). LL2's documented precision
/// scale also includes coarser buckets (day/quarter/half/year) for far-future or barely-scheduled
/// launches. Only "MIN" is treated as `.exact`; every coarser bucket (including a missing/null
/// `net_precision`, which LL2 uses for launches with essentially no real schedule yet) is
/// `.approximate` -- the simplest correct rule given the goal is "can the UI show an exact time,
/// or should it hedge with 'date approximate'".
enum LaunchTimePrecision: Equatable {
    case exact
    case approximate

    static func from(abbrev: String?) -> LaunchTimePrecision {
        abbrev == "MIN" ? .exact : .approximate
    }
}

// MARK: - Mapped model

/// One upcoming launch, mapped from LL2's wire model down to what the app actually renders.
struct UpcomingLaunch: Equatable, Identifiable {
    let id: String
    let missionName: String
    /// Full provider/agency name as LL2 reports it (e.g. "China Aerospace Science and Technology
    /// Corporation").
    let provider: String
    /// Short display form of `provider` (e.g. "SpaceX", "NASA", "ULA") for compact UI; falls back
    /// to `provider` unchanged when there is no known abbreviation (see
    /// `LaunchSchedule.providerAbbrev(for:)`).
    let providerAbbrev: String
    /// Vehicle display name (rocket configuration's `full_name`, falling back to `name` if
    /// `full_name` is empty -- see `LaunchSchedule.vehicleName(configuration:)`).
    let vehicle: String
    let padName: String
    /// Short "Cape Canaveral, FL"-style location string derived from `pad.location.name` (see
    /// `LaunchSchedule.locationDisplay(fromLocationName:)`).
    let locationDisplay: String
    /// T-0, i.e. LL2's `net`.
    let net: Date
    let netPrecision: LaunchTimePrecision
    let status: LaunchStatus
    /// Best-effort heuristic -- see `LaunchSchedule.isCrewedHeuristic`.
    let isCrewed: Bool
    let webcastLive: Bool
    let imageURL: URL?
    let missionDescription: String?

    static func == (lhs: UpcomingLaunch, rhs: UpcomingLaunch) -> Bool {
        lhs.id == rhs.id
            && lhs.missionName == rhs.missionName
            && lhs.provider == rhs.provider
            && lhs.providerAbbrev == rhs.providerAbbrev
            && lhs.vehicle == rhs.vehicle
            && lhs.padName == rhs.padName
            && lhs.locationDisplay == rhs.locationDisplay
            && lhs.net == rhs.net
            && lhs.netPrecision == rhs.netPrecision
            && lhs.status == rhs.status
            && lhs.isCrewed == rhs.isCrewed
            && lhs.webcastLive == rhs.webcastLive
            && lhs.imageURL == rhs.imageURL
            && lhs.missionDescription == rhs.missionDescription
    }
}

enum LaunchSchedule {
    // MARK: - Provider display abbreviation

    /// Long-form provider/agency names -> short display abbreviations, for the handful of
    /// agencies explicitly called out by the work package. Deliberately narrow: everything not in
    /// this table is shown as-is (LL2's `launch_service_provider.name` for most agencies, e.g.
    /// "Rocket Lab", "Arianespace", "Skyroot Aerospace", is already short), rather than guessing
    /// at abbreviations for agencies nobody asked for.
    private static let providerAbbreviations: [String: String] = [
        "National Aeronautics and Space Administration": "NASA",
        "United Launch Alliance": "ULA",
        "Space Exploration Technologies Corp.": "SpaceX",
        "SpaceX": "SpaceX",
        "Blue Origin": "Blue Origin",
        "Rocket Lab": "Rocket Lab",
        "Arianespace": "Arianespace",
    ]

    static func providerAbbrev(for name: String) -> String {
        providerAbbreviations[name] ?? name
    }

    // MARK: - Vehicle name

    /// `configuration.full_name` (e.g. "Falcon 9 Block 5") when present and non-empty, since it
    /// disambiguates vehicle variants that share a bare `name` (e.g. "Falcon 9"); falls back to
    /// `name` for the rare configuration with an empty `full_name`.
    static func vehicleName(name: String, fullName: String) -> String {
        fullName.trimmingCharacters(in: .whitespaces).isEmpty ? name : fullName
    }

    // MARK: - Location display

    /// Common long country names LL2 uses in `location.name` that are worth shortening for a
    /// compact UI string. Deliberately small -- only names actually observed live plus a few
    /// obvious siblings; anything else passes through unchanged.
    private static let countryShortNames: [String: String] = [
        "People's Republic of China": "China",
        "United States of America": "USA",
        "Russian Federation": "Russia",
    ]

    /// Derives a short "Cape Canaveral, FL"-style display string from LL2's `pad.location.name`.
    ///
    /// **Best-effort heuristic**, not a geocoder -- `location.name` has no single consistent
    /// shape across agencies (observed live: `"Vandenberg SFB, CA, USA"`,
    /// `"Cape Canaveral SFS, FL, USA"`, `"SpaceX Starbase, TX, USA"`,
    /// `"Satish Dhawan Space Centre, India"`, `"Rocket Lab Launch Complex 1, Mahia Peninsula, New
    /// Zealand"`, `"Xichang Satellite Launch Center, People's Republic of China"`,
    /// `"Haiyang Oriental Spaceport"`). The rule, applied to `name.components(separatedBy: ", ")`:
    ///  - 1 part (no comma): used as-is (e.g. "Haiyang Oriental Spaceport").
    ///  - 2 parts ("site, country"): kept as "site, shortCountry" (e.g. "Satish Dhawan Space
    ///    Centre, India"; "Xichang Satellite Launch Center, China" after country shortening).
    ///  - 3+ parts ("site, region, country"): if the middle part looks like a two-letter US state
    ///    code, the site's trailing base-type suffix (SFB/SFS/AFB/AFS) is stripped and the result
    ///    is "site, STATE" (e.g. "Vandenberg SFB, CA, USA" -> "Vandenberg, CA"; "SpaceX Starbase,
    ///    TX, USA" -> "SpaceX Starbase, TX", no suffix to strip). Otherwise the specific pad/site
    ///    name is dropped in favor of "region, shortCountry" (e.g. "Rocket Lab Launch Complex 1,
    ///    Mahia Peninsula, New Zealand" -> "Mahia Peninsula, New Zealand"), since a launch
    ///    complex's full name is usually longer than the region name and the region reads better
    ///    in a short label.
    static func locationDisplay(fromLocationName name: String) -> String {
        let parts = name.components(separatedBy: ", ").map { $0.trimmingCharacters(in: .whitespaces) }
        func shortCountry(_ s: String) -> String { countryShortNames[s] ?? s }

        switch parts.count {
        case 0:
            return name
        case 1:
            return parts[0]
        case 2:
            return "\(parts[0]), \(shortCountry(parts[1]))"
        default:
            let last = parts[parts.count - 1]
            let middle = parts[parts.count - 2]
            let isUSStateCode = middle.count == 2 && middle.allSatisfy { $0.isLetter && $0.isUppercase }
            if isUSStateCode {
                let site = stripBaseSuffix(parts[0])
                return "\(site), \(middle)"
            } else {
                return "\(middle), \(shortCountry(last))"
            }
        }
    }

    /// Strips a trailing US military/commercial spaceport base-type token (e.g. "Vandenberg SFB"
    /// -> "Vandenberg") so the short location string doesn't repeat "base" twice.
    private static let baseSuffixes = [" SFB", " SFS", " AFB", " AFS"]

    private static func stripBaseSuffix(_ site: String) -> String {
        for suffix in baseSuffixes where site.hasSuffix(suffix) {
            return String(site.dropLast(suffix.count))
        }
        return site
    }

    // MARK: - Crewed heuristic

    /// Best-effort "is this a crewed mission" signal: true if the mission's name or type
    /// (case-insensitively) contains the substring "crew". This catches the common cases (e.g.
    /// "Crew-12", "Commercial Crew", mission `type == "Human Exploration"` does NOT match --
    /// deliberately conservative to text containing "crew" rather than trying to enumerate every
    /// crewed-program name).
    ///
    /// **Known limitation**: named crewed missions whose mission name/type doesn't literally
    /// contain "crew" (e.g. a hypothetical Starliner crew flight named after its crew commander,
    /// or Soyuz crew rotation flights named "Soyuz MS-XX") will NOT be flagged. There is no
    /// reliable per-mission "crewed" boolean in the fields this endpoint returns; a fully correct
    /// answer would need LL2's `astronauts`/`crew` sub-resource (not fetched here to stay within
    /// one call per feed) or per-agency program knowledge. Documented, not fixed, per the work
    /// package's "best-effort" instruction.
    static func isCrewedHeuristic(missionName: String?, missionType: String?) -> Bool {
        let haystack = [missionName, missionType].compactMap { $0 }.joined(separator: " ").lowercased()
        return haystack.contains("crew")
    }

    // MARK: - Wire -> app model

    /// Maps one `LL2Launch` to an `UpcomingLaunch`, or `nil` if a truly essential field is missing
    /// (currently: the `net` date fails to parse). Provider/pad/vehicle text is defaulted rather
    /// than dropping the whole launch, since those are display-only strings.
    static func map(_ launch: LL2Launch) -> UpcomingLaunch? {
        guard let netDate = launch.netDate else { return nil }

        let providerName = launch.launchServiceProvider?.name ?? "Unknown provider"
        let vehicle = launch.rocket.map { vehicleName(name: $0.configuration.name, fullName: $0.configuration.fullName) }
            ?? "Unknown vehicle"
        let padName = launch.pad?.name ?? "Unknown pad"
        let locationName = launch.pad?.location.name
        let locationDisplay = locationName.map(Self.locationDisplay(fromLocationName:)) ?? "Unknown location"

        return UpcomingLaunch(
            id: launch.id,
            missionName: launch.mission?.name ?? launch.name,
            provider: providerName,
            providerAbbrev: providerAbbrev(for: providerName),
            vehicle: vehicle,
            padName: padName,
            locationDisplay: locationDisplay,
            net: netDate,
            netPrecision: .from(abbrev: launch.netPrecision?.abbrev),
            status: LaunchStatusMapping.simplified(statusID: launch.status.id),
            isCrewed: isCrewedHeuristic(missionName: launch.mission?.name, missionType: launch.mission?.type),
            webcastLive: launch.webcastLive,
            imageURL: launch.image.flatMap(URL.init(string:)),
            missionDescription: launch.mission?.description
        )
    }

    static func map(_ launches: [LL2Launch]) -> [UpcomingLaunch] {
        launches.compactMap(map)
    }

    // MARK: - Upcoming list

    /// Chronological upcoming launches: drops any launch whose *original* LL2 status id means it
    /// already flew (see `LaunchStatusMapping.isFlown`) or whose T-0 is already in the past
    /// relative to `now`, sorts the remainder by T-0 ascending, and returns at most `count`.
    ///
    /// Note this needs the raw LL2 status id, not the already-simplified `LaunchStatus`, since
    /// `.tbd`/`.go`/`.hold` collapses away the "already flown" distinction. Callers therefore pass
    /// the original `[LL2Launch]` here rather than `[UpcomingLaunch]` -- see the overload below for
    /// call sites that only have the mapped model (e.g. because they discarded raw LL2 launches
    /// after mapping) and are willing to filter on T-0 alone.
    static func nextLaunches(from raw: [LL2Launch], now: Date, count: Int) -> [UpcomingLaunch] {
        let mapped: [(launch: LL2Launch, upcoming: UpcomingLaunch)] = raw.compactMap { l in
            guard let u = map(l) else { return nil }
            return (l, u)
        }
        return mapped
            .filter { !LaunchStatusMapping.isFlown(statusID: $0.launch.status.id) && $0.upcoming.net >= now }
            .sorted { $0.upcoming.net < $1.upcoming.net }
            .prefix(count)
            .map(\.upcoming)
    }

    /// Same idea, for callers who already have `[UpcomingLaunch]` and no access to the raw LL2
    /// status id. Since `UpcomingLaunch.status` has already collapsed flown statuses away (they're
    /// never produced as `.go`/`.tbd`/`.hold` -- see `LaunchStatusMapping`), this overload can only
    /// filter on T-0 vs. `now`; it will NOT catch a launch whose status flipped to "flown" after it
    /// was mapped. Prefer the `[LL2Launch]` overload above when raw launches are available.
    static func nextLaunches(from launches: [UpcomingLaunch], now: Date, count: Int) -> [UpcomingLaunch] {
        launches
            .filter { $0.net >= now }
            .sorted { $0.net < $1.net }
            .prefix(count)
            .map { $0 }
    }

    // MARK: - Day grouping

    /// Groups launches by calendar day (in `timeZone`) for a sectioned list, sorted by day
    /// ascending, with each day's launches sorted chronologically. `timeZone` defaults to
    /// `.current` for convenience but callers that need deterministic output (tests, snapshot
    /// rendering) should pass a fixed zone explicitly.
    static func launchesByDay(
        _ launches: [UpcomingLaunch],
        timeZone: TimeZone = .current
    ) -> [(day: Date, launches: [UpcomingLaunch])] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone

        var buckets: [Date: [UpcomingLaunch]] = [:]
        for launch in launches {
            let dayStart = calendar.startOfDay(for: launch.net)
            buckets[dayStart, default: []].append(launch)
        }
        return buckets.keys.sorted().map { day in
            (day: day, launches: buckets[day]!.sorted { $0.net < $1.net })
        }
    }
}
