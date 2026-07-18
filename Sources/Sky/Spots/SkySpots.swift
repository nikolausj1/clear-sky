import Foundation

/// Live-data binding logic for the `SkySpot` atlas -- pure functions that take a spot plus
/// whatever live data the app already fetched elsewhere (launches, aurora feeds, a date, a
/// batch of saved cities' daily forecasts) and answer "what does tonight look like at this
/// place." No networking and no `Date()` defaults here, same convention as every other engine
/// in `Sources/Sky/` (`AuroraLikelihood`, `BestNight`, `StargazingScore`): every "now"/"tonight"
/// instant is supplied by the caller so this stays deterministic and testable against canned
/// input (see `Tests/SpotsSmokeTest.swift`).
///
/// This file deliberately does no new astronomy/aurora/scoring math of its own -- it's glue
/// that reuses the existing engines (`AuroraLikelihood`, `SunMoon`, `BestNight`) against a
/// `SkySpot`'s coordinates, per the work package's "reuse" instruction for each of the three
/// categories.
enum SkySpots {

    // MARK: - Launch sites: next scheduled launch

    /// Finds the next scheduled launch at `spot` among `launches`, by case-insensitive substring
    /// matching `spot.matchKeys` against each launch's `padName` and `locationDisplay` (LL2's pad
    /// location strings, e.g. `"Cape Canaveral, FL"`, `"SpaceX Starbase, TX"`, `"Vandenberg, CA"`
    /// -- see `LaunchSchedule.locationDisplay(fromLocationName:)`).
    ///
    /// - Returns: the earliest-`net` matching launch (`launches` is not assumed to already be
    ///   sorted), or `nil` if `spot` has no `matchKeys` (i.e. isn't a `launchSite` entry) or none
    ///   of `launches` matches any key. No false positives by construction: a pad string that
    ///   doesn't contain any of `spot.matchKeys` (e.g. "Jiuquan Satellite Launch Center, China"
    ///   against the Cape Canaveral spot's `["Cape Canaveral", "Kennedy", ...]` keys) simply
    ///   doesn't match -- there's no fuzzy/geographic fallback.
    static func launchSiteNext(spot: SkySpot, launches: [UpcomingLaunch]) -> UpcomingLaunch? {
        guard !spot.matchKeys.isEmpty else { return nil }
        let keys = spot.matchKeys.map { $0.lowercased() }
        let matches = launches.filter { launch in
            let haystack = "\(launch.padName) \(launch.locationDisplay)".lowercased()
            return keys.contains { haystack.contains($0) }
        }
        return matches.min { $0.net < $1.net }
    }

    // MARK: - Aurora spots: tonight's outlook

    /// Tonight's aurora outlook for `spot`, computed by feeding its coordinates straight into
    /// `AuroraLikelihood.outlook(...)` -- the existing OVATION-grid + Kp-forecast engine. This is
    /// a thin coordinate-forwarding wrapper, not new math: the reason Fairbanks/Yellowknife/
    /// Tromso/etc. read as good aurora bets even at modest Kp is entirely
    /// `AuroraLikelihood.geomagneticLatitude(...)`/`visibilityLatitude(forKp:)` doing their job
    /// on those spots' real coordinates (see `Tests/SpotsSmokeTest.swift`'s "flattering-math"
    /// assertion for Fairbanks vs. Miami at the same synthetic Kp).
    ///
    /// - Parameters:
    ///   - grid: the OVATION nowcast grid, already indexed (`AuroraTonight.fetch` builds one).
    ///   - kpForecast: SWPC's 3-hour Kp forecast rows.
    ///   - darkHoursStart/darkHoursEnd: `spot`'s own dark-hours window for the night in question
    ///     (typically that night's civil dusk -> next morning's civil dawn at `spot`'s
    ///     coordinates -- callers can get this from `SunMoon.sunTimes(after:lat:lon:)`, same as
    ///     `AuroraTonight.fetch`'s caller does for the user's own location).
    static func auroraSpotOutlook(
        spot: SkySpot,
        grid: AuroraLikelihood.IndexedGrid,
        kpForecast: [KpForecastRow],
        darkHoursStart: Date,
        darkHoursEnd: Date
    ) -> AuroraOutlook {
        AuroraLikelihood.outlook(
            grid: grid,
            kpForecast: kpForecast,
            latitude: spot.latitude,
            longitude: spot.longitude,
            darkHoursStart: darkHoursStart,
            darkHoursEnd: darkHoursEnd
        )
    }

