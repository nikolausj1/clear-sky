import SwiftUI

/// PRD Screen D: units toggle, attribution/legal, app version. "Nothing else" per the Phase 3
/// build brief — no other Settings content belongs here yet. States table: "Fully static" /
/// "Shows permission status and a shortcut to iOS Settings" (the latter piece lives in the
/// Locations screen's own denied-state row per PRD Section 6's state table row for Settings,
/// which is about location permission status — included here too since Settings is the natural
/// home for "why can't I use current location").
struct SettingsView: View {
    @Environment(UnitsSettings.self) private var unitsSettings
    @Environment(\.dismiss) private var dismiss
    let locationManager: CurrentLocationManager

    @State private var attribution: WeatherAttributionInfo?
    @State private var attributionError = false

    private var appVersion: String {
        let bundle = Bundle.main
        let shortVersion = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        let buildNumber = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
        return "\(shortVersion) (\(buildNumber))"
    }

    var body: some View {
        @Bindable var unitsSettings = unitsSettings
        NavigationStack {
            List {
                Section("Units") {
                    Picker("Temperature", selection: $unitsSettings.unit) {
                        ForEach(TemperatureUnit.allCases) { unit in
                            Text(unit.title).tag(unit)
                        }
                    }
                    .pickerStyle(.inline)
                }

                Section("Location") {
                    LabeledContent("Current Location Access", value: locationPermissionLabel)
                    if locationManager.status == .denied {
                        Button("Open iOS Settings") {
                            if let url = URL(string: UIApplication.openSettingsURLString) {
                                UIApplication.shared.open(url)
                            }
                        }
                    }
                }

                Section {
                    if let attribution {
                        Link(destination: attribution.legalPageURL) {
                            HStack {
                                Text("Weather data provided by \(attribution.serviceName)")
                                Spacer()
                                Image(systemName: "chevron.forward")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    } else if attributionError {
                        Text("Weather data provided by Weather.")
                    } else {
                        HStack {
                            Text("Weather data provided by Weather.")
                            Spacer()
                            ProgressView()
                        }
                    }
                } header: {
                    Text("About")
                } footer: {
                    // App Store-minimum attribution: the service name plus a single link to
                    // Apple's hosted legal/agency page (`legalPageURL`) — the full per-agency
                    // data-source list belongs behind that link, not dumped inline here.
                    Text("Full data source and legal attribution is available at the link above.")
                }

                Section("App") {
                    LabeledContent("Version", value: appVersion)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .task {
            await loadAttribution()
        }
    }

    private var locationPermissionLabel: String {
        switch locationManager.status {
        case .authorized: return "Allowed"
        case .denied: return "Denied"
        case .notDetermined: return "Not Requested"
        }
    }

    private func loadAttribution() async {
        do {
            attribution = try await WeatherService.shared.fetchAttribution()
        } catch {
            attributionError = true
        }
    }
}
