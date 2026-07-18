import Foundation

/// The hero-caption generator for "Tonight's Sky" — replaces the dry-wit `doodleCaption` phrase
/// bank for this surface with a single, deterministic "Observatory Guide" register: clear,
/// warm, factual, **no jokes, no exclamations**. One line (`text`) short enough for the hero
/// caption, plus a fuller `detailText` (1-3 sentences) for whatever expands when the user taps
/// it, and a `kind` the UI can switch on to style the card / route the tap.
///
/// ## Tier order (documented; first match wins)
///
/// 1. **Strong event** — a visible ISS pass, an aurora outlook of `.fair` or better, a
///    peak-night meteor shower, or a close conjunction — sourced straight from `BestMoment`'s
///    own `SkyMoment` (its tiers 1-4; see `BestMoment.bestMoment`'s doc comment). These are
///    reported regardless of tonight's cloud forecast: `BestMoment` doesn't know about weather,
///    and a genuine ISS pass or shower peak is still worth telling the user about (a cloud
///    break is possible), whereas the *fallback* fact tier below is purely "go look up
///    something pleasant," which is moot under solid cloud cover -- hence overcast (tier 2)
///    outranks the fact tier (3) but not this one.
/// 2. **Overcast tonight** -- every hour of tonight's dark window has a cloud-cover fraction
///    >= `overcastCloudThreshold` (0.8). Mentions a clearing time only if the caller's cloud
///    data actually shows one after tonight's window; otherwise a simpler line.
/// 3. **Best-available fact** -- tried in this fixed order (documented, not randomized -- the
///    data itself varies night to night, so no seeded variety is needed): brightest visible
///    planet's rise, a notably full/new Moon, a high (>= `goodStargazingThreshold`) peak
///    stargazing score, or a shower that's building toward its peak in the next few nights.
///
/// `BestMoment`'s own tiers 5-6 (brightest planet, full/new moonrise) deliberately are **not**
/// treated as "strong events" here -- they fall through to tier 3 above, where they're
/// re-considered alongside the stargazing score and "shower building" facts `BestMoment` never
/// sees, so the single most interesting fact wins rather than whatever `BestMoment` happened to
/// pick under its own, narrower ranking.
enum TonightHeadline {

    // MARK: - Output

    /// Coarse category so the UI can style the card / route a tap without re-deriving which
    /// tier produced the line. `isEvent` marks the four "strong event" kinds, for which
    /// `detailText` is always non-nil (see `generate`).
    enum Kind: Equatable {
        case issPass
        case aurora
        case meteorShower
        case conjunction
        case overcast
        case brightPlanet
        case notableMoon
        case goodStargazing
        case showerBuilding
        /// Nothing cleared any tier tonight -- a calm, generic line with no specific fact.
        case none

        var isEvent: Bool {
            switch self {
            case .issPass, .aurora, .meteorShower, .conjunction: return true
            default: return false
            }
        }
    }

    struct Headline {
        /// The hero caption itself -- kept to roughly `textCharacterBudget` characters.
        var text: String
        /// The fuller explanation shown on tap/expand. Always present (non-nil, non-empty) for
        /// `kind.isEvent`; may be nil for the quieter fact/overcast/none tiers where the short
        /// `text` is already the whole story.
        var detailText: String?
        var kind: Kind
    }

    /// Soft target for `Headline.text` length (see PhraseBank-style copy elsewhere in the app).
    static let textCharacterBudget = 90

    // MARK: - Input

    /// One hour's cloud-cover reading, for the overcast tier's "all night" check. Same 0...1
    /// convention as `StargazingScore.cloudCoverFraction` (this file doesn't recompute it --
    /// the caller, which already has tonight's `HourlyEntry`s and `StargazingScore`, supplies
    /// the fraction directly, keeping this file equally dependency-light).
    struct HourCloudCover {
        var date: Date
        var cloudCoverFraction: Double

        init(date: Date, cloudCoverFraction: Double) {
            self.date = date
            self.cloudCoverFraction = cloudCoverFraction
        }
    }

