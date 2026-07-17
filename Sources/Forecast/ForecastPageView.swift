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
        // left a white band exactly the status bar's height above the hero. Each state passes
        // this measured inset to `heroHeader`, which pulls the hero up by exactly that amount.
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
        .trackingHeroScrollOffset(onScrollOffsetChange)
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
        .trackingHeroScrollOffset(onScrollOffsetChange)
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
        .trackingHeroScrollOffset(onScrollOffsetChange)
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

                            ForecastSheetCard(title: "HOURLY FORECAST") {
                                HourlyForecastSection(hours: payload.hourly, metric: viewModel.selectedMetric)
                            }

                            ForecastSheetCard(title: "DAILY FORECAST") {
                                DailyForecastSection(
                                    daily: payload.daily,
                                    hourly: payload.hourly,
                                    metric: viewModel.selectedMetric,
                                    expandedDayId: $viewModel.expandedDayId
                                )
                            }

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
            .trackingHeroScrollOffset(onScrollOffsetChange)
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

/// A white (`.secondarySystemGroupedBackground`, so dark mode inverts correctly) rounded card on
/// the content sheet's gray surface, with a small uppercase header and a hairline divider — the
/// chrome for the hourly/daily cards per the redesign spec (see reference `IMG_1173.png`).
private struct ForecastSheetCard<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
            Divider()
            content
        }
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

private extension View {
    /// UX redesign part 2 (lead QC defect: scroll-aware top bar). Reports each `ScrollView`'s
    /// content offset via the iOS 18 `onScrollGeometryChange` API (available — this target's
    /// deployment target is 18.0) rather than a manual `GeometryReader`/`PreferenceKey` probe,
    /// which is fragile against SwiftUI's internal scroll-content layout passes. `contentOffset.y`
    /// is ~0 at rest (these scroll views bleed under the top safe area, so there's no positive
    /// inset baked into "resting") and grows positively as the user scrolls down.
    func trackingHeroScrollOffset(_ onChange: @escaping (CGFloat) -> Void) -> some View {
        onScrollGeometryChange(for: CGFloat.self) { geometry in
            geometry.contentOffset.y
        } action: { _, newValue in
            onChange(newValue)
        }
    }
}
