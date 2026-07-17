import SwiftData
import SwiftUI

/// Root container for Phase 3+. Hosts the floating bottom bar (Forecast | Rankings)
/// plus a search/locations button that presents the Locations screen as a sheet, per PRD Section
/// 6's "Navigation structure." The Forecast screen's top-right ellipsis (wired via
/// `onOpenSettings`) presents Settings as a sheet. Also the home for this phase's sim-verify
/// launch-arg hooks (Project Build Guide's autostart-hook pattern):
///
/// - `-showLocations` presents the Locations sheet at launch.
/// - `-showSettings` presents the Settings sheet at launch.
/// - `-showRankings` selects the Rankings tab at launch (mirrors `-showLocations`; `simctl`
///   can't tap the floating bottom bar for a screenshot of the non-default tab).
/// - `-locationDenied` forces `CurrentLocationManager` to report a denied permission status.
/// - `-locationGranted` forces `CurrentLocationManager` to report an already-authorized status
///   with a canned coordinate — works around a Simulator limitation where `simctl privacy grant
///   location` doesn't reliably suppress the system permission alert (see
///   `CurrentLocationManager`'s doc comment); `simctl` also can't tap through that alert.
/// - `-seedLocations "City,ST;City,ST"` seeds saved locations before the first load.
/// - `-activeLocationIndex <n>` starts the Forecast pager on the nth seeded location instead of
///   the first — `simctl` can't swipe the pager for a screenshot of a non-default page.
/// - `-scrollToAttribution` (Phase 7) scrolls the active Forecast page straight to the
///   `AttributionFooter` for a sim-verify screenshot — `simctl` can't scroll.
struct NavigationShell: View {
    private enum Tab {
        case forecast
        case rankings
    }

    @Environment(\.modelContext) private var modelContext

    @State private var forecastViewModel: ForecastViewModel?
    @State private var locationsViewModel: LocationsViewModel?
    @State private var rankingsViewModel: RankingsViewModel?
    @State private var unitsSettings = UnitsSettings()
    @State private var selectedTab: Tab = .forecast
    @State private var isPresentingLocations = false
    @State private var isPresentingSettings = false

    var body: some View {
        ZStack(alignment: .bottom) {
            Group {
                switch selectedTab {
                case .forecast:
                    if let forecastViewModel {
                        ForecastView(
                            viewModel: forecastViewModel,
                            scrollTargetHourIndex: Self.scrollToHourFromLaunchArgs(),
                            scrollToAttribution: Self.launchArgsContain("-scrollToAttribution"),
                            onOpenSettings: { isPresentingSettings = true },
                            onOpenLocations: { isPresentingLocations = true }
                        )
                    } else {
                        ProgressView()
                    }
                case .rankings:
                    if let rankingsViewModel {
                        RankingsView(
                            viewModel: rankingsViewModel,
                            onSelectCity: { location in
                                if let index = forecastViewModel?.locations.firstIndex(where: { $0.id == location.id }) {
                                    forecastViewModel?.activeIndex = index
                                }
                                selectedTab = .forecast
                            }
                        )
                    } else {
                        ProgressView()
                    }
                }
            }
            .environment(unitsSettings)

            floatingBar
        }
        .task {
            guard forecastViewModel == nil else { return }
            await bootstrap()
        }
        .sheet(isPresented: $isPresentingLocations) {
            if let locationsViewModel {
                LocationsView(viewModel: locationsViewModel, forceSearchFocused: Self.launchArgsContain("-focusSearch"))
                    .environment(unitsSettings)
            }
        }
        .sheet(isPresented: $isPresentingSettings) {
            if let locationsViewModel {
                SettingsView(locationManager: locationsViewModel.locationManager)
                    .environment(unitsSettings)
            }
        }
    }

    // MARK: - Bootstrap