    /// Everything the headline needs, gathered by the caller from `BestMoment`, the individual
    /// Sky engines, and `StargazingScore`. Plain Doubles/Dates/engine types only -- no weather
    /// model import (matches `StargazingScore`'s dependency shape).
    struct Inputs {
        /// Tonight's headline fact per `BestMoment`, if any cleared its own tiers. Its `.kind`
        /// payload already carries the underlying `ISSPass`/`AuroraOutlook`/`MeteorOutlook`/
        /// `Pairing` -- this file doesn't re-fetch or re-rank those; it only reformats
        /// `BestMoment`'s tiers 1-4 as event headlines, or otherwise ignores `moment` (see the
        /// type-level doc comment on why tiers 5-6 fall through instead of being used here).
        var moment: BestMoment.SkyMoment?
        /// Tonight's meteor outlook, independent of whether it made `moment` -- needed for the
        /// tier-3 "shower building toward peak" fact, which by definition covers showers that
        /// have *not* yet cleared `BestMoment`'s peak-night/rate bar.
        var meteorOutlook: MeteorShowers.MeteorOutlook?
        /// Tonight's planets, for the tier-3 "brightest visible planet" fact.
        var planets: [SkyTonight.PlanetVisibility]
        /// Tonight's Moon, for the tier-3 "notable Moon" fact.
        var moon: SkyTonight.MoonInfo
        /// Tonight's peak stargazing score (0...10, from `StargazingScore`) and the hour it
        /// occurs at, if any hours were scored.
        var peakStargazingScore: Int?
        var peakStargazingHour: Date?
        /// Tonight's dark-sky window (e.g. civil dusk through tomorrow's civil dawn), used to
        /// scope the tier-2 "all night" overcast check.
        var tonightWindow: DateInterval
        /// Hourly cloud-cover readings. Expected to cover at least `tonightWindow`; readings
        /// past `tonightWindow.end` (e.g. into tomorrow morning) are used, if present, to offer
        /// a "clearing by ..." time on the overcast line -- if the caller only supplies
        /// tonight's own hours, the overcast line simply omits that clause (documented gap, not
        /// a bug: this file never fabricates a clearing time it wasn't given data for).
        var hourlyCloudCover: [HourCloudCover]
        /// The IANA time zone to render times in (e.g. "9:42", "midnight").
        var timeZone: TimeZone

        init(
            moment: BestMoment.SkyMoment? = nil,
            meteorOutlook: MeteorShowers.MeteorOutlook? = nil,
            planets: [SkyTonight.PlanetVisibility] = [],
            moon: SkyTonight.MoonInfo,
            peakStargazingScore: Int? = nil,
            peakStargazingHour: Date? = nil,
            tonightWindow: DateInterval,
            hourlyCloudCover: [HourCloudCover] = [],
            timeZone: TimeZone
        ) {
            self.moment = moment
            self.meteorOutlook = meteorOutlook
            self.planets = planets
            self.moon = moon
            self.peakStargazingScore = peakStargazingScore
            self.peakStargazingHour = peakStargazingHour
            self.tonightWindow = tonightWindow
            self.hourlyCloudCover = hourlyCloudCover
            self.timeZone = timeZone
        }
    }

    // MARK: - Tunables (documented per work order)

    /// Tier 2: every hour of tonight's window needs a cloud-cover fraction at or above this to
    /// call it "overcast, no sky viewing."
    static let overcastCloudThreshold = 0.8
    /// A post-tonight hour below this cloud-cover fraction counts as "clearing" for the
    /// optional "Clearing ... if the forecast holds" clause.
    static let clearingCloudThreshold = 0.5
    /// Tier 3: minimum peak stargazing score (0...10) to headline "good stargazing" -- the top
    /// of `StargazingScore.QualityLabel.good` and all of `.excellent`.
    static let goodStargazingThreshold = 7
    /// Tier 3: a shower counts as "building" only within this many days of its peak (and only
    /// strictly *before* the peak -- `daysFromPeak < 0`); farther out than this it's not yet
    /// headline-worthy background trivia.
    static let showerBuildingWindowDays = 5

    // MARK: - Entry point

    static func generate(_ inputs: Inputs) -> Headline {
        if let moment = inputs.moment, let event = eventHeadline(for: moment, timeZone: inputs.timeZone) {
            return event
        }
        if let overcast = overcastHeadline(inputs) {
            return overcast
        }
        if let fact = bestFactHeadline(inputs) {
            return fact
        }
        return Headline(
            text: "No standout sky event tonight — check back after dusk.",
            detailText: nil,
            kind: .none
        )
    }

    // MARK: - Detail text for an already-picked `BestMoment.SkyMoment`

