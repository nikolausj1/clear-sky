import SwiftUI
import UIKit

/// Phase 5 ("Doodle layer system with programmatic placeholder layers") — PRD Section 7's full
/// five-layer grammar (base scene / season skin / weather condition / time-of-day lighting /
/// special-day overlay), resolved by `DoodleComposer` and painted by `DoodleSceneView`
/// (`Sources/Doodle/`).
///
/// **Public interface preserved from Phase 2:** `current` + `caption` remain the two
/// parameters every existing call site (`ForecastPageView`'s loading/error/empty states,
/// previews) passes — none of those needed to change. The additional parameters below
/// (`date`, `sunrise`, `sunset`, `forcedCondition`, `forcedTimeOfDay`) are all defaulted, purely
/// additive, and only exercised by the one call site that has real data + sim-verify forcing
/// to offer (`ForecastPageView.loadedView`) — see that file's `DoodleHeaderView(...)` call.
///
/// **UX redesign part 1 (hero header):** this view is now a full-bleed hero — it sizes itself to
/// roughly `heightFraction` of the screen height (including the status-bar region it extends
/// under; the actual safe-area bleed is handled by its host — `ForecastPageView`'s ScrollViews
/// and `ForecastView`'s TabView both apply `ignoresSafeArea(edges: .top)`, and both are needed:
/// see the comments at those two sites). When `current` is supplied it also overlays the big
/// condition-symbol + temperature + feels-like group that used to live in the standalone
/// `CurrentConditionsView` (removed — see that file's doc comment).
struct DoodleHeaderView: View {
    let current: CurrentConditions?
    /// Phase 4 fills this from the phrase bank. `nil` renders nothing.
    let caption: String?
    /// Date fed into `DoodleComposer` (season + special-day resolution). Defaults to "now";
    /// callers pass `viewModel.phraseBankDate` so `-forceDate` sim-verify screenshots move the
    /// doodle scene and the phrase-bank copy in lockstep.
    var date: Date = Date()
    /// Today's real sunrise/sunset, when known (`DailyEntry.sunrise`/`.sunset` for today) —
    /// sharpens `DoodleComposer`'s time-of-day resolution beyond the isDaylight+hour fallback.
    var sunrise: Date? = nil
    var sunset: Date? = nil
    /// Sim-verify hook: `-forceCondition clear|rain|snow|cloudy|fog|storm` (the same launch
    /// argument Phase 4 already uses for the phrase bank) also forces which weather-condition
    /// scene renders, via `DoodleComposer.ConditionCategory(phraseBankGroup:)`.
    var forcedCondition: DoodleComposer.ConditionCategory? = nil
    /// Sim-verify hook: `-forceTimeOfDay dawn|day|dusk|night` (new this phase).
    var forcedTimeOfDay: DoodleComposer.TimeOfDay? = nil
    /// True-sky doodle work package: the location whose sky this hero scene should depict.
    /// `nil` for the no-payload states (loading/error/empty previews — no coordinate to compute
    /// planet positions or fetch aurora/ISS for), which is exactly the "renders as today, no
    /// regression" fallback those states already rely on for `current`/`caption`.
    var location: SavedLocation? = nil
    /// Reuses `TonightSkyCard`'s exact override bundle (`-forceAuroraBand`, `-forceISSPass`,
    /// `-forceNoISS`, `-forceSkyUnavailable`) so one flag drives both the sky card and the hero
    /// scene together — see `ForecastViewModel.skyForcedOverrides`.
    var skyForcedOverrides: SkyTonightService.ForcedOverrides? = nil
    /// `-forceTrueSkyPlanets` — see `DoodleComposer.resolve`'s `forceTrueSkyPlanets` parameter.
    var forceTrueSkyPlanets: Bool = false
    /// `-forceISSStreakNow` — see `DoodleComposer.resolve`'s `forceISSStreakNow` parameter.
    var forceISSStreakNow: Bool = false
    /// Header space-event layers: `-forceMeteorStreaks`, `-forceConjunctionScene`,
    /// `-forceLaunchContrail` — see `DoodleComposer.resolve`'s matching parameters.
    var forceMeteorStreaks: Bool = false
    var forceConjunctionScene: Bool = false
    var forceLaunchContrail: Bool = false
    /// Forecast-surface overhaul, work item 1 (Tonight Headline hero): tonight's hourly cloud
    /// data, needed to build `TonightHeadline.Inputs`' overcast/stargazing-score tiers. Defaulted
    /// to empty so every existing call site (loading/error/empty previews) keeps compiling
    /// unchanged and simply never resolves a Tonight Headline (falls back to `caption`).
    var hourly: [HourlyEntry] = []
    /// Forecast-surface overhaul, work item 1: tapping the caption scrolls to the Tonight's Sky
    /// card — `ForecastPageView` wires this to its existing `ScrollViewProxy.scrollTo` mechanism
    /// (the same one `-scrollToSky` already drives).
    var onCaptionTap: (() -> Void)? = nil