    // MARK: - Dark-sky spots: tonight's moon note

    /// Tonight's Moon situation at `spot`, for the calendar day containing `date`: how lit the
    /// Moon is, whether it spends any time above the horizon during that night's dark hours, and
    /// a one-line, honest note about what that means for viewing.
    struct DarkSkyTonight: Equatable {
        /// 0...100, `SunMoon.MoonPhase.illuminatedFraction * 100` at dusk.
        var moonIlluminationPct: Double
        /// True if the Moon is above the horizon for any sampled instant of the night window
        /// (that evening's civil dusk through the next morning's civil dawn at `spot`'s
        /// coordinates).
        var moonUpDuringDarkHours: Bool
        var note: String
    }

    /// Illumination at/below which the note calls out a new-moon week regardless of whether the
    /// (nearly invisible) Moon happens to be up.
    static let newMoonIlluminationThreshold = 10.0
    /// Illumination at/above which -- *if* the Moon is also up during dark hours -- the note
    /// calls out a bright, full-Moon night.
    static let fullMoonIlluminationThreshold = 90.0

    /// Computes `DarkSkyTonight` for `spot` on the calendar night starting `date` (this day's
    /// civil dusk through the next day's civil dawn, same "tonight" window convention
    /// `BestNight.computeNight` uses), reusing `SunMoon` directly -- no new astronomy math.
    static func darkSkyTonight(spot: SkySpot, date: Date) -> DarkSkyTonight {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        let day = calendar.startOfDay(for: date)

        let sunToday = SunMoon.sunTimes(after: day, lat: spot.latitude, lon: spot.longitude)
        let nightStart = sunToday.civilDusk ?? calendar.date(byAdding: .hour, value: 21, to: day) ?? day
        let nextDay = calendar.date(byAdding: .day, value: 1, to: day) ?? day.addingTimeInterval(86400)
        let sunTomorrow = SunMoon.sunTimes(after: nextDay, lat: spot.latitude, lon: spot.longitude)
        let nightEnd = sunTomorrow.civilDawn ?? calendar.date(byAdding: .hour, value: 6, to: nextDay) ?? nextDay

        // Sample the night window the same fixed-step brute-force way `BestNight.computeNight`
        // does, for the same "cheap, simple to get right for an already-bounded window" reason.
        let step: TimeInterval = 15 * 60
        var moonUp = false
        var t = nightStart
        while t <= nightEnd {
            let jd = AstroTime.julianDay(t)
            let moonEq = SunMoon.moonEquatorial(date: t)
            let altitude = equatorialToHorizontal(moonEq, latitude: spot.latitude, longitudeEast: spot.longitude, jd: jd).altitude
            if altitude > 0 {
                moonUp = true
                break
            }
            t = t.addingTimeInterval(step)
        }

        let illuminatedFraction = SunMoon.moonPhase(date: nightStart).illuminatedFraction
        let illuminationPct = illuminatedFraction * 100

        let note: String
        if illuminationPct <= newMoonIlluminationThreshold {
            note = "New moon week — prime conditions"
        } else if illuminationPct >= fullMoonIlluminationThreshold && moonUp {
            note = "Full moon tonight — bright skies even here"
        } else if moonUp {
            note = "Moon \(Int(illuminationPct.rounded()))% lit and up tonight — some glow, still workable skies"
        } else {
            note = "Moon \(Int(illuminationPct.rounded()))% lit but below the horizon during dark hours — no interference"
        }

        return DarkSkyTonight(
            moonIlluminationPct: illuminationPct,
            moonUpDuringDarkHours: moonUp,
            note: note
        )
    }

