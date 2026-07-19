import SwiftUI

/// Screen A from PRD Section 6: the Forecast screen. Hosts one `ForecastPageView` per saved
/// location inside a horizontally-paged `TabView` (Screen B: "The Forecast screen also supports
/// horizontal swipe to page between saved locations directly ... with a page indicator"), plus
/// the shared title bar and the top-right ellipsis that opens Settings.
struct ForecastView: View {
    @Bindable var viewModel: ForecastViewModel
    /// Sim-verify only: scrolls the hourly list to a given hour index on load so a screenshot
    /// can show a specific part of the list without needing a tap (`simctl` can't tap/swipe).
    var scrollTargetHourIndex: Int? = nil
    /// Sim-verify only (Phase 7): `-scrollToAttribution` — see `ForecastPageView`'s doc comment.
    var scrollToAttribution: Bool = false
    /// Sim-verify only ("Tonight's Sky" work package): `-scrollToSky` — see
    /// `ForecastPageView`'s doc comment.
    var scrollToSky: Bool = false
    /// Sim-verify only (Forecast-surface overhaul, work item 4): `-showExplainer <key>` — see
    /// `ForecastPageView`'s doc comment.
    var forcedExplainerKey: String? = nil
    /// Sim-verify only ("People in Space" work package): `-showPeopleSheet` — see
    /// `TonightSkyCard.init`'s doc comment.
    var showPeopleSheetAtLaunch: Bool = false
    /// Sim-verify only (always-dark audit sweep): `-showAlertDetail` — see
    /// `ForecastPageView.showAlertDetailAtLaunch`'s doc comment.
    var showAlertDetailAtLaunch: Bool = false
    /// Notifications work package: forwarded straight through to every page's `TonightSkyCard`
    /// — see that file's doc comment on `onSkyStateResolved`.
    var onSkyStateResolved: (SavedLocation) -> Void = { _ in }
    var onOpenSettings: () -> Void = {}
    var onOpenLocations: () -> Void = {}

    /// UX redesign part 2 (lead QC defect: scroll-aware top bar). `true` once the active page has
    /// scrolled far enough that the hero is mostly off-screen; drives the nav bar's transparent
    /// vs. material treatment. Only the active page's `ForecastPageView` reports its offset (see
    /// `pagerView`), so swiping to a different page re-syncs this to whatever that page's own
    /// scroll position is.
    @State private var isHeroScrolledAway = false

    /// Thresholds (fractions of the hero's height) with hysteresis, so a scroll position
    /// hovering right at one boundary doesn't flicker the bar back and forth: scrolling DOWN
    /// past `showThreshold` switches to the material bar; scrolling back UP past `hideThreshold`
    /// (a smaller fraction, i.e. requiring more upward scroll before reverting) switches back to
    /// transparent. "Hero mostly off-screen" is interpreted as ~65% of it scrolled past.
    private static let showThresholdFraction: CGFloat = 0.65
    private static let hideThresholdFraction: CGFloat = 0.45

    /// Standard inline-nav-bar content height, reused for the custom top chrome bar so it reads
    /// as a drop-in replacement for the system bar it stands in for.
    private static let chromeBarHeight: CGFloat = 44

    var body: some View {
        NavigationStack {
            // The system navigation bar applies iOS 26's Liquid Glass "scroll edge effect" — a
            // progressive blur+dim over the top ~12% of the screen — whenever content scrolls
            // under it. This is NOT controllable via `.toolbarBackground` visibility,
            // `.scrollEdgeEffectHidden` (any placement), or `.statusBarHidden`: all verified
            // empirically to leave the effect in place. Hiding the bar entirely is the only fix
            // that removes it, so the bar is replaced below with custom top chrome that
            // reproduces its title/button/material behavior without the system's blur.
            //
            // The GeometryReader wraps the content BEFORE any `ignoresSafeArea` applied deeper
            // inside (`pagerView`/`emptyStateView`'s hero bleed), so `proxy.safeAreaInsets.top`
            // reports the real status bar/Dynamic Island inset rather than 0 — same measurement
            // technique `ForecastPageView.body` already uses for the hero bleed.
            GeometryReader { proxy in
                Group {
                    if viewModel.locations.isEmpty {
                        emptyStateView
                    } else {
                        pagerView
                    }
                }
                .overlay(alignment: .top) {
                    topChromeBar(topInset: proxy.safeAreaInsets.top)
                }
            }
            .toolbar(.hidden, for: .navigationBar)
        }
        .task {
            if viewModel.locations.isEmpty {
                await viewModel.loadAllPages()
            }
        }
        // Swiping to a different location page doesn't guarantee a fresh
        // `onScrollGeometryChange` firing for the newly-active page (it only fires on an actual
        // geometry change, and `TabView(.page)` keeps every page mounted) — reset eagerly so the
        // bar doesn't stay stuck in whatever state the previous page left it in.
        .onChange(of: viewModel.activeIndex) {
            isHeroScrolledAway = false
        }
    }