    /// Renders `kind`'s own detail sentence directly — the same wording `generate`'s tier-1 event
    /// headlines (and, for the two tiers `generate` itself never treats as "events" — brightest
    /// planet, notable moonrise — the equivalent tier-3 fact wording) use. For callers (the night
    /// panel's headline row) that already hold a `BestMoment.SkyMoment` and want its matching
    /// detail text specifically, rather than risking `generate`'s own independent tier-3
    /// re-ranking picking a *different* fact than the one the headline row is already titled
    /// with (see that tier's doc comment: "the single most interesting fact wins," which is not
    /// guaranteed to be the same fact `BestMoment` picked for a `.brightPlanet`/`.moonRise`
    /// moment). Always non-nil.
    static func detailText(for kind: BestMoment.Kind, timeZone: TimeZone) -> String {
        switch kind {
        case .issPass(let pass):
            return issHeadline(pass, timeZone: timeZone).detailText ?? ""
        case .auroraWindow(let outlook):
            return auroraHeadline(outlook, timeZone: timeZone).detailText ?? ""
        case .meteorShower(let outlook):
            return meteorHeadline(outlook, timeZone: timeZone).detailText ?? ""
        case .conjunction(let pairing):
            return conjunctionHeadline(pairing, timeZone: timeZone).detailText ?? ""
        case .brightPlanet(let planet):
            let direction = planet.bestAzimuth.map { compassWord(compassPoint(forAzimuth: $0)) } ?? "up tonight"
            let when = (planet.bestViewingStart ?? planet.rise).map { shortTime($0, timeZone: timeZone) }
            let whenClause = when.map { " around \($0)" } ?? ""
            return "\(planet.body.displayName) is the brightest planet visible tonight, best seen \(direction), "
                + "\(planet.directionDescription ?? "well up in the sky")\(whenClause)."
        case .moonRise(let moonKind, let illuminatedPercent, let riseTime):
            let riseClause = " rising around \(shortTime(riseTime, timeZone: timeZone))"
            switch moonKind {
            case .fullMoon:
                return "The Moon is essentially full tonight (about \(Int(illuminatedPercent.rounded()))% illuminated)\(riseClause), washing out all but the brightest stars."
            case .newMoon:
                return "The Moon is essentially new tonight (about \(Int(illuminatedPercent.rounded()))% illuminated)\(riseClause), leaving skies at their darkest all month."
            }
        }
    }

    // MARK: - Tier 1: strong event

    private static func eventHeadline(for moment: BestMoment.SkyMoment, timeZone: TimeZone) -> Headline? {
        switch moment.kind {
        case .issPass(let pass):
            return issHeadline(pass, timeZone: timeZone)
        case .auroraWindow(let outlook):
            return auroraHeadline(outlook, timeZone: timeZone)
        case .meteorShower(let outlook):
            return meteorHeadline(outlook, timeZone: timeZone)
        case .conjunction(let pairing):
            return conjunctionHeadline(pairing, timeZone: timeZone)
        case .brightPlanet, .moonRise:
            // Deliberately not an "event" here -- see the type-level doc comment. Falls through
            // to tiers 2/3.
            return nil
        }
    }

    private static func issHeadline(_ pass: ISSPass, timeZone: TimeZone) -> Headline {
        let startWord = compassWord(pass.startAzimuthCompass)
        let endWord = compassWord(pass.endAzimuthCompass)
        let text = "ISS crosses at \(shortTime(pass.peakTime, timeZone: timeZone)) tonight — look \(startWord)."
        let detail = "Rising low in the \(startWord) at \(shortTime(pass.startTime, timeZone: timeZone)), "
            + "\(arcDescription(peakAltitudeDegrees: pass.peakAltitudeDeg)), fading \(endWord) at "
            + "\(shortTime(pass.endTime, timeZone: timeZone)). It looks like a bright, steady star moving fast."
        return Headline(text: text, detailText: detail, kind: .issPass)
    }

    private static func arcDescription(peakAltitudeDegrees: Double) -> String {
        switch peakAltitudeDegrees {
        case ..<30: return "climbing partway up the sky"
        case 30..<70: return "climbing halfway up the sky"
        default: return "passing nearly overhead"
        }
    }

    private static func auroraHeadline(_ outlook: AuroraOutlook, timeZone: TimeZone) -> Headline {
        let verb: String
        switch outlook.band {
        case .strong: verb = "Strong aurora activity expected"
        case .good: verb = "Aurora likely"
        default: verb = "Aurora possible" // .fair is the only other band that reaches this tier
        }
        let start = shortTime(outlook.bestViewingWindow.start, timeZone: timeZone)
        let text = "\(verb) tonight — look north after \(start)."
        let detail = "NOAA's forecast puts tonight's peak Kp index at \(String(format: "%.0f", outlook.tonightPeakKp)), "
            + "a \(outlook.band.description) outlook for aurora at your latitude. Best viewing is looking north, "
            + "away from bright lights, from about \(start) to \(shortTime(outlook.bestViewingWindow.end, timeZone: timeZone))."
        return Headline(text: text, detailText: detail, kind: .aurora)
    }