    private func bootstrap() async {
        let weatherStore = WeatherStore(modelContext: modelContext)
        let locationsStore = LocationsStore(modelContext: modelContext)
        let locationManager = CurrentLocationManager(
            forcedDenied: Self.launchArgsContain("-locationDenied"),
            forcedAuthorizedCoordinate: Self.launchArgsContain("-locationGranted") ? ForecastViewModel.defaultCoordinate : nil
        )
        let networkMonitor = NetworkMonitor()

        Self.seedDemoLocationsIfNeeded(into: locationsStore)

        let vm = ForecastViewModel(
            store: weatherStore,
            forcedState: Self.forcedStateFromLaunchArgs(),
            initialExpandDayIndex: Self.expandDayIndexFromLaunchArgs(),
            initialMetric: Self.forcedMetricFromLaunchArgs(),
            forcedCondition: Self.forcedConditionFromLaunchArgs(),
            forcedTempBand: Self.forcedTempBandFromLaunchArgs(),
            forcedDate: Self.forcedDateFromLaunchArgs(),
            forcedComparisonDelta: Self.forcedComparisonDeltaFromLaunchArgs(),
            forcedTimeOfDay: Self.forcedTimeOfDayFromLaunchArgs()
        )

        let rankingsVM = RankingsViewModel(
            store: weatherStore,
            forcedDate: Self.forcedDateFromLaunchArgs()
        )

        let locationsVM = LocationsViewModel(
            store: locationsStore,
            weatherStore: weatherStore,
            locationManager: locationManager,
            searchService: LocationSearchService(),
            networkMonitor: networkMonitor,
            onLocationsChanged: { [weak vm, weak rankingsVM] locations, preferredActiveId in
                vm?.applyLocations(locations, preferredActiveId: preferredActiveId)
                rankingsVM?.applyLocations(locations)
            }
        )

        vm.applyLocations(locationsStore.fetchAll())
        if let index = Self.activeLocationIndexFromLaunchArgs(), vm.locations.indices.contains(index) {
            // Sim-verify hook: `-activeLocationIndex <n>` — `simctl` can't swipe the Forecast
            // pager, so this reaches a non-default page directly for a screenshot.
            vm.activeIndex = index
        }
        rankingsVM.applyLocations(locationsStore.fetchAll())

        forecastViewModel = vm
        locationsViewModel = locationsVM
        rankingsViewModel = rankingsVM

        if Self.launchArgsContain("-showLocations") {
            isPresentingLocations = true
        }
        if Self.launchArgsContain("-showSettings") {
            isPresentingSettings = true
        }
        if Self.launchArgsContain("-showRankings") {
            selectedTab = .rankings
        }
    }

    private static func seedDemoLocationsIfNeeded(into store: LocationsStore) {
        let seeds = DemoSeeding.seedLocationsFromLaunchArgs()
        guard !seeds.isEmpty else { return }
        for seed in seeds {
            store.addOrFind(name: seed.name, coordinate: seed.coordinate)
        }
    }

    // MARK: - Floating bottom bar

