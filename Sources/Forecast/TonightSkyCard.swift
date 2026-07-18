import SwiftUI

/// PRD Revision Notes (2026-07-17): the "Tonight's Sky" card — moon phase, naked-eye planet
/// visibility, aurora likelihood, and ISS passes — mounted between the daily forecast card and
/// the attribution footer in `ForecastPageView.loadedView`.
///
/// Row order (PRD work order, extended by work package WP-F "sky-intelligence rows"): Headline,
/// Moon, Planets, Aurora, Meteor, ISS, Conjunction, Sky note. Moon/planets/meteor/conjunction are
/// all on-device (`SkyTonightService.astronomy`/`meteorAndPairings`, synchronous) and render
/// immediately; Aurora/ISS are networked (`SkyTonightService.state`, async) and show a skeleton
/// placeholder until resolved, degrading to "—" on failure rather than blocking anything else.
/// The headline row is the one row that depends on *both* — see `load()`'s doc comment for how
/// it avoids flickering while the async sections resolve. Uses the exact same fade + `.clipped()`
/// inline-expand mechanism as `DailyForecastSection`'s day rows for the planet detail expansion.
struct TonightSkyCard: View {
    let location: SavedLocation
    let date: Date
    var forcedOverrides: SkyTonightService.ForcedOverrides? = nil

    @State private var astronomy: SkyTonight.TonightSky?
    @State private var issState: SkyTonightService.SectionState<[ISSPass]> = .loading
    @State private var auroraState: SkyTonightService.SectionState<AuroraOutlook> = .loading
    @State private var meteorOutlook: MeteorShowers.MeteorOutlook?
    @State private var pairings: [Conjunctions.Pairing] = []
    @State private var bestMoment: BestMoment.SkyMoment?
    @State private var expandedPlanet: Planets.Body?

    private var timeZone: TimeZone { .current }

    /// Sim-verify only: `-expandSkyPlanet mercury|venus|mars|jupiter|saturn` (see
    /// `NavigationShell`) pre-expands a planet row at launch — mirrors `-expandDay`'s rationale
    /// on `DailyForecastSection`: `simctl` can't tap through to an expanded row for a screenshot.
    init(
        location: SavedLocation,
        date: Date,
        forcedOverrides: SkyTonightService.ForcedOverrides? = nil,
        initialExpandedPlanet: Planets.Body? = nil
    ) {
        self.location = location
        self.date = date
        self.forcedOverrides = forcedOverrides
        self._expandedPlanet = State(initialValue: initialExpandedPlanet)
    }

    var body: some View {
        SheetCard(title: "TONIGHT'S SKY") {
            VStack(alignment: .leading, spacing: 0) {
                if let astronomy {
                    if bestMoment != nil {
                        headlineRow
                        Divider()
                    }
                    moonRow(astronomy.moon)
                    Divider()
                    planetsSection(astronomy.planets)
                    Divider()
                    auroraRow
                    Divider()
                    if meteorOutlook != nil {
                        meteorRow
                        Divider()
                    }
                    issRow
                    if let pairing = pairings.first {
                        Divider()
                        conjunctionRow(pairing)
                    }
                    Divider()
                    factRow
                } else {
                    skeletonRows
                }
            }
        }
        .id(Self.cardId)
        .task(id: taskKey) {
            await load()
        }
    }

    /// Sim-verify only: a stable id for `ScrollViewProxy.scrollTo` (see `ForecastPageView`'s
    /// `-scrollToSky` handling, mirroring `-scrollToAttribution`).
    static let cardId = "tonightSkyCard"