    private static func meteorHeadline(_ outlook: MeteorShowers.MeteorOutlook, timeZone: TimeZone) -> Headline {
        let rate = Int(outlook.estimatedVisiblePerHour.rounded())
        let start = shortTime(outlook.bestWindow.start, timeZone: timeZone)
        let text = "\(outlook.shower.name) peak tonight — up to \(rate)/hour after \(start)."
        let detail = "Tonight is peak night for the \(outlook.shower.name), radiating from \(outlook.shower.radiantConstellation). "
            + "Given tonight's sky, expect roughly \(rate) meteors per hour in the best window, "
            + "\(start) to \(shortTime(outlook.bestWindow.end, timeZone: timeZone))."
        return Headline(text: text, detailText: detail, kind: .meteorShower)
    }

    private static func conjunctionHeadline(_ pairing: Conjunctions.Pairing, timeZone: TimeZone) -> Headline {
        let a = pairing.bodyA.displayName
        let b = pairing.bodyB.displayName
        let text = "\(a) meets \(b) tonight — \(pairing.directionDescription)."
        let separation = String(format: "%.1f", pairing.separationDegrees)
        let detail = "\(a) and \(b) appear just \(separation)° apart tonight, best seen \(pairing.directionDescription) "
            + "around \(shortTime(pairing.bestViewingTime, timeZone: timeZone))."
        return Headline(text: text, detailText: detail, kind: .conjunction)
    }

    // MARK: - Tier 2: overcast

    private static func overcastHeadline(_ inputs: Inputs) -> Headline? {
        let nightHours = inputs.hourlyCloudCover.filter { inputs.tonightWindow.contains($0.date) }
        guard !nightHours.isEmpty, nightHours.allSatisfy({ $0.cloudCoverFraction >= overcastCloudThreshold }) else {
            return nil
        }

        let clearing = inputs.hourlyCloudCover
            .filter { $0.date > inputs.tonightWindow.end && $0.cloudCoverFraction < clearingCloudThreshold }
            .min { $0.date < $1.date }

        if let clearing {
            let when = shortTime(clearing.date, timeZone: inputs.timeZone)
            let text = "Overcast tonight — no sky viewing. Clearing \(when) if the forecast holds."
            let detail = "Cloud cover is expected to stay solid through the night, with a break forecast around \(when)."
            return Headline(text: text, detailText: detail, kind: .overcast)
        }

        let text = "Overcast tonight — no sky viewing."
        let detail = "Cloud cover is expected to stay solid through the night, so there won't be a clear window for stargazing."
        return Headline(text: text, detailText: detail, kind: .overcast)
    }

    // MARK: - Tier 3: best-available fact

    private static func bestFactHeadline(_ inputs: Inputs) -> Headline? {
        if let planet = brightPlanetHeadline(inputs.planets, timeZone: inputs.timeZone) {
            return planet
        }
        if let moon = notableMoonHeadline(inputs.moon, timeZone: inputs.timeZone) {
            return moon
        }
        if let score = goodStargazingHeadline(inputs) {
            return score
        }
        if let building = showerBuildingHeadline(inputs.meteorOutlook) {
            return building
        }
        return nil
    }

    /// Brightest (lowest apparent magnitude) visible planet with a known rise time; ties broken
    /// by raw case name for determinism (same tie-break as `BestMoment`'s own planet picker).
    private static func brightestVisiblePlanet(_ planets: [SkyTonight.PlanetVisibility]) -> SkyTonight.PlanetVisibility? {
        planets
            .filter { $0.isVisibleTonight && $0.apparentMagnitude != nil }
            .min { a, b in
                let ma = a.apparentMagnitude!, mb = b.apparentMagnitude!
                if ma != mb { return ma < mb }
                return a.body.rawValue < b.body.rawValue
            }
    }

    private static func brightPlanetHeadline(_ planets: [SkyTonight.PlanetVisibility], timeZone: TimeZone) -> Headline? {
        guard let planet = brightestVisiblePlanet(planets),
              let riseTime = planet.rise ?? planet.bestViewingStart,
              let azimuth = planet.bestAzimuth else {
            return nil
        }
        let direction = compassWord(compassPoint(forAzimuth: azimuth))
        let text = "\(planet.body.displayName) rises at \(shortTime(riseTime, timeZone: timeZone)) — look \(direction)."
        let detail = "\(planet.body.displayName) is the brightest planet visible tonight, best seen \(direction), "
            + "\(planet.directionDescription ?? "well up in the sky") around \(shortTime(planet.bestViewingStart ?? riseTime, timeZone: timeZone))."
        return Headline(text: text, detailText: detail, kind: .brightPlanet)
    }

