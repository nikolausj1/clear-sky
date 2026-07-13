import SwiftData
import SwiftUI

/// Root container for Phase 3+. Hosts the floating bottom bar (Forecast | Rankings-placeholder)
/// plus a search/locations button that presents the Locations screen as a sheet, per PRD Section
/// 6's "Navigation structure." The Forecast screen's top-right ellipsis (wired via
/// `onOpenSettings`) presents Settings as a sheet. Also the home for this phase's sim-verify
/// launch-arg hooks (Project Build Guide's autostart-hook pattern):
///
/// - `-showLocations` presents the Locations sheet at launch.
/// - `-showSettings` presents the Settings sheet at launch.
/// - `-locationDenied` forces `CurrentLocationManager` to report a denied permission status.
/// - `-locationGranted` forces `CurrentLocationManager` to report an already-authorized status
///   with a canned coordinate — works around a Simulator limitation where `simctl privacy grant
///   location` doesn't reliably suppress the system permission alert (see
///   `CurrentLocationManager`'s doc comment); `simctl` also can't tap through that alert.
/// - `-seedLocations "City,ST;City,ST"` seeds saved locations before the first load.
/// - `-activeLocationIndex <n>` starts the Forecast pager on the nth seeded location instead of
///   the first — `simctl` can't swipe the pager for a screenshot of a non-default page.
struct NavigationShell: View {
    private enum Tab {
        case forecast
        case rankings
    }

    @Environment(\.modelContext) private var modelContext

    @State private var forecastViewModel: ForecastViewModel?
    @State private var locationsViewModel: LocationsViewModel?
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
                            onOpenSettings: { isPresentingSettings = true },
                            onOpenLocations: { isPresentingLocations = true }
                        )
                    } else {
                        ProgressView()
                    }
                case .rankings:
                    RankingsPlaceholderView()
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
            initialMetric: Self.forcedMetricFromLaunchArgs()
        )

        let locationsVM = LocationsViewModel(
            store: locationsStore,
            weatherStore: weatherStore,
            locationManager: locationManager,
            searchService: LocationSearchService(),
            networkMonitor: networkMonitor,
            onLocationsChanged: { [weak vm] locations, preferredActiveId in
                vm?.applyLocations(locations, preferredActiveId: preferredActiveId)
            }
        )

        vm.applyLocations(locationsStore.fetchAll())
        if let index = Self.activeLocationIndexFromLaunchArgs(), vm.locations.indices.contains(index) {
            // Sim-verify hook: `-activeLocationIndex <n>` — `simctl` can't swipe the Forecast
            // pager, so this reaches a non-default page directly for a screenshot.
            vm.activeIndex = index
        }

        forecastViewModel = vm
        locationsViewModel = locationsVM

        if Self.launchArgsContain("-showLocations") {
            isPresentingLocations = true
        }
        if Self.launchArgsContain("-showSettings") {
            isPresentingSettings = true
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
            .background(.thinMaterial, in: Capsule())

            Button {
                isPresentingLocations = true
            } label: {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 17, weight: .semibold))
                    .frame(width: 48, height: 48)
                    .background(.thinMaterial, in: Circle())
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
            .background(isSelected ? Color.accentColor.opacity(0.18) : Color.clear, in: Capsule())
            .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
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
}
