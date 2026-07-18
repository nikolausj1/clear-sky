import SwiftUI
import UIKit

/// One page of the Forecast pager — everything `ForecastView` rendered in Phase 2 for a single
/// location, now parameterized by an explicit `location` + `page` state instead of reading a
/// singular `viewModel.payload`, so `ForecastView` can host one of these per saved location
/// inside a `TabView` for horizontal swipe-paging (PRD Screen B: "The Forecast screen also
/// supports horizontal swipe to page between saved locations").
///
/// UX redesign part 1 restructures every state (loading/error/empty/loaded) around the same
/// "hero + sheet" shape: a full-bleed `DoodleHeaderView` at the top (which sizes and positions
/// itself, including ignoring the top safe area — see that file), followed by a content sheet
/// (`Color(.systemGroupedBackground)`, rounded top corners, pulled up to overlap the scene's
/// bottom edge) that carries every other state's content. Sharing that shell across states means
/// switching between them never jumps the layout.
struct ForecastPageView: View {
    let location: SavedLocation
    let page: ForecastViewModel.PageState
    /// Sim-verify only: scrolls the hourly list to a given hour index on load (only meaningful
    /// for the page that's active at launch — `simctl` can't scroll/swipe either).
    var scrollTargetHourIndex: Int? = nil
    /// Sim-verify only (Phase 7): `-scrollToAttribution` — scrolls straight to the
    /// `AttributionFooter` at the bottom of the scroll content, so a screenshot can confirm the
    /// required Apple Weather attribution renders on the Forecast screen without needing a real
    /// scroll gesture (`simctl` can't scroll).
    var scrollToAttribution: Bool = false
    /// Sim-verify only ("Tonight's Sky" work package): `-scrollToSky` — scrolls straight to
    /// `TonightSkyCard`, mirroring `-scrollToAttribution` above.
    var scrollToSky: Bool = false
    /// Sim-verify only (Forecast-surface overhaul, work item 4): `-showExplainer <key>` —
    /// presents an explainer sheet directly at launch, since `simctl` can't tap through to an
    /// icon. See `Explainers.forLaunchArgKey(_:)` for the accepted keys.
    var forcedExplainerKey: String? = nil
    /// Sim-verify only ("People in Space" work package): `-showPeopleSheet` — see
    /// `TonightSkyCard.init`'s doc comment.
    var showPeopleSheetAtLaunch: Bool = false
    /// Sim-verify only (always-dark audit sweep): `-showAlertDetail` — presents
    /// `AlertDetailSheet` directly at launch (paired with `-forceState alert`, since `simctl`
    /// can't tap the `AdvisoryBanner` to open it), so the sheet's dark rendering can be
    /// screenshotted without a real tap.
    var showAlertDetailAtLaunch: Bool = false
    /// UX redesign part 2 (lead QC defect: scroll-aware top bar): reports this page's scroll
    /// content offset (`0` at rest, growing as the user scrolls down) up to `ForecastView`,
    /// which only listens for the currently-active page (see `ForecastView.pagerView`) and uses
    /// it to decide when to swap the transparent/white nav bar for a material one. A closure
    /// rather than a `Binding` because every page in the `TabView` mounts one of these, and only
    /// one page's offset should ever drive the shared bar state.
    var onScrollOffsetChange: (CGFloat) -> Void = { _ in }
    @Bindable var viewModel: ForecastViewModel
    var onRetry: () -> Void
    var onRefresh: () async -> Void

