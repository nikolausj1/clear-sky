import Foundation

/// Deterministic, static phrase-bank selection engine — PRD Section 8 ("PhraseBank") and
/// Section 5's "Deterministic over random" principle. No runtime AI, ever: every line this
/// type returns was hand-written into `phrasebank.json` (see that folder's `README.md` for
/// the full schema, tag vocabulary, and token table).
///
/// ## Deterministic rotation algorithm
///
/// For a given slot + resolved tag bucket (the specific set of JSON entries that matched a
/// query, at whatever fallback specificity — see below), the engine:
///
/// 1. Computes a stable **bucket key**: `slot rawValue + sorted "tagKey=tagValue" pairs that
///    matched`. This does NOT depend on the date, so it identifies "this exact pool of
///    variants" across every day.
/// 2. Seeds a small deterministic PRNG (`SeededGenerator`, a fixed-multiplier LCG — NOT
///    Swift's `Hasher`, which is process-randomized by design and would silently break
///    "same day + same location -> same line" across app launches) from a stable FNV-1a hash
///    of `bucketKey + "|" + locationId.uuidString`. Location is folded into the seed here
///    (rather than into the day index) specifically so two cities showing the same bucket on
///    the same day don't necessarily land on the same line (PRD Section 8: "plus location and
///    slot key, so different cities don't show identical lines on the same day").
/// 3. Performs a deterministic Fisher-Yates shuffle of `0..<variants.count` using that PRNG.
///    The result is a fixed **permutation** — a rotation order, not a per-day random draw.
/// 4. Computes `dayNumber` = whole days between a fixed epoch (2000-01-01, in the current
///    calendar) and `date` (normalized to the start of its day). The variant shown is
///    `variants[permutation[dayNumber % variants.count]]`.
///
/// Because a permutation is a bijection, `permutation[i] != permutation[j]` whenever `i !=
/// j`. So: (a) every variant appears exactly once per full cycle through the bucket before
/// any repeat, satisfying the 8-variant/7-day no-repeat success criterion by construction;
/// and (b) two calendar-consecutive days always map to different permutation slots whenever
/// the bucket has 2+ variants, so a line can never immediately repeat on the very next day —
/// this holds across a month/year boundary too, since `dayNumber` is a flat day count, not a
/// day-of-month or day-of-year value that could wrap and collide.
///
/// This whole computation is a pure function of (slot, matched tags, locationId, date) — no
/// `Date()`/`Int.random`/`Hasher` involved anywhere — so it is exactly reproducible and
/// testable without a simulator.
enum PhraseBank {

    // MARK: - Public vocabulary

    enum Slot: String {
        case summary
        case doodleCaption
        case comparison
        case rankingVerdict
        case emptyState
        case errorState
        // "Tonight's Sky" (PRD Revision Notes 2026-07-17):
        case skyPlanet
        case skyNoPlanets
        case skyAurora
        case skyISSPass
        case skyNoISS
        case skyMoon
        // Sky-intelligence rows (work package WP-F):
        case skyMeteor
        case skyPairing
        // Space tab (work package WP-K):
        case skyLaunch
        case skySolar
    }

    /// The condition groups `summary`/`doodleCaption` content is authored against. WeatherKit's
    /// ~30 raw `WeatherCondition` values are folded down to these via `conditionGroup(forRawCode:)`.
    enum ConditionGroup: String {
        case clear, cloudy, rain, snow, fog, wind, storm
    }

    /// **tempBand thresholds** (Fahrenheit, regardless of the user's F/C display setting —
    /// Settings' unit toggle only affects how `{temp}`-style tokens are *formatted*, never
    /// which bucket of copy is selected): `cold` below 45°F, `hot` above 82°F, `mild` in
    /// between (inclusive of both bounds).
    enum TempBand: String {
        case cold, mild, hot

        static func forFahrenheit(_ f: Double) -> TempBand {
            if f < 45 { return .cold }
            if f > 82 { return .hot }
            return .mild
        }

