import Foundation

/// "Which of the next 7 nights is the best one to go stargazing" — a per-night 0...10 rating
/// built from the same two factors `StargazingScore` scores hour-by-hour (clouds, Moon), plus a
/// non-scoring "something special is happening" flag for meteor-shower peaks and eclipses.
///
/// ## Why this is a separate engine from `StargazingScore`, not a wrapper around it
/// `StargazingScore` is an *hourly* engine driven by an hourly forecast (`HourInput` per hour,
/// each with its own condition code) — exactly right for "how good is stargazing right now
/// tonight." A 7-night outlook, by contrast, is fed a **daily** forecast: most weather APIs (and
/// this app's own daily forecast model) give one condition code per day, not one per hour six
/// days out. Reusing `StargazingScore.cloudCoverFraction(conditionCode:precipChance:)` for that
/// single daily code keeps the cloud mapping consistent app-wide, but everything around it here
/// (the window definition, the Moon metric, the per-night rating) is its own thing, documented
/// below.
///
/// **Coarseness, stated plainly per work order:** a daily condition code is a strictly coarser
/// signal than an hourly one — it cannot distinguish "clear all night" from "clear at dusk,
/// clouding up by 2am" or "overcast until midnight, clearing before dawn." `StargazingScore`'s
/// hourly per-hour scoring is the more accurate tool once a specific night is within the hourly
/// forecast's reach (typically the next 1-2 days); `BestNight` trades that precision for reach —
/// it's the only engine in this package that can compare "which night this week" at all, because
/// only the daily forecast extends that far out.
enum BestNight {

    // MARK: - Input

    /// One calendar day's forecast, at daily (not hourly) granularity. Callers build these from
    /// whatever 7-day daily forecast the app already has — one entry per day, in any order (this
    /// engine re-sorts).
    struct NightlyForecastInput {
        var date: Date
        /// Same WeatherKit-style raw condition-code string `StargazingScore.HourInput` takes,
        /// but here representing an entire day/night rather than one hour — see the type-level
        /// doc comment on why that's a coarser signal.
        var conditionCode: String
        var precipChance: Double

        init(date: Date, conditionCode: String, precipChance: Double = 0) {
            self.date = date
            self.conditionCode = conditionCode
            self.precipChance = precipChance
        }
    }

    // MARK: - Output

    /// Which single factor is holding tonight's rating back. `.none` when both factors are
    /// already close to ideal (see `limitingFactorDeficitThreshold`) — there's nothing
    /// meaningfully limiting the night, not even a technically-nonzero smaller of the two.
    enum LimitingFactor: String, Equatable {
        case clouds
        case moon
        case none
    }

    /// A non-scoring "heads up" flag — see the type-level doc comment and work order: these do
    /// NOT change `rating`, they're surfaced so a UI can badge a night as "also: Perseids peak"
    /// independent of how cloudy or moonlit it turns out to be.
    enum SpecialEvent: Equatable {
        case meteorShowerPeak(name: String)
        case eclipse(type: Eclipses.EclipseType)
    }

    struct NightOutlook: Identifiable {
        /// Local start-of-day for the calendar day whose *night* (that evening's civil dusk
        /// through the next morning's civil dawn) this outlook describes.
        var date: Date
        /// 0...10, rounded from `10 x cloudFactor x moonFactor`. See `computeNight` for the
        /// exact model.
        var rating: Int
        var limitingFactor: LimitingFactor
        var specialEvents: [SpecialEvent]
        /// True on exactly one night in a given `outlook(...)` result — see that function's
        /// tie-break rule.
        var isBestNight: Bool
        /// The two raw 0...1 factors behind `rating`, exposed so callers/tests can see the inputs
        /// rather than treating it as a black box (same "show your work" convention as
        /// `StargazingScore.HourScore` and `MeteorShowers.MeteorOutlook`).
        var cloudFactor: Double
        var moonFactor: Double
        var moonIlluminatedPercent: Double
        /// Fraction of the night window (civil dusk -> next civil dawn) the Moon spends above
        /// the horizon.
        var moonUpFraction: Double

        var id: Date { date }
    }