    /// Aurora/ISS/bestMoment/meteor are network-or-derived-state (`SkyTonightService.state`), so
    /// — unlike planets, which are synchronous math computed fresh in `scene` below — they're
    /// fetched once via `.task(id:)` and cached here. Calling `SkyTonightService.shared.state(...)`
    /// a second time for the same (location, evening) that `TonightSkyCard` already fetched hits
    /// that service's own in-memory cache/in-flight-task de-dup (see its doc comment) rather than
    /// re-hitting the network — this view never fetches twice for the same evening. Storing the
    /// full `State` (rather than just the aurora band/ISS passes the true-sky doodle scene
    /// needs) additionally lets this view build `TonightHeadline.Inputs` for the hero caption.
    @State private var fetchedSkyState: SkyTonightService.State? = nil
    /// Header space-event layers ("launch-day contrail"): cache-only, never triggers a network
    /// fetch of its own — same sourcing `HourlySkyEvents`' launch icons already use (see
    /// `loadLaunchCacheOnly()` below).
    @State private var fetchedGoLaunchToday: Bool = false
    /// Scroll-jank fix: see `resolvedScene`'s doc comment. `cachedSceneKey` is the `sceneCacheKey`
    /// value `cachedScene` was resolved from — a mismatch means the cache is stale (or not yet
    /// populated).
    @State private var cachedScene: DoodleComposer.Scene? = nil
    @State private var cachedSceneKey: String? = nil

    private var fetchedAuroraBand: AuroraBand? {
        fetchedSkyState.flatMap { SkyTonightService.availableValue($0.aurora) }?.band
    }

    private var fetchedISSPasses: [ISSPass] {
        fetchedSkyState.flatMap { SkyTonightService.availableValue($0.iss) } ?? []
    }

    /// Header space-event layers ("meteor streaks"/"conjunction nights"): `state(...)` already
    /// computes meteor outlook, close pairings, and moon phase synchronously as part of the one
    /// async call above (only ISS/aurora are genuinely networked) — so these three ride along on
    /// `fetchedSkyState` for free, no second fetch.
    private var fetchedMeteorOutlook: MeteorShowers.MeteorOutlook? {
        fetchedSkyState?.meteor
    }

    private var fetchedConjunctionPairing: Conjunctions.Pairing? {
        fetchedSkyState?.pairings.first
    }

    private var fetchedMoonIlluminatedFraction: Double? {
        fetchedSkyState.map { $0.astronomy.moon.illuminatedPercent / 100 }
    }

    private var fetchedMoonWaxing: Bool? {
        fetchedSkyState?.astronomy.moon.waxing
    }

    @Environment(UnitsSettings.self) private var unitsSettings

    /// Roughly 40-45% of screen height including the top safe area, per the redesign spec —
    /// the extra height contributed by `ignoresSafeArea(edges: .top)` (the status bar / Dynamic
    /// Island inset) lands this in that range on real devices without hand-tuning per model.
    private static let heightFraction: CGFloat = 0.40

