import Foundation

/// Major annual meteor showers, "is one active/peaking tonight", and — the actually useful
/// part — an honest attempt to translate a shower's textbook ZHR into "how many will a person
/// standing in their yard actually see," given tonight's Moon.
///
/// ## Why this file exists (and what it deliberately does NOT do)
/// Every meteor-shower calendar on the internet prints the same Zenithal Hourly Rate (ZHR):
/// the count a single experienced observer would see with the shower's radiant at the zenith,
/// under a limiting magnitude of +6.5 (i.e. a truly dark, moonless sky). Almost nobody's actual
/// sky matches that. The single biggest, most predictable knock-down factor — bigger than
/// radiant altitude, bigger than local light pollution for most suburban observers — is the
/// Moon: a bright Moon above the horizon during the viewing window raises the effective sky
/// background and erases every meteor fainter than roughly its own glow. That's the one factor
/// this file corrects for. It does NOT correct for radiant altitude (rate scales down when the
/// radiant is low, roughly by sin of its altitude), local light pollution, or cloud cover — all
/// real effects, all left as documented gaps (see `MeteorOutlook` below). Consider
/// `estimatedVisiblePerHour` a "how much is the Moon going to ruin this" estimate layered on
/// top of the textbook ZHR, not a full visibility model.
enum MeteorShowers {

    // MARK: - Static shower table

    struct MonthDay: Equatable {
        var month: Int
        var day: Int
    }

    struct MeteorShower: Equatable {
        var name: String
        /// Roughly when the shower produces any elevated meteor activity. Some showers
        /// (Quadrantids, Ursids) straddle the Dec 31/Jan 1 boundary; `activeStart` may be
        /// numerically "after" `activeEnd` in that case — `MeteorShowers.isActive` below
        /// handles the wraparound.
        var activeStart: MonthDay
        var activeEnd: MonthDay
        /// The shower's usual peak calendar night. **This is a fixed calendar day, not a
        /// per-year-accurate prediction.** Real peaks drift roughly ±1 day year to year (and,
        /// for a few showers — Draconids and Leonids especially — can shift by more, or spike
        /// unpredictably, in ways this static table cannot capture). Treat `isPeakNight` as
        /// "textbook peak calendar date", not an authoritative almanac lookup; a production
        /// app that wants exact per-year peak timing should source that from IMO/AMS instead.
        var peak: MonthDay
        /// Zenithal Hourly Rate under ideal (zenith radiant, +6.5 limiting magnitude, dark sky)
        /// conditions. Source: American Meteor Society / IMO published annual figures — these
        /// are themselves long-run averages; any given year's actual rate can differ.
        var zhr: Double
        var radiantConstellation: String
        /// Approximate J2000-ish radiant right ascension, degrees. "Rough" per work order —
        /// good enough to say "look toward Perseus", not for precision astrometry.
        var radiantRA: Double
        /// Approximate radiant declination, degrees.
        var radiantDec: Double
        /// Plain-language viewing guidance (when to look, relative to midnight/radiant
        /// altitude). This is reference material describing the shower itself, not app display
        /// copy for a specific night — similar in spirit to `Planets.Body.displayName`
        /// elsewhere in this engine.
        var viewingNotes: String
    }

