import SwiftUI

/// One page of the Forecast pager — everything `ForecastView` rendered in Phase 2 for a single
/// location, now parameterized by an explicit `location` + `page` state instead of reading a
/// singular `viewModel.payload`, so `ForecastView` can host one of these per saved location
/// inside a `TabView` for horizontal swipe-paging (PRD Screen B: "The Forecast screen also
/// supports horizontal swipe to page between saved locations").
struct ForecastPageView: View {
    let location: SavedLocation
    let page: ForecastViewModel.PageState
    /// Sim-verify only: scrolls the hourly list to a given hour index on load (only meaningful
    /// for the page that's active at launch — `simctl` can't scroll/swipe either).
    var scrollTargetHourIndex: Int? = nil
    @Bindable var viewModel: ForecastViewModel
    var onRetry: () -> Void
    var onRefresh: () async -> Void

    @Environment(UnitsSettings.self) private var unitsSettings
    @State private var isPresentingAlertDetail = false
    @State private var hasScrolledToTarget = false

    var body: some View {
        Group {
            switch page.screenState {
            case .loading:
                loadingView
            case .error(let message):
                errorView(message)
            case .loaded:
                if let payload = page.payload {
                    loadedView(payload)
                } else {
                    emptyStateView
                }
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
            Spacer()
            Spacer()
        }
    }

    // MARK: - Empty (defensive — a location with a `.loaded` state but no payload)

    private var emptyStateView: some View {
        VStack(spacing: 16) {
            DoodleHeaderView(current: nil, caption: nil)
            Spacer()
            VStack(spacing: 12) {
                Image(systemName: "location.slash")
                    .font(.system(size: 36))
                    .foregroundStyle(.secondary)
                Text("No forecast yet.")
                    .font(.headline)
                Text(PhraseBank.errorState(.generic, date: viewModel.phraseBankDate, locationId: location.id))
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
                    DoodleHeaderView(
                        current: payload.currentConditions,
                        caption: viewModel.doodleCaptionLine(location: location, payload: payload, unit: unitsSettings.unit),
                        date: viewModel.phraseBankDate,
                        sunrise: payload.daily.first?.sunrise,
                        sunset: payload.daily.first?.sunset,
                        forcedCondition: viewModel.forcedDoodleCondition,
                        forcedTimeOfDay: viewModel.forcedDoodleTimeOfDay
                    )

                    if page.cacheState == .stale {
                        staleBanner(payload.fetchedAt)
                            .padding(.horizontal)
                    }

                    CurrentConditionsView(current: payload.currentConditions)
                        .padding(.horizontal)

                    if !payload.activeAlerts.isEmpty {
                        AdvisoryBanner(alerts: payload.activeAlerts, isPresentingDetail: $isPresentingAlertDetail)
                            .padding(.horizontal)
                    }

                    CopyLinesView(
                        summary: viewModel.summaryLine(location: location, payload: payload, unit: unitsSettings.unit),
                        comparison: viewModel.comparisonLine(location: location, payload: payload, unit: unitsSettings.unit)
                    )
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
                // Extra clearance so the last content (attribution) isn't flush against the
                // floating bottom bar (`NavigationShell.floatingBar`), which overlays this screen.
                .padding(.bottom, 70)
            }
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
