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
        }
        .modelContainer(modelContainer)
    }
}
