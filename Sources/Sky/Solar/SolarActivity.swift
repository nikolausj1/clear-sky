import Foundation

// Pure computation over NOAA's three solar-activity feeds. No networking, no `Date()` defaults —
// "now" is always supplied by the caller so this file is deterministic and can be exercised
// entirely with canned JSON (see Tests/SolarSmokeTest.swift), mirroring the fetch/logic split in
// Sources/Sky/Aurora/AuroraLikelihood.swift.

// MARK: - Flare classification

/// A parsed GOES X-ray flare class: one letter (`A`/`B`/`C`/`M`/`X`, ascending severity, each
/// tier ~10x the X-ray flux of the one below it) plus a decimal magnitude *within* that tier
/// (e.g. `"M4.2"` -> letter `M`, magnitude `4.2`). NOAA's magnitude is always in `[1, 10)` within
/// a tier (a magnitude of 10 rolls over into the next letter), so ranking tiers ten apart and
/// adding the magnitude never lets a high magnitude in a lower tier outrank a low magnitude in the
/// tier above it.
struct FlareClass: Equatable {
    let raw: String
    let letter: Character
    let magnitude: Double

    private static let tierRank: [Character: Double] = ["A": 0, "B": 1, "C": 2, "M": 3, "X": 4]

    /// Sortable severity: letter tier dominates, magnitude only breaks ties within a tier.
    var rankValue: Double {
        (Self.tierRank[letter] ?? -1) * 10 + magnitude
    }

    /// Parses NOAA's `"<letter><magnitude>"` class strings (e.g. `"M4.2"`, `"X1.0"`, `"C5.9"`).
    /// Returns `nil` for anything that doesn't match (defensive against a future wire surprise;
    /// callers should treat `nil` the same as "no flare data", not crash).
    static func parse(_ raw: String) -> FlareClass? {
        guard let letter = raw.first, "ABCMX".contains(letter) else { return nil }
        guard let magnitude = Double(raw.dropFirst()) else { return nil }
        return FlareClass(raw: raw, letter: letter, magnitude: magnitude)
    }
}

// MARK: - Activity level

/// Overall solar-activity outlook, least to most disruptive/notable.
enum SolarActivityLevel: Int, Comparable, CaseIterable, CustomStringConvertible {
    case quiet
    case active
    case stormy

    static func < (lhs: SolarActivityLevel, rhs: SolarActivityLevel) -> Bool { lhs.rawValue < rhs.rawValue }

    var description: String {
        switch self {
        case .quiet: return "quiet"
        case .active: return "active"
        case .stormy: return "stormy"
        }
    }
}

/// The strongest flare in the trailing 24 hours that clears the "somebody would care" bar,
/// exposed for the UI headline (see `SolarActivity.notabilityThreshold` for the C5 cutoff).
struct NotableFlare: Equatable {
    /// Wire class string, e.g. `"M4.2"`.
    let classString: String
    let peakTime: Date
    let beginTime: Date?
    let endTime: Date?
}

/// Everything the app needs to render a "Space Weather" outlook for right now.
struct SolarOutlook: Equatable {
    /// See `SolarActivity.outlook(...)`'s doc comment for the exact mapping table.
    let activityLevel: SolarActivityLevel
    /// The strongest flare in the trailing 24h, or `nil` if either there was no flare at all in
    /// that window or the strongest one didn't clear the C5 notability threshold.
    let latestNotableFlare: NotableFlare?
    /// Most recent daily observed sunspot number, or `nil` if the feed had no rows at all.
    let sunspotNumber: Int?
    /// The calendar date that `sunspotNumber` was observed on.
    let sunspotObservationDate: Date?
    /// Current (NOAA scales `"0"` entry) R (radio blackout), S (solar radiation storm), and G
    /// (geomagnetic storm) scale, each 0-5. Defaults to 0 (quiet) if the `"0"` entry or a given
    /// sub-scale is missing from the feed, rather than failing the whole outlook.
    let rScaleNow: Int
    let sScaleNow: Int
    let gScaleNow: Int
    /// Max G scale across the NOAA 3-day forecast entries (`"1"`, `"2"`, `"3"`) — exposed
    /// separately from `gScaleNow` because a high forecast G, not the current G, is what should
    /// drive an aurora-odds callout tonight/this week (see work-order note on this field).
    let gScaleForecastMax: Int
    /// Timestamp of the `"0"` (current) scales entry, if parseable.
    let scalesObservedDate: Date?
}

enum SolarActivity {
    /// A flare's magnitude must be at least this severe before it's worth surfacing as
    /// `latestNotableFlare` — below C5, NOAA logs dozens of these a week and none of them are
    /// remarkable to a general audience; `rankValue` of exactly `FlareClass(letter: "C",
    /// magnitude: 5.0)` is `2*10 + 5 = 25`.
    static let notabilityThreshold: Double = FlareClass(raw: "C5.0", letter: "C", magnitude: 5.0).rankValue