    /// Applies the show/hide thresholds (with hysteresis) to a raw scroll offset reported by the
    /// active page. A no-op if the offset doesn't cross whichever boundary is relevant to the
    /// current state, so a single stray reading can't cause a flicker.
    private func updateHeroScrolledAway(forOffset offset: CGFloat) {
        let heroHeight = DoodleHeaderView.heroHeight
        if !isHeroScrolledAway && offset > heroHeight * Self.showThresholdFraction {
            isHeroScrolledAway = true
        } else if isHeroScrolledAway && offset < heroHeight * Self.hideThresholdFraction {
            isHeroScrolledAway = false
        }
    }

    // MARK: - Custom top chrome (replaces the system navigation bar)

    /// Stands in for the system navigation bar (hidden via `.toolbar(.hidden, for: .navigationBar)`
    /// on the enclosing `NavigationStack` — see `body`'s comment for why). Salvaged from the old
    /// `.toolbar { ToolbarItem... }` block: same centered title + trailing ellipsis button,
    /// same two visual states driven by `isHeroScrolledAway`.
    ///
    /// - Over-hero (`false`): transparent background, title/icon white with a shadow so they
    ///   read against the scene rather than a bar.
    /// - Scrolled (`true`): `.ultraThinMaterial` background (full-width, covering the status-bar
    ///   area down through the bar) with a bottom hairline, title/icon `.primary`, no shadow.
    ///
    /// `topInset` is measured by the caller (see `body`) rather than hardcoded, so this sits
    /// correctly below the status bar/Dynamic Island on every device. The bar's own
    /// `ignoresSafeArea` lets its background extend all the way to the true screen edge (y = 0)
    /// while `Spacer(height: topInset)` keeps the title/button row itself below the status bar.
    private func topChromeBar(topInset: CGFloat) -> some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
                .frame(height: topInset)

