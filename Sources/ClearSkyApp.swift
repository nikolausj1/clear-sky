import SwiftUI

@main
struct ClearSkyApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

struct ContentView: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(red: 0.40, green: 0.68, blue: 0.95), Color.white],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack(spacing: 8) {
                Text("Clear Sky")
                    .font(.system(size: 40, weight: .semibold, design: .rounded))
                    .foregroundStyle(.primary)
                Text("Phase 0")
                    .font(.system(size: 20, weight: .regular, design: .rounded))
                    .foregroundStyle(.secondary)
            }
        }
    }
}
