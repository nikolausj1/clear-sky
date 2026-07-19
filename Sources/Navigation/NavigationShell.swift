import SwiftData
import SwiftUI

/// Root container for Phase 3+. Hosts the floating bottom bar (Forecast | Space | Sky Spots)
/// plus a search/locations button that presents the Locations screen as a sheet, per PRD Section
/// 6's "Navigation structure." The Forecast screen's top-right ellipsis (wired via
/// `onOpenSettings`) presents Settings as a sheet. Also the home for this phase's sim-verify
/// launch-arg hooks (Project Build Guide's autostart-hook pattern):
///
/// - `-showLocations` presents the Locations sheet at launch.
/// - `-showSettings` presents the Settings sheet at launch.
/// - `-showSpots` selects the Sky Spots tab at launch (mirrors `-showLocations`; `simctl`
///   can't tap the floating bottom bar for a screenshot of the non-default tab). `-showRankings`
///   is kept as a back-compat alias (Sky Spots work package: Rankings retired, same launch-arg
///   contract preserved for any existing sim-verify script still passing the old flag).
/// - `-showSpace` selects the Space tab at launch (work package WP-K).
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
/// - `-showPeopleSheet` ("People in Space" work package) presents `PeopleInSpaceSheet` on the
///   active Forecast page at launch — `simctl` can't tap the Tonight's Sky card's people row.
/// - `-showFinder explore|moon|mercury|venus|mars|jupiter|saturn|iss|polaris` (Sky Finder work
///   package) presents `SkyFinderView` on the active Forecast page at launch, targeting the named
///   object (`explore` = free-explore mode; `polaris` is the bright-star work package's own
///   sim-verify entry point, since `simctl` can't tap through the "Stars" chip's sheet) —
///   `simctl` can't tap a "Find" button either. See `SkyFinderLaunchArgTarget`.
///   `-finderDemo`/`-finderDemoStage <stage>`/`-finderCalibrationPoor` (read directly by
///   `DeviceMotionAdapter`) drive the canned pointing sweep for every motion-dependent screenshot;
///   `-seedJournal` (read directly by `SkyJournalStore`) seeds a populated Sky Journal;
///   `-showFinderStarPicker` (read directly by `SkyFinderView`) opens the "Stars" chip's sheet at
///   launch.
/// - `-forceNotifTest` (notifications work package) schedules one test ISS notification 15
///   seconds out via `SkyNotificationScheduler.scheduleTestNotification()` — sim-verify only, so
///   a foreground-delivered banner can be screenshotted without waiting for a real pass.
/// - `-dumpPendingNotifs` (notifications work package) refreshes ISS scheduling for the first
///   saved location from real data, then prints every pending local notification request to the
///   console via `SkyNotificationScheduler.dumpPendingRequests()` — only visible when launched
///   with `xcrun simctl launch --console` (see that method's doc comment).
/// - `-forceISSActivity` (ISS Live Activity work package) starts a demo Live Activity with a
///   synthetic pass 2 minutes out, 4-minute duration, via `ISSActivityManager.startDemoActivity()`
///   — bypasses the Settings toggle/real-pass gates entirely, sim-verify only. Live Activities DO
///   run on the Simulator (unlike CoreMotion, which Sky Finder's own `-finderDemo` flag works
///   around), so this activity is real and screenshot-able from the home screen/Dynamic Island.
struct NavigationShell: View {
    private enum Tab {
        case forecast
        case space
        case spots
    }

    @Environment(\.modelContext) private var modelContext
    /// Notifications work package: drives the "on every app foreground" ISS/aurora refresh
    /// trigger — see `SkyNotificationScheduler.refreshISS`/`refreshAurora`'s doc comments.
    @Environment(\.scenePhase) private var scenePhase

