import Foundation

/// Top-level "Tonight's Sky" API: given a date/location, answers what's visible from civil
/// dusk tonight through civil dawn tomorrow morning. This is the file app code should call;
/// `AstroTime`/`SunMoon`/`Planets` are the machinery underneath it.
enum SkyTonight {

    // MARK: - Public result types

    struct SunInfo {
        var sunrise: Date?
        var sunset: Date?
        var civilDawn: Date?
        var civilDusk: Date?
        var astronomicalDawn: Date?
        var astronomicalDusk: Date?
    }

    struct MoonInfo {
        var rise: Date?
        var set: Date?
        /// 0 = new, 0.25 = first quarter, 0.5 = full, 0.75 = last quarter.
        var phaseFraction: Double
        var illuminatedPercent: Double
        var waxing: Bool
    }

    struct PlanetVisibility {
        var body: Planets.Body
        var isVisibleTonight: Bool
        var rise: Date?
        var set: Date?
        /// The window during which the planet is both above ~10° altitude and the sky is
        /// dark enough to see it (see `SkyTonight`'s twilight rule below). `nil` if the
        /// planet doesn't clear both bars at any point tonight.
        var bestViewingStart: Date?
        var bestViewingEnd: Date?
        /// Altitude/azimuth at the single best moment within the viewing window (the moment
        /// of peak altitude), and a ready-to-display phrase like "low in the WSW".
        var bestAltitude: Double?
        var bestAzimuth: Double?
        var directionDescription: String?
        var apparentMagnitude: Double?
    }

    struct TonightSky {
        var sun: SunInfo
        var moon: MoonInfo
        var planets: [PlanetVisibility]
    }

    // MARK: - Entry point

    /// Computes tonight's sky for the calendar day (in `timeZone`) containing `date`, at
    /// `latitude`/`longitude` (degrees; longitude **east**-positive — flip the sign for a
    /// caller that has west-positive longitude, e.g. most US longitudes are negative here).
    ///
    /// "Tonight" runs from that day's civil dusk through the following morning's civil dawn.
    /// If the location is far enough poleward that civil dusk/dawn don't occur (polar
    /// day/night), the planet visibility window falls back to the full 24 hours starting at
    /// local midnight, since there may be no conventional "dusk to dawn" to speak of.
    static func compute(date: Date, latitude: Double, longitude: Double, timeZone: TimeZone) -> TonightSky {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let dayStart = calendar.startOfDay(for: date)

        let todaySun = SunMoon.sunTimes(after: dayStart, lat: latitude, lon: longitude)

        // Anchor "the rest of the night" searches on tonight's civil dusk when it exists;
        // otherwise fall back to the calendar-day start so the engine still returns something
        // sensible near the poles instead of nil-ing out everything.
        let nightAnchor = todaySun.civilDusk ?? dayStart

        let astronomicalDuskTonight = todaySun.astronomicalDusk
            ?? RiseSetFinder.nextEvent(.set, after: dayStart, latitude: latitude, longitudeEast: longitude, standardAltitude: SunMoon.StandardAltitude.astronomicalTwilight) { SunMoon.sunEquatorial(date: $0) }
        let astronomicalDawnTomorrow = RiseSetFinder.nextEvent(.rise, after: nightAnchor, latitude: latitude, longitudeEast: longitude, standardAltitude: SunMoon.StandardAltitude.astronomicalTwilight) { SunMoon.sunEquatorial(date: $0) }
        let civilDawnTomorrow = RiseSetFinder.nextEvent(.rise, after: nightAnchor, latitude: latitude, longitudeEast: longitude, standardAltitude: SunMoon.StandardAltitude.civilTwilight) { SunMoon.sunEquatorial(date: $0) }
        let nauticalDuskTonight = RiseSetFinder.nextEvent(.set, after: dayStart, latitude: latitude, longitudeEast: longitude, standardAltitude: SunMoon.StandardAltitude.nauticalTwilight) { SunMoon.sunEquatorial(date: $0) }
        let nauticalDawnTomorrow = RiseSetFinder.nextEvent(.rise, after: nightAnchor, latitude: latitude, longitudeEast: longitude, standardAltitude: SunMoon.StandardAltitude.nauticalTwilight) { SunMoon.sunEquatorial(date: $0) }

        let sunInfo = SunInfo(
            sunrise: todaySun.sunrise,
            sunset: todaySun.sunset,
            civilDawn: todaySun.civilDawn,
            civilDusk: todaySun.civilDusk,
            astronomicalDawn: todaySun.astronomicalDawn,
            astronomicalDusk: astronomicalDuskTonight
        )

        let moonTimes = SunMoon.moonTimes(after: dayStart, lat: latitude, lon: longitude)
        let phase = SunMoon.moonPhase(date: date)
        let moonInfo = MoonInfo(
            rise: moonTimes.rise,
            set: moonTimes.set,
            phaseFraction: phase.phaseFraction,
            illuminatedPercent: phase.illuminatedFraction * 100,
            waxing: phase.waxing
        )

        // The window we scan for planet visibility: civil dusk tonight through civil dawn
        // tomorrow (falling back to a plain 24h window if twilight didn't resolve).
        let windowStart = todaySun.civilDusk ?? dayStart
        let windowEnd = civilDawnTomorrow ?? dayStart.addingTimeInterval(86400)

        let planetVisibilities = Planets.Body.allCases.map { body in
            planetVisibility(
                body,
                windowStart: windowStart,
                windowEnd: windowEnd,
                sunsetTonight: todaySun.sunset,
                sunriseTomorrow: RiseSetFinder.nextEvent(.rise, after: nightAnchor, latitude: latitude, longitudeEast: longitude, standardAltitude: SunMoon.StandardAltitude.sunriseSunset) { SunMoon.sunEquatorial(date: $0) },
                nauticalDuskTonight: nauticalDuskTonight,
                nauticalDawnTomorrow: nauticalDawnTomorrow,
                astronomicalDuskTonight: astronomicalDuskTonight,
                astronomicalDawnTomorrow: astronomicalDawnTomorrow,
                latitude: latitude,
                longitude: longitude
            )
        }

        return TonightSky(sun: sunInfo, moon: moonInfo, planets: planetVisibilities)
    }