    /// Re-runs `load()` whenever the location, calendar evening, or a forced sim-verify override
    /// changes — `.task(id:)` cancels/restarts automatically on any change, same pattern
    /// `ForecastPageView.loadedView`'s `.onChange(of: viewModel.selectedMetric)` relies on
    /// elsewhere for "re-derive when an input changes."
    private var taskKey: String {
        var parts = ["\(location.id)", "\(Calendar.current.startOfDay(for: date).timeIntervalSince1970)"]
        if let overrides = forcedOverrides {
            parts.append("band=\(overrides.auroraBand?.description ?? "nil")")
            parts.append("issPass=\(overrides.issPass)")
            parts.append("noISS=\(overrides.noISS)")
            parts.append("unavailable=\(overrides.unavailable)")
            parts.append("meteorPeak=\(overrides.meteorPeak.map(String.init(describing:)) ?? "nil")")
            parts.append("pairing=\(overrides.pairing)")
        }
        return parts.joined(separator: "|")
    }

    /// Loads every row's data. Astronomy and the meteor/conjunction engines are all synchronous
    /// (no network), so they — and a first-pass `bestMoment` guess computed from them alone — are
    /// set immediately, before the async ISS/aurora fetch even starts. Once that fetch resolves,
    /// `bestMoment` is recomputed with the real ISS/aurora data folded in. Per
    /// `SkyTonightService.bestMoment`'s doc comment, that second computation can only ever
    /// *upgrade* the headline (to an ISS pass or aurora window — both strictly higher-priority
    /// than anything the sync-only pass could have produced), never blank it out or downgrade it,
    /// which is what keeps this update feeling smooth rather than a flicker.
    private func load() async {
        let astro = SkyTonightService.astronomy(latitude: location.latitude, longitude: location.longitude, date: date, timeZone: timeZone)
        astronomy = astro
        issState = .loading
        auroraState = .loading

        let (meteor, pairings) = SkyTonightService.meteorAndPairings(
            latitude: location.latitude,
            longitude: location.longitude,
            date: date,
            timeZone: timeZone,
            overrides: forcedOverrides
        )
        meteorOutlook = meteor
        self.pairings = pairings
        bestMoment = SkyTonightService.bestMoment(astronomy: astro, iss: [], aurora: nil, meteor: meteor, pairings: pairings)

        let result = await SkyTonightService.shared.state(
            locationId: location.id,
            latitude: location.latitude,
            longitude: location.longitude,
            date: date,
            timeZone: timeZone,
            overrides: forcedOverrides
        )
        issState = result.iss
        auroraState = result.aurora
        bestMoment = result.bestMoment
    }

    // MARK: - Headline