    @State private var forecastViewModel: ForecastViewModel?
    @State private var locationsViewModel: LocationsViewModel?
    @State private var skySpotsViewModel: SkySpotsViewModel?
    @State private var spaceViewModel: SpaceViewModel?
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
                            scrollToSky: Self.launchArgsContain("-scrollToSky"),
                            forcedExplainerKey: Self.forcedExplainerKeyFromLaunchArgs(),
                            showPeopleSheetAtLaunch: Self.launchArgsContain("-showPeopleSheet"),
                            showJournalAtLaunch: Self.launchArgsContain("-showJournal"),
                            showAlertDetailAtLaunch: Self.launchArgsContain("-showAlertDetail"),
                            showFinderTargetAtLaunch: Self.showFinderTargetFromLaunchArgs(),
                            onSkyStateResolved: handleSkyStateResolved,
                            onOpenSettings: { isPresentingSettings = true },
                            onOpenLocations: { isPresentingLocations = true }
                        )
                    } else {
                        ProgressView()
                    }
                case .space:
                    if let spaceViewModel {
                        SpaceView(
                            viewModel: spaceViewModel,
                            location: spaceLocation,
                            scrollTarget: Self.scrollSpaceTargetFromLaunchArgs(),
                            showLaunchDetailAtLaunch: Self.launchArgsContain("-showLaunchDetail")
                        )
                    } else {
                        ProgressView()
                    }
                case .spots:
                    if let skySpotsViewModel {
                        SkySpotsView(
                            viewModel: skySpotsViewModel,
                            onSelectCity: { location in
                                if let index = forecastViewModel?.locations.firstIndex(where: { $0.id == location.id }) {
                                    forecastViewModel?.activeIndex = index
                                }
                                selectedTab = .forecast
                            },
                            scrollTarget: Self.scrollSpotsTargetFromLaunchArgs(),
                            initialExpandedSpotId: Self.expandSpotIdFromLaunchArgs()
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
                    .nightVisionAware()
            }
        }
        .sheet(isPresented: $isPresentingSettings) {
            if let locationsViewModel {
                SettingsView(locationManager: locationsViewModel.locationManager, firstSavedLocation: forecastViewModel?.locations.first)
                    .environment(unitsSettings)
                    .nightVisionAware()
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .active else { return }
            handleForeground()
        }
    }

    // MARK: - Notifications work package

    /// `scenePhase == .active` fires on every launch AND every return-to-foreground — both are
    /// "the app foreground" trigger the notifications work order asks for. Silently does nothing
    /// if there's no saved location yet (nothing to schedule against).
    private func handleForeground() {
        guard let location = forecastViewModel?.locations.first else { return }
        Task {
            await SkyNotificationScheduler.shared.refreshISS(location: location)
            await SkyNotificationScheduler.shared.refreshAurora(location: location)
            // ISS Live Activity work package: same foreground trigger — ends any stale activity
            // and starts a fresh one if a visible pass now falls inside the 45-minute window. See
            // `ISSActivityManager.refresh`'s doc comment.
            await ISSActivityManager.refresh(location: location)
        }
    }

    /// `TonightSkyCard.load()`'s post-fetch hook, forwarded from every page — filters down to
    /// just the first saved location (the notifications work order's "ACTIVE (first) saved
    /// location," i.e. `locations.first`, NOT necessarily the pager's currently-active page —
    /// unlike `spaceLocation` below, which follows the active page). A no-op for every other
    /// page's card.
    ///
    /// Widget work package: this is also the "hook where `SkyTonightService` resolves" the
    /// widgets' own data-handoff spec calls for — `WidgetSnapshotWriter.refresh` runs alongside
    /// the two notification refreshes, same first-saved-location scope, so the lock/home-screen
    /// widgets and the two sanctioned notifications always agree on which location "tonight"
    /// means.
    private func handleSkyStateResolved(_ location: SavedLocation) {
        guard forecastViewModel?.locations.first?.id == location.id else { return }
        Task {
            await SkyNotificationScheduler.shared.refreshISS(location: location)
            await SkyNotificationScheduler.shared.refreshAurora(location: location)
            await WidgetSnapshotWriter.refresh(location: location)
            await ISSActivityManager.refresh(location: location)
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
            forcedTimeOfDay: Self.forcedTimeOfDayFromLaunchArgs(),
            forcedAuroraBand: Self.forcedAuroraBandFromLaunchArgs(),
            forceISSPass: Self.launchArgsContain("-forceISSPass"),
            forceNoISS: Self.launchArgsContain("-forceNoISS"),
            forceSkyUnavailable: Self.launchArgsContain("-forceSkyUnavailable"),
            forcedMeteorPeak: Self.forcedMeteorPeakFromLaunchArgs(),
            forcePairing: Self.launchArgsContain("-forcePairing"),
            initialExpandedSkyPlanet: Self.expandSkyPlanetFromLaunchArgs(),
            forceTrueSkyPlanets: Self.launchArgsContain("-forceTrueSkyPlanets"),
            forceISSStreakNow: Self.launchArgsContain("-forceISSStreakNow"),
            forceMeteorStreaks: Self.launchArgsContain("-forceMeteorStreaks"),
            forceConjunctionScene: Self.launchArgsContain("-forceConjunctionScene"),
            forceLaunchContrail: Self.launchArgsContain("-forceLaunchContrail")
        )

        let skySpotsVM = SkySpotsViewModel(
            store: weatherStore,
            forcedDate: Self.forcedDateFromLaunchArgs()
        )

        let spaceVM = SpaceViewModel(
            overrides: Self.spaceOverridesFromLaunchArgs(),
            forcedDate: Self.forcedDateFromLaunchArgs()
        )

        let locationsVM = LocationsViewModel(
            store: locationsStore,
            weatherStore: weatherStore,
            locationManager: locationManager,
            searchService: LocationSearchService(),
            networkMonitor: networkMonitor,
            onLocationsChanged: { [weak vm, weak skySpotsVM] locations, preferredActiveId in
                vm?.applyLocations(locations, preferredActiveId: preferredActiveId)
                skySpotsVM?.applyLocations(locations)
            }
        )

        vm.applyLocations(locationsStore.fetchAll())
        if let index = Self.activeLocationIndexFromLaunchArgs(), vm.locations.indices.contains(index) {
            // Sim-verify hook: `-activeLocationIndex <n>` — `simctl` can't swipe the Forecast
            // pager, so this reaches a non-default page directly for a screenshot.
            vm.activeIndex = index
        }
        skySpotsVM.applyLocations(locationsStore.fetchAll())

        forecastViewModel = vm
        locationsViewModel = locationsVM
        skySpotsViewModel = skySpotsVM
        spaceViewModel = spaceVM

        if Self.launchArgsContain("-showLocations") {
            isPresentingLocations = true
        }
        if Self.launchArgsContain("-showSettings") {
            isPresentingSettings = true
        }
        if Self.launchArgsContain("-showSpots") || Self.launchArgsContain("-showRankings") {
            selectedTab = .spots
        }
        if Self.launchArgsContain("-showSpace") {
            selectedTab = .space
        }

        // Notifications work package sim-verify hooks. `SkyNotificationScheduler.shared` is
        // touched here (once, on every bootstrap) purely to construct the singleton early —
        // its `init` installs the `UNUserNotificationCenterDelegate` that lets a
        // foreground-delivered notification present as a banner, and that needs to be in place
        // before anything (real schedule or `-forceNotifTest`) could possibly fire.
        let scheduler = SkyNotificationScheduler.shared
        if Self.launchArgsContain("-forceNotifTest") {
            Task { await scheduler.scheduleTestNotification() }
        }
        if Self.launchArgsContain("-dumpPendingNotifs") {
            Task {
                // Real pass data for the first saved location (not a synthetic/forced one) —
                // per work order, this dump is meant to prove real ISS-alert scheduling, so it
                // refreshes from actual `SkyTonightService` data before printing. A no-op inside
                // `refreshISS` if the ISS toggle is currently off (see that method's doc
                // comment), which is exactly what makes this dump usable as toggle-off proof too:
                // relaunch with this same flag after toggling off and the printed list reflects
                // whatever `disableISS()` already removed in the prior session.
                if let location = vm.locations.first {
                    await scheduler.refreshISS(location: location)
                }
                await scheduler.dumpPendingRequests()
            }
        }

        // ISS Live Activity work package sim-verify hook: see this file's own doc comment.
        if Self.launchArgsContain("-forceISSActivity") {
            Task { await ISSActivityManager.startDemoActivity() }
        }
    }

    private static func seedDemoLocationsIfNeeded(into store: LocationsStore) {
        let seeds = DemoSeeding.seedLocationsFromLaunchArgs()
        guard !seeds.isEmpty else { return }
        for seed in seeds {
            store.addOrFind(name: seed.name, coordinate: seed.coordinate)
        }
    }

    // MARK: - Space tab location context

    /// The location the Space tab's Sky Calendar computes meteor-peak/pairing rows from: the
    /// active Forecast location (same source `TonightSkyCard` uses), falling back to the first
    /// saved location, falling back to `nil` (which hides those location-dependent rows entirely
    /// -- see `SkyCalendar.events(...)`'s doc comment). Reading `forecastViewModel.activeIndex`/
    /// `.locations` here means SwiftUI's observation tracking re-evaluates this whenever either
    /// changes while the Space tab is on screen, same mechanism `RankedRowView`'s `onSelectCity`
    /// callback already relies on elsewhere in this file.
    private var spaceLocation: SavedLocation? {
        guard let forecastViewModel else { return nil }
        if forecastViewModel.locations.indices.contains(forecastViewModel.activeIndex) {
            return forecastViewModel.locations[forecastViewModel.activeIndex]
        }
        return forecastViewModel.locations.first
    }

    // MARK: - Floating bottom bar

    private var floatingBar: some View {
        HStack(spacing: 12) {
            HStack(spacing: 0) {
                tabButton(title: "Forecast", systemImage: "sun.max.fill", tab: .forecast)
                tabButton(title: "Space", systemImage: "moon.stars", tab: .space)
                tabButton(title: "Sky Spots", systemImage: "map", tab: .spots)
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

    /// `-showExplainer issPass|aurora|meteorShower|stargazingScore|brightness|rocketLaunch|bortle`
    /// — see `ForecastPageView`'s doc comment and `Explainers.forLaunchArgKey(_:)`.
    private static func forcedExplainerKeyFromLaunchArgs() -> String? {
        let args = CommandLine.arguments
        guard let flagIndex = args.firstIndex(of: "-showExplainer"), flagIndex + 1 < args.count else { return nil }
        return args[flagIndex + 1]
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

    // MARK: - "Tonight's Sky" hooks

    /// `-forceAuroraBand none|low|fair|good|strong` — synthesizes an `AuroraOutlook` at the
    /// given band instead of fetching NOAA SWPC, so a screenshot doesn't depend on real
    /// geomagnetic activity cooperating. Values match `AuroraBand.description`.
    private static func forcedAuroraBandFromLaunchArgs() -> AuroraBand? {
        let args = CommandLine.arguments
        guard let flagIndex = args.firstIndex(of: "-forceAuroraBand"), flagIndex + 1 < args.count else { return nil }
        return AuroraBand.allCases.first { $0.description == args[flagIndex + 1] }
    }

    /// `-expandSkyPlanet mercury|venus|mars|jupiter|saturn` — sim-verify only, pre-expands a
    /// planet row in `TonightSkyCard` at launch (`simctl` can't tap through to an expanded row).
    private static func expandSkyPlanetFromLaunchArgs() -> Planets.Body? {
        let args = CommandLine.arguments
        guard let flagIndex = args.firstIndex(of: "-expandSkyPlanet"), flagIndex + 1 < args.count else { return nil }
        return Planets.Body(rawValue: args[flagIndex + 1])
    }

    /// `-showFinder explore|moon|mercury|venus|mars|jupiter|saturn|iss|polaris` — see this file's
    /// own doc comment and `SkyFinderLaunchArgTarget`.
    private static func showFinderTargetFromLaunchArgs() -> SkyFinderLaunchArgTarget? {
        let args = CommandLine.arguments
        guard let flagIndex = args.firstIndex(of: "-showFinder"), flagIndex + 1 < args.count else { return nil }
        return SkyFinderLaunchArgTarget(rawValue: args[flagIndex + 1])
    }

    // MARK: - Sky-intelligence hooks (work package WP-F: headline/meteor/conjunction rows)

    /// `-forceMeteorPeak none|some|severe` — synthesizes a Perseids-at-peak `MeteorOutlook` at
    /// the given Moon-interference level, so the meteor row (and, when it wins the ranking, the
    /// headline row) can be screenshotted without waiting for a real shower to be active/peaking
    /// tonight. See `SkyTonightService.ForcedOverrides.meteorPeak`.
    private static func forcedMeteorPeakFromLaunchArgs() -> MeteorShowers.MoonInterference? {
        let args = CommandLine.arguments
        guard let flagIndex = args.firstIndex(of: "-forceMeteorPeak"), flagIndex + 1 < args.count else { return nil }
        return MeteorShowers.MoonInterference(launchArgValue: args[flagIndex + 1])
    }

    // MARK: - Space tab hooks (work package WP-K)

    /// `-forceSolarLevel quiet|active|stormy` (synthesizes a notable flare + G2 3-day forecast for
    /// active/stormy), `-forceLaunchesSample` (3 synthetic launches, one of each status chip,
    /// bypassing the network), `-forceSpaceOffline` (simulates no-network for the Launch Schedule
    /// card and a stale cache for the Sun card in one flag) — see `SpaceViewModel.ForcedOverrides`.
    private static func spaceOverridesFromLaunchArgs() -> SpaceViewModel.ForcedOverrides {
        let args = CommandLine.arguments
        var overrides = SpaceViewModel.ForcedOverrides()
        if let flagIndex = args.firstIndex(of: "-forceSolarLevel"), flagIndex + 1 < args.count {
            overrides.solarLevel = SolarActivityLevel.allCases.first { $0.description == args[flagIndex + 1] }
        }
        overrides.launchesSample = launchArgsContain("-forceLaunchesSample")
        overrides.offline = launchArgsContain("-forceSpaceOffline")
        return overrides
    }

    /// `-scrollSpaceTo sun|calendar` — sim-verify only, scrolls the Space tab straight to a card
    /// below the fold at launch (`simctl` can't scroll). See `SpaceView.ScrollTarget`.
    private static func scrollSpaceTargetFromLaunchArgs() -> SpaceView.ScrollTarget? {
        let args = CommandLine.arguments
        guard let flagIndex = args.firstIndex(of: "-scrollSpaceTo"), flagIndex + 1 < args.count else { return nil }
        return SpaceView.ScrollTarget(rawValue: args[flagIndex + 1])
    }

    // MARK: - Sky Spots tab hooks

    /// `-scrollSpotsTo launchSites|aurora|darkSky` — sim-verify only, scrolls the Sky Spots tab
    /// straight to a card below the fold at launch (`simctl` can't scroll). See
    /// `SkySpotsView.ScrollTarget`.
    private static func scrollSpotsTargetFromLaunchArgs() -> SkySpotsView.ScrollTarget? {
        let args = CommandLine.arguments
        guard let flagIndex = args.firstIndex(of: "-scrollSpotsTo"), flagIndex + 1 < args.count else { return nil }
        return SkySpotsView.ScrollTarget(rawValue: args[flagIndex + 1])
    }

    /// `-expandSpotId <id>` — sim-verify only, pre-expands the named `SkySpot` row (an `id` from
    /// `skyspots.json`, e.g. "cape-canaveral") at launch (`simctl` can't tap a row to expand it).
    private static func expandSpotIdFromLaunchArgs() -> String? {
        let args = CommandLine.arguments
        guard let flagIndex = args.firstIndex(of: "-expandSpotId"), flagIndex + 1 < args.count else { return nil }
        return args[flagIndex + 1]
    }
}
