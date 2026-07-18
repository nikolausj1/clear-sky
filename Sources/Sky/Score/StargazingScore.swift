import Foundation

/// Per-hour "how good is stargazing right now" score (0...10) for tonight's hours, built from
/// three independent, multiplicative factors — how dark the sky is, how much cloud is in the
/// way, and how much the Moon is washing everything out — plus a `DarknessTier` per hour (the
/// UI's track-tint gradient) and a one-word quality label.
///
/// ## Dependency shape (per work order)
/// This file takes **plain Doubles/Dates** in (`HourInput` below), never a weather-model type
/// (`HourlyEntry`, `CachedWeather`, etc.) — the app layer is responsible for building an array
/// of `HourInput` from `CachedWeather.hourly` plus whatever location it already has. That keeps
/// this a leaf dependency: only `Foundation` plus the `Astronomy` engine it sits beside
/// (`SunMoon`, `AstroTime`, `equatorialToHorizontal`), never `Sources/Models`.
///
/// ## The three factors (documented weights)
/// `score = 10 x darkness x clouds x moon`, each factor 0...1, rounded to the nearest `Int`:
///
/// 1. **Darkness** — from the Sun's altitude at that hour (`SunMoon.sunPosition`), bucketed
///    into the same bands `SunMoon.StandardAltitude` already defines: day = 0.0, civil
///    twilight = 0.15, nautical twilight = 0.5, astronomical twilight = 0.85, full dark = 1.0.
///    A meaningful amount of skylight (day, civil twilight) crushes this factor toward zero
///    regardless of how good the other two factors are — you cannot out-cloud or out-moon
///    actual daylight.
/// 2. **Clouds** — `1 - cloudCoverFraction(conditionCode:precipChance:)` (see that function for
///    the documented condition-code -> cloud-cover mapping; precipitation/fog conditions floor
///    cloud cover at 1.0, i.e. clouds factor 0).
/// 3. **Moon** — moon-up x illumination, but *gentler* than `MeteorShowers`' washout model
///    (see `moonFactor(moonAltitudeDegrees:illuminatedFraction:)`): new moon or moon-down scores
///    1.0 (no penalty), a full moon up scores `fullMoonFloor` (0.35) — stars and planets survive
///    moonlight far better than faint meteors do, so this floor is well above the meteor model's
///    ~0.20 bright-Moon floor.
enum StargazingScore {

    // MARK: - Input

    /// One hour's raw inputs, already stripped of any weather-model type by the caller (see the
    /// type-level doc comment). This is the file's only "get data in" surface.
    struct HourInput {
        var date: Date
        /// WeatherKit's raw `WeatherCondition.rawValue` string (e.g. "clear", "mostlyCloudy",
        /// "rain"), the same string already stored on `HourlyEntry.conditionCode` — passed
        /// through unparsed so this file, not the caller, owns the cloud-cover mapping.
        var conditionCode: String
        /// 0...1 chance of precipitation this hour (`HourlyEntry.precipChance`). Any real
        /// chance of precipitation floors the cloud factor at fully overcast (see
        /// `cloudCoverFraction`), since rain/snow/storms block the sky regardless of what the
        /// bare condition code would otherwise suggest.
        var precipChance: Double

        init(date: Date, conditionCode: String, precipChance: Double = 0) {
            self.date = date
            self.conditionCode = conditionCode
            self.precipChance = precipChance
        }
    }

    // MARK: - Output

    /// How dark the sky is at an hour, in the same bands `SunMoon.StandardAltitude` already
    /// defines. The UI's track tint reuses this directly so its gradient stops line up exactly
    /// with the thresholds this engine scores against.
    enum DarknessTier: String, CaseIterable {
        case day
        case civilTwilight
        case nauticalTwilight
        case astronomicalTwilight
        case fullDark

        /// The `darkness` multiplier this tier contributes (see the type-level doc comment's
        /// weight table).
        var darknessFactor: Double {
            switch self {
            case .day: return 0.0
            case .civilTwilight: return 0.15
            case .nauticalTwilight: return 0.5
            case .astronomicalTwilight: return 0.85
            case .fullDark: return 1.0
            }
        }
    }