    // MARK: - Planet visibility

    /// The altitude, in degrees, a planet needs to clear to count as "up" for viewing
    /// purposes — low enough to catch it just above rooftops/trees, high enough to be above
    /// the worst of horizon murk and extinction.
    private static let minimumViewingAltitude = 10.0

    private static func planetVisibility(
        _ body: Planets.Body,
        windowStart: Date,
        windowEnd: Date,
        sunsetTonight: Date?,
        sunriseTomorrow: Date?,
        nauticalDuskTonight: Date?,
        nauticalDawnTomorrow: Date?,
        astronomicalDuskTonight: Date?,
        astronomicalDawnTomorrow: Date?,
        latitude: Double,
        longitude: Double
    ) -> PlanetVisibility {
        func position(at t: Date) -> EquatorialCoordinates {
            Planets.geocentric(body, date: t).equatorial
        }
        let rise = RiseSetFinder.nextEvent(.rise, after: windowStart.addingTimeInterval(-16 * 3600), latitude: latitude, longitudeEast: longitude, standardAltitude: SunMoon.StandardAltitude.starsAndPlanets, position: position)
        let set = RiseSetFinder.nextEvent(.set, after: windowStart.addingTimeInterval(-16 * 3600), latitude: latitude, longitudeEast: longitude, standardAltitude: SunMoon.StandardAltitude.starsAndPlanets, position: position)

        // The twilight rule (per work order): Mercury/Venus are twilight objects, so their
        // "dark enough" band is bounded by the Sun's own altitude between sunset/sunrise and
        // nautical dusk/dawn — wait any longer for full darkness and, being always close to
        // the Sun, they've typically already set (evening) or not yet risen (morning). The
        // outer three need real darkness (past nautical twilight) since they're faint enough,
        // and far enough from the Sun, that twilight glow washes them out.
        let darkBandStart: Date?
        let darkBandEnd: Date?
        if body.isInferior {
            darkBandStart = sunsetTonight
            darkBandEnd = nauticalDuskTonight
        } else {
            darkBandStart = nauticalDuskTonight
            darkBandEnd = nauticalDawnTomorrow
        }

        // Inferior planets can also be morning objects (visible before sunrise instead of
        // after sunset, depending on which side of inferior conjunction they're on); scan
        // both bands and keep whichever produces a qualifying (or higher) result.
        let morningBandStart: Date? = body.isInferior ? nauticalDawnTomorrow : nauticalDuskTonight
        let morningBandEnd: Date? = body.isInferior ? sunriseTomorrow : nauticalDawnTomorrow

        let eveningResult = scanForBestViewing(body, bandStart: darkBandStart, bandEnd: darkBandEnd, latitude: latitude, longitude: longitude)
        let morningResult = body.isInferior
            ? scanForBestViewing(body, bandStart: morningBandStart, bandEnd: morningBandEnd, latitude: latitude, longitude: longitude)
            : nil

        let best: ScanResult?
        switch (eveningResult, morningResult) {
        case (nil, nil): best = nil
        case (let e, nil): best = e
        case (nil, let m): best = m
        case (let e?, let m?): best = e.bestAltitude >= m.bestAltitude ? e : m
        }

        guard let best, best.bestAltitude >= minimumViewingAltitude else {
            return PlanetVisibility(
                body: body, isVisibleTonight: false, rise: rise, set: set,
                bestViewingStart: nil, bestViewingEnd: nil,
                bestAltitude: nil, bestAzimuth: nil, directionDescription: nil, apparentMagnitude: nil
            )
        }

        let (equatorial, r, delta) = Planets.geocentric(body, date: best.bestTime)
        let jd = AstroTime.julianDay(best.bestTime)
        let T = AstroTime.julianCenturies(jd: jd)
        let (_, sunEarthDistance) = SunMoon.sunGeometric(T: T)
        let phaseAngle = Planets.phaseAngle(r: r, delta: delta, sunEarthDistance: sunEarthDistance)
        let ringTilt = body == .saturn ? Planets.saturnRingTilt(date: best.bestTime) : nil
        let magnitude = Planets.apparentMagnitude(body, r: r, delta: delta, phaseAngleDegrees: phaseAngle, saturnRingTiltDegrees: ringTilt)
        let horizontalAtBest = equatorialToHorizontal(equatorial, latitude: latitude, longitudeEast: longitude, jd: jd)

        return PlanetVisibility(
            body: body,
            isVisibleTonight: true,
            rise: rise,
            set: set,
            bestViewingStart: best.windowStart,
            bestViewingEnd: best.windowEnd,
            bestAltitude: horizontalAtBest.altitude,
            bestAzimuth: horizontalAtBest.azimuth,
            directionDescription: directionPhrase(altitude: horizontalAtBest.altitude, azimuth: horizontalAtBest.azimuth),
            apparentMagnitude: magnitude
        )
    }