    /// How far back from `now` a flare's peak (`FlareEvent.maxDate`) may be and still count
    /// toward "trailing 24h" for both the activity-level scan and `latestNotableFlare`. Half-open
    /// on the old end, closed at `now`: `[now - 24h, now]`. A flare peaking at exactly `now - 24h`
    /// counts; one at `now - 24h - 1s` (a "25h-old" flare, per the work order's edge case) does
    /// not.
    static let trailingWindow: TimeInterval = 24 * 60 * 60

    /// Builds the `SolarOutlook` from the three raw feeds and the caller-supplied "now".
    ///
    /// **`activityLevel` mapping** — driven by the current R/G scale (from the NOAA scales `"0"`
    /// entry) and the single strongest flare (by `FlareClass.rankValue`) whose peak falls in the
    /// trailing 24 hours ending at `now`:
    /// ```
    ///  any X-class flare in trailing 24h        -> .stormy
    ///  R scale (now) >= 3                       -> .stormy
    ///  any M-class flare in trailing 24h        -> .active   (if not already .stormy)
    ///  R scale (now) is 1 or 2                  -> .active   (if not already .stormy)
    ///  G scale (now) >= 1                       -> .active   (if not already .stormy)
    ///  none of the above                        -> .quiet
    /// ```
    /// S (solar radiation storm) scale is tracked and exposed (`sScaleNow`) but deliberately does
    /// not feed this mapping — it's a radiation-exposure hazard (aviation/astronaut relevant), not
    /// a "how exciting is the sky/geomagnetic activity right now" signal, which is this outlook's
    /// focus. This mirrors the work order's own example mapping literally: only R (not S, not G)
    /// gates `.stormy`, and R/G (not S) gate `.active`.
    ///
    /// **`latestNotableFlare`** is that same trailing-24h strongest flare, but only reported if it
    /// clears `notabilityThreshold` (>= C5.0) — otherwise `nil`. This can diverge from what drove
    /// `.active`/`.stormy`: e.g. an M1.0 flare pushes `activityLevel` to `.active` (M-class always
    /// qualifies) while still comfortably clearing C5 as notable too; a C3.0 flare does not push
    /// past `.quiet` (unless G/R do) and does not clear C5, so it's simply invisible to both.
    ///
    /// **`gScaleForecastMax`** is the max G scale across the `"1"`/`"2"`/`"3"` (3-day forecast)
    /// entries — kept independent of `gScaleNow` per the work order (a high forecast, not current,
    /// G is the aurora-odds signal worth surfacing ahead of time).
    static func outlook(
        scales: NOAAScales,
        flares: [FlareEvent],
        sunspots: [SunspotObservation],
        now: Date
    ) -> SolarOutlook {
        let current = scales["0"]
        let rScaleNow = current?.r.scaleValue ?? 0
        let sScaleNow = current?.s.scaleValue ?? 0
        let gScaleNow = current?.g.scaleValue ?? 0
        let scalesObservedDate = current?.date

        let forecastGMax = ["1", "2", "3"]
            .compactMap { scales[$0]?.g.scaleValue }
            .max() ?? 0

        let windowStart = now.addingTimeInterval(-trailingWindow)
        let trailing: [(event: FlareEvent, flareClass: FlareClass)] = flares.compactMap { event in
            guard let peak = event.maxDate, peak >= windowStart, peak <= now else { return nil }
            guard let flareClass = FlareClass.parse(event.maxClass) else { return nil }
            return (event, flareClass)
        }
        let strongest = trailing.max { $0.flareClass.rankValue < $1.flareClass.rankValue }

        var level: SolarActivityLevel = .quiet
        if strongest?.flareClass.letter == "X" || rScaleNow >= 3 {
            level = .stormy
        } else if strongest?.flareClass.letter == "M" || (1...2).contains(rScaleNow) || gScaleNow >= 1 {
            level = .active
        }

        var notableFlare: NotableFlare?
        if let strongest, strongest.flareClass.rankValue >= notabilityThreshold, let peak = strongest.event.maxDate {
            notableFlare = NotableFlare(
                classString: strongest.event.maxClass,
                peakTime: peak,
                beginTime: strongest.event.beginDate,
                endTime: strongest.event.endDate
            )
        }

        let latestSunspot = sunspots.max { lhs, rhs in
            (lhs.date ?? .distantPast) < (rhs.date ?? .distantPast)
        }

        return SolarOutlook(
            activityLevel: level,
            latestNotableFlare: notableFlare,
            sunspotNumber: latestSunspot?.swpcSsn,
            sunspotObservationDate: latestSunspot?.date,
            rScaleNow: rScaleNow,
            sScaleNow: sScaleNow,
            gScaleNow: gScaleNow,
            gScaleForecastMax: forecastGMax,
            scalesObservedDate: scalesObservedDate
        )
    }
}