        static func forMeasurement(_ measurement: Measurement<UnitTemperature>) -> TempBand {
            forFahrenheit(measurement.converted(to: .fahrenheit).value)
        }
    }

    enum ComparisonDirection: String {
        case warmer, cooler, same
    }

    enum ComparisonMagnitude: String {
        case slight, moderate, large

        /// PRD canonical line #3 ("Six degrees warmer... Progress, technically.") is a
        /// `moderate` swing under this bucketing. `slight`: 1-3°. `moderate`: 4-9°. `large`:
        /// 10°+. A delta of 0 is handled separately as `ComparisonDirection.same` and never
        /// reaches this bucketing.
        static func forDelta(_ absoluteDegrees: Double) -> ComparisonMagnitude {
            if absoluteDegrees < 4 { return .slight }
            if absoluteDegrees < 10 { return .moderate }
            return .large
        }
    }

    enum RankPosition: String {
        case top, middle, bottom
    }

    enum Pleasantness: String {
        case great, fine, rough
    }

    enum EmptyContext: String {
        case noLocations
        case rankingsNeedOneMore
        case rankingsNoCities
        case searchOffline
    }

    enum ErrorContext: String {
        case weatherFetchFailed
        case locationRowFailed
        case rankingRowFailed
        case generic
    }

    /// "Tonight's Sky" `skyMoon` tag values. Four quarters rather than all 8 phase names (the
    /// Moon row's own phase name/symbol are computed separately in `TonightSkyCard` from the
    /// exact `phaseFraction`/`illuminatedPercent`) — this coarser bucketing is just for which
    /// wit-line pool applies. `AuroraBand` (Sources/Sky/Aurora) and `Planets.Body`
    /// (Sources/Sky/Astronomy) are reused directly as tag sources for `skyAurora`/`skyPlanet`
    /// rather than duplicating their vocabularies here.
    enum MoonQuarter: String {
        case new, waxing, full, waning
    }

    // MARK: - Absolute last-resort fallbacks (used only if the JSON fails to load or a slot
    // decodes to zero entries — defensive, per PRD "never render '-' in production")

    private static let hardcodedFallback: [Slot: String] = [
        .summary: "Today's forecast is in. Details above.",
        .doodleCaption: "Today's forecast, illustrated above.",
        .comparison: "Compared to yesterday: results above.",
        .rankingVerdict: "Ranked today; see above for specifics.",
        .emptyState: "Nothing to show here yet.",
        .errorState: "Something went wrong. Try again.",
        .skyPlanet: "Visible tonight, weather permitting.",
        .skyNoPlanets: "No naked-eye planets tonight.",
        .skyAurora: "Aurora outlook: see above.",
        .skyISSPass: "The ISS passes over tonight.",
        .skyNoISS: "No visible ISS pass tonight.",
        .skyMoon: "Tonight's moon, as shown above.",
        .skyMeteor: "Meteor activity tonight, as shown above.",
        .skyPairing: "A close pairing tonight, as shown above.",
        .skyLaunch: "Launch schedule, as shown above.",
        .skySolar: "Solar activity, as shown above.",
    ]

    // MARK: - Public API

    static func summary(
        condition: ConditionGroup,
        tempBand: TempBand,
        date: Date,
        locationId: UUID,
        tokens: [String: String]
    ) -> String {
        render(
            slot: .summary,
            queries: [
                ["condition": condition.rawValue, "tempBand": tempBand.rawValue],
                ["condition": condition.rawValue],
                [:],
            ],
            date: date,
            locationId: locationId,
            tokens: tokens
        )
    }

    static func doodleCaption(
        condition: ConditionGroup,
        tempBand: TempBand,
        date: Date,
        locationId: UUID,
        tokens: [String: String]
    ) -> String {
        render(
            slot: .doodleCaption,
            queries: [
                ["condition": condition.rawValue, "tempBand": tempBand.rawValue],
                ["condition": condition.rawValue],
                [:],
            ],
            date: date,
            locationId: locationId,
            tokens: tokens
        )
    }