    /// One-word quality label for a score: 0-2 poor, 3-4 fair, 5-7 good, 8-10 excellent.
    enum QualityLabel: String {
        case poor, fair, good, excellent

        static func forScore(_ score: Int) -> QualityLabel {
            switch score {
            case ..<3: return .poor       // 0...2
            case 3...4: return .fair
            case 5...7: return .good
            default: return .excellent    // 8...10 (and any out-of-range positive score)
            }
        }
    }

    struct HourScore {
        var date: Date
        /// 0...10, rounded from `10 x darknessFactor x cloudFactor x moonFactor`.
        var score: Int
        var tier: DarknessTier
        var quality: QualityLabel
        /// The three raw 0...1 factors behind `score`, exposed so callers/tests can see what
        /// drove a given hour's number rather than treating it as a black box (same
        /// "show your work" spirit as `MeteorShowers.MeteorOutlook`'s transparency fields).
        var darknessFactor: Double
        var cloudFactor: Double
        var moonFactor: Double
    }

    // MARK: - Cloud-cover mapping
    //
    // `HourlyEntry` (the weather model) has no explicit cloud-cover percentage, only a
    // `conditionCode` string and a `precipChance` fraction — so this engine derives an
    // approximate 0 (clear) ... 1 (fully overcast) cloud-cover fraction from the condition
    // code text (documented per work order):
    //
    //   clear             -> 0.0
    //   mostlyClear       -> 0.2
    //   partlyCloudy      -> 0.45
    //   mostlyCloudy      -> 0.75
    //   cloudy/overcast   -> 1.0
    //   precip/storm/fog  -> 1.0  (fully obstructed regardless of the literal cloud fraction --
    //                               rain/snow/fog/thunder all block the sky just as thoroughly
    //                               as a solid overcast deck would)
    //
    // Matching is done on the lowercased condition string via `contains`, the same technique
    // `PhraseBank.conditionGroup(forRawCode:)` / `DoodleHeaderView` already use, so this
    // engine's notion of "cloudy" agrees with the rest of the app's. More specific codes
    // (`mostlyClear`, `mostlyCloudy`) are matched before the broader substrings they contain
    // (`clear`, `cloud`).

    /// Condition codes matching any of these count as fully sky-obstructing regardless of
    /// their literal cloud description (precipitation, storms, fog/haze/smoke/dust).
    private static let fullyObstructingSubstrings = [
        "thunder", "storm", "hurricane",
        "rain", "drizzle", "snow", "flurries", "sleet", "hail", "ice", "wintry", "blizzard",
        "fog", "haze", "hazy", "smok", "dust",
    ]

    /// A better-than-even chance of precipitation this hour is treated as "the sky's blocked"
    /// even when `conditionCode` alone reads as merely partly cloudy — a "partlyCloudy" hour
    /// with a 60% chance of rain is more realistically a passing-shower hour than a good
    /// stargazing one.
    static let precipOverridesCloudThreshold = 0.5

    /// Maps a raw condition code (+ precipitation chance) to an approximate 0...1 cloud-cover
    /// fraction. See the mapping table above.
    static func cloudCoverFraction(conditionCode: String, precipChance: Double = 0) -> Double {
        if precipChance >= precipOverridesCloudThreshold {
            return 1.0
        }

        let code = conditionCode.lowercased()
        if fullyObstructingSubstrings.contains(where: { code.contains($0) }) {
            return 1.0
        }

        // Graded cloud descriptions, most specific substring first.
        if code.contains("mostlyclear") { return 0.2 }
        if code.contains("partlycloudy") { return 0.45 }
        if code.contains("mostlycloudy") { return 0.75 }
        if code.contains("cloudy") || code.contains("overcast") { return 1.0 }
        if code.contains("clear") { return 0.0 }

        // Unrecognized/rare codes (e.g. "breezy", "windy", "hot", "frigid" -- conditions that
        // say nothing about cloud cover either way): assume a moderate, partly-cloudy sky
        // rather than either extreme, matching `PhraseBank.conditionGroup`'s own "safest
        // generic bucket" philosophy for codes it doesn't recognize.
        return 0.45
    }