    /// The ~12 major annual showers reliably active for northern-hemisphere observers.
    /// Active-range/peak dates and ZHR figures are standard AMS/IMO reference values.
    static let all: [MeteorShower] = [
        MeteorShower(
            name: "Quadrantids",
            activeStart: MonthDay(month: 12, day: 28), activeEnd: MonthDay(month: 1, day: 12),
            peak: MonthDay(month: 1, day: 3),
            zhr: 120,
            radiantConstellation: "Boötes", radiantRA: 230, radiantDec: 49,
            viewingNotes: "Very short, sharp peak (just a few hours) — best in the few hours before dawn when the radiant, low in the northeast at dusk, has climbed highest."
        ),
        MeteorShower(
            name: "Lyrids",
            activeStart: MonthDay(month: 4, day: 16), activeEnd: MonthDay(month: 4, day: 25),
            peak: MonthDay(month: 4, day: 22),
            zhr: 18,
            radiantConstellation: "Lyra", radiantRA: 271, radiantDec: 34,
            viewingNotes: "Best after midnight, once Lyra (near Vega) is well up in the east; occasional bright fireballs."
        ),
        MeteorShower(
            name: "Eta Aquariids",
            activeStart: MonthDay(month: 4, day: 19), activeEnd: MonthDay(month: 5, day: 28),
            peak: MonthDay(month: 5, day: 5),
            zhr: 50,
            radiantConstellation: "Aquarius", radiantRA: 338, radiantDec: -1,
            viewingNotes: "A Halley's-Comet shower, better from the southern hemisphere / low northern latitudes; radiant rises late, so the best window is the couple of hours right before dawn."
        ),
        MeteorShower(
            name: "Southern Delta Aquariids",
            activeStart: MonthDay(month: 7, day: 12), activeEnd: MonthDay(month: 8, day: 23),
            peak: MonthDay(month: 7, day: 30),
            zhr: 25,
            radiantConstellation: "Aquarius", radiantRA: 339, radiantDec: -16,
            viewingNotes: "Broad, weak peak best seen after midnight when Aquarius is higher in the south; often blends with early Perseid activity."
        ),
        MeteorShower(
            name: "Perseids",
            activeStart: MonthDay(month: 7, day: 17), activeEnd: MonthDay(month: 8, day: 24),
            peak: MonthDay(month: 8, day: 12),
            zhr: 100,
            radiantConstellation: "Perseus", radiantRA: 48, radiantDec: 58,
            viewingNotes: "The most reliable major shower. Rates build through the night; best after midnight through dawn as Perseus climbs the northeastern sky."
        ),
        MeteorShower(
            name: "Draconids",
            activeStart: MonthDay(month: 10, day: 6), activeEnd: MonthDay(month: 10, day: 10),
            peak: MonthDay(month: 10, day: 8),
            zhr: 10,
            radiantConstellation: "Draco", radiantRA: 262, radiantDec: 54,
            viewingNotes: "Unusual among showers: best in the evening (radiant highest right after dusk), not after midnight. Normally sparse but has produced sudden storms in past outburst years — this table cannot predict those."
        ),
        MeteorShower(
            name: "Orionids",
            activeStart: MonthDay(month: 10, day: 2), activeEnd: MonthDay(month: 11, day: 7),
            peak: MonthDay(month: 10, day: 21),
            zhr: 20,
            radiantConstellation: "Orion", radiantRA: 95, radiantDec: 16,
            viewingNotes: "Another Halley's-Comet shower; best after midnight once Orion is well up, fast meteors that often leave persistent trains."
        ),
        MeteorShower(
            name: "Southern Taurids",
            activeStart: MonthDay(month: 9, day: 10), activeEnd: MonthDay(month: 11, day: 20),
            peak: MonthDay(month: 10, day: 10),
            zhr: 5,
            radiantConstellation: "Taurus", radiantRA: 52, radiantDec: 13,
            viewingNotes: "Low rate but a high fraction of bright fireballs; radiant is up most of the night, so timing is less critical than for other showers."
        ),
        MeteorShower(
            name: "Northern Taurids",
            activeStart: MonthDay(month: 10, day: 20), activeEnd: MonthDay(month: 12, day: 10),
            peak: MonthDay(month: 11, day: 12),
            zhr: 5,
            radiantConstellation: "Taurus", radiantRA: 58, radiantDec: 22,
            viewingNotes: "Overlaps the Southern Taurids and shares its fireball-heavy character; the two together are sometimes called the 'Halloween fireballs'."
        ),
        MeteorShower(
            name: "Leonids",
            activeStart: MonthDay(month: 11, day: 6), activeEnd: MonthDay(month: 11, day: 30),
            peak: MonthDay(month: 11, day: 17),
            zhr: 15,
            radiantConstellation: "Leo", radiantRA: 152, radiantDec: 22,
            viewingNotes: "Best after midnight when Leo has risen; ordinarily modest, but the source comet's 33-year return period has produced historic meteor storms this table cannot predict."
        ),
        MeteorShower(
            name: "Geminids",
            activeStart: MonthDay(month: 12, day: 4), activeEnd: MonthDay(month: 12, day: 17),
            peak: MonthDay(month: 12, day: 13),
            zhr: 120,
            radiantConstellation: "Gemini", radiantRA: 112, radiantDec: 33,
            viewingNotes: "Rivals the Perseids and is arguably more reliable; unusually good even before midnight, with the best rates typically 1-2am local when Gemini is highest."
        ),
        MeteorShower(
            name: "Ursids",
            activeStart: MonthDay(month: 12, day: 17), activeEnd: MonthDay(month: 12, day: 26),
            peak: MonthDay(month: 12, day: 22),
            zhr: 10,
            radiantConstellation: "Ursa Minor", radiantRA: 217, radiantDec: 75,
            viewingNotes: "Sparse, circumpolar radiant near the Little Dipper — technically visible all night at northern latitudes, best in the pre-dawn hours."
        ),
    ]