    private static func notableMoonHeadline(_ moon: SkyTonight.MoonInfo, timeZone: TimeZone) -> Headline? {
        if moon.illuminatedPercent >= BestMoment.fullMoonIlluminationThreshold {
            let text = "Full moon tonight — bright enough to cast shadows."
            let riseClause = moon.rise.map { " and rising around \(shortTime($0, timeZone: timeZone))" } ?? ""
            let detail = "The Moon is essentially full tonight (about \(Int(moon.illuminatedPercent.rounded()))% illuminated)\(riseClause), washing out all but the brightest stars."
            return Headline(text: text, detailText: detail, kind: .notableMoon)
        }
        if moon.illuminatedPercent <= BestMoment.newMoonIlluminationThreshold {
            let text = "New moon tonight — the darkest skies of the month."
            let detail = "The Moon is essentially new tonight (about \(Int(moon.illuminatedPercent.rounded()))% illuminated), leaving skies at their darkest all month."
            return Headline(text: text, detailText: detail, kind: .notableMoon)
        }
        return nil
    }

    private static func goodStargazingHeadline(_ inputs: Inputs) -> Headline? {
        guard let score = inputs.peakStargazingScore, score >= goodStargazingThreshold,
              let hour = inputs.peakStargazingHour else {
            return nil
        }
        let time = shortTime(hour, timeZone: inputs.timeZone)
        let text = "Good stargazing after \(time) — clear, dark skies rating \(score)/10."
        let detail = "Stargazing conditions peak after \(time) tonight, with clear skies and minimal moonlight for a rating of \(score) out of 10."
        return Headline(text: text, detailText: detail, kind: .goodStargazing)
    }

    private static func showerBuildingHeadline(_ outlook: MeteorShowers.MeteorOutlook?) -> Headline? {
        guard let outlook, !outlook.isPeakNight, outlook.daysFromPeak < 0,
              abs(outlook.daysFromPeak) <= showerBuildingWindowDays else {
            return nil
        }
        let text = "The \(outlook.shower.name) are building — peak in \(abs(outlook.daysFromPeak)) day\(abs(outlook.daysFromPeak) == 1 ? "" : "s")."
        let detail = "The \(outlook.shower.name) meteor shower is ramping up, radiating from \(outlook.shower.radiantConstellation), and should peak in about \(abs(outlook.daysFromPeak)) day\(abs(outlook.daysFromPeak) == 1 ? "" : "s")."
        return Headline(text: text, detailText: detail, kind: .showerBuilding)
    }

    // MARK: - Formatting helpers
    //
    // `compassWord`/`shortTime` are `internal` (not `private`) rather than file-scoped, so
    // `TonightSkyCard`'s ISS plain-language block (Forecast-surface overhaul, work item 5) can
    // reuse the exact same compass-word/time wording this file already uses for the hero
    // caption, instead of a second, potentially-drifting copy of the same trivial formatting.

    static let compassWords: [String: String] = [
        "N": "north", "NNE": "north-northeast", "NE": "northeast", "ENE": "east-northeast",
        "E": "east", "ESE": "east-southeast", "SE": "southeast", "SSE": "south-southeast",
        "S": "south", "SSW": "south-southwest", "SW": "southwest", "WSW": "west-southwest",
        "W": "west", "WNW": "west-northwest", "NW": "northwest", "NNW": "north-northwest",
    ]

    static func compassWord(_ abbreviation: String) -> String {
        compassWords[abbreviation] ?? abbreviation.lowercased()
    }

    /// Renders `date` as a plain local time in `timeZone`: "midnight"/"noon" at exactly those
    /// instants, otherwise a bare 12-hour "h:mm" with no AM/PM suffix (matching the Observatory
    /// Guide register's terse style, e.g. "9:42", "11:15") -- deliberately not disambiguated
    /// with AM/PM since every use in this file is already anchored to "tonight."
    static func shortTime(_ date: Date, timeZone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let components = calendar.dateComponents([.hour, .minute], from: date)
        let hour24 = components.hour ?? 0
        let minute = components.minute ?? 0
        if minute == 0, hour24 == 0 { return "midnight" }
        if minute == 0, hour24 == 12 { return "noon" }
        let hour12 = hour24 % 12 == 0 ? 12 : hour24 % 12
        return String(format: "%d:%02d", hour12, minute)
    }
}
