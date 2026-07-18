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
    /// UX polish package ("Depth & motion" — hero parallax): the same content-scroll offset the
    /// scroll-aware top bar already tracks (`onScrollOffsetChange`), mirrored into local state so
    /// `heroHeader` can apply a parallax offset/overscroll scale to the hero without needing a
    /// second scroll probe.
    @State private var scrollOffset: CGFloat = 0

    /// Approximate remaining viewport height below the hero, so the loading/error/empty sheets
    /// fill the screen and center their content the same way the hero+sheet shell will once real
    /// content loads, rather than being sized to whatever their (short) content needs.
    private var stateSheetMinHeight: CGFloat {
        max(UIScreen.main.bounds.height - DoodleHeaderView.heroHeight, 320)
    }

    var body: some View {
        // The GeometryReader exists to measure this page's *top safe-area inset* (status bar /
        // Dynamic Island). The ScrollViews below all `ignoresSafeArea(edges: .top)`, but the
        // `TabView(.page)` container reintroduces that inset to their *content* regardless
        // (verified empirically — the scroll viewport reaches y=0, its content doesn't), which
        // left a white band above the hero. Each state passes this measured inset to
        // `heroHeader`/`loadedView`, which pulls the hero up by exactly that amount.
        //
        // Custom top chrome (replacing the system nav bar so iOS 26's Liquid Glass scroll-edge
        // effect can be hidden — see `ForecastView.body`'s comment) removed the one visible
        // signal `geo.safeAreaInsets.top` used to track: with the nav bar gone, this reads 0,
        // yet the paging `UICollectionView` backing `TabView(.page)` was still silently
        // reintroducing its own top content inset regardless — a residual white strip at the
        // very top that neither this measurement nor `ignoresSafeArea` alone could reach, since
        // it's applied *inside* the collection view's own content layout, below where SwiftUI's
        // safe-area/ignoresSafeArea machinery operates. Fixed at the source, once, in
        // `ForecastView.pagerView` (`PagingCollectionViewInsetFix`), which disables that
        // collection view's automatic content-inset adjustment entirely — after that fix,
        // `geo.safeAreaInsets.top` here is simply 0 and this whole mechanism is a no-op, kept
        // in place (rather than deleted) so a future device/OS combination that reintroduces a
        // real nonzero inset is still handled automatically instead of silently regressing.
        GeometryReader { geo in
            Group {
                switch page.screenState {
                case .loading:
                    loadingView(topInset: geo.safeAreaInsets.top)
                case .error(let message):
                    errorView(message, topInset: geo.safeAreaInsets.top)
                case .loaded:
                    if let payload = page.payload {
                        loadedView(payload, topInset: geo.safeAreaInsets.top)
                    } else {
                        emptyStateView(topInset: geo.safeAreaInsets.top)
                    }
                }
            }
        }
    }

    /// The full-bleed hero for a state with no payload (loading/error/empty), pulled up over
    /// the status-bar inset — see `body`'s comment for why the pull-up is a measured negative
    /// padding rather than `ignoresSafeArea` alone.
    private func heroHeader(topInset: CGFloat) -> some View {
        DoodleHeaderView(current: nil, caption: nil)
            .padding(.top, -topInset)
            .parallax(scrollOffset: scrollOffset)
    }

    /// Forwards a scroll offset reading both up to `onScrollOffsetChange` (the scroll-aware top
    /// bar's existing consumer) and into local `scrollOffset` state (the hero parallax's
    /// consumer) — one probe, two readers.
    private func reportScrollOffset(_ offset: CGFloat) {
        onScrollOffsetChange(offset)
        scrollOffset = offset
    }

    // MARK: - Loading

    private func loadingView(topInset: CGFloat) -> some View {
        ScrollView {
            VStack(spacing: 0) {
                heroHeader(topInset: topInset)
                sheetSurface(minHeight: stateSheetMinHeight) {
                    centeredStateContent {
                        ProgressView("Consulting the sky.")
                            .tint(.secondary)
                    }
                }
            }
        }
        .ignoresSafeArea(edges: .top)
        .trackingHeroScrollOffset(reportScrollOffset)
    }

    // MARK: - Error

    private func errorView(_ message: String, topInset: CGFloat) -> some View {
        ScrollView {
            VStack(spacing: 0) {
                heroHeader(topInset: topInset)
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
        .trackingHeroScrollOffset(reportScrollOffset)
    }

    // MARK: - Empty (defensive — a location with a `.loaded` state but no payload)

    private func emptyStateView(topInset: CGFloat) -> some View {
        ScrollView {
            VStack(spacing: 0) {
                heroHeader(topInset: topInset)
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
    private func loadedView(_ payload: CachedWeather, topInset: CGFloat) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    DoodleHeaderView(
                        current: payload.currentConditions,
                        caption: viewModel.doodleCaptionLine(location: location, payload: payload, unit: unitsSettings.unit),
                        date: viewModel.phraseBankDate,
                        sunrise: payload.daily.first?.sunrise,
                        sunset: payload.daily.first?.sunset,
                        forcedCondition: viewModel.forcedDoodleCondition,
                        forcedTimeOfDay: viewModel.forcedDoodleTimeOfDay
                    )
                    // See `body`'s comment: pulls the hero up over the status-bar inset that
                    // the TabView container reintroduces to this scroll content.
                    .padding(.top, -topInset)
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
                                HourlyForecastSection(hours: payload.hourly, metric: viewModel.selectedMetric)
                            }

                            SheetCard(title: "DAILY FORECAST") {
                                DailyForecastSection(
                                    daily: payload.daily,
                                    hourly: payload.hourly,
                                    metric: viewModel.selectedMetric,
                                    expandedDayId: $viewModel.expandedDayId,
                                    currentTemperature: payload.currentConditions.temperature
                                )
                            }

                            // `TonightSkyCard` applies its own `.id(TonightSkyCard.cardId)`
                            // internally (to its `SheetCard`), which is what `-scrollToSky`
                            // below targets — no separate id needed at the mount site.
                            TonightSkyCard(
                                location: location,
                                date: viewModel.phraseBankDate,
                                forcedOverrides: viewModel.skyForcedOverrides,
                                initialExpandedPlanet: viewModel.initialExpandedSkyPlanet
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
            .trackingHeroScrollOffset(reportScrollOffset)
            .refreshable {
                await onRefresh()
            }
            .sheet(isPresented: $isPresentingAlertDetail) {
                AlertDetailSheet(alerts: payload.activeAlerts)
            }
            .onAppear {
                scrollToTargetIfNeeded(payload, proxy: proxy)
            }
            .onChange(of: viewModel.selectedMetric) {
                scrollToTargetIfNeeded(payload, proxy: proxy)
            }
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
                // Sky-intelligence rows (work package WP-F) made the card tall enough, on a
                // fully-loaded evening (headline + meteor + conjunction all present), that
                // `anchor: .top` can now scroll all the way to the card's literal top edge —
                // which sits exactly at the scroll content's y=0, directly under the floating
                // translucent top bar (`NavigationShell`'s scroll-aware chrome), cropping the
                // card's title/headline underneath it. (On a shorter card — fewer rows present —
                // the scroll view previously couldn't scroll far enough to reach that position at
                // all, which is why this wasn't visible before this work package.) A small
                // positive `anchor.y` leaves deliberate headroom above the card's top edge
                // instead of pinning it to the very top, clearing the floating bar.
                proxy.scrollTo(TonightSkyCard.cardId, anchor: UnitPoint(x: 0.5, y: 0.22))
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
