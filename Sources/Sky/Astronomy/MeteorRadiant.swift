import Foundation

/// Additive extension to `MeteorShowers`: "which way do I look" for a shower's radiant, in plain
/// language — a compass direction plus a qualitative altitude ("low", "high overhead", ...)
/// rather than raw alt/az degrees. Built entirely from `AstroTime`'s existing coordinate
/// transforms and `compassPoint(forAzimuth:)`; no new astronomy, just a friendlier presentation
/// of `MeteorShower.radiantRA`/`radiantDec`, which the base file already documents as
/// "rough... good enough to say 'look toward Perseus', not for precision astrometry" — this
/// extension inherits that same precision ceiling.
extension MeteorShowers {

    /// A shower's radiant direction as seen from a specific place and moment, in the same plain
    /// language `directionPhrase(altitude:azimuth:)` uses elsewhere in this engine, but split
    /// into its two parts (`compass`, `altitudeQualitative`) rather than one combined phrase, per
    /// work order — a caller that wants the combined "low in the NE" string can still get it via
    /// `directionPhrase(altitude:azimuth:)` using this function's underlying altitude/azimuth
    /// (see `radiantHorizontal(shower:date:lat:lon:)` below for that raw form).
    ///
    /// `date` should be a specific instant during the viewing window the caller cares about (the
    /// work order's suggested convention: roughly 1am local on the shower's peak night, when
    /// radiant altitude is typically climbing toward its best) — this function does no time
    /// selection itself, it just transforms whatever instant it's given.
    static func radiantDirection(shower: MeteorShower, date: Date, lat: Double, lon: Double) -> (compass: String, altitudeQualitative: String) {
        let horizontal = radiantHorizontal(shower: shower, date: date, lat: lat, lon: lon)
        return (compassPoint(forAzimuth: horizontal.azimuth), altitudeQualitative(horizontal.altitude))
    }

    /// The radiant's raw alt/az at `date` as seen from `lat`/`lon` (degrees; `lon` positive
    /// east, matching every other engine in this package) — the underlying transform behind
    /// `radiantDirection`, exposed for callers/tests that want the numeric altitude rather than
    /// just its qualitative bucket.
    static func radiantHorizontal(shower: MeteorShower, date: Date, lat: Double, lon: Double) -> HorizontalCoordinates {
        let radiantEquatorial = EquatorialCoordinates(rightAscension: shower.radiantRA, declination: shower.radiantDec)
        let jd = AstroTime.julianDay(date)
        return equatorialToHorizontal(radiantEquatorial, latitude: lat, longitudeEast: lon, jd: jd)
    }

    /// Convenience for the work order's own suggested moment: `hourLocal` (default 1am) on the
    /// shower's textbook peak calendar date (`MeteorShower.peak`) in `year`, in `timeZone`. `nil`
    /// only if the calendar can't construct that date (should not happen for any real
    /// year/timeZone combination). Uses the shower's fixed-calendar-day peak, with the same
    /// "textbook date, not a per-year-exact prediction" caveat `MeteorShower.peak` already
    /// documents.
    static func radiantDirectionOnPeakNight(
        shower: MeteorShower,
        year: Int,
        hourLocal: Int = 1,
        lat: Double,
        lon: Double,
        timeZone: TimeZone
    ) -> (compass: String, altitudeQualitative: String)? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        var components = DateComponents()
        components.year = year
        components.month = shower.peak.month
        components.day = shower.peak.day
        components.hour = hourLocal
        guard let date = calendar.date(from: components) else { return nil }
        return radiantDirection(shower: shower, date: date, lat: lat, lon: lon)
    }

    /// Buckets an altitude (degrees) into the qualitative language this file's `compass` pairing
    /// uses. Deliberately a finer, radiant-specific wording than `directionPhrase`'s built-in
    /// buckets (which top out at a bare "high in the SE" with no "overhead" language) since a
    /// shower's radiant altitude is exactly the number a stargazer uses to judge "is this worth
    /// going outside for yet" -- "very low" / "low" reads as "wait a bit longer" in viewing notes
    /// like the ones on `MeteorShower.viewingNotes`.
    private static func altitudeQualitative(_ altitude: Double) -> String {
        switch altitude {
        case ..<0: return "below the horizon"
        case 0..<10: return "very low"
        case 10..<30: return "low"
        case 30..<60: return "well up"
        default: return "high overhead"
        }
    }
}
