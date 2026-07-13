import SwiftData
import SwiftUI

@main
struct ClearSkyApp: App {
    let modelContainer: ModelContainer = {
        let schema = Schema([SavedLocation.self, CachedWeatherRecord.self])
        let configuration = ModelConfiguration(schema: schema)
        return try! ModelContainer(for: schema, configurations: [configuration])
    }()

    var body: some Scene {
        WindowGroup {
            if CommandLine.arguments.contains("-smoketest") {
                SmokeTestView()
            } else {
                ForecastScreen()
            }
        }
        .modelContainer(modelContainer)
    }
}

/// Root container for Phase 2. Builds `WeatherStore` and `ForecastViewModel` once a real
/// SwiftData `ModelContext` is available from the environment, then hands off to
/// `ForecastView`. Also the home for the `-forceState` / `-expandDay` sim-verify launch-arg
/// hooks (Project Build Guide's autostart-hook pattern — simctl can't tap through a UI to
/// reach every state, so each is reachable directly via a launch argument):
///
/// - `-forceState loading|error|stale|alert|normal`
/// - `-expandDay <index>` auto-expands the given daily row for screenshot capture.
/// - `-forceMetric temp|precipChance|precipAmount|feelsLike|wind|uv` presets the selected
///   metric chip — `simctl` can't tap the chip row either, so this is the same kind of hook.
struct ForecastScreen: View {
    @Environment(\.modelContext) private var modelContext
    @State private var viewModel: ForecastViewModel?

    var body: some View {
        Group {
            if let viewModel {
                ForecastView(viewModel: viewModel, scrollTargetHourIndex: Self.scrollToHourFromLaunchArgs())
            } else {
                ProgressView()
            }
        }
        .task {
            guard viewModel == nil else { return }
            let store = WeatherStore(modelContext: modelContext)
            let vm = ForecastViewModel(
                store: store,
                forcedState: Self.forcedStateFromLaunchArgs(),
                initialExpandDayIndex: Self.expandDayIndexFromLaunchArgs(),
                initialMetric: Self.forcedMetricFromLaunchArgs()
            )
            viewModel = vm
            await vm.load()
        }
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
}