    @Environment(UnitsSettings.self) private var unitsSettings
    @State private var isPresentingAlertDetail = false
    @State private var hasScrolledToTarget = false
    /// Forecast-surface overhaul, work item 4: the currently-presented tap-to-explain sheet, if
    /// any. Centralized here (rather than one `@State` per tappable icon scattered across
    /// `HourlyForecastSection`/`TonightSkyCard`) so every explainer — hourly event icons, the Sky
    /// chip's score info button, `TonightSkyCard`'s ISS section — shares one sheet presentation.
    @State private var presentedExplainer: ExplainerContent?
    /// Forecast-surface overhaul, work item 3: the Sky/Events chips' per-hour intelligence,
    /// resolved once per (location, evening) via `loadSkyContext()` below and threaded into both
    /// `HourlyForecastSection` and `DailyForecastSection`. Starts as the all-defaults value (no
    /// events, no scores) so the chips render their quiet/empty states until the task resolves —
    /// same "never blocks the rest of the page" spirit as `TonightSkyCard`'s own async rows.
    @State private var skyContext = HourlySkyContext()
    /// UX polish package ("Depth & motion" — hero parallax): the same content-scroll offset the
    /// scroll-aware top bar already tracks (`onScrollOffsetChange`), mirrored into local state so
    /// `heroHeader` can apply a parallax offset/overscroll scale to the hero without needing a
    /// second scroll probe.
    @State private var scrollOffset: CGFloat = 0
    /// True-sky doodle QC fix (defect 1, "coordinate space regressed upward") — see `body`'s doc
    /// comment for the full investigation. The hero needs to be pulled up by however much the
    /// scroll content naturally rests below the true screen top at launch, but that amount
    /// turned out not to be safely knowable from any single API on this OS/SwiftUI version — so
    /// it's measured directly instead, once, via a zero-size sentinel at the very top of each
    /// state's scroll content (see `heroTopOffsetSentinel`).
    @State private var heroTopOffset: CGFloat = 0
    @State private var hasMeasuredHeroTopOffset = false

    /// Approximate remaining viewport height below the hero, so the loading/error/empty sheets
    /// fill the screen and center their content the same way the hero+sheet shell will once real
    /// content loads, rather than being sized to whatever their (short) content needs.
    private var stateSheetMinHeight: CGFloat {
        max(UIScreen.main.bounds.height - DoodleHeaderView.heroHeight, 320)
    }

    var body: some View {
        // True-sky doodle QC fix (defect 1, "coordinate space regressed upward" — the hero's sky
        // content, moon/sun, twinkle stars, and the true-sky doodle's planet dots/aurora/ISS
        // streak were all rendering compressed up behind the status bar/Dynamic Island).
        //
        // HISTORY, for whoever next has to touch this: this used to be `GeometryReader { geo in
        // ... }`, threading `geo.safeAreaInsets.top` down to `heroHeader`/`loadedView` as a
        // `topInset` applied as `.padding(.top, -topInset)` on the hero, paired with
        // `ForecastView.pagerView`'s (also since-removed) `PagingCollectionViewInsetFix` — a
        // `UIViewRepresentable` probe that walked `superview` to find the `UICollectionView`
        // backing `TabView(.page)` and disable its automatic top content-inset adjustment. Two
        // separate fixes for what were, at the time, two independently observed residual
        // insets (a ~31pt one attributed to that collection view, and the status-bar/Dynamic-
        // Island inset the `-topInset` pull-up compensated for).
        //
        // Root-caused via sim-verify + on-device debug logging (bisected against `HEAD~1`,
        // before the true-sky-doodle commit — this bug already existed there too, so it was
        // never that commit's regression, just newly *visible* in its screenshots): on the
        // current iOS/SwiftUI runtime, `TabView(.page)` is no longer backed by a
        // `UICollectionView` at all (confirmed by logging the probe's full `superview` chain —
        // zero `UICollectionView` anywhere in it; instead it's `UINavigationTransitionView`/
        // `UILayoutContainerView` internals, i.e. `UINavigationController`'s own hidden-nav-bar
        // machinery), so `PagingCollectionViewInsetFix` had become a silent no-op. Separately,
        // `geo.safeAreaInsets.top` no longer reads 0 here (measured 62pt on iPhone 17 Pro Max),
        // so the "harmless no-op" `-topInset` pull-up was actually firing on every launch,
        // over-correcting by that full 62pt and shoving the hero up off the top of the screen.
        // Removing *only* that pull-up (first fix attempt here) unmasked the OTHER, smaller
        // residual (~31pt, i.e. the one `PagingCollectionViewInsetFix` used to own) as a plain
        // white gap above the hero — proving it never actually went away, it had just been
        // overwhelmed by the larger, wrong-direction 62pt correction the whole time.
        //
        // Rather than re-chase a new private view to poke for the second time (this project has
        // now hit that dead end twice — Apple's paging-tab-view internals aren't a stable target
        // to introspect), both historical mechanisms are gone for good, replaced with one
        // measurement of the actual symptom: `heroTopOffsetSentinel` below reports each state's
        // scroll content's real resting position in the window's coordinate space, and that
        // measured value — whatever combination of insets produced it, on whatever OS version —
        // is what gets pulled up. Future OS/SwiftUI internals changes can't silently regress
        // this the way they did twice already; sim-verify's moon-position screenshot check
        // (`_review/redesign3-moon-fixed.png`) is the backstop if they ever do.
        Group {
            switch page.screenState {
            case .loading:
                loadingView()
            case .error(let message):
                errorView(message)
            case .loaded:
                if let payload = page.payload {
                    loadedView(payload)
                } else {
                    emptyStateView()
                }
            }
        }
    }

