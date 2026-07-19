import Foundation

/// Pure, on-device computation of "what's notable in the sky over the next N days" for the Space
/// tab's SKY CALENDAR card. Combines four already-verified engines (`Sources/Sky/Astronomy` +
/// `Sources/Doodle/SpecialDayTable.swift`) into one chronological event list — this file adds no
/// astronomy math of its own, it only calls/dates/filters/sorts what those engines already
/// compute, mirroring the "orchestrator that doesn't touch engine logic" split documented on
/// `Sources/Sky/SkyTonightService.swift`.
///
/// **Location dependence:** meteor-shower peak-night conditions and close pairings both need
/// lat/lon (Moon/planet altitude at a specific place), so `events(...)` simply omits both when
/// `latitude`/`longitude` are `nil` — full moons, new moons, and solstices/equinoxes are all
/// geocentric/calendar-only and still appear. See work-order note: "if none at all, hide the
/// calendar's location-dependent rows and keep moons/solstices."
///
/// No networking, no `Date()` default — every "today" is caller-supplied, so this is exactly as
/// deterministic/testable as the engines it calls.
enum SkyCalendar {

    struct Event: Identifiable, Equatable {
        var id: String { "\(Int(date.timeIntervalSince1970))|\(title)|\(note)" }
        let date: Date
        let title: String
        /// Short secondary line ("Full moon" / "Moon-Jupiter, 1.3°" / "" for solstices/equinoxes
        /// which need no elaboration beyond their title).
        let note: String
    }

    private static let solsticeEquinoxIds: Set<String> = [
        "springEquinox", "summerSolstice", "fallEquinox", "winterSolstice",
    ]

    /// Below this separation, a pairing counts as "close" for the Sky Calendar specifically — a
    /// tighter bar than `Conjunctions.closePairings`' own 3°/5° thresholds (work-order spec: "close
    /// pairings <2.5°"), since a 30-day calendar has room to be pickier than a single-night card.
    private static let calendarPairingThresholdDegrees = 2.5

    /// Every notable sky event in `[startDate, startDate + days)`, sorted chronologically.
    /// Callers should cap the result themselves (work order: "cap at ~12 rows, nearest first") --
    /// this returns the full set so a caller can decide how many to show.
    ///
    /// - Parameters:
    ///   - startDate: the first day of the window (normalized to that day's start in `timeZone`).
    ///   - days: window length in days (work order: 30).
    ///   - latitude/longitude: `nil` when there's no location to compute from at all (no active
    ///     Forecast location and no saved locations) -- location-dependent rows are simply
    ///     omitted in that case, per the work order.
    static func events(
        from startDate: Date,
        days: Int,
        latitude: Double?,
        longitude: Double?,
        timeZone: TimeZone
    ) -> [Event] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let start = calendar.startOfDay(for: startDate)
        guard let windowEnd = calendar.date(byAdding: .day, value: days, to: start) else { return [] }

        var events: [Event] = []

        if let latitude, let longitude {
            events.append(contentsOf: meteorPeakEvents(
                start: start, days: days, latitude: latitude, longitude: longitude,
                timeZone: timeZone, calendar: calendar
            ))
            events.append(contentsOf: pairingEvents(
                start: start, days: days, latitude: latitude, longitude: longitude,
                timeZone: timeZone, calendar: calendar
            ))
        }

        events.append(contentsOf: moonPhaseEvents(start: start, days: days, calendar: calendar))
        events.append(contentsOf: solsticeEquinoxEvents(start: start, windowEnd: windowEnd, calendar: calendar))
        events.append(contentsOf: eclipseEvents(
            start: start, windowEnd: windowEnd, calendar: calendar, latitude: latitude, longitude: longitude
        ))
        events.append(contentsOf: cometEvents(start: start, windowEnd: windowEnd))

