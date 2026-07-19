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
            Group {
                if CommandLine.arguments.contains("-smoketest") {
                    SmokeTestView()
                } else {
                    NavigationShell()
                }
            }
            // UX polish package ("Define the app accent once"): the single sky-blue accent used
            // for every tint/selection/link across the app, applied at the root so it reaches
            // every `NavigationStack`/sheet without needing a bespoke `AccentColor` asset.
            .tint(Color.clearSkyAccent)
            // Owner decision (People-in-Space/always-dark package): the app is dark-only,
            // night-sky-identity — forced here at the window root so EVERY screen (Forecast,
            // Rankings, Locations, Settings, every sheet) renders dark regardless of the device's
            // system appearance, not just the Space tab/night panel/doodle hero, which were
            // already dark by construction. No Settings toggle is added for this (that's a
            // future product decision, explicitly not part of this package).
            .preferredColorScheme(.dark)
            // Night Vision work package: the app-root half of the red-on-black dark-adaptation
            // mode — see `NightVisionModifier`'s doc comment for the compositing technique and
            // why `.sheet` content each needs this applied again at its own root (it does not
            // inherit from here the way `.tint`/`.preferredColorScheme` do).
            .nightVisionAware()
        }
        .modelContainer(modelContainer)
    }
}