    /// "Step outside at 9:42 PM" + one factual subtitle line naming the moment. Hidden entirely
    /// when `bestMoment` is `nil` (per work order: "don't manufacture" a headline) — the `if let`
    /// in `body` already gates this, so this computed view can assume `bestMoment` is non-nil.
    private var headlineRow: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let bestMoment {
                Text("Step outside at \(Self.timeFormatter.string(from: bestMoment.time))")
                    .font(.title3.weight(.semibold))
                    .monospacedDigit()
                Text(Self.headlineSubtitle(bestMoment.kind))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 8)
    }

    /// One factual line naming tonight's headline moment, per `BestMoment.Kind` — see the
    /// work-order examples this mirrors: "ISS pass, NW→ENE, bright" / "Venus at its best, low in
    /// the W" / "Perseids peak, moon out of the way" / "Aurora window, fair odds" / "Moon-Jupiter
    /// pairing, 1.3° apart".
    private static func headlineSubtitle(_ kind: BestMoment.Kind) -> String {
        switch kind {
        case .issPass(let pass):
            return "ISS pass, \(pass.startAzimuthCompass)→\(pass.endAzimuthCompass), \(pass.brightness.rawValue)"
        case .auroraWindow(let outlook):
            return "Aurora window, \(outlook.band.description) odds"
        case .meteorShower(let outlook):
            return "\(outlook.shower.name) peak, \(meteorInterferencePhrase(outlook.moonInterference))"
        case .conjunction(let pairing):
            return "\(pairing.bodyA.displayName)-\(pairing.bodyB.displayName) pairing, \(String(format: "%.1f", pairing.separationDegrees))° apart"
        case .brightPlanet(let planet):
            return "\(planet.body.displayName) at its best, \(planet.directionDescription ?? "up tonight")"
        case .moonRise(let moonKind, _, _):
            switch moonKind {
            case .fullMoon: return "Full moon rising"
            case .newMoon: return "New moon tonight, invisible but on schedule"
            }
        }
    }

    /// Shared with `meteorRow`'s own rate line — a short "is the Moon in the way" phrase for the
    /// three `MeteorShowers.MoonInterference` cases.
    private static func meteorInterferencePhrase(_ interference: MeteorShowers.MoonInterference) -> String {
        switch interference {
        case .none: return "moon out of the way"
        case .some: return "some moonlight in the way"
        case .severe: return "bright moon washing it out"
        }
    }

    // MARK: - Moon

    private func moonRow(_ moon: SkyTonight.MoonInfo) -> some View {
        let quarter = Self.moonQuarter(illuminatedPercent: moon.illuminatedPercent, phaseFraction: moon.phaseFraction)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 12) {
                Image(systemName: Self.moonSymbolName(phaseFraction: moon.phaseFraction))
                    .font(.title2)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(Color.clearSkyAccent)
                    .frame(width: 28)

                VStack(alignment: .leading, spacing: 2) {
                    Text(Self.moonPhaseName(phaseFraction: moon.phaseFraction))
                        .font(.subheadline.weight(.semibold))
                    Text(Self.moonRiseSetText(moon))
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Text("\(Int(moon.illuminatedPercent.rounded()))%")
                    .font(.subheadline)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }

            Text(PhraseBank.skyMoon(quarter: quarter, date: date, locationId: location.id))
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 8)
    }

    /// 8 equal-width (45°/0.125) phase bins, offset by half a bin so New/Full land centered on
    /// `phaseFraction` 0 and 0.5 rather than at a bin edge.
    private static func moonPhaseName(phaseFraction: Double) -> String {
        switch phaseFraction {
        case 0..<0.0625, 0.9375...1.0: return "New Moon"
        case 0.0625..<0.1875: return "Waxing Crescent"
        case 0.1875..<0.3125: return "First Quarter"
        case 0.3125..<0.4375: return "Waxing Gibbous"
        case 0.4375..<0.5625: return "Full Moon"
        case 0.5625..<0.6875: return "Waning Gibbous"
        case 0.6875..<0.8125: return "Last Quarter"
        default: return "Waning Crescent"
        }
    }

    private static func moonSymbolName(phaseFraction: Double) -> String {
        switch phaseFraction {
        case 0..<0.0625, 0.9375...1.0: return "moonphase.new.moon"
        case 0.0625..<0.1875: return "moonphase.waxing.crescent"
        case 0.1875..<0.3125: return "moonphase.first.quarter"
        case 0.3125..<0.4375: return "moonphase.waxing.gibbous"
        case 0.4375..<0.5625: return "moonphase.full.moon"
        case 0.5625..<0.6875: return "moonphase.waning.gibbous"
        case 0.6875..<0.8125: return "moonphase.last.quarter"
        default: return "moonphase.waning.crescent"
        }
    }

    /// The coarser 4-quarter bucketing `PhraseBank.skyMoon` queries on (see that function's doc
    /// comment) — driven off `illuminatedPercent` for new/full (a direct, unambiguous read) and
    /// `phaseFraction`'s waxing/waning half otherwise.
    private static func moonQuarter(illuminatedPercent: Double, phaseFraction: Double) -> PhraseBank.MoonQuarter {
        if illuminatedPercent < 5 { return .new }
        if illuminatedPercent > 95 { return .full }
        return phaseFraction < 0.5 ? .waxing : .waning
    }

    private static func moonRiseSetText(_ moon: SkyTonight.MoonInfo) -> String {
        let rise = moon.rise.map { timeFormatter.string(from: $0) } ?? "—"
        let set = moon.set.map { timeFormatter.string(from: $0) } ?? "—"
        return "Rises \(rise) · Sets \(set)"
    }

    // MARK: - Planets

    private func planetsSection(_ planets: [SkyTonight.PlanetVisibility]) -> some View {
        let visible = planets.filter(\.isVisibleTonight)
        return Group {
            if visible.isEmpty {
                Text(PhraseBank.skyNoPlanets(date: date, locationId: location.id))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(visible.enumerated()), id: \.element.body) { index, planet in
                        planetRow(planet)
                        if index < visible.count - 1 {
                            Divider()
                        }
                    }
                }
            }
        }
    }

    private func planetRow(_ planet: SkyTonight.PlanetVisibility) -> some View {
        let isExpanded = expandedPlanet == planet.body
        return VStack(spacing: 0) {
            Button {
                // Same spring + inline-fade mechanism as `DailyForecastRow.onTap`.
                withAnimation(.spring(duration: 0.35)) {
                    expandedPlanet = (expandedPlanet == planet.body) ? nil : planet.body
                }
            } label: {
                HStack(spacing: 10) {
                    Text(planet.body.displayName)
                        .font(.subheadline.weight(.semibold))
                        .frame(width: 62, alignment: .leading)

                    Text(planet.directionDescription ?? "")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)

                    Spacer(minLength: 8)

                    if let start = planet.bestViewingStart, let end = planet.bestViewingEnd {
                        Text(Self.windowText(start: start, end: end))
                            .font(.footnote)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }

                    Image(systemName: "chevron.down")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isExpanded ? 180 : 0))
                }
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(PressableRowStyle())

            if isExpanded {
                planetExpandedDetail(planet)
            }
        }
        // Same masking technique as `DailyForecastRow`: clips the expanding detail to this
        // row's animated bounds so the reveal unfolds in place instead of painting over the
        // rows below it mid-animation.
        .clipped()
    }

    /// Fade-only reveal (no `.move`) — identical rationale to `DailyExpandedDetail`'s own
    /// comment: a `.move(edge: .top)` transition here would visibly slide the detail over the
    /// row above during the expand animation; the clean unfold comes entirely from the row's
    /// animated height + `.clipped()` above, with this view just fading in beneath it.
    private func planetExpandedDetail(_ planet: SkyTonight.PlanetVisibility) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(SkyFindItGuide.blurb(for: planet.body))
                .font(.footnote)

            if let magnitude = planet.apparentMagnitude {
                Text(Self.magnitudeDescription(magnitude))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Text(PhraseBank.skyPlanet(planet.body, date: date, locationId: location.id))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .italic()
        }
        .padding(.leading, 8)
        .padding(.top, 2)
        .padding(.bottom, 6)
        .transition(.opacity)
    }

    /// Plain-English brightness helper text (PRD ask: "'bright as the brightest stars' style
    /// helper text, not raw numbers alone"). Lower (more negative) apparent magnitude = brighter.
    private static func magnitudeDescription(_ magnitude: Double) -> String {
        switch magnitude {
        case ..<(-3): return "Brighter than every star in the sky — only the Moon can outshine it tonight."
        case -3..<(-1): return "Brighter than any star in the night sky."
        case -1..<0.5: return "As bright as the brightest stars up there."
        case 0.5..<1.5: return "As bright as a prominent, easy-to-spot star."
        case 1.5..<3: return "A modest, steady point of light."
        default: return "Faint — best from a dark sky, away from city lights."
        }
    }

    private static func windowText(start: Date, end: Date) -> String {
        "\(timeFormatter.string(from: start))–\(timeFormatter.string(from: end))"
    }

    // MARK: - Aurora

    @ViewBuilder
    private var auroraRow: some View {
        switch auroraState {
        case .loading:
            skeletonLine
        case .unavailable:
            unavailableRow(label: "Aurora", note: "Aurora data unavailable right now.")
        case .available(let outlook):
            if outlook.band == .none {
                Text(PhraseBank.skyAurora(band: .none, date: date, locationId: location.id))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    Text(Self.auroraHeadline(outlook))
                        .font(.subheadline)
                        .monospacedDigit()
                    Text(PhraseBank.skyAurora(band: outlook.band, date: date, locationId: location.id))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 8)
            }
        }
    }

    /// "Aurora: fair chance · best 11 PM–1 AM" (+ "· 22% now" only when `chanceNow` clears 5%,
    /// per the PRD's "avoid fake precision" note).
    private static func auroraHeadline(_ outlook: AuroraOutlook) -> String {
        var parts = ["Aurora: \(outlook.band.description) chance"]
        parts.append("best \(timeFormatter.string(from: outlook.bestViewingWindow.start))–\(timeFormatter.string(from: outlook.bestViewingWindow.end))")
        if outlook.chanceNow >= 5 {
            parts.append("\(outlook.chanceNow)% now")
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - Meteor

    /// Only rendered when a shower is active tonight (`body`'s `if meteorOutlook != nil` gate) —
    /// no "no shower tonight" row exists, per work order (most nights have no active shower at
    /// all, and a row saying so every night would be noise).
    private var meteorRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let meteorOutlook {
                if meteorOutlook.isPeakNight {
                    HStack(alignment: .firstTextBaseline) {
                        Text("\(meteorOutlook.shower.name) peaks tonight")
                            .font(.subheadline.weight(.semibold))
                        Spacer(minLength: 8)
                        Text(Self.windowText(start: meteorOutlook.bestWindow.start, end: meteorOutlook.bestWindow.end))
                            .font(.footnote)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    Text(Self.meteorRateText(meteorOutlook))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    Text(Self.meteorBuildingText(meteorOutlook))
                        .font(.subheadline)
                }
                Text(PhraseBank.skyMeteor(
                    interference: meteorOutlook.moonInterference,
                    date: date,
                    locationId: location.id,
                    tokens: ["shower": meteorOutlook.shower.name]
                ))
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 8)
    }

    /// "100/hr on paper; the moon says closer to 15 — bright moon washing out the faint ones." —
    /// the "estimated-vs-theoretical honesty" the work order asks for. Collapses to a single
    /// number (no "on paper vs. actual" split) on the rare night the two numbers round the same,
    /// since restating an identical figure twice reads as a bug, not honesty.
    private static func meteorRateText(_ outlook: MeteorShowers.MeteorOutlook) -> String {
        let theoretical = Int(outlook.theoreticalZHR.rounded())
        let estimated = Int(outlook.estimatedVisiblePerHour.rounded())
        let interferenceNote: String
        switch outlook.moonInterference {
        case .none: interferenceNote = "moon mostly out of the way"
        case .some: interferenceNote = "some moonlight cutting into the count"
        case .severe: interferenceNote = "bright moon washing out the faint ones"
        }
        if theoretical == estimated {
            return "\(theoretical)/hr, \(interferenceNote)."
        }
        return "\(theoretical)/hr on paper; the moon says closer to \(estimated) — \(interferenceNote)."
    }

    /// "Perseids active, building toward Aug 12." — the quieter single line for a non-peak active
    /// night (work-order example).
    private static func meteorBuildingText(_ outlook: MeteorShowers.MeteorOutlook) -> String {
        let verb = outlook.daysFromPeak < 0 ? "building toward" : "fading from"
        return "\(outlook.shower.name) active, \(verb) \(Self.peakDateText(outlook.shower.peak))."
    }

    private static func peakDateText(_ monthDay: MeteorShowers.MonthDay) -> String {
        var components = DateComponents()
        components.year = 2001
        components.month = monthDay.month
        components.day = monthDay.day
        guard let peakDate = Calendar(identifier: .gregorian).date(from: components) else { return "" }
        return Self.monthDayFormatter.string(from: peakDate)
    }

    private static let monthDayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d"
        return formatter
    }()

    // MARK: - ISS

    @ViewBuilder
    private var issRow: some View {
        switch issState {
        case .loading:
            skeletonLine
        case .unavailable:
            unavailableRow(label: "ISS", note: "ISS pass data unavailable right now.")
        case .available(let passes):
            if passes.isEmpty {
                Text(PhraseBank.skyNoISS(date: date, locationId: location.id))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(passes.prefix(2).enumerated()), id: \.offset) { _, pass in
                        Text(Self.issPassText(pass))
                            .font(.subheadline)
                            .monospacedDigit()
                    }
                    Text(PhraseBank.skyISSPass(date: date, locationId: location.id))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 8)
            }
        }
    }

    /// "9:42 PM · WNW→ESE · 4 min · bright" — PRD-specified row format.
    private static func issPassText(_ pass: ISSPass) -> String {
        let durationMinutes = max(1, Int((pass.endTime.timeIntervalSince(pass.startTime) / 60.0).rounded()))
        return "\(timeFormatter.string(from: pass.startTime)) · \(pass.startAzimuthCompass)→\(pass.endAzimuthCompass) · \(durationMinutes) min · \(pass.brightness.rawValue)"
    }

    // MARK: - Conjunction

    /// Only rendered when `pairings` (tightest-separation first, see
    /// `Conjunctions.closePairings`'s doc comment) is non-empty — `body` passes `pairings.first`,
    /// tonight's single closest pairing, and gates the row + its preceding `Divider()` on it
    /// existing at all.
    private func conjunctionRow(_ pairing: Conjunctions.Pairing) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text("\(pairing.bodyA.displayName)-\(pairing.bodyB.displayName)")
                    .font(.subheadline.weight(.semibold))
                Spacer(minLength: 8)
                Text(Self.timeFormatter.string(from: pairing.bestViewingTime))
                    .font(.footnote)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Text(Self.conjunctionDetailText(pairing))
                .font(.footnote)
                .foregroundStyle(.secondary)
            Text(PhraseBank.skyPairing(date: date, locationId: location.id))
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 8)
    }

    /// "1.3° apart — about a thumb's width at arm's length, high in the SSW."
    private static func conjunctionDetailText(_ pairing: Conjunctions.Pairing) -> String {
        let separation = String(format: "%.1f", pairing.separationDegrees)
        return "\(separation)° apart — \(Self.everydayScaleDescription(pairing.separationDegrees)), \(pairing.directionDescription)"
    }

    /// Everyday-scale translation helper for an angular separation, held at arm's length (work
    /// order): under 1° ≈ a pinky-tip's width, 1-3° ≈ a thumb's width, 3-5° ≈ three fingers.
    /// Above 5° never reaches this row (`Conjunctions`' own thresholds — 5° for Moon-planet, 3°
    /// for planet-planet — gate what counts as "close" before it ever gets here), so that band
    /// only exists as a defensive fallback, not a case this row is expected to actually hit.
    private static func everydayScaleDescription(_ degrees: Double) -> String {
        switch degrees {
        case ..<1: return "about a pinky-tip's width at arm's length"
        case 1..<3: return "about a thumb's width at arm's length"
        case 3..<5: return "about three fingers at arm's length"
        default: return "easily fitting in the same binocular view"
        }
    }

    // MARK: - Sky note

    private var factRow: some View {
        Text(SkyFacts.tonight(date: date, locationId: location.id))
            .font(.footnote)
            .foregroundStyle(.secondary)
            .padding(.vertical, 8)
    }

    // MARK: - Shared row chrome

    private func unavailableRow(label: String, note: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text("—")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Text(note)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 8)
    }

    /// A single redacted-placeholder line for an async row still resolving (`.loading`).
    private var skeletonLine: some View {
        RoundedRectangle(cornerRadius: 6)
            .fill(Color(.tertiarySystemFill))
            .frame(height: 16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 8)
    }

    /// Full-card skeleton — only shown in the (normally near-instantaneous, since astronomy is
    /// synchronous) moment before `astronomy` has been set at all.
    private var skeletonRows: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(0..<4, id: \.self) { _ in
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(.tertiarySystemFill))
                    .frame(height: 16)
            }
        }
        .padding(.vertical, 8)
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        return formatter
    }()
}