    /// Day-of-year ordinal (1...365/366) for a bare month/day, computed against a fixed
    /// non-leap reference year so every `MonthDay` maps to a stable ordinal regardless of what
    /// year the caller's actual date falls in. Leap-year Feb 29 shifts everything after it by
    /// one day in a real year; none of this table's dates fall in February, so that's a
    /// non-issue here, and the ±1 day peak-date fuzziness already swallows slop this small.
    private static func ordinal(_ md: MonthDay) -> Int {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        var components = DateComponents()
        components.year = 2001
        components.month = md.month
        components.day = md.day
        let date = calendar.date(from: components)!
        return calendar.ordinality(of: .day, in: .year, for: date)!
    }

    /// True if the ordinal `d` falls within `[s, e]`, allowing `s > e` to mean "wraps across
    /// the year boundary" (e.g. Quadrantids: active Dec 28 -> Jan 12).
    private static func ordinalInRange(_ d: Int, _ s: Int, _ e: Int) -> Bool {
        if s <= e {
            return d >= s && d <= e
        } else {
            return d >= s || d <= e
        }
    }

    /// Shortest signed distance (in days) from ordinal `d` to ordinal `peak`, wrapping across
    /// the ~365-day year boundary so e.g. Jan 1 reads as "+4 days past" a Dec 28 peak rather
    /// than "-361 days before" it.
    private static func signedDaysFromPeak(_ d: Int, peak: Int) -> Int {
        var delta = d - peak
        if delta > 182 { delta -= 365 }
        if delta < -182 { delta += 365 }
        return delta
    }

    private static func monthDay(of date: Date, timeZone: TimeZone) -> MonthDay {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let components = calendar.dateComponents([.month, .day], from: date)
        return MonthDay(month: components.month!, day: components.day!)
    }

    // MARK: - Active-shower lookup

    struct ActiveShower {
        var shower: MeteorShower
        var isPeakNight: Bool
        /// Signed days from the shower's (fixed-calendar-day) peak; 0 = peak night, negative =
        /// before peak, positive = after.
        var daysFromPeak: Int
    }

    /// Every shower whose active range covers `date` (there can be more than one — e.g. the
    /// Taurids run for months and regularly overlap the Orionids or Leonids).
    static func activeShowers(on date: Date, timeZone: TimeZone = .current) -> [ActiveShower] {
        let md = monthDay(of: date, timeZone: timeZone)
        let d = ordinal(md)
        return all.compactMap { shower in
            let s = ordinal(shower.activeStart)
            let e = ordinal(shower.activeEnd)
            guard ordinalInRange(d, s, e) else { return nil }
            let peakOrdinal = ordinal(shower.peak)
            let delta = signedDaysFromPeak(d, peak: peakOrdinal)
            return ActiveShower(shower: shower, isPeakNight: delta == 0, daysFromPeak: delta)
        }
    }

