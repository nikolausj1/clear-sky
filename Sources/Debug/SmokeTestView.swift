import CoreLocation
import SwiftUI

/// Phase 1 exit-criteria screen: "a smoke test prints real WeatherKit data for a hardcoded
/// coordinate." Shown instead of the normal root view when the app launches with the
/// `-smoketest` argument (see `ClearSkyApp.swift`). Talks to `WeatherService` directly
/// (bypassing `WeatherStore`'s caching) since the point here is to prove the raw WeatherKit
/// fetch path itself works end to end, including surfacing the exact error text if it doesn't
/// (e.g. while the WeatherKit App Services capability is still propagating).
struct SmokeTestView: View {
    /// Tomah, WI - hardcoded per the Phase 1 spec.
    private static let coordinate = CLLocationCoordinate2D(latitude: 43.9814, longitude: -90.5040)
    private static let locationId = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!

    private enum LoadState {
        case loading
        case loaded(CachedWeather)
        case failed(String)
    }

    @State private var state: LoadState = .loading

    var body: some View {
        NavigationStack {
            Group {
                switch state {
                case .loading:
                    ProgressView("Consulting the sky.")
                case .loaded(let payload):
                    loadedView(payload)
                case .failed(let message):
                    errorView(message)
                }
            }
            .navigationTitle("Smoke Test")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Retry") { Task { await fetch() } }
                }
            }
        }
        .task {
            await fetch()
        }
    }

    private func fetch() async {
        state = .loading
        do {
            let payload = try await WeatherService.shared.fetchWeather(
                for: CLLocation(latitude: Self.coordinate.latitude, longitude: Self.coordinate.longitude),
                locationId: Self.locationId
            )
            state = .loaded(payload)
        } catch {
            state = .failed((error as? LocalizedError)?.errorDescription ?? String(reflecting: error))
        }
    }

    // MARK: - Loaded

    /// Whole-degree temperature formatting - the raw `Measurement.formatted()` default
    /// carries WeatherKit's full floating-point precision (e.g. "71.405806°F"), which is
    /// noisy for a diagnostic list meant to be eyeballed and screenshotted.
    private func formattedTemp(_ measurement: Measurement<UnitTemperature>) -> String {
        measurement.formatted(.measurement(width: .narrow, numberFormatStyle: .number.precision(.fractionLength(0))))
    }

    @ViewBuilder
    private func loadedView(_ payload: CachedWeather) -> some View {
        List {
            Section("Current Conditions") {
                LabeledContent("Temperature", value: formattedTemp(payload.currentConditions.temperature))
                LabeledContent("Feels Like", value: formattedTemp(payload.currentConditions.feelsLike))
                LabeledContent("Condition", value: payload.currentConditions.conditionDescription)
            }

            Section("Hourly (first 6)") {
                ForEach(payload.hourly.prefix(6)) { hour in
                    LabeledContent(hour.date.formatted(date: .omitted, time: .shortened)) {
                        Text("\(formattedTemp(hour.temperature)) — \(hour.conditionDescription)")
                    }
                }
            }

            Section("Daily (first 5)") {
                ForEach(payload.daily.prefix(5)) { day in
                    LabeledContent(day.date.formatted(date: .abbreviated, time: .omitted)) {
                        Text("H:\(formattedTemp(day.high)) L:\(formattedTemp(day.low))")
                    }
                }
            }

            Section("Alerts") {
                LabeledContent("Active alert count", value: "\(payload.activeAlerts.count)")
            }

            Section("Attribution") {
                Text(payload.attribution.legalPageURL.absoluteString)
                    .font(.footnote)
                    .textSelection(.enabled)
            }

            Section("Fetched At") {
                Text(payload.fetchedAt.formatted(date: .abbreviated, time: .standard))
            }
        }
    }

    // MARK: - Error

    private func errorView(_ message: String) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Weather fetch failed.")
                    .font(.headline)
                Text(message)
                    .font(.system(.footnote, design: .monospaced))
                    .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
        }
    }
}

#Preview {
    SmokeTestView()
}