    /// The full-bleed hero for a state with no payload (loading/error/empty). The pull-up
    /// correction (`heroTopOffset`) is applied to the enclosing `ScrollView` itself, not here —
    /// see `body`'s doc comment for why: a `ScrollView` clips its content to its own frame, so a
    /// negative top padding on a view *inside* the scroll content can only lift that view up to
    /// the scroll view's own top edge before it's clipped away, never past it. Shifting the
    /// `ScrollView`'s own frame is what actually reaches the missing space above it.
    private func heroHeader() -> some View {
        DoodleHeaderView(current: nil, caption: nil)
            .parallax(scrollOffset: scrollOffset)
    }

    /// A zero-size sentinel meant to sit as the very first child of a scrolling `VStack`, right
    /// above the hero. Reports that position — this view's own top edge in the window's
    /// coordinate space (`.global`) — into `heroTopOffset` exactly once, on first layout, then
    /// ignores every later geometry change: scrolling moves this same sentinel by the scroll
    /// amount, and feeding that back into the hero's pull-up would double-count the scroll on
    /// top of `.parallax`'s own handling of it. See `body`'s doc comment for why this replaces
    /// trusting any single safe-area/inset API for this value.
    private func heroTopOffsetSentinel() -> some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minY } action: { _, newValue in
                guard !hasMeasuredHeroTopOffset else { return }
                hasMeasuredHeroTopOffset = true
                heroTopOffset = newValue
            }
    }

    /// Forwards a scroll offset reading both up to `onScrollOffsetChange` (the scroll-aware top
    /// bar's existing consumer) and into local `scrollOffset` state (the hero parallax's
    /// consumer) — one probe, two readers.
    private func reportScrollOffset(_ offset: CGFloat) {
        onScrollOffsetChange(offset)
        scrollOffset = offset
    }

    // MARK: - Loading

    private func loadingView() -> some View {
        ScrollView {
            VStack(spacing: 0) {
                heroTopOffsetSentinel()
                heroHeader()
                sheetSurface(minHeight: stateSheetMinHeight) {
                    centeredStateContent {
                        ProgressView("Consulting the sky.")
                            .tint(.secondary)
                    }
                }
            }
        }
        .ignoresSafeArea(edges: .top)
        // See `body`'s doc comment: this `ScrollView`'s own frame — not its content — is what
        // needs pulling up by the measured `heroTopOffset` (a `ScrollView` clips content to its
        // own bounds, so correcting *inside* it just gets clipped at the scroll view's edge).
        .padding(.top, -heroTopOffset)
        .trackingHeroScrollOffset(reportScrollOffset)
    }

    // MARK: - Error

    private func errorView(_ message: String) -> some View {
        ScrollView {
            VStack(spacing: 0) {
                heroTopOffsetSentinel()
                heroHeader()
                sheetSurface(minHeight: stateSheetMinHeight) {
                    centeredStateContent {
                        Image(systemName: "exclamationmark.icloud")
                            .font(.system(size: 40))
                            .foregroundStyle(.secondary)
                        // PRD Section 6 "WeatherKit error" state: "dry-wit error line, retry action."
                        Text(PhraseBank.errorState(.weatherFetchFailed, date: viewModel.phraseBankDate, locationId: location.id))
                            .font(.headline)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 32)
                        Text(message)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 32)
                        Button("Retry", action: onRetry)
                            .buttonStyle(.borderedProminent)
                    }
                }
            }
        }
        .ignoresSafeArea(edges: .top)
        // See `body`'s doc comment: this `ScrollView`'s own frame — not its content — is what
        // needs pulling up by the measured `heroTopOffset` (a `ScrollView` clips content to its
        // own bounds, so correcting *inside* it just gets clipped at the scroll view's edge).
        .padding(.top, -heroTopOffset)
        .trackingHeroScrollOffset(reportScrollOffset)
    }

    // MARK: - Empty (defensive — a location with a `.loaded` state but no payload)

    private func emptyStateView() -> some View {
        ScrollView {
            VStack(spacing: 0) {
                heroTopOffsetSentinel()
                heroHeader()
                sheetSurface(minHeight: stateSheetMinHeight) {
                    centeredStateContent {
                        Image(systemName: "location.slash")
                            .font(.system(size: 36))
                            .foregroundStyle(.secondary)
                        Text("No forecast yet.")
                            .font(.headline)
                        Text(PhraseBank.errorState(.generic, date: viewModel.phraseBankDate, locationId: location.id))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .ignoresSafeArea(edges: .top)
        // See `body`'s doc comment: this `ScrollView`'s own frame — not its content — is what
        // needs pulling up by the measured `heroTopOffset` (a `ScrollView` clips content to its
        // own bounds, so correcting *inside* it just gets clipped at the scroll view's edge).
        .padding(.top, -heroTopOffset)
        .trackingHeroScrollOffset(reportScrollOffset)
    }

    /// Shared vertical centering for the loading/error/empty sheets: a flexible spacer on each
    /// side of the content so it sits in the middle of the sheet's minimum height, matching
    /// where the equivalent content used to sit when it was centered in the full-screen page.
    private func centeredStateContent<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 12) {
            Spacer(minLength: 12)
            content()
            Spacer(minLength: 12)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Loaded

    @ViewBuilder
    private func loadedView(_ payload: CachedWeather) -> some View {
        ScrollViewReader { proxy in
            // User-reported defect fix ("header isn't showing the night sky" / stale hourly
            // anchor): everything time-anchored in this page — the hero scene's time-of-day,
            // the hourly list's "Now" row, today's expansion — was resolved from a Date captured
            // at render time, and nothing forced a re-render as wall-clock time moved (an app
            // resumed from hours of suspension happily showed the afternoon scene at midnight).
            // A minute-cadence TimelineView re-evaluates this content on schedule AND on
            // scene re-activation, so the scene/rows re-anchor themselves; the sections also
            // now take `now` explicitly instead of trusting index 0 (see their doc comments).
            TimelineView(.periodic(from: .now, by: 60)) { timeline in
                let displayNow = viewModel.isDateForced ? viewModel.phraseBankDate : timeline.date
                ScrollView {
                VStack(spacing: 0) {
                    heroTopOffsetSentinel()
                    DoodleHeaderView(
                        current: payload.currentConditions,
                        caption: viewModel.doodleCaptionLine(location: location, payload: payload, unit: unitsSettings.unit),
                        date: displayNow,
                        sunrise: payload.daily.first?.sunrise,
                        sunset: payload.daily.first?.sunset,
                        forcedCondition: viewModel.forcedDoodleCondition,
                        forcedTimeOfDay: viewModel.forcedDoodleTimeOfDay,
                        location: location,
                        skyForcedOverrides: viewModel.skyForcedOverrides,
                        forceTrueSkyPlanets: viewModel.forceTrueSkyPlanets,
                        forceISSStreakNow: viewModel.forceISSStreakNow,
                        forceMeteorStreaks: viewModel.forceMeteorStreaks,
                        forceConjunctionScene: viewModel.forceConjunctionScene,
                        forceLaunchContrail: viewModel.forceLaunchContrail,
                        hourly: payload.hourly,
                        onCaptionTap: { scrollToSkyCard(proxy: proxy) }
                    )
                    .parallax(scrollOffset: scrollOffset)

                    sheetSurface {
                        VStack(alignment: .leading, spacing: 20) {
                            if page.cacheState == .stale {
                                staleBanner(payload.fetchedAt)
                            }

                            if !payload.activeAlerts.isEmpty {
                                AdvisoryBanner(alerts: payload.activeAlerts, isPresentingDetail: $isPresentingAlertDetail)
                            }

                            CopyLinesView(
                                summary: viewModel.summaryLine(location: location, payload: payload, unit: unitsSettings.unit),
                                comparison: viewModel.comparisonLine(location: location, payload: payload, unit: unitsSettings.unit)
                            )

                            MetricChipsRow(selected: $viewModel.selectedMetric)

                            SheetCard(title: "HOURLY FORECAST") {
                                HourlyForecastSection(hours: payload.hourly, metric: viewModel.selectedMetric, skyContext: skyContext, now: displayNow)
                            }

                            SheetCard(title: "DAILY FORECAST") {
                                DailyForecastSection(
                                    daily: payload.daily,
                                    now: displayNow,
                                    hourly: payload.hourly,
                                    metric: viewModel.selectedMetric,
                                    skyContext: skyContext,
                                    expandedDayId: $viewModel.expandedDayId,
                                    currentTemperature: payload.currentConditions.temperature
                                )
                            }

                            // `TonightSkyCard` applies its own `.id(TonightSkyCard.cardId)`
                            // internally (to its own bespoke "night panel" container — Editor's-
                            // Choice sky-surfaces elevation moved this card off `SheetCard`
                            // entirely, see that file's type-level doc comment), which is what
                            // `-scrollToSky` below targets — no separate id needed at the mount
                            // site.
                            TonightSkyCard(
                                location: location,
                                date: displayNow,
                                forcedOverrides: viewModel.skyForcedOverrides,
                                initialExpandedPlanet: viewModel.initialExpandedSkyPlanet,
                                initialShowPeopleSheet: showPeopleSheetAtLaunch,
                                onExplain: { presentedExplainer = $0 }
                            )

                            AttributionFooter(attribution: payload.attribution)
                                .id(Self.attributionFooterId)
                        }
                    }
                }
            }
            // Paired with the same modifier on `ForecastView`'s `TabView`: the TabView-level
            // one lets pages extend under the status bar at all; this ScrollView-level one
            // stops the scroll content from being re-inset by that reclaimed safe area (which
            // otherwise shows as a white band above the hero, exactly the height of the status
            // bar). Both are needed — verified each in isolation during sim-verify.
            .ignoresSafeArea(edges: .top)
            // See `body`'s doc comment: this `ScrollView`'s own frame — not its content — is
            // what needs pulling up by the measured `heroTopOffset`, since a `ScrollView` clips
            // content to its own bounds (a negative padding *inside* it just gets clipped at the
            // scroll view's top edge, as the hero-level version of this fix, tried first, found
            // out the hard way).
            .padding(.top, -heroTopOffset)
            .trackingHeroScrollOffset(reportScrollOffset)
                .refreshable {
                    await onRefresh()
                }
            }
            .sheet(isPresented: $isPresentingAlertDetail) {
                AlertDetailSheet(alerts: payload.activeAlerts)
            }
            .sheet(item: $presentedExplainer) { content in
                ExplainerSheet(content: content)
            }
            .onAppear {
                scrollToTargetIfNeeded(payload, proxy: proxy)
                if showAlertDetailAtLaunch, !payload.activeAlerts.isEmpty {
                    isPresentingAlertDetail = true
                }
                if let forcedExplainerKey, presentedExplainer == nil {
                    presentedExplainer = Explainers.forLaunchArgKey(forcedExplainerKey)
                }
            }
            .onChange(of: viewModel.selectedMetric) {
                scrollToTargetIfNeeded(payload, proxy: proxy)
            }
            .task(id: skyContextTaskKey) {
                await loadSkyContext(payload: payload)
            }
        }
    }

    // MARK: - Sky intelligence context (work item 3)

    /// Re-runs whenever the location or calendar evening changes — mirrors `TonightSkyCard
    /// .taskKey`'s exact rationale (`.task(id:)` cancels/restarts automatically on any change).
    private var skyContextTaskKey: String {
        "\(location.id)|\(Calendar.current.startOfDay(for: viewModel.phraseBankDate).timeIntervalSince1970)"
    }

    /// `sky/` subdirectory of the app's caches directory — the same directory
    /// `SkyTonightService`/`SpaceViewModel` already share for their own ISS/aurora/launch/solar
    /// caches (each file within it is independently named, so there's no collision).
    private static var skyCacheDirectory: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("sky", isDirectory: true)
    }

    /// Resolves this evening's Sky/Events chip data: ISS passes + aurora outlook via
    /// `SkyTonightService` (already fetched/cached for `TonightSkyCard`/`DoodleHeaderView`, so
    /// this is a cache hit in practice, not a second network round-trip), the meteor outlook
    /// (synchronous, no network), and launches via the cache-only path (work order: "do NOT add
    /// new network behavior — reuse the Space tab's service/cache; if no cache, no launch icons,
    /// fine").
    private func loadSkyContext(payload: CachedWeather) async {
        let result = await SkyTonightService.shared.state(
            locationId: location.id,
            latitude: location.latitude,
            longitude: location.longitude,
            date: viewModel.phraseBankDate,
            overrides: viewModel.skyForcedOverrides
        )
        let launches = await LaunchesUpcoming.cachedNextLaunchesIfFresh(
            cacheDirectory: Self.skyCacheDirectory,
            from: viewModel.phraseBankDate,
            count: 10
        )
        skyContext = HourlySkyContext(
            location: location,
            issPasses: SkyTonightService.availableValue(result.iss) ?? [],
            auroraOutlook: SkyTonightService.availableValue(result.aurora),
            meteorOutlook: result.meteor,
            launches: launches,
            onExplain: { presentedExplainer = $0 }
        )
    }

    /// Work item 1: tapping the hero caption scrolls to `TonightSkyCard` — reuses the exact same
    /// anchor `-scrollToSky`'s sim-verify hook already uses (see `scrollToTargetIfNeeded`'s doc
    /// comment for why `0.10` was chosen over `.top`/`0.22`).
    private func scrollToSkyCard(proxy: ScrollViewProxy) {
        withAnimation {
            proxy.scrollTo(TonightSkyCard.cardId, anchor: UnitPoint(x: 0.5, y: 0.10))
        }
    }

    private static let attributionFooterId = "attributionFooter"

    private func scrollToTargetIfNeeded(_ payload: CachedWeather, proxy: ScrollViewProxy) {
        guard !hasScrolledToTarget else { return }

        if scrollToAttribution {
            hasScrolledToTarget = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                proxy.scrollTo(Self.attributionFooterId, anchor: .bottom)
            }
            return
        }

        if scrollToSky {
            hasScrolledToTarget = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                // Sky-intelligence rows (WP-F) plus the Editor's-Choice "night panel" elevation's
                // dusk-to-dawn timeline strip have made a fully-loaded card (headline + timeline +
                // moon + 3 planets + aurora + meteor + ISS + conjunction) comfortably TALLER than
                // the visible scroll viewport on this device — there is no single `scrollTo`
                // anchor that can show both its header and its lower rows in one screenshot
                // anymore. Empirically re-tuned during this package's sim-verify (0.22, this
                // repo's earlier value, hid the header entirely once the card grew; `.top`/0.0
                // was, perhaps counterintuitively, no better) — 0.06 was the best of the three at
                // keeping at least the top of the headline in frame. Still an approximation, not
                // an exact fit; a real fix would need the floating top bar's height threaded in
                // as an actual content inset rather than an overlay, which is out of scope here.
                proxy.scrollTo(TonightSkyCard.cardId, anchor: UnitPoint(x: 0.5, y: 0.10))
            }
            return
        }

        // UX redesign part 2: the hourly list now only renders every other hour, so
        // `-scrollToHour N` is reinterpreted as the Nth DISPLAYED row (see
        // `HourlyForecastSection.hourlyIndex(forDisplayedRow:hours:)`) rather than a raw index
        // into the full-resolution `payload.hourly` array.
        if let displayedRow = scrollTargetHourIndex,
           let index = HourlyForecastSection.hourlyIndex(forDisplayedRow: displayedRow, hours: payload.hourly) {
            hasScrolledToTarget = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                proxy.scrollTo(HourlyForecastSection.rowId(for: payload.hourly[index]), anchor: .top)
            }
            return
        }

        // Sim-verify: if a day was auto-expanded via `-expandDay`, scroll to it so the
        // expansion is visible in a screenshot without needing a real tap.
        if let expandedDayId = viewModel.expandedDayId,
           let day = payload.daily.first(where: { $0.date == expandedDayId }) {
            hasScrolledToTarget = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                proxy.scrollTo(DailyForecastSection.rowId(for: day), anchor: .top)
            }
        }
    }

    private func staleBanner(_ fetchedAt: Date) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "wifi.slash")
            Text("As of \(fetchedAt.formatted(date: .omitted, time: .shortened))")
            Spacer()
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
        .padding(10)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Sheet chrome

    private static let sheetCornerRadius: CGFloat = 28

    /// The content sheet: `Color(.systemGroupedBackground)`, top corners rounded, pulled up to
    /// overlap the hero scene's bottom edge by `DoodleHeaderView.sheetOverlap` so the scene
    /// visibly curves behind it, per the redesign spec. `minHeight` lets the loading/error/empty
    /// states fill the remaining viewport so they don't look like a sliver of content floating
    /// under a mostly-empty scene.
    private func sheetSurface<Content: View>(minHeight: CGFloat? = nil, @ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(.horizontal, 16)
            .padding(.top, 20)
            // Extra clearance so the last content (attribution / centered state content) isn't
            // flush against the floating bottom bar (`NavigationShell.floatingBar`), which
            // overlays this screen.
            .padding(.bottom, 70)
            .frame(maxWidth: .infinity)
            .frame(minHeight: minHeight, alignment: .top)
            .background(
                Color(.systemGroupedBackground),
                in: UnevenRoundedRectangle(
                    topLeadingRadius: Self.sheetCornerRadius,
                    bottomLeadingRadius: 0,
                    bottomTrailingRadius: 0,
                    topTrailingRadius: Self.sheetCornerRadius,
                    style: .continuous
                )
            )
            .padding(.top, -DoodleHeaderView.sheetOverlap)
    }
}

