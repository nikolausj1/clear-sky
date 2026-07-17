import Foundation

/// Picks tonight's single headline moment out of everything the other Sky engines know about:
/// ISS passes, the aurora outlook, tonight's planets, the meteor outlook, and close pairings.
/// This is a **picker, not a copywriter** — per work order, `SkyMoment` carries a typed enum
/// plus the underlying data (an `ISSPass`, an `AuroraOutlook`, etc.), not display strings. The
/// UI layer / phrase bank is responsible for turning e.g. `.issPass(let pass)` into whatever
/// sentence a human should read; this file only decides *which* fact is the headline and *when*
/// it happens.
enum BestMoment {

    // MARK: - Input

    /// Everything about tonight this picker needs, gathered from the other engines. Callers
    /// assemble this from `SkyTonight.compute`, `ISSTonight.passes`, `AuroraTonight.fetch`,
    /// `MeteorShowers.outlook`, and `Conjunctions.closePairings` — this type doesn't compute
    /// any of it, just bundles it for the ranking below.
    struct TonightData {
        var sky: SkyTonight.TonightSky
        /// Visible ISS passes for tonight, chronological order (as returned by
        /// `ISSTonight.passes`); empty if none.
        var issPasses: [ISSPass]
        /// `nil` if the aurora outlook couldn't be fetched (e.g. offline) rather than "checked
        /// and found nothing" — callers should treat a missing outlook as "unknown", which this
        /// picker simply skips over (falls through to the next priority tier).
        var auroraOutlook: AuroraOutlook?
        /// `nil` if no shower is active tonight (see `MeteorShowers.activeShower`).
        var meteorOutlook: MeteorShowers.MeteorOutlook?
        /// Close pairings visible tonight (see `Conjunctions.closePairings`), already filtered
        /// to ones that clear the horizon in darkness.
        var pairings: [Conjunctions.Pairing]

        init(
            sky: SkyTonight.TonightSky,
            issPasses: [ISSPass] = [],
            auroraOutlook: AuroraOutlook? = nil,
            meteorOutlook: MeteorShowers.MeteorOutlook? = nil,
            pairings: [Conjunctions.Pairing] = []
        ) {
            self.sky = sky
            self.issPasses = issPasses
            self.auroraOutlook = auroraOutlook
            self.meteorOutlook = meteorOutlook
            self.pairings = pairings
        }
    }

    // MARK: - Output

    enum MoonRiseKind: Equatable {
        case fullMoon
        case newMoon
    }

    /// The headline fact for tonight, plus its own associated data — no display strings live
    /// here on purpose (see the type-level doc comment).
    enum Kind {
        case issPass(ISSPass)
        case auroraWindow(AuroraOutlook)
        case meteorShower(MeteorShowers.MeteorOutlook)
        case conjunction(Conjunctions.Pairing)
        case brightPlanet(SkyTonight.PlanetVisibility)
        case moonRise(kind: MoonRiseKind, illuminatedPercent: Double, riseTime: Date)
    }

    struct SkyMoment {
        /// When to actually go look.
        var time: Date
        var kind: Kind
        /// A short internal note on *why* this won the ranking (e.g. "bright ISS pass beats
        /// aurora .fair"). This is debug/telemetry material for logs and tests, not user-facing
        /// copy — same "not display strings" rule as `kind`'s payload, just spelled out
        /// separately since a free-text field is otherwise tempting to surface directly.
        var rationale: String
    }

    // MARK: - Priority ranking
    //
    // 1. A visible ISS pass tonight (bright, unmistakable, and time-boxed to a few minutes —
    //    the single most "must not miss this" event the app can report).
    // 2. An aurora outlook of .fair or better (genuinely rare at most latitudes; when it
    //    happens, it outranks routine planet/meteor viewing).
    // 3. A peak-night meteor shower whose *washout-adjusted* estimated rate is still decent
    //    (>= ~10/hour) — below that bar a shower isn't really a "headline", just background
    //    trivia, so it falls through to lower tiers instead.
    // 4. A close Moon/planet or planet/planet pairing.
    // 5. The brightest visible planet's best viewing window (planets are the reliable fallback
    //    most nights have).
    // 6. A full or new moonrise (a nice ambient note when nothing more exciting is going on).
    //
    // Returns `nil` if nothing clears any tier tonight (deliberately no forced fallback --
    // some nights just don't have a headline moment).
    static func bestMoment(tonight: TonightData) -> SkyMoment? {
        if let pass = bestISSPass(tonight.issPasses) {
            return SkyMoment(
                time: pass.peakTime,
                kind: .issPass(pass),
                rationale: "Visible ISS pass (\(pass.brightness.rawValue), peak altitude \(Int(pass.peakAltitudeDeg.rounded()))°) outranks everything else."
            )
        }

        if let aurora = tonight.auroraOutlook, aurora.band >= .fair {
            return SkyMoment(
                time: aurora.bestViewingWindow.start,
                kind: .auroraWindow(aurora),
                rationale: "Aurora outlook is \(aurora.band) (>= .fair threshold) with no ISS pass to beat it."
            )
        }

        if let meteor = tonight.meteorOutlook, meteor.isPeakNight, meteor.estimatedVisiblePerHour >= meteorHeadlineThreshold {
            return SkyMoment(
                time: meteor.bestWindow.start,
                kind: .meteorShower(meteor),
                rationale: "\(meteor.shower.name) at peak night, washout-adjusted rate \(Int(meteor.estimatedVisiblePerHour.rounded()))/hr clears the \(Int(meteorHeadlineThreshold))/hr headline bar."
            )
        }

        if let pairing = bestPairing(tonight.pairings) {
            return SkyMoment(
                time: pairing.bestViewingTime,
                kind: .conjunction(pairing),
                rationale: "Closest pairing tonight: \(pairing.bodyA.displayName)-\(pairing.bodyB.displayName) at \(String(format: "%.1f", pairing.separationDegrees))°."
            )
        }

        if let planet = brightestVisiblePlanet(tonight.sky.planets) {
            return SkyMoment(
                time: planet.bestViewingStart ?? tonight.sky.sun.civilDusk ?? Date(),
                kind: .brightPlanet(planet),
                rationale: "Brightest visible planet tonight: \(planet.body.displayName) (mag \(planet.apparentMagnitude.map { String(format: "%.1f", $0) } ?? "?"))."
            )
        }

        if let moment = moonRiseMoment(tonight.sky.moon) {
            return moment
        }

        return nil
    }