    // MARK: - Saved-city ranking: tonight only

    /// One saved city's input for `savedCityRanking`. Deliberately the smallest slice of a
    /// day's forecast `BestNight.NightlyForecastInput` needs -- a name/coordinate plus a single
    /// condition code and precip chance -- **not** an hourly array or a full `CachedWeather`.
    ///
    /// **What the UI needs to feed this:** for each saved location, the `DailyEntry` (this
    /// app's own daily-forecast model, `Sources/Models/WeatherPayload.swift`) whose `date` is
    /// today's calendar day. That entry's `conditionCode` and `precipChance` fields map directly
    /// onto this struct's fields of the same name -- no transformation needed. This is a
    /// one-value-per-city lookup (today's row out of `CachedWeather.daily`), not a fetch of new
    /// data: `RankingsViewModel`'s existing per-location `WeatherStore` cache already has
    /// everything this needs.
    struct CityForecastInput {
        var name: String
        var latitude: Double
        var longitude: Double
        var conditionCode: String
        var precipChance: Double

        init(name: String, latitude: Double, longitude: Double, conditionCode: String, precipChance: Double = 0) {
            self.name = name
            self.latitude = latitude
            self.longitude = longitude
            self.conditionCode = conditionCode
            self.precipChance = precipChance
        }
    }

    /// One city's result from `savedCityRanking`.
    struct CityRanking: Equatable {
        var city: String
        /// 0...10, `BestNight`'s rating for tonight specifically (not the best night this week).
        var tonightScore: Int
        var limitingFactor: BestNight.LimitingFactor
    }

    /// Ranks `cities` by tonight's stargazing rating only (not "best night this week" --
    /// `BestNight.outlook` is fed a single-entry daily forecast per city, so the only night it
    /// can possibly return is tonight), highest score first, ties broken alphabetically by city
    /// name -- the same tie-break `RankingsViewModel.rows(unit:)` already uses for its
    /// pleasantness ranking, kept consistent here.
    ///
    /// **Time zone, stated plainly:** like the rest of this app's daily-forecast handling (see
    /// `Sources/Models/WeatherPayload.swift` -- `DailyEntry` carries no per-location time zone
    /// of its own), "today" is resolved against a single caller-supplied `timeZone` for every
    /// city in the batch, not a per-city zone (`SavedLocation` has no time zone field to draw
    /// one from). For a US-only or few-time-zone saved-city list this is a non-issue; for a
    /// world-spanning list it means a city many hours away from `timeZone` could have its
    /// "today" boundary reflect the caller's day rather than its own local one. Documented
    /// limitation, not fixed here, matching the app's existing single-time-zone-day convention
    /// rather than inventing new per-location time zone plumbing nothing else in the app has.
    static func savedCityRanking(
        cities: [CityForecastInput],
        timeZone: TimeZone,
        now: Date
    ) -> [CityRanking] {
        let ranked: [CityRanking] = cities.compactMap { city in
            let nights = BestNight.outlook(
                dailyForecast: [
                    BestNight.NightlyForecastInput(date: now, conditionCode: city.conditionCode, precipChance: city.precipChance)
                ],
                latitude: city.latitude,
                longitude: city.longitude,
                timeZone: timeZone,
                now: now
            )
            guard let tonight = nights.first else { return nil }
            return CityRanking(city: city.name, tonightScore: tonight.rating, limitingFactor: tonight.limitingFactor)
        }

        return ranked.sorted { lhs, rhs in
            if lhs.tonightScore != rhs.tonightScore { return lhs.tonightScore > rhs.tonightScore }
            return lhs.city.localizedStandardCompare(rhs.city) == .orderedAscending
        }
    }
}