    static var heroHeight: CGFloat {
        UIScreen.main.bounds.height * heightFraction
    }

    /// How far the content sheet (`ForecastPageView`) is pulled up to overlap this scene's
    /// bottom edge. Exposed so `ForecastPageView` can keep its own sheet-surface math and the
    /// caption's bottom clearance in lockstep with this single value.
    static let sheetOverlap: CGFloat = 24

    /// Fixed allowance for the status bar/Dynamic Island plus `ForecastView`'s custom top chrome
    /// bar (the transparent, white-styled title + ellipsis overlay that replaced the system
    /// navigation bar — see `ForecastView.topChromeBar`), so the temperature group sits "in the
    /// upper-middle area of the scene, clear of the status bar and city title" rather than
    /// butting up against them. A constant rather than `GeometryReader.safeAreaInsets.top`
    /// because this view renders inside ScrollViews that themselves
    /// `ignoresSafeArea(edges: .top)` — in that configuration the proxy reports a top inset of
    /// 0, which would park the group under the Dynamic Island. Bumped from 108 to 150 when the
    /// custom top chrome landed: `ForecastPageView`'s hero-bleed fix (see its `body` comment)
    /// stopped a residual ~31pt inset the paging collection view used to silently add, which had
    /// been quietly padding this same clearance out — verified empirically (`_review/chrome-*
    /// .png`) that 150 clears the new bar's title with room to spare in both the tallest
    /// (`Dynamic Island`) and shortest supported device's status-bar height.
    private static let topChromeClearance: CGFloat = 150

    /// Space-first design batch, item 1: the compact weather cluster's leading inset — chosen
    /// between the top chrome bar's own 16pt horizontal padding (`ForecastView.topChromeBar`)
    /// and the space block's 24pt (below), splitting the difference for a hero-scale element
    /// that isn't quite either.
    private static let heroLeadingMargin: CGFloat = 20

    // MARK: - Tonight preview (always-night hero)

    /// The owner's decision: the hero always shows a preview of TONIGHT's sky, resolved to
    /// either a live view of the sky right now (dark hours) or a fixed point later this evening
    /// (daytime viewing). `nil` location (loading/error/empty previews — no coordinate to run
    /// the dusk/dawn math against) falls back to "live now, not a preview" — the same
    /// "no regression" fallback every other location-dependent computation on this view uses.
    private var tonightPreview: DoodleComposer.TonightPreviewResolution {
        guard let location else { return DoodleComposer.TonightPreviewResolution(representativeDate: date, isForecastPreview: false) }
        return DoodleComposer.resolveTonightPreview(now: date, latitude: location.latitude, longitude: location.longitude)
    }

    /// The instant in time the hero scene actually depicts — "now" whenever `date` (the real or
    /// `-forceDate`d wall clock) already falls inside tonight's dark window, else this evening's
    /// dusk + 90 minutes. Everything time-based below (season/moon phase via `Scene.date`, real
    /// planet positions, the aurora/ISS network fetch, tonight's forecast condition lookup) is
    /// anchored to this, not to `date` directly, so the whole scene depicts one consistent
    /// moment.
    private var representativeDate: Date { tonightPreview.representativeDate }

    /// True when the scene is a forecast (a sky not yet reached) rather than a live view —
    /// drives the "A look at tonight's sky" caption below.
    private var isForecastPreview: Bool { tonightPreview.isForecastPreview }

    /// Location terrain integration: which curated landscape art set matches the display
    /// location, via the offline `TerrainClassifier`. `.hills` (the pre-existing default) for
    /// the no-location states, matching their usual fallback.
    private var terrainClass: TerrainClass {
        guard let location else { return .hills }
        return TerrainClassifier.classify(latitude: location.latitude, longitude: location.longitude)
    }

