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
///
/// **Editor's-Choice sky-surfaces elevation ("the night panel"):** this is the one inverted card
/// in the app — a deep-indigo background in BOTH light and dark mode, starlight-white text, a
/// static (non-animated) star-speck backdrop. Every color here is therefore an explicit white/
/// white-opacity/planet-color value rather than `.primary`/`.secondary`/system fills, which would
/// resolve to the wrong (dark) ink against this card's always-dark background. `SheetCard` is
/// deliberately NOT used here for that reason — this card's chrome (background, divider color,
/// header opacity) is bespoke; every other card in the app keeps using `SheetCard` unchanged.
struct TonightSkyCard: View {
    let location: SavedLocation
    let date: Date
    /// Engine-integration work package: the location's 7(ish)-day daily forecast, fed straight
    /// through to `BestNight.outlook(dailyForecast:...)` for the "BEST NIGHT THIS WEEK" row.
    /// Defaulted to empty so every existing call site/preview keeps compiling unchanged — an
    /// empty array simply hides that row (see `bestNightOutlook`'s doc comment).
    var dailyForecast: [DailyEntry] = []
    var forcedOverrides: SkyTonightService.ForcedOverrides? = nil
    /// Forecast-surface overhaul, work item 4: tap-to-explain wiring for the ISS section's
    /// `info.circle` button. Defaulted so every existing call site/preview keeps compiling
    /// unchanged (a no-op tap).
    var onExplain: (ExplainerContent) -> Void = { _ in }
    /// Notifications work package: fired at the end of every `load()` with this card's own
    /// `location` — this is the "hook where `SkyTonightService` resolves passes"
    /// `SkyNotificationScheduler`'s own doc comment refers to. Only the location is passed (not
    /// the resolved `State`): `SkyNotificationScheduler.refreshISS` needs BOTH tonight's and
    /// tomorrow night's passes, but this card only ever loads tonight's, so the scheduler always
    /// re-derives what it needs itself (a cheap in-memory-cache hit for "tonight," since this
    /// card just resolved exactly that) rather than being handed a partial result here. Every
    /// page's card fires this (each saved location gets its own `TonightSkyCard`, and
    /// `TabView(.page)` keeps every page mounted, not just the active one — see
    /// `ForecastView.pagerView`'s doc comment), so the caller (ultimately `NavigationShell`) is
    /// responsible for filtering to whichever location it actually cares about (the first saved
    /// location, per the notifications work order) rather than this view knowing anything about
    /// "which location is the notification location." Defaulted to a no-op so every existing call
    /// site/preview keeps compiling unchanged.
    var onSkyStateResolved: (SavedLocation) -> Void = { _ in }
    /// Sky Finder work package: fired by every "Find" ghost-button (planet/moon/satellite rows)
    /// and the header's `scope` free-explore button (`nil` kind). Defaulted to a no-op so every
    /// existing call site/preview keeps compiling unchanged.
    var onOpenFinder: (SkyFinderTarget.Kind?) -> Void = { _ in }

    @State private var astronomy: SkyTonight.TonightSky?
    @State private var issState: SkyTonightService.SectionState<[ISSPass]> = .loading
    @State private var auroraState: SkyTonightService.SectionState<AuroraOutlook> = .loading
    /// SATELLITES section (engine-integration work package): ISS + Hubble + Tiangong + any
    /// discovered Starlink trains, merged and sorted soonest-first. Separate from `issState`
    /// above, which stays ISS-only and keeps feeding the headline exactly as before.
    @State private var satellitesState: SkyTonightService.SectionState<[SatellitePass]> = .loading
    @State private var meteorOutlook: MeteorShowers.MeteorOutlook?
    @State private var pairings: [Conjunctions.Pairing] = []
    @State private var bestMoment: BestMoment.SkyMoment?
    @State private var expandedPlanet: Planets.Body?
    /// Tonight's civil-dusk -> tomorrow-dawn window for the timeline strip. `nil` on the (rare,
    /// polar-latitude) occasions `SkyTonightService.duskDawnWindow` can't resolve both edges —
    /// the strip is simply omitted in that case (spec: "hide the strip gracefully").
    @State private var duskDawnWindow: DateInterval?
    /// People-in-Space row (Tonight's Sky card work package): shared app-wide, not per-location —
    /// see `PeopleInSpaceStore`'s own doc comment for why this is a plain reference to an
    /// `@Observable` singleton rather than a per-card fetch.
    private let peopleStore = PeopleInSpaceStore.shared
    @State private var isPresentingPeopleSheet = false
    /// Sky Finder work package: the JOURNAL row at the night panel's bottom.
    @State private var isPresentingJournal = false
    private let journalStore = SkyJournalStore.shared

    @Environment(\.colorScheme) private var colorScheme

    private var timeZone: TimeZone { .current }