    // MARK: - Darkness

    /// Buckets a Sun altitude (degrees) into a `DarknessTier`, using the exact same threshold
    /// altitudes `SunMoon.sunTimes`'s own dawn/dusk solver is built on
    /// (`SunMoon.StandardAltitude`), so an hour just after civil dusk here is guaranteed to
    /// agree with `SunMoon.sunTimes(...).civilDusk` for the same instant/location.
    static func darknessTier(sunAltitudeDegrees: Double) -> DarknessTier {
        if sunAltitudeDegrees >= SunMoon.StandardAltitude.sunriseSunset { return .day }
        if sunAltitudeDegrees >= SunMoon.StandardAltitude.civilTwilight { return .civilTwilight }
        if sunAltitudeDegrees >= SunMoon.StandardAltitude.nauticalTwilight { return .nauticalTwilight }
        if sunAltitudeDegrees >= SunMoon.StandardAltitude.astronomicalTwilight { return .astronomicalTwilight }
        return .fullDark
    }

    // MARK: - Moon interference

    /// Full-moon-up floor: the worst the Moon factor ever gets, at 100% illumination while up.
    /// Deliberately much gentler than `MeteorShowers.moonRetentionFactor`'s ~0.20 bright-Moon
    /// floor (see the type-level doc comment) -- naked-eye stars and planets are far less
    /// washed out by moonlight than faint meteors are.
    static let fullMoonFloor = 0.35

    /// Moon interference factor: 1.0 whenever the Moon is below the horizon (or new), linearly
    /// interpolating down to `fullMoonFloor` as illumination rises to 100% while the Moon is up.
    static func moonFactor(moonAltitudeDegrees: Double, illuminatedFraction: Double) -> Double {
        guard moonAltitudeDegrees > 0 else { return 1.0 }
        let illum = max(0, min(1, illuminatedFraction))
        return 1.0 - (1.0 - fullMoonFloor) * illum
    }

    // MARK: - Scoring

    /// Scores a single hour.
    static func score(for hour: HourInput, latitude: Double, longitude: Double) -> HourScore {
        let sunAltitude = SunMoon.sunPosition(date: hour.date, lat: latitude, lon: longitude).altitude
        let tier = darknessTier(sunAltitudeDegrees: sunAltitude)
        let darkness = tier.darknessFactor

        let cloudCover = cloudCoverFraction(conditionCode: hour.conditionCode, precipChance: hour.precipChance)
        let clouds = 1.0 - cloudCover

        let jd = AstroTime.julianDay(hour.date)
        let moonEquatorial = SunMoon.moonEquatorial(date: hour.date)
        let moonAltitude = equatorialToHorizontal(moonEquatorial, latitude: latitude, longitudeEast: longitude, jd: jd).altitude
        let illuminatedFraction = SunMoon.moonPhase(date: hour.date).illuminatedFraction
        let moon = moonFactor(moonAltitudeDegrees: moonAltitude, illuminatedFraction: illuminatedFraction)

        let rawScore = 10.0 * darkness * clouds * moon
        let roundedScore = Int(rawScore.rounded())

        return HourScore(
            date: hour.date,
            score: roundedScore,
            tier: tier,
            quality: QualityLabel.forScore(roundedScore),
            darknessFactor: darkness,
            cloudFactor: clouds,
            moonFactor: moon
        )
    }

    /// Scores every hour in `hours`, in the order given. Callers typically pre-filter `hours`
    /// to tonight's window (e.g. civil dusk through tomorrow's civil dawn, or simply "the next
    /// 24 hours of `HourlyEntry`") before calling this -- hours outside any dark window still
    /// score correctly (they just come back as `DarknessTier.day` / score 0 via the darkness
    /// factor), so no separate windowing logic lives in this file.
    static func hourlyScores(hours: [HourInput], latitude: Double, longitude: Double) -> [HourScore] {
        hours.map { score(for: $0, latitude: latitude, longitude: longitude) }
    }
}