    /// Below this, a factor's "deficit" (`1 - factor`) is treated as negligible rather than
    /// naming it the limiting factor — e.g. a night that's 97% clear and moonless shouldn't have
    /// its trivial 3% cloud deficit reported as "limited by clouds."
    static let limitingFactorDeficitThreshold = 0.1

    // MARK: - Outlook

    /// Rates each of the next 7 calendar nights covered by `dailyForecast` (any entries outside
    /// that window are ignored; entries are re-sorted by date regardless of input order), for an
    /// observer at `latitude`/`longitude` (degrees, longitude positive east) in `timeZone`.
    /// `now` anchors "next 7 nights" and is supplied by the caller — this function reads no
    /// clock itself, matching every other "now"-taking engine in this package (`Conjunctions`,
    /// `MeteorShowers.outlook`).
    ///
    /// Exactly one returned night has `isBestNight == true`: the highest `rating`, ties broken by
    /// earliest `date`. Returns fewer than 7 entries if `dailyForecast` doesn't cover all 7
    /// nights, and an empty array (no crash) if it covers none.
    ///
    /// `eclipseTable` defaults to the bundled `Eclipses.all` and only exists as a parameter so
    /// callers/tests can inject a specific table (same seam `Eclipses.nextEclipse(in:)` and
    /// `Comets.upcoming(in:)` already expose) — production call sites never need to pass it.
    static func outlook(
        dailyForecast: [NightlyForecastInput],
        latitude: Double,
        longitude: Double,
        timeZone: TimeZone,
        now: Date,
        eclipseTable: [Eclipses.Eclipse] = Eclipses.all
    ) -> [NightOutlook] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone

        let todayStart = calendar.startOfDay(for: now)
        let horizonEnd = calendar.date(byAdding: .day, value: 7, to: todayStart) ?? todayStart

        let relevantDays = dailyForecast
            .map { (input: $0, day: calendar.startOfDay(for: $0.date)) }
            .filter { $0.day >= todayStart && $0.day < horizonEnd }
            .sorted { $0.day < $1.day }

        var nights = relevantDays.map { entry in
            computeNight(
                entry.input,
                day: entry.day,
                latitude: latitude,
                longitude: longitude,
                calendar: calendar,
                timeZone: timeZone,
                eclipseTable: eclipseTable
            )
        }

        // argmax by rating, ties -> earliest date. Written as an explicit fold (rather than
        // `max(by:)`) so the tie-break direction is unambiguous and easy to verify by inspection.
        var bestIndex: Int?
        for i in nights.indices {
            guard let currentBest = bestIndex else { bestIndex = i; continue }
            if nights[i].rating > nights[currentBest].rating {
                bestIndex = i
            } else if nights[i].rating == nights[currentBest].rating && nights[i].date < nights[currentBest].date {
                bestIndex = i
            }
        }
        if let bestIndex { nights[bestIndex].isBestNight = true }