    /// A shower needs at least this many washout-adjusted meteors/hour to count as tonight's
    /// headline rather than background trivia (see tier 3 above).
    static let meteorHeadlineThreshold = 10.0

    /// Illumination bar for calling a moonrise "full" or "new" enough to be worth a mention
    /// (tier 6). Exact 0%/100% essentially never happens at an arbitrary observation instant,
    /// so this allows a few points of slop either side.
    static let fullMoonIlluminationThreshold = 97.0
    static let newMoonIlluminationThreshold = 3.0

    // MARK: - Tie-break helpers (all deterministic)

    /// Brightest-first: `.bright` pass beats `.moderate` beats `.dim`; within a brightness tier,
    /// higher peak altitude wins; final tie-break is earliest start time.
    private static func bestISSPass(_ passes: [ISSPass]) -> ISSPass? {
        func rank(_ b: ISSBrightness) -> Int {
            switch b {
            case .bright: return 0
            case .moderate: return 1
            case .dim: return 2
            }
        }
        return passes.min { a, b in
            let ra = rank(a.brightness), rb = rank(b.brightness)
            if ra != rb { return ra < rb }
            if a.peakAltitudeDeg != b.peakAltitudeDeg { return a.peakAltitudeDeg > b.peakAltitudeDeg }
            return a.startTime < b.startTime
        }
    }

    /// Tightest separation wins; ties broken alphabetically by the pair's body names so the
    /// result is stable regardless of input ordering.
    private static func bestPairing(_ pairings: [Conjunctions.Pairing]) -> Conjunctions.Pairing? {
        pairings.min { a, b in
            if a.separationDegrees != b.separationDegrees { return a.separationDegrees < b.separationDegrees }
            let aKey = "\(a.bodyA.displayName)-\(a.bodyB.displayName)"
            let bKey = "\(b.bodyA.displayName)-\(b.bodyB.displayName)"
            return aKey < bKey
        }
    }

    /// Lowest apparent magnitude (= brightest) among planets visible tonight; ties broken by
    /// raw case name for determinism.
    private static func brightestVisiblePlanet(_ planets: [SkyTonight.PlanetVisibility]) -> SkyTonight.PlanetVisibility? {
        planets
            .filter { $0.isVisibleTonight && $0.apparentMagnitude != nil }
            .min { a, b in
                let ma = a.apparentMagnitude!, mb = b.apparentMagnitude!
                if ma != mb { return ma < mb }
                return a.body.rawValue < b.body.rawValue
            }
    }

    private static func moonRiseMoment(_ moon: SkyTonight.MoonInfo) -> SkyMoment? {
        guard let rise = moon.rise else { return nil }
        if moon.illuminatedPercent >= fullMoonIlluminationThreshold {
            return SkyMoment(
                time: rise,
                kind: .moonRise(kind: .fullMoon, illuminatedPercent: moon.illuminatedPercent, riseTime: rise),
                rationale: "Nothing higher-priority tonight; Moon is \(String(format: "%.0f", moon.illuminatedPercent))% illuminated (>= \(Int(fullMoonIlluminationThreshold))% full-moon bar) and rises tonight."
            )
        }
        if moon.illuminatedPercent <= newMoonIlluminationThreshold {
            return SkyMoment(
                time: rise,
                kind: .moonRise(kind: .newMoon, illuminatedPercent: moon.illuminatedPercent, riseTime: rise),
                rationale: "Nothing higher-priority tonight; Moon is \(String(format: "%.0f", moon.illuminatedPercent))% illuminated (<= \(Int(newMoonIlluminationThreshold))% new-moon bar) and rises tonight."
            )
        }
        return nil
    }
}