    /// Callers must only invoke this when a yesterday reference point actually exists (PRD
    /// Section 6: "if neither [WeatherKit historical comparison nor `dailyActuals`] exists
    /// yet, the line is omitted rather than faked"). `PhraseBank` has no opinion on data
    /// availability — that decision lives in `ForecastViewModel`.
    static func comparison(
        direction: ComparisonDirection,
        magnitude: ComparisonMagnitude?,
        date: Date,
        locationId: UUID,
        tokens: [String: String]
    ) -> String {
        var exact = ["direction": direction.rawValue]
        if let magnitude, direction != .same {
            exact["magnitude"] = magnitude.rawValue
        }
        return render(
            slot: .comparison,
            queries: [
                exact,
                ["direction": direction.rawValue],
                [:],
            ],
            date: date,
            locationId: locationId,
            tokens: tokens
        )
    }

    static func rankingVerdict(
        position: RankPosition,
        pleasantness: Pleasantness,
        date: Date,
        locationId: UUID,
        tokens: [String: String]
    ) -> String {
        render(
            slot: .rankingVerdict,
            queries: [
                ["position": position.rawValue, "pleasantness": pleasantness.rawValue],
                ["position": position.rawValue],
                [:],
            ],
            date: date,
            locationId: locationId,
            tokens: tokens
        )
    }

    static func emptyState(
        _ context: EmptyContext,
        date: Date,
        locationId: UUID = Self.universalLocationId,
        tokens: [String: String] = [:]
    ) -> String {
        render(
            slot: .emptyState,
            queries: [
                ["context": context.rawValue],
                [:],
            ],
            date: date,
            locationId: locationId,
            tokens: tokens
        )
    }

    static func errorState(
        _ context: ErrorContext,
        date: Date,
        locationId: UUID = Self.universalLocationId,
        tokens: [String: String] = [:]
    ) -> String {
        render(
            slot: .errorState,
            queries: [
                ["context": context.rawValue],
                [:],
            ],
            date: date,
            locationId: locationId,
            tokens: tokens
        )
    }

    /// Used by `emptyState`/`errorState` call sites that aren't location-specific (e.g. the
    /// Forecast screen's "no saved locations at all" empty state). A fixed, well-known UUID
    /// so rotation is still deterministic rather than accidentally random.
    static let universalLocationId = UUID(uuidString: "00000000-0000-0000-0000-00000000BEEF")!

    // MARK: - "Tonight's Sky" (PRD Revision Notes 2026-07-17)

    /// A dry-wit line about a specific visible planet, keyed by `Planets.Body` (reused directly
    /// from `Sources/Sky/Astronomy` rather than a duplicate tag enum). Shown inside that
    /// planet's inline-expanded detail, alongside (not instead of) `SkyFindItGuide`'s
    /// informational blurb — see that type's doc comment for the "teach vs. entertain" split.
    static func skyPlanet(
        _ body: Planets.Body,
        date: Date,
        locationId: UUID,
        tokens: [String: String] = [:]
    ) -> String {
        render(
            slot: .skyPlanet,
            queries: [["planet": body.rawValue], [:]],
            date: date,
            locationId: locationId,
            tokens: tokens
        )
    }

    /// Zero-visible-planets row: a single quiet dry-wit line.
    static func skyNoPlanets(date: Date, locationId: UUID) -> String {
        render(slot: .skyNoPlanets, queries: [[:]], date: date, locationId: locationId, tokens: [:])
    }

    /// A dry-wit line for tonight's aurora outlook, keyed by `AuroraBand` (reused directly from
    /// `Sources/Sky/Aurora` via its `description` — "none"/"low"/"fair"/"good"/"strong" — rather
    /// than a duplicate tag enum).
    static func skyAurora(
        band: AuroraBand,
        date: Date,
        locationId: UUID,
        tokens: [String: String] = [:]
    ) -> String {
        render(
            slot: .skyAurora,
            queries: [["band": band.description], [:]],
            date: date,
            locationId: locationId,
            tokens: tokens
        )
    }