    /// How close (in either direction) an hourly entry needs to land to `representativeDate` to
    /// count as "reaching that far" — generous relative to the ~1h hourly cadence so a
    /// representative time that lands between two hourly stamps still resolves, while a
    /// genuinely out-of-coverage representative time (hourly data that stops short of tonight)
    /// correctly falls through to the `current`-conditions fallback below.
    private static let tonightConditionMaxGap: TimeInterval = 90 * 60

    /// Tonight-preview composer mode: the nearest hourly forecast entry's `conditionCode` to
    /// `representativeDate`, so the weather-condition layer draws TONIGHT's forecast condition
    /// rather than whatever's happening right now. `nil` when `hourly` is empty or its coverage
    /// doesn't reach anywhere near `representativeDate` — `DoodleComposer.resolve` documents the
    /// matching fallback to `current`'s condition in that case.
    private var tonightConditionCode: String? {
        guard let nearest = hourly.min(by: {
            abs($0.date.timeIntervalSince(representativeDate)) < abs($1.date.timeIntervalSince(representativeDate))
        }) else { return nil }
        guard abs(nearest.date.timeIntervalSince(representativeDate)) <= Self.tonightConditionMaxGap else { return nil }
        return nearest.conditionCode
    }

    private var scene: DoodleComposer.Scene {
        DoodleComposer.resolve(
            date: representativeDate,
            current: current,
            sunrise: sunrise,
            sunset: sunset,
            forcedCondition: forcedCondition,
            forcedTimeOfDay: forcedTimeOfDay,
            terrainClass: terrainClass,
            tonightConditionCode: tonightConditionCode,
            trueSkyPlanets: currentPlanetPositions,
            trueSkyAuroraBand: fetchedAuroraBand,
            trueSkyISSPasses: fetchedISSPasses,
            forceTrueSkyPlanets: forceTrueSkyPlanets,
            forceISSStreakNow: forceISSStreakNow,
            trueSkyMeteorOutlook: fetchedMeteorOutlook,
            trueSkyConjunctionPairing: fetchedConjunctionPairing,
            trueSkyMoonIlluminatedFraction: fetchedMoonIlluminatedFraction,
            trueSkyMoonWaxing: fetchedMoonWaxing,
            hasGoLaunchToday: fetchedGoLaunchToday,
            forceMeteorStreaks: forceMeteorStreaks,
            forceConjunctionScene: forceConjunctionScene,
            forceLaunchContrail: forceLaunchContrail
        )
    }

    /// Scroll-jank fix (lead QC defect: "sluggish scrolling on the Forecast page"): `scene`
    /// bundles genuinely expensive pure math — `currentPlanetPositions`' Meeus geocentric-position
    /// solve for all five naked-eye planets, `tonightHeadline`'s `StargazingScore.hourlyScores`
    /// pass over the full `hourly` array — that has no business re-running just because this
    /// view's `body` was asked to re-evaluate. That used to happen on every render regardless of
    /// whether any real input changed (the type-level doc comment called this "cheap enough to
    /// call on every render," true in isolation, false once `body` is asked to run at 60-120Hz
    /// during a scroll — see `ForecastPageView.ParallaxHero`, which now rebuilds this view every
    /// scroll frame for the parallax offset). Measured ~52ms average per `scene` resolution
    /// (sim-verify, 2s animated scroll) before this cache existed — see the commit message for
    /// the full before/after numbers.
    ///
    /// `cachedScene`/`cachedSceneKey` below cache the resolved value, refreshed via
    /// `.onChange(of: sceneCacheKey, initial: true)` in `body` — an effect, not a body-time
    /// mutation, so it never trips "modifying state during view update." This computed property
    /// stays side-effect-free (never mutates `@State`): when the cache is stale — before that
    /// `onChange` has fired even once, or the vanishingly rare race where a real input changed in
    /// the same instant the cache was read — it simply recomputes `scene` fresh inline, so the
    /// rendered scene is never wrong or stale, just (in that rare case) not free.
    private var resolvedScene: DoodleComposer.Scene {
        if let cachedScene, cachedSceneKey == sceneCacheKey {
            return cachedScene
        }
        return scene
    }

