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
                NavigationShell()
            }
        }
        .modelContainer(modelContainer)
    }
}
