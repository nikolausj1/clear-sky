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

    var body: some View {
        NavigationStack {
            Group {
                if viewModel.locations.isEmpty {
                    emptyStateView
                } else {
                    pagerView
                }
            }
            // UX redesign part 1: the hero (`DoodleHeaderView`, inside `ForecastPageView`) now
            // bleeds up under the status bar/nav bar via `ignoresSafeArea(edges: .top)`, so the
            // nav bar itself is made transparent here and its title/button restyled white (with
            // a shadow on the title for legibility) so it reads as sitting on the scene rather
            // than on an opaque bar. `.navigationTitle` is kept empty (rather than removed) so
            // `.navigationBarTitleDisplayMode(.inline)` still has a title to lay out around; the
            // actual visible title is the white `Text` in the `.principal` toolbar item below.
            //
            // UX redesign part 2 (lead QC defect): that transparent-white treatment left the
            // title unreadable once list content scrolled underneath it. Past
            // `isHeroScrolledAway`, the bar gets a real material background and the title/button
            // switch to `.primary`/legible-on-material colors; below that threshold it's back to
            // the original transparent-on-scene look. Both states are driven by the same
            // `isHeroScrolledAway` flag so they never disagree, and the switch is animated.
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.ultraThinMaterial, for: .navigationBar)
            .toolbarBackground(isHeroScrolledAway ? .visible : .hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text(viewModel.locationName)
                        .font(.headline)
                        .foregroundStyle(isHeroScrolledAway ? Color.primary : Color.white)
                        .shadow(color: .black.opacity(isHeroScrolledAway ? 0 : 0.35), radius: 3, y: 1)
                }
                ToolbarItem(placement: .primaryAction) {
                    Button(action: onOpenSettings) {
                        Image(systemName: "ellipsis.circle")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(isHeroScrolledAway ? Color.primary : Color.white)
                            .padding(6)
                            .background(.thinMaterial, in: Circle())
                    }
                }
            }
            .animation(.easeInOut(duration: 0.2), value: isHeroScrolledAway)
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
                        // Only the active page's scroll offset should drive the shared bar
                        // state — an inactive page's `ScrollView` can report stale/irrelevant
                        // offsets (e.g. from before a swipe) that would otherwise fight the
                        // active page's own readings.
                        onScrollOffsetChange: index == viewModel.activeIndex ? { updateHeroScrolledAway(forOffset: $0) } : { _ in },
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