    private struct ScanResult {
        var bestTime: Date
        var bestAltitude: Double
        var windowStart: Date
        var windowEnd: Date
    }

    /// Steps through `[bandStart, bandEnd]` in 5-minute increments, finding the contiguous
    /// sub-interval where the planet's altitude is at least `minimumViewingAltitude` and
    /// reports the moment of peak altitude within it. A fixed-step scan (rather than an
    /// analytic altitude-threshold solve, as used for rise/set) because we additionally need
    /// "peak altitude within a bounded twilight band", which the two-boundary case handles
    /// more simply by brute force than by solving three simultaneous threshold crossings —
    /// cheap for a phone CPU at this step count (a few hundred samples per planet per night).
    private static func scanForBestViewing(_ body: Planets.Body, bandStart: Date?, bandEnd: Date?, latitude: Double, longitude: Double) -> ScanResult? {
        guard let bandStart, let bandEnd, bandEnd > bandStart else { return nil }
        let step: TimeInterval = 5 * 60
        var t = bandStart
        var bestAltitude = -90.0
        var bestTime = bandStart
        var qualifyingStart: Date?
        var qualifyingEnd: Date?
        var sawQualifying = false

        while t <= bandEnd {
            let (equatorial, _, _) = Planets.geocentric(body, date: t)
            let jd = AstroTime.julianDay(t)
            let horizontalCoordinates = equatorialToHorizontal(equatorial, latitude: latitude, longitudeEast: longitude, jd: jd)
            if horizontalCoordinates.altitude >= minimumViewingAltitude {
                if !sawQualifying { qualifyingStart = t }
                qualifyingEnd = t
                sawQualifying = true
            }
            if horizontalCoordinates.altitude > bestAltitude {
                bestAltitude = horizontalCoordinates.altitude
                bestTime = t
            }
            t = t.addingTimeInterval(step)
        }

        guard sawQualifying, let qualifyingStart, let qualifyingEnd else {
            return ScanResult(bestTime: bestTime, bestAltitude: bestAltitude, windowStart: bandStart, windowEnd: bandEnd)
        }
        return ScanResult(bestTime: bestTime, bestAltitude: bestAltitude, windowStart: qualifyingStart, windowEnd: qualifyingEnd)
    }
}