    /// A dry-wit line shown alongside tonight's visible ISS pass(es).
    static func skyISSPass(date: Date, locationId: UUID, tokens: [String: String] = [:]) -> String {
        render(slot: .skyISSPass, queries: [[:]], date: date, locationId: locationId, tokens: tokens)
    }

    /// No-visible-ISS-pass-tonight row: a single dry-wit line.
    static func skyNoISS(date: Date, locationId: UUID) -> String {
        render(slot: .skyNoISS, queries: [[:]], date: date, locationId: locationId, tokens: [:])
    }

    /// A dry-wit line about tonight's moon, keyed by `MoonQuarter` (new/waxing/full/waning — a
    /// coarser bucketing than the Moon row's own 8-phase name/symbol, which `TonightSkyCard`
    /// computes separately from the exact phase fraction).
    static func skyMoon(
        quarter: MoonQuarter,
        date: Date,
        locationId: UUID,
        tokens: [String: String] = [:]
    ) -> String {
        render(
            slot: .skyMoon,
            queries: [["phase": quarter.rawValue], [:]],
            date: date,
            locationId: locationId,
            tokens: tokens
        )
    }

    /// A dry-wit line for tonight's active meteor shower, keyed by `MeteorShowers.MoonInterference`
    /// (reused directly from `Sources/Sky/Astronomy` — none/some/severe — rather than a duplicate
    /// tag enum). Shown alongside the meteor row's own factual rate/window text. Callers should
    /// pass `{shower}` in `tokens` (the active shower's name, e.g. "Perseids") — every variant
    /// uses that token rather than hardcoding a shower name, since this same line pool backs
    /// whichever shower happens to be active tonight.
    static func skyMeteor(
        interference: MeteorShowers.MoonInterference,
        date: Date,
        locationId: UUID,
        tokens: [String: String] = [:]
    ) -> String {
        render(
            slot: .skyMeteor,
            queries: [["interference": Self.interferenceTag(interference)], [:]],
            date: date,
            locationId: locationId,
            tokens: tokens
        )
    }

    private static func interferenceTag(_ interference: MeteorShowers.MoonInterference) -> String {
        switch interference {
        case .none: return "none"
        case .some: return "some"
        case .severe: return "severe"
        }
    }

    /// A dry-wit line for tonight's closest visible Moon/planet or planet/planet pairing. Untagged
    /// (one shared pool) — the row's own factual text already names the specific bodies and
    /// separation, so this line is deliberately generic enough to sit under any pairing.
    static func skyPairing(date: Date, locationId: UUID, tokens: [String: String] = [:]) -> String {
        render(slot: .skyPairing, queries: [[:]], date: date, locationId: locationId, tokens: tokens)
    }

    // MARK: - Space tab (work package WP-K)

    /// A dry-wit line about the Launch Schedule card. Untagged (one shared pool) — rockets and
    /// schedules in general, not any specific mission, so it works underneath whichever launches
    /// happen to be next.
    static func skyLaunch(date: Date, locationId: UUID, tokens: [String: String] = [:]) -> String {
        render(slot: .skyLaunch, queries: [[:]], date: date, locationId: locationId, tokens: tokens)
    }

    /// A dry-wit line for the Sun card, keyed by `SolarActivityLevel` (reused directly from
    /// `Sources/Sky/Solar` — quiet/active/stormy). Stormy lines lead with the real-world
    /// disruption (radio/GPS) before any wit, per work order: a genuine X-class flare is useful
    /// information the joke must never undercut.
    static func skySolar(
        level: SolarActivityLevel,
        date: Date,
        locationId: UUID,
        tokens: [String: String] = [:]
    ) -> String {
        render(
            slot: .skySolar,
            queries: [["level": level.description], [:]],
            date: date,
            locationId: locationId,
            tokens: tokens
        )
    }