    /// `scene`'s full dependency set as a single joined-string key, mirroring the
    /// `trueSkyTaskKey`/`launchCacheTaskKey`/`taskKey` "cache key as joined string" idiom already
    /// used elsewhere in this file (and in `TonightSkyCard`). Every field `scene`'s resolution
    /// actually reads (directly or via `currentPlanetPositions`/`tonightConditionCode`/
    /// `terrainClass`/`tonightHeadline`) is represented here — `hourly`'s identity is
    /// approximated by its count + first/last dates rather than a full per-element comparison,
    /// which is deliberately cheap (this key is rebuilt every render) while still changing
    /// whenever a genuinely new payload lands (a different fetch always shifts the hourly
    /// window's bounds or length).
    private var sceneCacheKey: String {
        [
            "\(representativeDate.timeIntervalSince1970)",
            "\(date.timeIntervalSince1970)",
            location?.id.uuidString ?? "none",
            current?.conditionCode ?? "none",
            "\(current?.temperature.value ?? -9999)",
            "\(sunrise?.timeIntervalSince1970 ?? -1)",
            "\(sunset?.timeIntervalSince1970 ?? -1)",
            forcedCondition?.rawValue ?? "none",
            forcedTimeOfDay?.rawValue ?? "none",
            "\(hourly.count)",
            "\(hourly.first?.date.timeIntervalSince1970 ?? -1)",
            "\(hourly.last?.date.timeIntervalSince1970 ?? -1)",
            fetchedAuroraBand?.description ?? "none",
            "\(fetchedISSPasses.count)",
            fetchedMeteorOutlook == nil ? "none" : "some",
            fetchedConjunctionPairing == nil ? "none" : "some",
            "\(fetchedMoonIlluminatedFraction ?? -1)",
            fetchedMoonWaxing.map(String.init) ?? "none",
            "\(fetchedGoLaunchToday)",
            "\(forceTrueSkyPlanets)",
            "\(forceISSStreakNow)",
            "\(forceMeteorStreaks)",
            "\(forceConjunctionScene)",
            "\(forceLaunchContrail)",
        ].joined(separator: "|")
    }

    /// Synchronous, pure math (no network) — recomputed on every render just like
    /// `TonightSkyCard`'s own `SkyTonightService.astronomy(...)` call, so this never waits on
    /// the async aurora/ISS fetch below. Evaluated at `representativeDate` (not raw `date`) so a
    /// daytime preview shows tonight's actual planet positions, not right-now's.
    private var currentPlanetPositions: [SkyTonight.CurrentPlanetPosition] {
        guard let location else { return [] }
        return SkyTonight.currentPlanetPositions(date: representativeDate, latitude: location.latitude, longitude: location.longitude)
    }

    /// Re-runs whenever the location, calendar evening, or a forced aurora/ISS override changes
    /// — mirrors `TonightSkyCard.taskKey`'s exact rationale. Keyed on `representativeDate` rather
    /// than raw `date`; both fall on the same calendar day (the representative time is always
    /// either "now" or later the same evening), so this is a no-op change for the cache key in
    /// practice, kept in sync with `loadTrueSkyNetworkState()`'s own switch to it below.
    private var trueSkyTaskKey: String {
        guard let location else { return "none" }
        var parts = ["\(location.id)", "\(Calendar.current.startOfDay(for: representativeDate).timeIntervalSince1970)"]
        if let overrides = skyForcedOverrides {
            parts.append("band=\(overrides.auroraBand?.description ?? "nil")")
            parts.append("issPass=\(overrides.issPass)")
            parts.append("noISS=\(overrides.noISS)")
            parts.append("unavailable=\(overrides.unavailable)")
        }
        return parts.joined(separator: "|")
    }