        return events.sorted { $0.date < $1.date }
    }

    // MARK: - Eclipses

    /// Every eclipse (solar or lunar) whose peak instant falls on a calendar day inside the
    /// window, from the bundled `Eclipses.all` table -- calendar-only, like moon phases and
    /// solstices/equinoxes, so it still appears with no location known. When a location IS
    /// available the note upgrades from the table's generic `visibilitySummary` to a
    /// location-specific verdict via `Eclipses.isVisible`, same honesty split the ECLIPSE
    /// COUNTDOWN row (`SpaceView`) uses.
    private static func eclipseEvents(
        start: Date, windowEnd: Date, calendar: Calendar, latitude: Double?, longitude: Double?
    ) -> [Event] {
        Eclipses.all.compactMap { eclipse -> Event? in
            let day = calendar.startOfDay(for: eclipse.peakUTC)
            guard day >= start, day < windowEnd else { return nil }
            let note: String
            if let latitude, let longitude {
                note = Eclipses.isVisible(eclipse, latitude: latitude, longitude: longitude)
                    ? "Visible from your location"
                    : "Not visible from your location"
            } else {
                note = eclipse.visibilitySummary
            }
            return Event(date: day, title: eclipse.type.displayName, note: note)
        }
    }

    // MARK: - Comets

    /// Comet rows for a comet whose apparition intersects the 30-day window. `Comets.Comet` only
    /// exposes a structured `perihelionDate` -- `visibilityWindow` is deliberately free text (see
    /// that type's own doc comment on why comet-brightness/visibility forecasts resist a
    /// structured date range) -- so "intersects the 30 days" is evaluated against the one
    /// structured signal available: the comet's perihelion date falling inside the window. The
    /// event's note still surfaces the full free-text `visibilityWindow` description.
    private static func cometEvents(start: Date, windowEnd: Date) -> [Event] {
        Comets.upcoming(after: start).compactMap { comet -> Event? in
            guard let perihelion = comet.perihelionUTCDate, perihelion < windowEnd else { return nil }
            return Event(date: perihelion, title: comet.name, note: comet.visibilityWindow)
        }
    }

    // MARK: - Meteor-shower peak nights

    private static func meteorPeakEvents(
        start: Date, days: Int, latitude: Double, longitude: Double, timeZone: TimeZone, calendar: Calendar
    ) -> [Event] {
        var results: [Event] = []
        for offset in 0..<days {
            guard let day = calendar.date(byAdding: .day, value: offset, to: start) else { continue }
            let peaking = MeteorShowers.activeShowers(on: day, timeZone: timeZone).filter(\.isPeakNight)
            for active in peaking {
                let note = conditionsNote(
                    for: day, latitude: latitude, longitude: longitude, timeZone: timeZone,
                    expectedShowerName: active.shower.name
                )
                results.append(Event(date: day, title: "\(active.shower.name) peak", note: note))
            }
        }
        return results
    }

    /// "New moon, dark skies" / "62% moon, some moonlight" / "Full moon, washed out" — the
    /// shower's estimated viewing conditions on its peak night, from `MeteorShowers.outlook`'s
    /// Moon-washout model (see that file's doc comment). Falls back to a bare title-only note if
    /// `outlook` returns `nil` or, on an overlapping-showers night, isn't the specific shower this
    /// row is about (`outlook` only ever reports the single best-ranked active shower for the
    /// date -- see `MeteorShowers.activeShower`).
    private static func conditionsNote(
        for day: Date, latitude: Double, longitude: Double, timeZone: TimeZone, expectedShowerName: String
    ) -> String {
        guard let outlook = MeteorShowers.outlook(on: day, latitude: latitude, longitude: longitude, timeZone: timeZone),
              outlook.shower.name == expectedShowerName else {
            return ""
        }
        let moonDescriptor: String
        if outlook.moonIlluminatedPercent < 10 {
            moonDescriptor = "new moon"
        } else if outlook.moonIlluminatedPercent > 90 {
            moonDescriptor = "full moon"
        } else {
            moonDescriptor = "\(Int(outlook.moonIlluminatedPercent.rounded()))% moon"
        }
        let skyDescriptor: String
        switch outlook.moonInterference {
        case .none: skyDescriptor = "dark skies"
        case .some: skyDescriptor = "some moonlight"
        case .severe: skyDescriptor = "washed out"
        }
        return "\(moonDescriptor), \(skyDescriptor)"
    }

    // MARK: - Close pairings

    private static func pairingEvents(
        start: Date, days: Int, latitude: Double, longitude: Double, timeZone: TimeZone, calendar: Calendar
    ) -> [Event] {
        var results: [Event] = []
        for offset in 0..<days {
            guard let day = calendar.date(byAdding: .day, value: offset, to: start) else { continue }
            let pairings = Conjunctions.closePairings(on: day, latitude: latitude, longitude: longitude, timeZone: timeZone)
            for pairing in pairings where pairing.separationDegrees < calendarPairingThresholdDegrees {
                let separation = String(format: "%.1f", pairing.separationDegrees)
                results.append(Event(
                    date: day,
                    title: "\(pairing.bodyA.displayName)-\(pairing.bodyB.displayName)",
                    note: "\(separation)\u{00B0} apart"
                ))
            }
        }
        return results
    }

    // MARK: - Full moons / new moons

    /// Scans `SunMoon.moonPhase`'s illuminated fraction once per day (sampled at local noon) and
    /// reports the day of each local maximum (full moon) and local minimum (new moon) -- the
    /// illuminated-fraction curve has exactly one of each per ~29.53-day synodic cycle, so a daily
    /// sample plus a 1-day pad on each side of the window is enough resolution to place the event
    /// on the correct calendar day without needing the precise sub-day instant of exact fullness/
    /// newness (a decorative-calendar-appropriate approximation, same spirit as
    /// `FullMoonCalculator`'s own documented day-match rule, but driven by this engine's more
    /// accurate true-phase-angle `SunMoon.moonPhase` rather than the mean-synodic-cycle model).
    private static func moonPhaseEvents(start: Date, days: Int, calendar: Calendar) -> [Event] {
        guard let paddedStart = calendar.date(byAdding: .day, value: -1, to: start) else { return [] }
        let totalSamples = days + 2

        var samples: [(day: Date, illuminatedFraction: Double)] = []
        for offset in 0..<totalSamples {
            guard let day = calendar.date(byAdding: .day, value: offset, to: paddedStart),
                  let noon = calendar.date(byAdding: .hour, value: 12, to: day) else { continue }
            samples.append((day, SunMoon.moonPhase(date: noon).illuminatedFraction))
        }
        guard samples.count >= 3 else { return [] }

        guard let windowEnd = calendar.date(byAdding: .day, value: days, to: start) else { return [] }

        var results: [Event] = []
        for i in 1..<(samples.count - 1) {
            let (day, illum) = samples[i]
            guard day >= start, day < windowEnd else { continue }
            let prev = samples[i - 1].illuminatedFraction
            let next = samples[i + 1].illuminatedFraction
            if illum >= prev, illum >= next {
                results.append(Event(date: day, title: "Full moon", note: ""))
            } else if illum <= prev, illum <= next {
                results.append(Event(date: day, title: "New moon", note: ""))
            }
        }
        return results
    }

    // MARK: - Solstice / equinox

    /// Consults `SpecialDayTable` (the same offline table the doodle grammar uses) but filters to
    /// just its four solstice/equinox entries -- this card isn't showing holidays, just
    /// astronomical dates. **Documented edge case:** `SpecialDayTable.specialDay(for:)` gives a
    /// fixed-date holiday precedence over a same-day astronomical entry (its own documented
    /// rule); on the rare calendar day a holiday exactly coincides with a solstice/equinox, this
    /// function would miss that day's astronomical entry. Accepted rather than reimplementing
    /// `SpecialDayTable`'s own date matching here.
    private static func solsticeEquinoxEvents(start: Date, windowEnd: Date, calendar: Calendar) -> [Event] {
        var results: [Event] = []
        var day = start
        while day < windowEnd {
            if let special = SpecialDayTable.specialDay(for: day, calendar: calendar),
               solsticeEquinoxIds.contains(special.id) {
                results.append(Event(date: day, title: special.label, note: ""))
            }
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return results
    }
}