    // MARK: - WeatherKit condition-code -> ConditionGroup mapping
    //
    // Mirrors the lowercased-contains-checks `DoodleHeaderView` already uses for its palette,
    // so the phrase bank and the doodle art agree on what "counts" as rain/snow/fog/etc.

    static func conditionGroup(forRawCode rawCode: String) -> ConditionGroup {
        let code = rawCode.lowercased()
        if code.contains("thunder") {
            return .storm
        }
        if code.contains("snow") || code.contains("flurries") || code.contains("sleet") || code.contains("hail") || code.contains("ice") || code.contains("wintry") {
            return .snow
        }
        if code.contains("rain") || code.contains("drizzle") {
            return .rain
        }
        if code.contains("fog") || code.contains("haze") || code.contains("smok") {
            return .fog
        }
        if code.contains("windy") || code.contains("breezy") || code.contains("squall") {
            return .wind
        }
        if code.contains("cloud") || code.contains("overcast") || code.contains("hazy") {
            return .cloudy
        }
        if code.contains("clear") || code.contains("sun") || code.contains("hot") || code.contains("frigid") || code.contains("mostlyclear") {
            return .clear
        }
        // Unrecognized/rare codes (e.g. "hurricane", "tropicalStorm", "blizzard", "blowingDust")
        // fall to `.cloudy` as the safest generic bucket rather than `.clear`, since these are
        // all "something notable is happening" conditions, not calm-sky ones.
        return .cloudy
    }

    // MARK: - Rendering core

    /// `queries` is a fallback chain, most specific first; the last entry should be `[:]`
    /// (matches any entry with no tags at all — the slot's universal safety net).
    private static func render(
        slot: Slot,
        queries: [[String: String]],
        date: Date,
        locationId: UUID,
        tokens: [String: String]
    ) -> String {
        let entries = ContentStore.shared.entries(for: slot)
        guard !entries.isEmpty else {
            return hardcodedFallback[slot] ?? ""
        }

        for query in queries {
            let matchingEntries = entries.filter { tagsMatch(entryTags: $0.tags, query: query) }
            guard !matchingEntries.isEmpty else { continue }
            let key = bucketKey(slot: slot, query: query)
            let text = pick(from: matchingEntries.map(\.text), bucketKey: key, locationId: locationId, date: date)
            return fill(text, tokens: tokens)
        }

        return hardcodedFallback[slot] ?? ""
    }

    /// An entry matches a query if, for every key present in the entry's own tags, the
    /// query supplies the same value. An entry with fewer tags than the query is a
    /// *wildcard* on the keys it omits (this is how fog/wind/storm — tagged `condition`
    /// only, no `tempBand` — match at the "condition-only" fallback tier). An entry is never
    /// allowed to match a query that's *missing* one of the entry's tag keys, and an entry's
    /// tag value must never contradict the query's value for a shared key.
    ///
    /// The one deliberate exception: a completely **untagged** entry (the JSON's universal
    /// safety-net lines) matches ONLY the empty `[:]` query, never a specific one. Without
    /// this early-return, an untagged entry's tag-comparison loop runs zero iterations (there
    /// are no tags to check) and is vacuously satisfied by *any* query — silently smuggling
    /// the universal lines into every condition/tempBand-specific bucket's rotation pool
    /// alongside the entries actually authored for it. (This was a real bug caught during
    /// Phase 4 sim-verify: the summary/doodleCaption lines intermittently rendered a generic
    /// universal line instead of the forced condition's bucket, because the "13-entry
    /// clear+hot bucket" `pick()` was rotating through was actually 9 real entries plus all 4
    /// universal ones.)
    private static func tagsMatch(entryTags: [String: String], query: [String: String]) -> Bool {
        if entryTags.isEmpty {
            return query.isEmpty
        }
        for (key, value) in entryTags {
            guard let queryValue = query[key], queryValue == value else { return false }
        }
        return true
    }