    private func loadTrueSkyNetworkState() async {
        guard let location else { return }
        let result = await SkyTonightService.shared.state(
            locationId: location.id,
            latitude: location.latitude,
            longitude: location.longitude,
            date: representativeDate,
            overrides: skyForcedOverrides
        )
        fetchedSkyState = result
    }

    /// `sky/` subdirectory of the app's caches directory — the same shared cache directory
    /// `ForecastPageView.loadSkyContext()`/`SpaceViewModel` already use for the launch cache.
    private static var skyCacheDirectory: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("sky", isDirectory: true)
    }

    /// Header space-event layers ("launch-day contrail"): cache-only read, mirroring
    /// `ForecastPageView.loadSkyContext()`'s own launch sourcing (work order: "cache-only read,
    /// same as the hourly icons") — never triggers a new network fetch; a cache miss/stale cache
    /// simply means no contrail today, which is the documented, acceptable degraded behavior.
    private func loadLaunchCacheOnly() async {
        let launches = await LaunchesUpcoming.cachedNextLaunchesIfFresh(
            cacheDirectory: Self.skyCacheDirectory, from: date, count: 10
        )
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        fetchedGoLaunchToday = launches.contains {
            $0.status == .go && calendar.isDate($0.net, inSameDayAs: date)
        }
    }

    // MARK: - Tonight Headline (work item 1)

    /// Builds `TonightHeadline.Inputs` from `fetchedSkyState` (bestMoment/meteor/planets/moon)
    /// plus `hourly` (this evening's cloud data, for the overcast/stargazing-score tiers) and
    /// generates tonight's headline. `nil` whenever the inputs aren't available yet — first
    /// launch, no location, the async sky fetch hasn't resolved, or tonight's dusk/dawn window
    /// can't be resolved (polar edge case) — in which case `resolvedCaption` falls back to the
    /// phrase-bank `caption` passed in, per work order.
    private var tonightHeadline: TonightHeadline.Headline? {
        guard let location, let skyState = fetchedSkyState, !hourly.isEmpty else { return nil }
        guard let window = SkyTonightService.duskDawnWindow(
            latitude: location.latitude, longitude: location.longitude, date: date, timeZone: .current
        ) else { return nil }

        let hourInputs = hourly.map {
            StargazingScore.HourInput(date: $0.date, conditionCode: $0.conditionCode, precipChance: $0.precipChance)
        }
        let scores = StargazingScore.hourlyScores(hours: hourInputs, latitude: location.latitude, longitude: location.longitude)
        let peak = scores.filter { window.contains($0.date) }.max { $0.score < $1.score }
        let cloudCovers = hourly.map {
            TonightHeadline.HourCloudCover(
                date: $0.date,
                cloudCoverFraction: StargazingScore.cloudCoverFraction(conditionCode: $0.conditionCode, precipChance: $0.precipChance)
            )
        }

        let inputs = TonightHeadline.Inputs(
            moment: skyState.bestMoment,
            meteorOutlook: skyState.meteor,
            planets: skyState.astronomy.planets,
            moon: skyState.astronomy.moon,
            peakStargazingScore: peak?.score,
            peakStargazingHour: peak?.date,
            tonightWindow: window,
            hourlyCloudCover: cloudCovers,
            timeZone: .current
        )
        return TonightHeadline.generate(inputs)
    }

    /// The hero caption actually shown: `TonightHeadline`'s line when its inputs are available,
    /// otherwise the phrase-bank `caption` passed in (work order fallback: "first launch, no
    /// astronomy yet").
    private var resolvedCaption: String? {
        tonightHeadline?.text ?? caption
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .bottom) {
                DoodleSceneView(scene: resolvedScene)

                // Space-first design batch, item 1 ("this is now a space weather app" — weather
                // diminishes, space leads): the temp/condition/feels-like cluster moves from a
                // centered mid-scene block to a compact top-LEFT group, at the same vertical
                // line (`topChromeClearance`) it used to center at. The scene's center is left
                // open on purpose — nothing else renders there — so the stars/planets/terrain
                // breathe, and the space block below reads as the clear typographic hero.
                if current != nil {
                    VStack(alignment: .leading, spacing: 0) {
                        Spacer()
                            .frame(height: Self.topChromeClearance)
                        heroTemperatureGroup
                            .padding(.leading, Self.heroLeadingMargin)
                        Spacer(minLength: 0)
                    }
                    .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
                }

                if resolvedCaption != nil {
                    // Full-width bottom-up scrim, sized independently of the caption text so it
                    // spans the entire header edge-to-edge — a hard-edged box around just the
                    // text (the previous behavior, when the gradient was a `.background()` on
                    // the Text itself) is exactly the visible-box artifact this is fixing.
                    captionScrim
                        .frame(height: Self.scrimHeight)
                        .allowsHitTesting(false)
                }

                if resolvedCaption != nil {
                    spaceHeroBlock
                        .padding(.horizontal, 24)
                        // Nudged up by `sheetOverlap` beyond its original 14pt clearance so the
                        // block stays fully visible above the content sheet's curved top edge,
                        // which now overlaps this scene by that same amount.
                        .padding(.bottom, 14 + Self.sheetOverlap)
                        .frame(maxWidth: .infinity)
                        .contentShape(Rectangle())
                        // Work item 1: tapping the whole space block scrolls to the Tonight's
                        // Sky card. Only active when the caller supplied a target (the loaded
                        // state) — a no-op tap on the loading/error/empty previews, which pass
                        // no closure.
                        .onTapGesture { onCaptionTap?() }
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .frame(height: Self.heroHeight)
        .frame(maxWidth: .infinity)
        .clipped()
        .task(id: trueSkyTaskKey) {
            await loadTrueSkyNetworkState()
        }
        .task(id: launchCacheTaskKey) {
            await loadLaunchCacheOnly()
        }
        // Scroll-jank fix: refreshes `cachedScene` as an effect (never during body evaluation —
        // see `resolvedScene`'s doc comment) whenever a real input changes. `initial: true` also
        // populates the cache once on first appearance, so the very next render already hits the
        // fast path rather than relying solely on `resolvedScene`'s inline fallback.
        .onChange(of: sceneCacheKey, initial: true) { _, newKey in
            cachedScene = scene
            cachedSceneKey = newKey
        }
    }

    /// Re-runs whenever the location or calendar day changes — same `.task(id:)` rationale as
    /// `trueSkyTaskKey`. Kept as its own key (rather than folded into `trueSkyTaskKey`) since this
    /// cache-only read doesn't depend on `skyForcedOverrides` at all.
    private var launchCacheTaskKey: String {
        "\(location?.id.uuidString ?? "none")|\(Calendar.current.startOfDay(for: date).timeIntervalSince1970)"
    }

    /// Space-first design batch, item 1: the weather cluster, now compact and top-left rather
    /// than the previous 96pt-thin centered hero. Still white with a soft shadow (it still sits
    /// directly on the sky illustration), but sized and weighted to read as secondary context
    /// next to the space block below, not as competing hero typography.
    @ViewBuilder
    private var heroTemperatureGroup: some View {
        if let current {
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: current.symbolName)
                        .font(.system(size: 20, weight: .light))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.3), radius: 4, y: 1)

                    Text(TemperatureFormatting.string(current.temperature, unit: unitsSettings.unit))
                        .font(.system(size: 54, weight: .light))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.3), radius: 6, y: 2)
                }
                .lineLimit(1)
                .minimumScaleFactor(0.7)

                Text("Feels \(TemperatureFormatting.string(current.feelsLike, unit: unitsSettings.unit))")
                    .font(.footnote)
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
        }
    }

    /// Space-first design batch, item 1: the space block — preview label, then the headline
    /// (now the hero's typographic centerpiece at `.title2` rounded semibold, up from the
    /// previous `.subheadline`), then a detail line when `tonightHeadline` has one. Lower-third
    /// centered, directly above the caption scrim; the whole block stays tappable (unchanged
    /// scroll-to-Tonight's-Sky-card behavior lives on the caller of this computed view, in
    /// `body`).
    @ViewBuilder
    private var spaceHeroBlock: some View {
        if let resolvedCaption {
            VStack(spacing: 6) {
                // Always-night hero, preview label: only shown when the scene is a forecast
                // (daytime viewing, previewing this evening's sky) rather than a live view — at
                // night the scene IS the live sky, so no label per the owner's decision ("no
                // exclamations... factual, no label at night").
                if isForecastPreview {
                    Text("A look at tonight's sky")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.55))
                        .multilineTextAlignment(.center)
                }

                Text(resolvedCaption)
                    .font(.system(.title2, design: .rounded).weight(.semibold))
                    .foregroundStyle(.white)
                    // A stronger shadow than the old subheadline caption's — this is now the
                    // hero's largest, most load-bearing text, so it needs to hold up over every
                    // terrain/season/time-of-day combination on its own.
                    .shadow(color: .black.opacity(0.4), radius: 6, y: 2)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)

                // The fuller "Step outside" explanation beneath the headline — only present when
                // `TonightHeadline` actually resolved one (event/overcast tiers always have one;
                // the quieter fact tiers, and the phrase-bank `caption` fallback, may not).
                if let detail = tonightHeadline?.detailText {
                    Text(detail)
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.75))
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                }
            }
        }
    }

    private static let scrimHeight: CGFloat = 112

    /// A full-width, bottom-anchored dark gradient so the caption stays legible over every
    /// season/weather/time-of-day combination — including bright scenes like a snowy winter day
    /// or a pale summer sky, and dark ones like a night scene, where a flat single-opacity
    /// scrim would either wash out or look muddy. Clear at the top edge (no visible seam against
    /// the scene above it), building to a subtle dark base so white text reads reliably without
    /// a boxed-in look.
    private var captionScrim: some View {
        // Legibility pass (illustrated-landscape integration): nudged from 0.16/0.48 to
        // 0.22/0.58 — the caption now overlays painted landscape art (previously a flat
        // gradient), and the palest scene (winter's snow strip) left the caption a little thin
        // against the ground at the original strengths. Still clear at the top edge so there's
        // no visible seam against the scene above it.
        LinearGradient(
            colors: [.black.opacity(0), .black.opacity(0.22), .black.opacity(0.58)],
            startPoint: .top,
            endPoint: .bottom
        )
    }
}