    /// The single best "the shower for tonight" pick among whatever's active: peak night wins
    /// outright; otherwise closest to peak; ties broken by higher ZHR, then name (for
    /// determinism). `nil` if nothing is active at all.
    static func activeShower(on date: Date, timeZone: TimeZone = .current) -> ActiveShower? {
        activeShowers(on: date, timeZone: timeZone).min { a, b in
            if a.isPeakNight != b.isPeakNight { return a.isPeakNight && !b.isPeakNight }
            let da = abs(a.daysFromPeak), db = abs(b.daysFromPeak)
            if da != db { return da < db }
            if a.shower.zhr != b.shower.zhr { return a.shower.zhr > b.shower.zhr }
            return a.shower.name < b.shower.name
        }
    }

    // MARK: - Moon washout model

    enum MoonInterference {
        case none
        case some
        case severe
    }

    struct MeteorOutlook {
        var shower: MeteorShower
        var isPeakNight: Bool
        var daysFromPeak: Int
        var theoreticalZHR: Double
        /// The honest differentiator: `theoreticalZHR` scaled down by how much of tonight's
        /// prime viewing window has the Moon up and how bright it is. See the doc comment on
        /// `MeteorShowers` and `moonRetentionFactor(exposure:)` for the model and its basis.
        /// Does NOT additionally correct for radiant altitude, light pollution, or weather —
        /// documented gaps, not oversights.
        var estimatedVisiblePerHour: Double
        var moonInterference: MoonInterference
        /// The sub-window of tonight's post-midnight prime viewing band with the least Moon
        /// interference (ideally: Moon below the horizon). If the Moon is up for the entire
        /// prime window, this equals the whole window — there simply isn't a better slice of
        /// the night to offer.
        var bestWindow: DateInterval
        /// Transparency fields backing `estimatedVisiblePerHour`, exposed so callers/tests can
        /// see the inputs behind the number rather than treating it as a black box.
        var moonIlluminatedPercent: Double
        var moonUpFraction: Double
    }

    /// The fraction of tonight's prime window the Moon needs to be up, weighted by
    /// illumination, before we call it "some" vs "severe" interference. See
    /// `moonRetentionFactor` for how these same two inputs drive the numeric estimate.
    private static let someInterferenceThreshold = 0.15
    private static let severeInterferenceThreshold = 0.5

    /// Degrades ideal-sky ZHR to a rough "what a suburban observer might actually count"
    /// estimate, driven by `exposure` = illuminated fraction (0...1) x fraction of the prime
    /// window the Moon spends above the horizon (0...1).
    ///
    /// **Basis (documented per work order, deliberately a rough field model, not a photometric
    /// one):** ZHR already presumes a dark, moonless sky at the shower's own +6.5 limiting
    /// magnitude. Real-world writeups of specific shower/Moon combinations consistently land in
    /// two bands: a moonless (or Moon-down) night under typical suburban skies still loses a
    /// good chunk of the faintest meteors to ambient light pollution/haze even without the
    /// Moon's help, commonly quoted as **roughly 40-60% of ZHR actually counted**; a bright
    /// Moon up all night pushes that down to **roughly 15-25% of ZHR**, per field reports for
    /// e.g. Perseids 2025 (bright waning-gibbous Moon up most of the night; widely reported
    /// "10-20/hour" against a ZHR of 100, i.e. ~10-20%) versus Perseids 2026 (new Moon; NASA's
    /// "up to 100/hour" implies close to full ZHR credit). This function linearly interpolates
    /// between a `exposure = 0` point estimate of 0.50 (middle of the 40-60% moonless band) and
    /// an `exposure = 1` point estimate of 0.20 (middle of the 15-25% bright-Moon-all-night
    /// band) — a straight line is not a physically derived curve, just the simplest function
    /// that hits both documented endpoints; treat the output as order-of-magnitude guidance,
    /// not a precise forecast.
    static func moonRetentionFactor(exposure: Double) -> Double {
        let e = max(0, min(1, exposure))
        return 0.50 - 0.30 * e
    }

