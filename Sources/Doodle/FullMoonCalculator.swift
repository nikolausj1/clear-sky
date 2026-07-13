import Foundation

/// Computes full-moon dates offline via a known reference full moon + the synodic (new-moon-
/// to-new-moon) lunar cycle length — no network lookup, per PRD Section 8 ("All entries are
/// computable offline").
///
/// **Reference epoch:** 2000-01-06 18:14 UTC is a widely-cited reference **new** moon. Adding
/// half a synodic month lands on the following full moon, 2000-01-21 04:00:29 UTC — that's
/// the fixed reference point this calculator walks forward/backward from.
///
/// **Synodic month:** 29.530588853 days (the mean interval between successive full moons).
/// Because the real lunar cycle has small periodic variations (a few hours) around this mean,
/// treating every cycle as exactly this length drifts by roughly half a day per **decade**
/// from the true instant of fullness — acceptable for a "is tonight a full-moon night"
/// decorative overlay, not acceptable for an almanac. This is the documented approximation.
///
/// **Day-match rule:** rather than requiring the precise fullness instant to fall inside the
/// query day (which would occasionally miss a full moon that peaks a few minutes into the
/// next/previous local day), this finds the *nearest* predicted full-moon instant to the query
/// date and reports a match if that instant falls on the same calendar day (in the given
/// calendar's time zone). A full moon reads as "full" to the eye for roughly a day either side
/// of exact fullness, so this stays visually honest despite the epoch's minutes-level drift.
enum FullMoonCalculator {
    private static let synodicMonth: TimeInterval = 29.530588853 * 24 * 60 * 60

    /// 2000-01-21 04:00:29 UTC — reference new moon (2000-01-06 18:14 UTC) plus half a
    /// synodic month.
    private static let referenceFullMoon: Date = {
        var components = DateComponents()
        components.year = 2000
        components.month = 1
        components.day = 6
        components.hour = 18
        components.minute = 14
        var utcCalendar = Calendar(identifier: .gregorian)
        utcCalendar.timeZone = TimeZone(identifier: "UTC")!
        let referenceNewMoon = utcCalendar.date(from: components)!
        return referenceNewMoon.addingTimeInterval(synodicMonth / 2)
    }()

    static func isFullMoon(on date: Date, calendar: Calendar = Calendar(identifier: .gregorian)) -> Bool {
        let elapsedCycles = date.timeIntervalSince(referenceFullMoon) / synodicMonth
        let nearestCycle = elapsedCycles.rounded()
        let nearestFullMoonInstant = referenceFullMoon.addingTimeInterval(nearestCycle * synodicMonth)
        return calendar.isDate(nearestFullMoonInstant, inSameDayAs: date)
    }

    /// The exact predicted instant of the full moon nearest `date` — used by sim-verify tooling
    /// to compute a `-forceDate` value that lands on a real full-moon night without hand-
    /// searching a calendar.
    static func nearestFullMoonInstant(to date: Date) -> Date {
        let elapsedCycles = date.timeIntervalSince(referenceFullMoon) / synodicMonth
        let nearestCycle = elapsedCycles.rounded()
        return referenceFullMoon.addingTimeInterval(nearestCycle * synodicMonth)
    }

    /// Approximate illuminated fraction of the moon's disc on `date` — 0 at new moon, 1 at
    /// full moon — used by `CelestialBody` to draw a plausible waxing/waning crescent on
    /// ordinary nights, so a genuine full-moon night (via `SpecialDayTable`'s `fullMoon` rule)
    /// visibly stands out from an ordinary one instead of every night showing an identical
    /// full disc. `phaseFraction` is 0...1 through one synodic cycle starting at new moon
    /// (0 = new, 0.5 = full, 1 = new again); illumination follows the standard
    /// `(1 - cos(2*pi*phaseFraction)) / 2` cosine approximation. Not astronomically precise
    /// (real illumination isn't a perfect cosine curve), which is an acceptable approximation
    /// for a decorative placeholder moon, not an almanac.
    static func moonPhase(on date: Date) -> (illumination: Double, waxing: Bool) {
        let referenceNewMoon = referenceFullMoon.addingTimeInterval(-synodicMonth / 2)
        let elapsed = date.timeIntervalSince(referenceNewMoon)
        var phaseFraction = (elapsed / synodicMonth).truncatingRemainder(dividingBy: 1)
        if phaseFraction < 0 { phaseFraction += 1 }
        let illumination = (1 - cos(2 * Double.pi * phaseFraction)) / 2
        return (illumination, phaseFraction < 0.5)
    }
}