    /// Sim-verify only: `-expandSkyPlanet mercury|venus|mars|jupiter|saturn` (see
    /// `NavigationShell`) pre-expands a planet row at launch — mirrors `-expandDay`'s rationale
    /// on `DailyForecastSection`: `simctl` can't tap through to an expanded row for a screenshot.
    /// Sim-verify only ("People in Space" work package): `-showPeopleSheet` — see
    /// `NavigationShell`'s doc comment. Mirrors `initialExpandedPlanet`'s pattern: `simctl` can't
    /// tap the row to open the sheet, so this reaches it directly at launch instead. The sheet
    /// itself only renders real content once `peopleStore.state` resolves to `.available` (see
    /// `body`'s `.sheet` modifier) — since `PeopleInSpaceStore` is `@Observable`, presenting the
    /// sheet before that fetch resolves just shows it empty for a moment, then it fills in with
    /// real data the instant the fetch completes, same as the live row does.
    init(
        location: SavedLocation,
        date: Date,
        dailyForecast: [DailyEntry] = [],
        forcedOverrides: SkyTonightService.ForcedOverrides? = nil,
        initialExpandedPlanet: Planets.Body? = nil,
        initialShowPeopleSheet: Bool = false,
        initialShowJournal: Bool = false,
        onExplain: @escaping (ExplainerContent) -> Void = { _ in },
        onSkyStateResolved: @escaping (SavedLocation) -> Void = { _ in },
        onOpenFinder: @escaping (SkyFinderTarget.Kind?) -> Void = { _ in }
    ) {
        self.location = location
        self.date = date
        self.dailyForecast = dailyForecast
        self.forcedOverrides = forcedOverrides
        self._expandedPlanet = State(initialValue: initialExpandedPlanet)
        self._isPresentingPeopleSheet = State(initialValue: initialShowPeopleSheet)
        self._isPresentingJournal = State(initialValue: initialShowJournal)
        self.onExplain = onExplain
        self.onSkyStateResolved = onSkyStateResolved
        self.onOpenFinder = onOpenFinder
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("TONIGHT'S SKY")
                    .font(.footnote.weight(.semibold))
                    .tracking(0.8)
                    .foregroundStyle(Color.white.opacity(0.55))
                Spacer()
                findItButton
                nightVisionQuickToggle
            }
            nightDivider
            VStack(alignment: .leading, spacing: 0) {
                if let astronomy {
                    if bestMoment != nil {
                        headlineRow
                    }
                    if let duskDawnWindow {
                        sectionHeader("TONIGHT'S TIMELINE")
                        timelineStrip(window: duskDawnWindow, astronomy: astronomy)
                            .padding(.vertical, 8)
                        nightDivider
                    }
                    // Engine-integration work package: BEST NIGHT THIS WEEK, right after the
                    // timeline section — hidden entirely when there's no daily forecast to build
                    // it from (`dailyForecast` defaults to empty for existing call sites).
                    if let bestNightOutlook {
                        sectionHeader("BEST NIGHT THIS WEEK")
                        bestNightRow(bestNightOutlook)
                        nightDivider
                    }
                    // Night panel UX pass: PLANETS moved directly under the timeline strip (was
                    // below the Moon row) so the strip's planet bars sit adjacent to their rows.
                    sectionHeader("PLANETS")
                    planetsSection(astronomy.planets)
                    nightDivider
                    sectionHeader("THE MOON")
                    moonRow(astronomy.moon)
                    nightDivider
                    sectionHeader("AURORA")
                    auroraRow
                    nightDivider
                    if meteorOutlook != nil {
                        sectionHeader("METEOR SHOWER")
                        meteorRow
                        nightDivider
                    }
                    sectionHeaderWithInfo("SATELLITES") { onExplain(Explainers.issPass) }
                    satellitesSection
                    peopleInSpaceRow
                    if let pairing = pairings.first {
                        nightDivider
                        conjunctionRow(pairing)
                    }
                    nightDivider
                    factRow
                    nightDivider
                    journalRow
                } else {
                    skeletonRows
                }
            }
        }
        .padding(16)
        .background(NightPanelBackground())
        // 16pt radius, matching `SheetCard.cornerRadius` — every other card in the app.
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        // A stronger shadow than `SheetCard`'s own (and shown in both color schemes, not just
        // light) — this card needs to visually "lift" off a light surrounding in light mode AND
        // off a dark surrounding in dark mode, since unlike every other card it never matches its
        // surroundings' luminance.
        .shadow(color: .black.opacity(colorScheme == .dark ? 0.35 : 0.18), radius: 14, y: 6)
        .id(Self.cardId)
        .task(id: taskKey) {
            await load()
        }
        .sheet(isPresented: $isPresentingPeopleSheet) {
            if case .available(let summary) = peopleStore.state {
                PeopleInSpaceSheet(summary: summary)
                    .nightVisionAware()
            }
        }
        .sheet(isPresented: $isPresentingJournal) {
            SkyJournalView(store: journalStore)
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
        // People-in-Space row: location-independent, so this only ever actually triggers a fetch
        // once app-wide (see `PeopleInSpaceStore.ensureLoaded`'s doc comment) — every other page's
        // card calling this is a no-op that just keeps observing the shared `peopleStore.state`.
        peopleStore.ensureLoaded()

        let astro = SkyTonightService.astronomy(latitude: location.latitude, longitude: location.longitude, date: date, timeZone: timeZone)
        astronomy = astro
        issState = .loading
        auroraState = .loading
        satellitesState = .loading
        duskDawnWindow = SkyTonightService.duskDawnWindow(
            latitude: location.latitude, longitude: location.longitude, date: date, timeZone: timeZone
        )

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
        satellitesState = result.satellites
        bestMoment = result.bestMoment

        // Sim-verify forced overrides (`-forceISSPass`, `-forceAuroraBand`, etc.) synthesize
        // data that doesn't reflect real conditions — never worth waking a real device over, so
        // this hook is skipped entirely whenever any override is active, mirroring how those
        // overrides already bypass `SkyTonightService`'s own cache.
        guard forcedOverrides?.isActive != true else { return }
        onSkyStateResolved(location)
    }

    // MARK: - Night Vision quick toggle

    /// Night Vision work package: the "no Settings trip" ingress — one tap flips
    /// `NightVisionMode.shared.enabled` from right inside the card whose whole reason for
    /// existing is "you're about to go outside and look at the sky." Mounted in the "TONIGHT'S
    /// SKY" header row's trailing side (this card's own top-right corner), not the "TONIGHT'S
    /// TIMELINE" sub-header, since the card-level header is visible immediately without scrolling
    /// past the headline row.
    // MARK: - Sky Finder ingress

    /// Free-explore ingress: the "TONIGHT'S SKY" header's `scope` button opens Sky Finder with no
    /// fixed target — mirrors `nightVisionQuickToggle`'s own placement/sizing conventions exactly
    /// so the two read as one small icon-button group.
    private var findItButton: some View {
        Button {
            onOpenFinder(nil)
        } label: {
            Image(systemName: "scope")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Color.white.opacity(0.55))
                .frame(width: 28, height: 28)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Open Sky Finder")
    }

    /// A small "Find" ghost-button, trailing on planet/moon/satellite rows — same visual weight
    /// as those rows' own chevron/info icons (`.footnote`, `Color.white.opacity(0.5)`), just a
    /// distinct glyph (`binoculars`) so it doesn't read as another disclosure chevron.
    private func findRowButton(muted: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "binoculars.fill")
                .font(.footnote)
                .foregroundStyle(Color.white.opacity(muted ? 0.3 : 0.6))
                .frame(width: 28, height: 28)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Find with Sky Finder")
    }

    private var nightVisionQuickToggle: some View {
        Button {
            NightVisionMode.shared.enabled.toggle()
        } label: {
            Image(systemName: NightVisionMode.shared.enabled ? "eye.fill" : "eye")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(NightVisionMode.shared.enabled ? Color(red: 1.0, green: 0.35, blue: 0.3) : Color.white.opacity(0.55))
                .frame(width: 28, height: 28)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(NightVisionMode.shared.enabled ? "Turn off Night Vision" : "Turn on Night Vision")
    }

    // MARK: - Night panel chrome

    /// Hairline row separator — `Color.white.opacity(0.12)` per spec, replacing `Divider()`
    /// (which resolves to a light-mode-oriented system color that would be nearly invisible
    /// against this card's always-dark background). Night panel UX pass: ~14pt vertical padding
    /// (up from none) so sections get more breathing room between them.
    private var nightDivider: some View {
        Rectangle()
            .fill(Color.white.opacity(0.12))
            .frame(height: 1)
            .padding(.vertical, 14)
    }

    /// Space-first design batch, item 3: a small-caps mini-header above each section, in the
    /// exact style `factRow`'s pre-existing "SPACE FACT" label already established (`.footnote`
    /// semibold, tracked, white 0.55). Deliberately no top padding of its own — the preceding
    /// `nightDivider`'s own `.padding(.vertical, 14)` already supplies the "~14pt above it" gap;
    /// this only adds the "~4pt below it" gap to its own content, mirroring `factRow`'s internal
    /// `spacing: 4` between its own header and fact line.
    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.footnote.weight(.semibold))
            .tracking(0.8)
            .foregroundStyle(Color.white.opacity(0.55))
            .padding(.bottom, 4)
    }

    /// Same mini-header styling as `sectionHeader`, plus a trailing ⓘ button — SATELLITES work
    /// item 2: the tap-to-explain affordance moves off the individual pass rows (which are now
    /// tappable to open `PeopleInSpaceSheet` for station passes) and onto this single
    /// section-level icon instead.
    private func sectionHeaderWithInfo(_ title: String, onInfoTap: @escaping () -> Void) -> some View {
        HStack {
            Text(title)
                .font(.footnote.weight(.semibold))
                .tracking(0.8)
                .foregroundStyle(Color.white.opacity(0.55))
            Spacer()
            Button(action: onInfoTap) {
                Image(systemName: "info.circle")
                    .font(.footnote)
                    .foregroundStyle(Color.white.opacity(0.5))
            }
            .buttonStyle(.plain)
        }
        .padding(.bottom, 4)
    }

    // MARK: - Headline

    /// "Step outside at 9:42 PM" + one factual subtitle line naming the moment. Hidden entirely
    /// when `bestMoment` is `nil` (per work order: "don't manufacture" a headline) — the `if let`
    /// in `body` already gates this, so this computed view can assume `bestMoment` is non-nil.
    private var headlineRow: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "sparkles")
                .font(.subheadline)
                .foregroundStyle(Color.clearSkyAccentOnDark)
                .padding(.top, 3)
            VStack(alignment: .leading, spacing: 4) {
                if let bestMoment {
                    Text("Step outside at \(Self.timeFormatter.string(from: bestMoment.time))")
                        .font(.system(.title3, design: .rounded).weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                    Text(Self.headlineSubtitle(bestMoment.kind))
                        .font(.subheadline)
                        .foregroundStyle(Color.white.opacity(0.65))
                    // Night panel UX pass: the fuller "Step outside" explanation beneath the
                    // headline's own treatment — `TonightHeadline.detailText` renders the exact
                    // same fact `bestMoment.kind` already names above, so this is always
                    // consistent with the headline text itself (see that function's doc comment
                    // on why it takes `bestMoment.kind` directly rather than re-deriving via
                    // `TonightHeadline.generate`, which could independently pick a different
                    // fact for the quieter tiers).
                    Text(TonightHeadline.detailText(for: bestMoment.kind, timeZone: timeZone))
                        .font(.subheadline)
                        .foregroundStyle(Color.white.opacity(0.75))
                }
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

    // MARK: - Best night this week

    /// Which of the next 7 nights (starting tonight) rates best, built from `dailyForecast` via
    /// `BestNight.outlook`/`BestNight.bestNight(among:)`. `nil` — hiding the row entirely — when
    /// there's no daily forecast to build it from (the default empty `dailyForecast` every
    /// existing call site/preview still compiles with). Cheap, synchronous, pure math (same as
    /// `BestNight`'s own doc comment on why it's fine to recompute per render), so this is a
    /// computed property rather than `@State` set from `load()` — it stays correct even if a
    /// parent re-renders this card with fresh `dailyForecast` data without the location/date
    /// (and therefore `taskKey`) changing.
    private var bestNightOutlook: BestNight.NightOutlook? {
        guard !dailyForecast.isEmpty else { return nil }
        let inputs = dailyForecast.map {
            BestNight.NightlyForecastInput(date: $0.date, conditionCode: $0.conditionCode, precipChance: $0.precipChance)
        }
        let nights = BestNight.outlook(
            dailyForecast: inputs,
            latitude: location.latitude,
            longitude: location.longitude,
            timeZone: timeZone,
            now: date
        )
        return BestNight.bestNight(among: nights)
    }

    /// "Thursday looks best — clear and moonless, 9/10." / "Tonight is the best night this week —
    /// 8/10." — tapping opens the Stargazing Score explainer, extended with a paragraph
    /// explaining this row specifically (see `Explainers.stargazingScore`).
    private func bestNightRow(_ outlook: BestNight.NightOutlook) -> some View {
        Button {
            onExplain(Explainers.stargazingScore())
        } label: {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "star.fill")
                    .font(.footnote)
                    .foregroundStyle(Color.clearSkyAccentOnDark)
                    .padding(.top, 3)
                Text(Self.bestNightText(outlook, now: date, timeZone: timeZone))
                    .font(.subheadline)
                    .foregroundStyle(.white)
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(Color.white.opacity(0.4))
            }
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableRowStyle())
    }

    private static func bestNightText(_ outlook: BestNight.NightOutlook, now: Date, timeZone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        if calendar.isDate(outlook.date, inSameDayAs: now) {
            return "Tonight is the best night this week — \(outlook.rating)/10."
        }
        let weekday = Self.weekdayFormatter.string(from: outlook.date)
        let descriptor = Self.limitingFactorDescriptor(outlook.limitingFactor)
        return "\(weekday) looks best — \(descriptor), \(outlook.rating)/10."
    }

    private static func limitingFactorDescriptor(_ factor: BestNight.LimitingFactor) -> String {
        switch factor {
        case .none: return "clear and moonless"
        case .clouds: return "some cloud in the way"
        case .moon: return "bright moon washing things out"
        }
    }

    private static let weekdayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE"
        return formatter
    }()

    // MARK: - Dusk-to-dawn timeline strip

    /// Selects up to 3 planet bars for the strip, brightest (most negative apparent magnitude)
    /// first — spec: "stacked in thin rows below the track (max 3 rows; if more planets, keep
    /// the 3 brightest)". Only planets with a real best-viewing window (both edges non-`nil`,
    /// non-degenerate) are eligible, same "is there actually a window to draw" bar
    /// `planetRow`/`planetsSection` already apply.
    private static func timelinePlanetBars(_ planets: [SkyTonight.PlanetVisibility]) -> [NightSkyTimelineStrip.PlanetBar] {
        planets
            .filter(\.isVisibleTonight)
            .compactMap { planet -> (planet: SkyTonight.PlanetVisibility, start: Date, end: Date)? in
                guard let start = planet.bestViewingStart, let end = planet.bestViewingEnd, end > start else { return nil }
                return (planet, start, end)
            }
            .sorted { ($0.planet.apparentMagnitude ?? 99) < ($1.planet.apparentMagnitude ?? 99) }
            .prefix(3)
            .map { NightSkyTimelineStrip.PlanetBar(body: $0.planet.body, start: $0.start, end: $0.end) }
    }

    /// ISS pass start times to tick on the strip's main track — every resolved pass, not just the
    /// (at most 2) the ISS row itself lists, since the strip has room for more than 2 marks.
    private var issPassTimesForStrip: [Date] {
        guard case .available(let passes) = issState else { return [] }
        return passes.map(\.startTime)
    }

    /// The aurora band to wash over the track, only when it clears `.fair` (spec: "Aurora best
    /// window when band >= .fair") — a `.none`/`.low` night draws no band at all, matching the
    /// aurora row's own "not worth mentioning" bar for those two levels.
    private var auroraWindowForStrip: DateInterval? {
        guard case .available(let outlook) = auroraState, outlook.band >= .fair else { return nil }
        return outlook.bestViewingWindow
    }

    private func timelineStrip(window: DateInterval, astronomy: SkyTonight.TonightSky) -> some View {
        NightSkyTimelineStrip(
            window: window,
            moonRise: astronomy.moon.rise,
            moonSet: astronomy.moon.set,
            planetBars: Self.timelinePlanetBars(astronomy.planets),
            issPassTimes: issPassTimesForStrip,
            auroraWindow: auroraWindowForStrip,
            now: Date(),
            timeZone: timeZone
        )
    }

    // MARK: - Moon

    private func moonRow(_ moon: SkyTonight.MoonInfo) -> some View {
        let quarter = Self.moonQuarter(illuminatedPercent: moon.illuminatedPercent, phaseFraction: moon.phaseFraction)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 12) {
                MoonPhaseDisc(illumination: moon.illuminatedPercent / 100, waxing: moon.waxing, diameter: 28, style: .dark)

                VStack(alignment: .leading, spacing: 2) {
                    Text(Self.moonPhaseName(phaseFraction: moon.phaseFraction))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                    Text(Self.moonRiseSetText(moon))
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(Color.white.opacity(0.65))
                }

                Spacer()

                Text("\(Int(moon.illuminatedPercent.rounded()))%")
                    .font(.subheadline)
                    .monospacedDigit()
                    .foregroundStyle(Color.white.opacity(0.65))

                findRowButton { onOpenFinder(.moon()) }
            }

            Text(PhraseBank.skyMoon(quarter: quarter, date: date, locationId: location.id))
                .font(.footnote)
                .foregroundStyle(Color.white.opacity(0.65))
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
                    .foregroundStyle(Color.white.opacity(0.65))
                    .padding(.vertical, 8)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(visible.enumerated()), id: \.element.body) { index, planet in
                        planetRow(planet)
                        if index < visible.count - 1 {
                            nightDivider
                        }
                    }
                }
            }
        }
    }

    private func planetRow(_ planet: SkyTonight.PlanetVisibility) -> some View {
        let isExpanded = expandedPlanet == planet.body
        let color = TrueSkyLayer.dotColor(for: planet.body)
        return VStack(spacing: 0) {
            HStack(spacing: 2) {
                Button {
                    // Same spring + inline-fade mechanism as `DailyForecastRow.onTap`.
                    withAnimation(.spring(duration: 0.35)) {
                        expandedPlanet = (expandedPlanet == planet.body) ? nil : planet.body
                    }
                } label: {
                    HStack(spacing: 10) {
                        // Leading colored dot + glow (spec item 3) — the same `TrueSkyLayer` color
                        // this planet renders as in the true-sky doodle, so the two surfaces agree.
                        Circle()
                            .fill(color)
                            .frame(width: 10, height: 10)
                            .shadow(color: color.opacity(0.9), radius: 4)

                        Text(planet.body.displayName)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white)
                            .frame(width: 62, alignment: .leading)

                        Text(planet.directionDescription ?? "")
                            .font(.footnote)
                            .foregroundStyle(Color.white.opacity(0.65))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)

                        Spacer(minLength: 8)

                        if let start = planet.bestViewingStart, let end = planet.bestViewingEnd {
                            Text(Self.windowText(start: start, end: end))
                                .font(.footnote)
                                .monospacedDigit()
                                .foregroundStyle(Color.white.opacity(0.65))
                        }

                        Image(systemName: "chevron.down")
                            .font(.caption2)
                            .foregroundStyle(Color.white.opacity(0.4))
                            .rotationEffect(.degrees(isExpanded ? 180 : 0))
                    }
                    .padding(.vertical, 8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(PressableRowStyle())

                // Sky Finder work package: a SIBLING of the row's own expand `Button`, not
                // nested inside it — two overlapping `Button`s fighting over the same tap is a
                // known SwiftUI hit-testing footgun; keeping this outside the expand button's own
                // label avoids it entirely while still reading as "trailing on the row."
                findRowButton { onOpenFinder(.planet(planet.body)) }
            }

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
                .foregroundStyle(.white)

            if let magnitude = planet.apparentMagnitude {
                Text(Self.magnitudeDescription(magnitude))
                    .font(.footnote)
                    .foregroundStyle(Color.white.opacity(0.65))
            }

            Text(PhraseBank.skyPlanet(planet.body, date: date, locationId: location.id))
                .font(.footnote)
                .foregroundStyle(Color.white.opacity(0.65))
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
                    .foregroundStyle(Color.white.opacity(0.65))
                    .padding(.vertical, 8)
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    Text(Self.auroraHeadline(outlook))
                        .font(.subheadline)
                        .monospacedDigit()
                        .foregroundStyle(.white)
                    Text(PhraseBank.skyAurora(band: outlook.band, date: date, locationId: location.id))
                        .font(.footnote)
                        .foregroundStyle(Color.white.opacity(0.65))
                }
                .padding(.vertical, 8)
            }
        }
    }

    /// "Aurora: fair chance · best 11 PM–1 AM" (+ "· 22% chance right now" only when `chanceNow`
    /// clears 5%, per the PRD's "avoid fake precision" note).
    private static func auroraHeadline(_ outlook: AuroraOutlook) -> String {
        var parts = ["Aurora: \(outlook.band.description) chance"]
        parts.append("best \(timeFormatter.string(from: outlook.bestViewingWindow.start))–\(timeFormatter.string(from: outlook.bestViewingWindow.end))")
        if outlook.chanceNow >= 5 {
            // Night panel UX pass ("non-nerd sweep"): "45% now" -> "45% chance right now".
            parts.append("\(outlook.chanceNow)% chance right now")
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
                            .foregroundStyle(.white)
                        Spacer(minLength: 8)
                        Text(Self.windowText(start: meteorOutlook.bestWindow.start, end: meteorOutlook.bestWindow.end))
                            .font(.footnote)
                            .monospacedDigit()
                            .foregroundStyle(Color.white.opacity(0.65))
                    }
                    Text(Self.meteorRateText(meteorOutlook))
                        .font(.footnote)
                        .foregroundStyle(Color.white.opacity(0.65))
                } else {
                    Text(Self.meteorBuildingText(meteorOutlook))
                        .font(.subheadline)
                        .foregroundStyle(.white)
                }
                Text(Self.meteorSecondaryLine(meteorOutlook, date: date, location: location, timeZone: timeZone))
                .font(.footnote)
                .foregroundStyle(Color.white.opacity(0.65))
            }
        }
        .padding(.vertical, 8)
    }

    /// The shower row's secondary line, PhraseBank's own moon-washout sentence with the radiant
    /// direction appended — "…Look northeast after 1 AM." (meteor-radiant work item). The
    /// direction is evaluated at 1 AM local time on tonight's date (the work order's own
    /// suggested moment, per `MeteorShowers.radiantDirectionOnPeakNight`'s doc comment on why
    /// that's when a radiant's altitude is typically climbing toward its best) rather than that
    /// shower's fixed textbook peak calendar day, since this row renders on every active night,
    /// not just the peak.
    private static func meteorSecondaryLine(_ outlook: MeteorShowers.MeteorOutlook, date: Date, location: SavedLocation, timeZone: TimeZone) -> String {
        let base = PhraseBank.skyMeteor(
            interference: outlook.moonInterference,
            date: date,
            locationId: location.id,
            tokens: ["shower": outlook.shower.name]
        )
        guard let radiant = Self.radiantDirectionTonight(
            shower: outlook.shower, date: date, latitude: location.latitude, longitude: location.longitude, timeZone: timeZone
        ) else {
            return base
        }
        return "\(base) Look \(TonightHeadline.compassWord(radiant.compass)) after 1 AM."
    }

    /// The shower's radiant compass/altitude at 1 AM local on tonight's calendar night (evening
    /// of `date` -> the following morning) — see `MeteorShowers.radiantDirection`'s doc comment
    /// for the underlying transform.
    private static func radiantDirectionTonight(
        shower: MeteorShowers.MeteorShower, date: Date, latitude: Double, longitude: Double, timeZone: TimeZone
    ) -> (compass: String, altitudeQualitative: String)? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let dayStart = calendar.startOfDay(for: date)
        guard let nextDay = calendar.date(byAdding: .day, value: 1, to: dayStart),
              let oneAM = calendar.date(byAdding: .hour, value: 1, to: nextDay) else { return nil }
        return MeteorShowers.radiantDirection(shower: shower, date: oneAM, lat: latitude, lon: longitude)
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

    // MARK: - Satellites

    /// SATELLITES section body (engine-integration work package): up to 4 pass rows, soonest
    /// first (`SatellitesTonight.passes(satellites:...)` already returns them sorted that way), a
    /// quiet "+N more tonight" line if there are more, and the explainer moved off the individual
    /// rows onto the section header's ⓘ (see `sectionHeaderWithInfo`).
    private static let maxSatelliteRows = 4

    @ViewBuilder
    private var satellitesSection: some View {
        switch satellitesState {
        case .loading:
            skeletonLine
        case .unavailable:
            unavailableRow(label: "Satellites", note: "Satellite pass data unavailable right now.")
        case .available(let passes):
            if passes.isEmpty {
                Text("No satellite passes visible tonight.")
                    .font(.footnote)
                    .foregroundStyle(Color.white.opacity(0.65))
                    .padding(.vertical, 8)
            } else {
                let shown = Array(passes.prefix(Self.maxSatelliteRows))
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(shown.enumerated()), id: \.offset) { index, pass in
                        satelliteRow(pass)
                        if index < shown.count - 1 {
                            nightDivider
                        }
                    }
                    if passes.count > shown.count {
                        Text("+\(passes.count - shown.count) more tonight")
                            .font(.footnote)
                            .foregroundStyle(Color.white.opacity(0.5))
                            .padding(.top, 4)
                    }
                }
            }
        }
    }

    /// One tracked-satellite pass row: glyph, name + start time, direction + brightness note.
    /// ISS↔crew link (work item 2): a station pass (ISS or Tiangong) is a `Button` that opens
    /// `PeopleInSpaceSheet` — Hubble and Starlink-train rows aren't crew-linked, so they stay
    /// plain (non-tappable) content rows.
    private func satelliteRow(_ satellitePass: SatellitePass) -> some View {
        let isStation = satellitePass.satellite.kind == .iss || satellitePass.satellite.kind == .tiangong
        let content = HStack(alignment: .top, spacing: 10) {
            satelliteGlyph(for: satellitePass.satellite)
                .foregroundStyle(.white.opacity(0.85))
                .padding(.top, 5)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(satellitePass.satellite.name)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Text(Self.timeFormatter.string(from: satellitePass.pass.startTime))
                        .font(.footnote)
                        .monospacedDigit()
                        .foregroundStyle(Color.white.opacity(0.65))
                }
                Text("\(satellitePass.pass.startAzimuthCompass) → \(satellitePass.pass.endAzimuthCompass) · \(Self.brightnessSimile(satellitePass.pass.brightness))")
                    .font(.footnote)
                    .foregroundStyle(Color.white.opacity(0.65))
            }
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())

        return HStack(spacing: 2) {
            Group {
                if isStation {
                    Button {
                        isPresentingPeopleSheet = true
                    } label: {
                        content
                    }
                    .buttonStyle(PressableRowStyle())
                } else {
                    content
                }
            }

            // Sky Finder work package: a SIBLING of the station rows' own `Button` (see the
            // planet row's identical comment on why) — opens the finder targeting this pass
            // regardless of whether it's soon/current; `SkyFinderView` itself is what tells the
            // "actively tracking" story apart from the "not up yet — rises {time} in the {dir}"
            // one (see `SkyFinderTarget.isSatellitePassActive`/`riseWaitingText`), so this button
            // is never disabled — it always opens Sky Finder, just to a different initial state.
            findRowButton { onOpenFinder(.satellite(satellitePass)) }
        }
    }

    /// "Reuse ISSGlyph for stations, a simple dot-line glyph for trains" (spec) — Hubble (a lone
    /// satellite, not a train) gets the same dot-line glyph with a single dot.
    @ViewBuilder
    private func satelliteGlyph(for satellite: TrackedSatellite) -> some View {
        switch satellite.kind {
        case .iss, .tiangong:
            ISSGlyph()
        case .hubble:
            SatelliteDotGlyph(dotCount: 1)
        case .starlinkTrain:
            SatelliteDotGlyph(dotCount: min(max(satellite.memberCount, 3), 5))
        }
    }

    /// Brightness similes replacing the raw `ISSBrightness` class words (spec): bright -> "as
    /// bright as the brightest star", moderate -> "easy to spot if you're looking", dim ->
    /// "faint — easier from somewhere dark".
    private static func brightnessSimile(_ brightness: ISSBrightness) -> String {
        switch brightness {
        case .bright: return "As bright as the brightest star in the sky."
        case .moderate: return "Easy to spot if you're looking."
        case .dim: return "Faint — easier to see from somewhere dark."
        }
    }

    // MARK: - People in space

    /// "N people in space right now" (Tonight's Sky card work package), directly after the
    /// SATELLITES section — live count from the app-wide `PeopleInSpaceStore`, chevron to
    /// `PeopleInSpaceSheet`. Deliberately quieter than the network rows above it: `.loading` shows
    /// a skeleton (same as `satellitesSection`/`auroraRow`), but `.unavailable` renders nothing at all — no
    /// "—" row, no divider — per work order ("it's supplementary; document"). This is
    /// supplementary trivia layered on top of the night panel's core sky-observing content, not a
    /// core row users depend on the way ISS/aurora are, so a quiet omission on failure is more
    /// honest than manufacturing a placeholder for it.
    @ViewBuilder
    private var peopleInSpaceRow: some View {
        switch peopleStore.state {
        case .loading:
            nightDivider
            skeletonLine
        case .unavailable:
            EmptyView()
        case .available(let summary):
            nightDivider
            Button {
                isPresentingPeopleSheet = true
            } label: {
                HStack(spacing: 10) {
                    // Space-first design batch, item 4: the "SPACE STATION" section header now
                    // groups this row with the ISS pass row directly above it, so both use the
                    // same ISS glyph as their leading icon rather than a generic person icon.
                    ISSGlyph()
                        .foregroundStyle(.white.opacity(0.85))
                    Text("\(summary.count) people in space right now")
                        .font(.subheadline)
                        .monospacedDigit()
                        .foregroundStyle(.white)
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(Color.white.opacity(0.4))
                }
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(PressableRowStyle())
        }
    }

    // MARK: - Conjunction

    /// Only rendered when `pairings` (tightest-separation first, see
    /// `Conjunctions.closePairings`'s doc comment) is non-empty — `body` passes `pairings.first`,
    /// tonight's single closest pairing, and gates the row + its preceding divider on it existing
    /// at all.
    private func conjunctionRow(_ pairing: Conjunctions.Pairing) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text("\(pairing.bodyA.displayName)-\(pairing.bodyB.displayName)")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                Spacer(minLength: 8)
                Text(Self.timeFormatter.string(from: pairing.bestViewingTime))
                    .font(.footnote)
                    .monospacedDigit()
                    .foregroundStyle(Color.white.opacity(0.65))
            }
            Text(Self.conjunctionDetailText(pairing))
                .font(.footnote)
                .foregroundStyle(Color.white.opacity(0.65))
            Text(PhraseBank.skyPairing(date: date, locationId: location.id))
                .font(.footnote)
                .foregroundStyle(Color.white.opacity(0.65))
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

    /// Night panel UX pass: a "SPACE FACT" mini-label above the fact line, matching the card's
    /// own "TONIGHT'S SKY" header treatment (footnote semibold, tracked, white 0.55) at a
    /// smaller scope.
    private var factRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("SPACE FACT")
                .font(.footnote.weight(.semibold))
                .tracking(0.8)
                .foregroundStyle(Color.white.opacity(0.55))
            Text(SkyFacts.tonight(date: date, locationId: location.id))
                .font(.footnote)
                .foregroundStyle(Color.white.opacity(0.65))
        }
        .padding(.vertical, 8)
    }

    // MARK: - Sky Journal row

    /// Sky Finder work package: the night panel's own JOURNAL row, at the very bottom — a book
    /// icon + live tally, mirroring `peopleInSpaceRow`'s row shape/chevron convention.
    private var journalRow: some View {
        Button {
            isPresentingJournal = true
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "book.closed.fill")
                    .foregroundStyle(.white.opacity(0.85))
                Text("JOURNAL")
                    .font(.footnote.weight(.semibold))
                    .tracking(0.8)
                    .foregroundStyle(Color.white.opacity(0.55))
                Spacer(minLength: 8)
                Text("\(journalStore.planetsFoundCount) of 5 planets found")
                    .font(.subheadline)
                    .foregroundStyle(Color.white.opacity(0.65))
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(Color.white.opacity(0.4))
            }
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableRowStyle())
    }

    // MARK: - Shared row chrome

    private func unavailableRow(label: String, note: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                Spacer()
                Text("—")
                    .font(.subheadline)
                    .foregroundStyle(Color.white.opacity(0.65))
            }
            Text(note)
                .font(.caption)
                .foregroundStyle(Color.white.opacity(0.5))
        }
        .padding(.vertical, 8)
    }

    /// A single redacted-placeholder line for an async row still resolving (`.loading`).
    private var skeletonLine: some View {
        RoundedRectangle(cornerRadius: 6)
            .fill(Color.white.opacity(0.12))
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
                    .fill(Color.white.opacity(0.12))
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

/// SATELLITES section glyph for non-station tracked objects (spec: "a simple dot-line glyph for
/// trains"): several small dots on a faint connecting line for a Starlink train, or a single
/// centered dot (no line) for a lone satellite like Hubble. Sized to `ISSGlyph.nominalSize` so
/// every satellite row's leading glyph column lines up regardless of which glyph it renders.
private struct SatelliteDotGlyph: View {
    var dotCount: Int = 1

    var body: some View {
        ZStack {
            if dotCount > 1 {
                Rectangle()
                    .fill(Color.white.opacity(0.3))
                    .frame(height: 1)
            }
            HStack(spacing: 0) {
                ForEach(0..<max(dotCount, 1), id: \.self) { index in
                    Circle()
                        .fill(Color.white.opacity(0.85))
                        .frame(width: 4, height: 4)
                    if index < dotCount - 1 {
                        Spacer(minLength: 0)
                    }
                }
            }
        }
        .frame(width: ISSGlyph.nominalSize.width, height: ISSGlyph.nominalSize.height)
    }
}

/// The night panel's signature deep-indigo gradient plus a fixed set of tiny static star specks —
/// deliberately NOT animated (spec: "NO animation — static"), unlike the doodle hero's
/// `TwinkleStar` (`TimeOfDaySkyBackground`) — this is a compact card background sitting behind
/// live data, not a hero scene, so a busy twinkle loop here would compete with the rows on top of
/// it rather than read as atmosphere.
private struct NightPanelBackground: View {
    /// (xFraction, yFraction, diameter, opacity) — ~14 tiny dots, 1-2pt, 0.3-0.5 white opacity,
    /// per spec, at fixed positions (same "hand-placed constant array" pattern as
    /// `TimeOfDaySkyBackground.starPositions`).
    private static let starPositions: [(CGFloat, CGFloat, CGFloat, Double)] = [
        (0.05, 0.06, 1.5, 0.40), (0.14, 0.22, 1.0, 0.30), (0.22, 0.09, 1.5, 0.45),
        (0.31, 0.32, 1.0, 0.35), (0.40, 0.15, 1.5, 0.40), (0.52, 0.05, 1.0, 0.30),
        (0.61, 0.27, 1.5, 0.50), (0.70, 0.12, 1.0, 0.35), (0.79, 0.30, 1.5, 0.40),
        (0.88, 0.08, 1.0, 0.30), (0.93, 0.24, 1.5, 0.45), (0.10, 0.40, 1.0, 0.30),
        (0.46, 0.38, 1.5, 0.35), (0.83, 0.42, 1.0, 0.40),
    ]

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 13.0 / 255.0, green: 17.0 / 255.0, blue: 42.0 / 255.0),
                    Color(red: 24.0 / 255.0, green: 30.0 / 255.0, blue: 66.0 / 255.0),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            GeometryReader { proxy in
                ForEach(Array(Self.starPositions.enumerated()), id: \.offset) { _, star in
                    Circle()
                        .fill(Color.white.opacity(star.3))
                        .frame(width: star.2, height: star.2)
                        .position(x: proxy.size.width * star.0, y: proxy.size.height * star.1)
                }
            }
        }
    }
}