    /// Computes tonight's meteor outlook for the calendar night (in `timeZone`) containing
    /// `date`, at `latitude`/`longitude` (same east-positive-longitude convention as the rest of
    /// this engine). Returns `nil` if no shower is active tonight.
    ///
    /// "Tonight's prime window" is defined as local midnight through astronomical dawn the next
    /// morning — the part of the night radiants are typically climbing highest and skies are
    /// darkest, per the `viewingNotes` on most showers above ("best after midnight"). A few
    /// showers (Draconids, Southern Taurids) are actually better in the evening; this function
    /// still scores the post-midnight band uniformly for simplicity, which is a known
    /// conservative simplification for those specific showers (documented on their
    /// `viewingNotes`).
    static func outlook(on date: Date, latitude: Double, longitude: Double, timeZone: TimeZone) -> MeteorOutlook? {
        guard let active = activeShower(on: date, timeZone: timeZone) else { return nil }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let dayStart = calendar.startOfDay(for: date)
        let midnightTonight = dayStart.addingTimeInterval(86400)

        let sunTomorrow = SunMoon.sunTimes(after: midnightTonight, lat: latitude, lon: longitude)
        let primeStart = midnightTonight
        let primeEnd = sunTomorrow.astronomicalDawn ?? midnightTonight.addingTimeInterval(6 * 3600)

        let phase = SunMoon.moonPhase(date: primeStart)
        let illuminatedPercent = phase.illuminatedFraction * 100

        // Sample the prime window to find the fraction of it the Moon spends above the horizon,
        // and the longest contiguous "Moon down" sub-interval (the best slice to offer, if one
        // exists) — same fixed-step brute-force approach `SkyTonight.scanForBestViewing` uses,
        // for the same reason: cheap, and simpler to get right than solving threshold crossings
        // analytically for an already-bounded band.
        let step: TimeInterval = 15 * 60
        var t = primeStart
        var samples = 0
        var moonUpSamples = 0
        var bestDownStart: Date?
        var bestDownEnd: Date?
        var bestDownLength: TimeInterval = -1
        var runStart: Date?
        while t <= primeEnd {
            samples += 1
            let eq = SunMoon.moonEquatorial(date: t)
            let jd = AstroTime.julianDay(t)
            let alt = equatorialToHorizontal(eq, latitude: latitude, longitudeEast: longitude, jd: jd).altitude
            let moonUp = alt > 0
            if moonUp {
                moonUpSamples += 1
                if let s = runStart {
                    let length = t.timeIntervalSince(s)
                    if length > bestDownLength {
                        bestDownLength = length
                        bestDownStart = s
                        bestDownEnd = t
                    }
                    runStart = nil
                }
            } else if runStart == nil {
                runStart = t
            }
            t = t.addingTimeInterval(step)
        }
        // Close out a "Moon down" run that extends to the end of the window.
        if let s = runStart {
            let length = primeEnd.timeIntervalSince(s)
            if length > bestDownLength {
                bestDownLength = length
                bestDownStart = s
                bestDownEnd = primeEnd
            }
        }

        let moonUpFraction = samples > 0 ? Double(moonUpSamples) / Double(samples) : 0
        let exposure = (illuminatedPercent / 100.0) * moonUpFraction
        let retention = moonRetentionFactor(exposure: exposure)
        let estimatedVisiblePerHour = active.shower.zhr * retention

        let interference: MoonInterference
        if exposure < someInterferenceThreshold {
            interference = .none
        } else if exposure < severeInterferenceThreshold {
            interference = .some
        } else {
            interference = .severe
        }

        let bestWindow: DateInterval
        if let s = bestDownStart, let e = bestDownEnd, e > s {
            bestWindow = DateInterval(start: s, end: e)
        } else {
            bestWindow = DateInterval(start: primeStart, end: max(primeStart, primeEnd))
        }

        return MeteorOutlook(
            shower: active.shower,
            isPeakNight: active.isPeakNight,
            daysFromPeak: active.daysFromPeak,
            theoreticalZHR: active.shower.zhr,
            estimatedVisiblePerHour: estimatedVisiblePerHour,
            moonInterference: interference,
            bestWindow: bestWindow,
            moonIlluminatedPercent: illuminatedPercent,
            moonUpFraction: moonUpFraction
        )
    }
}