            HStack {
                Spacer()
                Text(viewModel.locationName)
                    .font(.headline)
                    .foregroundStyle(isHeroScrolledAway ? Color.primary : Color.white)
                    .shadow(color: .black.opacity(isHeroScrolledAway ? 0 : 0.35), radius: 3, y: 1)
                Spacer()
            }
            .overlay(alignment: .trailing) {
                Button(action: onOpenSettings) {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(isHeroScrolledAway ? Color.primary : Color.white)
                        .padding(6)
                        .background(.thinMaterial, in: Circle())
                }
            }
            .padding(.horizontal, 16)
            .frame(height: Self.chromeBarHeight)
        }
        .frame(maxWidth: .infinity)
        .background {
            if isHeroScrolledAway {
                VStack(spacing: 0) {
                    Rectangle()
                        .fill(.ultraThinMaterial)
                    Rectangle()
                        .fill(Color(.separator).opacity(0.3))
                        .frame(height: 0.5)
                }
            }
        }
        .ignoresSafeArea(edges: .top)
        .animation(.easeInOut(duration: 0.2), value: isHeroScrolledAway)
    }

    // MARK: - Pager

    private var pagerView: some View {
        VStack(spacing: 6) {
            TabView(selection: $viewModel.activeIndex) {
                ForEach(Array(viewModel.locations.enumerated()), id: \.element.id) { index, location in
                    ForecastPageView(
                        location: location,
                        page: viewModel.state(for: location),
                        scrollTargetHourIndex: index == viewModel.activeIndex ? scrollTargetHourIndex : nil,
                        scrollToAttribution: index == viewModel.activeIndex && scrollToAttribution,
                        scrollToSky: index == viewModel.activeIndex && scrollToSky,
                        forcedExplainerKey: index == viewModel.activeIndex ? forcedExplainerKey : nil,
                        showPeopleSheetAtLaunch: index == viewModel.activeIndex && showPeopleSheetAtLaunch,
                        showAlertDetailAtLaunch: index == viewModel.activeIndex && showAlertDetailAtLaunch,
                        // Only the active page's scroll offset should drive the shared bar
                        // state — an inactive page's `ScrollView` can report stale/irrelevant
                        // offsets (e.g. from before a swipe) that would otherwise fight the
                        // active page's own readings.
                        onScrollOffsetChange: index == viewModel.activeIndex ? { updateHeroScrolledAway(forOffset: $0) } : { _ in },
                        onSkyStateResolved: onSkyStateResolved,
                        viewModel: viewModel,
                        onRetry: { Task { await viewModel.load(location: location, forceRefresh: false) } },
                        onRefresh: { await viewModel.load(location: location, forceRefresh: true) }
                    )
                    .tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            // UX redesign part 1: `DoodleHeaderView`'s own `ignoresSafeArea(edges: .top)` (deep
            // inside each page's `ScrollView`) doesn't propagate past the `TabView(.page)`
            // boundary — verified empirically: without this, every page rendered an opaque nav
            // bar with the hero starting below it instead of bleeding under the status bar.
            // Ignoring the safe area on the `TabView` itself (this exact container, not a child
            // buried inside one page's scroll content) is what actually lets each page's hero
            // extend under the status bar/nav bar.
            .ignoresSafeArea(edges: .top)
            // Custom top chrome fix, part 2 — HISTORICAL, removed (true-sky doodle QC fix,
            // defect 1): this used to also carry `.background(PagingCollectionViewInsetFix())`,
            // which walked up from an invisible probe view to find the paging `UICollectionView`
            // backing this `TabView(.page)` and disable its automatic content-inset adjustment,
            // because that collection view was found (empirically, via a temporary red
            // `.background`) to silently reintroduce its own top content inset to every page
            // regardless of `ignoresSafeArea` above.
            //
            // Root-caused during the true-sky doodle QC pass: on the current iOS/SwiftUI
            // runtime, `TabView(.page)` is no longer backed by a `UICollectionView` at all
            // (confirmed by logging the probe's full `superview` chain — zero `UICollectionView`
            // anywhere in it), so this fix had silently become a no-op. Separately, direct
            // `.onGeometryChange` measurement of a page's scroll content confirmed it already
            // rests at true `y = 0` with `ignoresSafeArea` alone — there is no residual inset
            // left for this fix to correct on this runtime. Removed rather than chasing a new
            // private view to poke; if a future OS/SwiftUI version reintroduces a real residual
            // inset here, it should show up as the same symptom this whole investigation started
            // from (the hero's sky content — moon, stars, true-sky planet dots — creeping up
            // behind the status bar/Dynamic Island in `_review/truesky-*.png` sim-verify shots)
            // rather than as a silently-reapplied private-API workaround.

            if viewModel.locations.count > 1 {
                pageIndicator
            }
        }
    }

    private var pageIndicator: some View {
        HStack(spacing: 6) {
            ForEach(viewModel.locations.indices, id: \.self) { index in
                Circle()
                    .fill(index == viewModel.activeIndex ? Color.primary : Color.secondary.opacity(0.3))
                    .frame(width: 6, height: 6)
            }
        }
        // Clears the floating bottom bar (`NavigationShell.floatingBar`), which overlays this
        // screen at a fixed position — without this the dots render directly underneath it.
        .padding(.bottom, 74)
    }

    // MARK: - Empty (no saved locations at all)

    private var emptyStateView: some View {
        VStack(spacing: 16) {
            DoodleHeaderView(current: nil, caption: nil)
            Spacer()
            VStack(spacing: 12) {
                Image(systemName: "location.slash")
                    .font(.system(size: 36))
                    .foregroundStyle(.secondary)
                // PRD Section 6 "No saved locations" state, Screen A: dry-wit nudge to search.
                Text(PhraseBank.emptyState(.noLocations, date: viewModel.phraseBankDate))
                    .font(.headline)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                Button("Search for a City", action: onOpenLocations)
                    .buttonStyle(.borderedProminent)
                    .padding(.top, 4)
            }
            Spacer()
            Spacer()
        }
        // Same full-bleed hero treatment as the per-location pages (see `pagerView`'s
        // `ignoresSafeArea` comment) so the no-locations state doesn't render the scene
        // awkwardly pushed down below a transparent nav bar.
        .ignoresSafeArea(edges: .top)
    }
}
