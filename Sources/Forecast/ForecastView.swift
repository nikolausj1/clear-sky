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
            .navigationTitle(viewModel.locationName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button(action: onOpenSettings) {
                        Image(systemName: "ellipsis.circle")
                    }
                    .foregroundStyle(.secondary)
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
                        viewModel: viewModel,
                        onRetry: { Task { await viewModel.load(location: location, forceRefresh: false) } },
                        onRefresh: { await viewModel.load(location: location, forceRefresh: true) }
                    )
                    .tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))

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
                Text("No active location.")
                    .font(.headline)
                Text("Search for a city to see its forecast.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Button("Search for a City", action: onOpenLocations)
                    .buttonStyle(.borderedProminent)
                    .padding(.top, 4)
            }
            Spacer()
            Spacer()
        }
    }
}
