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
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text(viewModel.locationName)
                        .font(.headline)
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
                }
                ToolbarItem(placement: .primaryAction) {
                    Button(action: onOpenSettings) {
                        Image(systemName: "ellipsis.circle")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(6)
                            .background(.thinMaterial, in: Circle())
                    }
                }
            }
        }
        .task {
            if viewModel.locations.isEmpty {
                await viewModel.loadAllPages()
            }
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