        return nights
    }

    /// Convenience accessor for the single `isBestNight` entry in an `outlook(...)` result —
    /// equivalent to `nights.first(where: \.isBestNight)`, `nil` only if `nights` is empty.
    static func bestNight(among nights: [NightOutlook]) -> NightOutlook? {
        nights.first(where: \.isBestNight)
    }

    // MARK: - Per-night computation

    private static func computeNight(
        _ input: NightlyForecastInput,
        day: Date,
        latitude: Double,
        longitude: Double,
        calendar: Calendar,
        timeZone: TimeZone,
        eclipseTable: [Eclipses.Eclipse]
    ) -> NightOutlook {
        // Night window: this calendar day's civil dusk through the next day's civil dawn — same
        // "tonight's dark-sky window" convention `Conjunctions` already uses elsewhere in this
        // engine. Falls back to a fixed 9pm-6am local window on the (never-observed at real-world
        // latitudes, but not impossible at extreme polar latitudes in summer) chance the Sun
        // doesn't cross civil twilight that night, so this always returns a well-formed window.
        let sunToday = SunMoon.sunTimes(after: day, lat: latitude, lon: longitude)
        let nightStart = sunToday.civilDusk ?? calendar.date(byAdding: .hour, value: 21, to: day) ?? day
        let nextDay = calendar.date(byAdding: .day, value: 1, to: day) ?? day.addingTimeInterval(86400)
        let sunTomorrow = SunMoon.sunTimes(after: nextDay, lat: latitude, lon: longitude)
        let nightEnd = sunTomorrow.civilDawn ?? calendar.date(byAdding: .hour, value: 6, to: nextDay) ?? nextDay

        // --- Cloud factor: one daily condition code/precip chance for the whole night (see
        // type-level doc comment on why this is coarser than StargazingScore's hourly version).
        let cloudCover = StargazingScore.cloudCoverFraction(conditionCode: input.conditionCode, precipChance: input.precipChance)
        let cloudFactor = 1.0 - cloudCover

        // --- Moon factor: illumination x up-fraction across the night window, sampled the same
        // fixed-step brute-force way `MeteorShowers.outlook` and `SkyTonight.scanForBestViewing`
        // already do for the same reason (cheap, simple to get right for an already-bounded
        // window). Combined into a single `moonFactor` using the exact same "gentler than the
        // meteor model" floor `StargazingScore.moonFactor` uses for its per-instant version
        // (`fullMoonFloor` = 0.35: a full Moon up the *entire* night still leaves the sky at 35%
        // of its moonless quality, since stars/planets survive moonlight far better than faint
        // meteors do) — reused here rather than re-deriving a second floor constant, so a
        // "worst-case Moon night" reads the same whether the app is looking at StargazingScore's
        // per-hour view or BestNight's per-night view.
        let step: TimeInterval = 15 * 60
        var t = nightStart
        var samples = 0
        var moonUpSamples = 0
        while t <= nightEnd {
            samples += 1
            let jd = AstroTime.julianDay(t)
            let moonEq = SunMoon.moonEquatorial(date: t)
            let altitude = equatorialToHorizontal(moonEq, latitude: latitude, longitudeEast: longitude, jd: jd).altitude
            if altitude > 0 { moonUpSamples += 1 }
            t = t.addingTimeInterval(step)
        }
        let moonUpFraction = samples > 0 ? Double(moonUpSamples) / Double(samples) : 0
        let illuminatedFraction = SunMoon.moonPhase(date: nightStart).illuminatedFraction
        let moonExposure = illuminatedFraction * moonUpFraction
        let moonFactor = 1.0 - (1.0 - StargazingScore.fullMoonFloor) * moonExposure

        let rawRating = 10.0 * cloudFactor * moonFactor
        let rating = Int(rawRating.rounded())

        let cloudDeficit = 1.0 - cloudFactor
        let moonDeficit = 1.0 - moonFactor
        let limitingFactor: LimitingFactor
        if cloudDeficit < limitingFactorDeficitThreshold && moonDeficit < limitingFactorDeficitThreshold {
            limitingFactor = .none
        } else if cloudDeficit >= moonDeficit {
            limitingFactor = .clouds
        } else {
            limitingFactor = .moon
        }

        // --- Special-event flags (bonus only, per type-level doc comment -- never touches
        // `rating` above). A meteor shower counts only on its textbook peak night (matching
        // `MeteorShowers.ActiveShower.isPeakNight`'s own "peak calendar date" caveat); an eclipse
        // counts if its peak UTC instant falls on this calendar day in `timeZone`, regardless of
        // whether it's actually visible from `latitude`/`longitude` (a "heads up" flag, not a
        // visibility claim -- see `Eclipses.eclipses(onCalendarDay:timeZone:)`).
        var specialEvents: [SpecialEvent] = []
        if let activePeak = MeteorShowers.activeShowers(on: day, timeZone: timeZone).first(where: { $0.isPeakNight }) {
            specialEvents.append(.meteorShowerPeak(name: activePeak.shower.name))
        }
        for eclipse in Eclipses.eclipses(onCalendarDay: day, timeZone: timeZone, in: eclipseTable) {
            specialEvents.append(.eclipse(type: eclipse.type))
        }

        return NightOutlook(
            date: day,
            rating: rating,
            limitingFactor: limitingFactor,
            specialEvents: specialEvents,
            isBestNight: false,
            cloudFactor: cloudFactor,
            moonFactor: moonFactor,
            moonIlluminatedPercent: illuminatedFraction * 100,
            moonUpFraction: moonUpFraction
        )
    }
}
