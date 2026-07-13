import SwiftUI

/// Screen A from PRD Section 6: the Forecast screen. Top to bottom: doodle header, current
/// conditions, advisory banner (when present), summary/comparison placeholder lines, metric
/// chips, hourly list with positional pills, 10-day forecast with inline expansion, and Apple
/// Weather attribution. Renders every state in the Section 6 state table via
/// `ForecastViewModel.screenState` / `cacheState`.
struct ForecastView: View {
    @Bindable var viewModel: ForecastViewModel
    @State private var isPresentingAlertDetail = false
    /// Sim-verify only: scrolls the hourly list to a given hour index on load so a screenshot
    /// can show a specific part of the list without needing a tap (`simctl` can't tap/swipe).
    var scrollTargetHourIndex: Int? = nil
    @State private var hasScrolledToTarget = false

    var body: some View {
        NavigationStack {
            Group {
                switch viewModel.screenState {
                case .loading:
                    loadingView
                case .error(let message):
                    errorView(message)
                case .loaded:
                    if let payload = viewModel.payload {
                        loadedView(payload)
                    } else {
                        // Defensive: PRD's "no active location" empty state. Not reachable in
                        // Phase 2 since the active location always defaults to Tomah, WI, but
                        // kept so the screen degrades gracefully rather than blanking.
                        emptyStateView
                    }
                }
            }
            .navigationTitle(viewModel.locationName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    // Settings (Phase 3 scope) opens from here per PRD Section 6; placeholder
                    // affordance only for now.
                    Image(systemName: "ellipsis.circle")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .task {
            if viewModel.payload == nil {
                await viewModel.load()
            }
        }
    }

    // MARK: - Loading

    private var loadingView: some View {
        VStack(spacing: 16) {
            DoodleHeaderView(current: nil, caption: nil)
            Spacer()
            ProgressView("Consulting the sky.")
                .tint(.secondary)
            Spacer()
            Spacer()
        }
    }

    // MARK: - Error

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 16) {
            DoodleHeaderView(current: nil, caption: nil)
            Spacer()
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.icloud")
                    .font(.system(size: 40))
                    .foregroundStyle(.secondary)
                Text("The sky isn't answering.")
                    .font(.headline)
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                Button("Retry") {
                    Task { await viewModel.load() }
                }
                .buttonStyle(.borderedProminent)
            }
            Spacer()
            Spacer()
        }
    }

    // MARK: - Empty (no active location)

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
            }
            Spacer()
            Spacer()
        }
    }

    // MARK: - Loaded

    @ViewBuilder
    private func loadedView(_ payload: CachedWeather) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    DoodleHeaderView(current: payload.currentConditions, caption: nil)

                    if viewModel.cacheState == .stale {
                        staleBanner(payload.fetchedAt)
                            .padding(.horizontal)
                    }

                    CurrentConditionsView(current: payload.currentConditions)
                        .padding(.horizontal)

                    if !payload.activeAlerts.isEmpty {
                        AdvisoryBanner(alerts: payload.activeAlerts, isPresentingDetail: $isPresentingAlertDetail)
                            .padding(.horizontal)
                    }

                    PlaceholderCopyLines()
                        .padding(.horizontal)

                    MetricChipsRow(selected: $viewModel.selectedMetric)
                        .padding(.horizontal)

                    HourlyForecastSection(hours: payload.hourly, metric: viewModel.selectedMetric)
                        .padding(.horizontal)

                    DailyForecastSection(
                        daily: payload.daily,
                        hourly: payload.hourly,
                        metric: viewModel.selectedMetric,
                        expandedDayId: $viewModel.expandedDayId
                    )
                    .padding(.horizontal)

                    AttributionFooter(attribution: payload.attribution)
                }
                .padding(.bottom, 12)
            }
            .refreshable {
                await viewModel.refresh()
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

    private func scrollToTargetIfNeeded(_ payload: CachedWeather, proxy: ScrollViewProxy) {
        guard !hasScrolledToTarget else { return }

        if let index = scrollTargetHourIndex, payload.hourly.indices.contains(index) {
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
        .background(Color(.secondarySystemFill), in: RoundedRectangle(cornerRadius: 10))
    }
}