private extension View {
    /// UX redesign part 2 (lead QC defect: scroll-aware top bar). Reports each `ScrollView`'s
    /// content offset via the iOS 18 `onScrollGeometryChange` API (available — this target's
    /// deployment target is 18.0) rather than a manual `GeometryReader`/`PreferenceKey` probe,
    /// which is fragile against SwiftUI's internal scroll-content layout passes. `contentOffset.y`
    /// is ~0 at rest (these scroll views bleed under the top safe area, so there's no positive
    /// inset baked into "resting") and grows positively as the user scrolls down.
    /// Also disables iOS 26's automatic top scroll-edge effect: because these scroll views bleed
    /// under the navigation bar, the system injects a dim/blur gradient over the top of the hero
    /// scene (subtle in light mode, a heavy smoky band in dark). The scroll-aware toolbar already
    /// provides the scrolled-state treatment explicitly, so the automatic effect is pure defect
    /// here. Scoped to the Forecast surface only — other screens keep the system behavior.
    @ViewBuilder
    func trackingHeroScrollOffset(_ onChange: @escaping (CGFloat) -> Void) -> some View {
        let tracked = onScrollGeometryChange(for: CGFloat.self) { geometry in
            geometry.contentOffset.y
        } action: { _, newValue in
            onChange(newValue)
        }
        if #available(iOS 26.0, *) {
            tracked.scrollEdgeEffectHidden(true, for: .top)
        } else {
            // Pre-iOS 26 has no automatic scroll-edge effect to suppress.
            tracked
        }
    }

    /// UX polish package ("Depth & motion" — hero parallax). Applied to the hero while it's
    /// still a normal in-flow child of the scrolling `VStack` (not pulled out into a separate
    /// background layer — "cheap, no continuous timers" per the design spec), so it needs care
    /// to avoid revealing a blank gap above the hero as it's pushed down.
    ///
    /// **On downward scroll** (`scrollOffset > 0`): offsetting the hero down by `0.6 * offset`
    /// makes its remaining visible height shrink at only `1 - 0.6 = 0.4x` the normal 1x rate —
    /// i.e. the *net* apparent scroll rate the design spec asks for ("translates at ~0.4x scroll
    /// rate") — while the sheet below it, which gets no offset, keeps scrolling normally. (The
    /// literal spec snippet was `offset(y: offset * 0.4)`; applied directly that only yields a
    /// 0.6x apparent rate for an in-flow view, so the complementary 0.6 coefficient is what's
    /// needed to actually hit 0.4x — verified against `polish-parallax.png`.) This never uncovers
    /// blank space: the region that would be exposed at the very top of the hero is always
    /// already scrolled above the visible viewport (0.6·offset < offset for any offset > 0).
    ///
    /// **On upward overscroll / pull-down-past-top** (`scrollOffset < 0`, e.g. rubber-banding at
    /// rest): no offset; instead a top-anchored `scaleEffect` stretches the hero to fill the
    /// gap the pull reveals, the classic "stretchy header" rubber-band look.
    func parallax(scrollOffset: CGFloat) -> some View {
        let downwardOffset = max(scrollOffset, 0) * 0.6
        let overscroll = max(-scrollOffset, 0)
        let scale = 1 + overscroll / DoodleHeaderView.heroHeight
        return self
            .offset(y: downwardOffset)
            .scaleEffect(scale, anchor: .top)
    }
}