    private static func bucketKey(slot: Slot, query: [String: String]) -> String {
        let sortedTags = query.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "&")
        return "\(slot.rawValue)|\(sortedTags)"
    }

    /// Deterministic rotation: see the type-level doc comment for the full algorithm.
    static func pick(from variants: [String], bucketKey: String, locationId: UUID, date: Date) -> String {
        guard variants.count > 1 else { return variants.first ?? "" }

        let seed = fnv1aHash("\(bucketKey)|\(locationId.uuidString)")
        var generator = SeededGenerator(seed: seed)
        var permutation = Array(0..<variants.count)
        // Fisher-Yates, deterministic.
        if permutation.count > 1 {
            for i in stride(from: permutation.count - 1, to: 0, by: -1) {
                let j = Int(generator.next() % UInt64(i + 1))
                permutation.swapAt(i, j)
            }
        }

        let dayNumber = dayNumber(for: date)
        let index = permutation[dayNumber % permutation.count]
        return variants[index]
    }

    private static let epoch: Date = {
        var components = DateComponents()
        components.year = 2000
        components.month = 1
        components.day = 1
        return Calendar(identifier: .gregorian).date(from: components)!
    }()

    static func dayNumber(for date: Date) -> Int {
        let calendar = Calendar(identifier: .gregorian)
        let startOfDay = calendar.startOfDay(for: date)
        let days = calendar.dateComponents([.day], from: epoch, to: startOfDay).day ?? 0
        return max(days, 0)
    }

    private static func fill(_ text: String, tokens: [String: String]) -> String {
        guard !tokens.isEmpty else { return text }
        var result = text
        for (key, value) in tokens {
            result = result.replacingOccurrences(of: "{\(key)}", with: value)
        }
        return result
    }

    // MARK: - Stable (non-randomized) hashing

    /// FNV-1a over UTF-8 bytes. Deliberately NOT Swift's `Hasher`/`String.hashValue`, which
    /// Apple randomizes per-process for hash-flooding resistance — using it here would make
    /// "same day + same location -> same line" true only *within* one app launch, not across
    /// relaunches, silently violating the PRD's determinism requirement.
    private static func fnv1aHash(_ string: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        let prime: UInt64 = 0x0000_0100_0000_01B3
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* prime
        }
        return hash
    }

    /// A tiny deterministic linear-congruential generator, seeded explicitly. Not
    /// cryptographic, not `Hasher`-based — just reproducible.
    private struct SeededGenerator {
        private var state: UInt64

        init(seed: UInt64) {
            // Avoid a zero state, which would make every subsequent value zero.
            self.state = seed == 0 ? 0x9E37_79B9_7F4A_7C15 : seed
        }

        mutating func next() -> UInt64 {
            // Constants from Numerical Recipes' LCG.
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return state
        }
    }

    // MARK: - JSON loading

    private final class ContentStore {
        static let shared = ContentStore()

        struct Entry {
            let tags: [String: String]
            let text: String
        }

        private var bySlot: [Slot: [Entry]] = [:]

        private init() {
            guard let url = Bundle.main.url(forResource: "phrasebank", withExtension: "json"),
                  let data = try? Data(contentsOf: url) else {
                assertionFailure("phrasebank.json missing from bundle — check project.yml resource wiring")
                return
            }
            decode(data)
        }

        func entries(for slot: Slot) -> [Entry] {
            bySlot[slot] ?? []
        }

        private func decode(_ data: Data) {
            struct RawEntry: Decodable {
                let tags: [String: String]
                let text: String
            }
            guard let raw = try? JSONDecoder().decode([String: [RawEntry]].self, from: data) else {
                assertionFailure("phrasebank.json failed to decode")
                return
            }
            for (slotName, entries) in raw {
                guard let slot = Slot(rawValue: slotName) else { continue }
                bySlot[slot] = entries.map { Entry(tags: $0.tags, text: $0.text) }
            }
        }
    }
}