#Preview("Clear day") {
    DoodleHeaderView(
        current: CurrentConditions(
            date: Date(), temperature: Measurement(value: 87, unit: .fahrenheit),
            feelsLike: Measurement(value: 90, unit: .fahrenheit), conditionCode: "clear",
            conditionDescription: "Clear", symbolName: "sun.max.fill", humidity: 0.4,
            windSpeed: Measurement(value: 5, unit: .milesPerHour),
            windDirection: Measurement(value: 0, unit: .degrees), uvIndexValue: 6,
            uvIndexCategory: "High", isDaylight: true
        ),
        caption: "Not a cloud in sight. Suspicious, honestly."
    )
    .environment(UnitsSettings())
}

#Preview("Snowy night") {
    DoodleHeaderView(
        current: CurrentConditions(
            date: Date(), temperature: Measurement(value: 22, unit: .fahrenheit),
            feelsLike: Measurement(value: 14, unit: .fahrenheit), conditionCode: "snow",
            conditionDescription: "Snow", symbolName: "snow", humidity: 0.7,
            windSpeed: Measurement(value: 8, unit: .milesPerHour),
            windDirection: Measurement(value: 0, unit: .degrees), uvIndexValue: 0,
            uvIndexCategory: "Low", isDaylight: false
        ),
        caption: "Snow at night. The good kind of quiet."
    )
    .environment(UnitsSettings())
}