    private var floatingBar: some View {
        HStack(spacing: 12) {
            HStack(spacing: 0) {
                tabButton(title: "Forecast", systemImage: "sun.max.fill", tab: .forecast)
                tabButton(title: "Rankings", systemImage: "list.number", tab: .rankings)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 6)
            // UX polish package ("Cross-screen consistency"): `.ultraThinMaterial` + the same
            // subtle shadow recipe as the scroll-aware top bar, so the floating bar and search
            // button read as part of the same chrome system rather than a heavier `.thinMaterial`
            // fallback.
            .background(.ultraThinMaterial, in: Capsule())
            .shadow(color: .black.opacity(0.06), radius: 10, y: 3)

            Button {
                isPresentingLocations = true
            } label: {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 17, weight: .semibold))
                    .frame(width: 48, height: 48)
                    .background(.ultraThinMaterial, in: Circle())
                    .shadow(color: .black.opacity(0.06), radius: 10, y: 3)
            }
            .foregroundStyle(.primary)
        }
        .padding(.bottom, 8)
    }

    private func tabButton(title: String, systemImage: String, tab: Tab) -> some View {
        let isSelected = selectedTab == tab
        return Button {
            selectedTab = tab
        } label: {
            VStack(spacing: 2) {
                Image(systemName: systemImage)
                    .font(.system(size: 18))
                Text(title)
                    .font(.caption2.weight(.medium))
            }
            .frame(width: 72, height: 46)
            .background(isSelected ? Color.clearSkyAccent.opacity(0.18) : Color.clear, in: Capsule())
            .foregroundStyle(isSelected ? Color.clearSkyAccent : Color.secondary)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Launch-arg hooks (Phase 2 hooks preserved; Phase 3 hooks added)

    private static func launchArgsContain(_ flag: String) -> Bool {
        CommandLine.arguments.contains(flag)
    }

    private static func forcedStateFromLaunchArgs() -> ForecastViewModel.ForcedState? {
        let args = CommandLine.arguments
        guard let flagIndex = args.firstIndex(of: "-forceState"), flagIndex + 1 < args.count else { return nil }
        return ForecastViewModel.ForcedState(rawValue: args[flagIndex + 1])
    }

    private static func expandDayIndexFromLaunchArgs() -> Int? {
        let args = CommandLine.arguments
        guard let flagIndex = args.firstIndex(of: "-expandDay"), flagIndex + 1 < args.count else { return nil }
        return Int(args[flagIndex + 1])
    }

    private static func forcedMetricFromLaunchArgs() -> ForecastMetric? {
        let args = CommandLine.arguments
        guard let flagIndex = args.firstIndex(of: "-forceMetric"), flagIndex + 1 < args.count else { return nil }
        return ForecastMetric(rawValue: args[flagIndex + 1])
    }

    private static func scrollToHourFromLaunchArgs() -> Int? {
        let args = CommandLine.arguments
        guard let flagIndex = args.firstIndex(of: "-scrollToHour"), flagIndex + 1 < args.count else { return nil }
        return Int(args[flagIndex + 1])
    }

    private static func activeLocationIndexFromLaunchArgs() -> Int? {
        let args = CommandLine.arguments
        guard let flagIndex = args.firstIndex(of: "-activeLocationIndex"), flagIndex + 1 < args.count else { return nil }
        return Int(args[flagIndex + 1])
    }

    // MARK: - Phase 4 hooks (phrase bank)

    /// `-forceCondition clear|cloudy|rain|snow|fog|wind|storm` — overrides which condition
    /// bucket the phrase bank queries for the summary/caption lines, without touching the
    /// actual fetched temperature/condition shown elsewhere on screen (see
    /// `ForecastViewModel.forcedCondition`'s doc comment).
    private static func forcedConditionFromLaunchArgs() -> PhraseBank.ConditionGroup? {
        let args = CommandLine.arguments
        guard let flagIndex = args.firstIndex(of: "-forceCondition"), flagIndex + 1 < args.count else { return nil }
        return PhraseBank.ConditionGroup(rawValue: args[flagIndex + 1])
    }

    /// `-forceTempBand cold|mild|hot` — overrides which tempBand bucket the phrase bank
    /// queries, independent of the real fetched temperature.
    private static func forcedTempBandFromLaunchArgs() -> PhraseBank.TempBand? {
        let args = CommandLine.arguments
        guard let flagIndex = args.firstIndex(of: "-forceTempBand"), flagIndex + 1 < args.count else { return nil }
        return PhraseBank.TempBand(rawValue: args[flagIndex + 1])
    }

    /// `-forceDate YYYY-MM-DD` — overrides the date fed into the phrase bank's deterministic
    /// rotation, so a sim-verify screenshot can show a different day's variant on demand.
    private static func forcedDateFromLaunchArgs() -> Date? {
        let args = CommandLine.arguments
        guard let flagIndex = args.firstIndex(of: "-forceDate"), flagIndex + 1 < args.count else { return nil }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = Calendar.current.timeZone
        return formatter.date(from: args[flagIndex + 1])
    }

    /// `-forceComparisonDelta <signed integer>` — synthesizes a "yesterday" `dailyActuals`
    /// entry so the comparison line can be screenshotted without real multi-day history.
    private static func forcedComparisonDeltaFromLaunchArgs() -> Double? {
        let args = CommandLine.arguments
        guard let flagIndex = args.firstIndex(of: "-forceComparisonDelta"), flagIndex + 1 < args.count else { return nil }
        return Double(args[flagIndex + 1])
    }

    // MARK: - Phase 5 hooks (doodle layer system)

    /// `-forceTimeOfDay dawn|day|dusk|night` — overrides `DoodleComposer`'s time-of-day
    /// resolution for the doodle header art, independent of the real current time/isDaylight.
    /// (`-forceCondition` is reused as-is for the doodle scene — see
    /// `ForecastViewModel.forcedDoodleCondition`.)
    private static func forcedTimeOfDayFromLaunchArgs() -> DoodleComposer.TimeOfDay? {
        let args = CommandLine.arguments
        guard let flagIndex = args.firstIndex(of: "-forceTimeOfDay"), flagIndex + 1 < args.count else { return nil }
        return DoodleComposer.TimeOfDay(rawValue: args[flagIndex + 1])
    }
}
