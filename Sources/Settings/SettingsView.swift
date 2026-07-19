import SwiftUI

/// PRD Screen D: units toggle, attribution/legal, app version. States table: "Fully static" /
/// "Shows permission status and a shortcut to iOS Settings" (the latter piece lives in the
/// Locations screen's own denied-state row per PRD Section 6's state table row for Settings,
/// which is about location permission status — included here too since Settings is the natural
/// home for "why can't I use current location").
///
/// PRD Revision Notes (2026-07-18, night-first expansion): a NOTIFICATIONS section, between
/// Location and About, hosts the app's only two notification toggles — "ISS pass alerts" and
/// "Aurora storm alerts," both opt-in, both default-off (`SkyNotificationScheduler`'s own
/// type-level doc comment covers scheduling/dedupe/limitations; this file only owns the toggle UI
/// and the authorization-denial flow).
///
/// ISS Live Activity work package: the same section gains a third toggle, "ISS pass Live
/// Activity" — a fully separate permission (`ActivityAuthorizationInfo().areActivitiesEnabled`,
/// not `UNUserNotificationCenter` authorization), owned end-to-end by `ISSActivityManager`. Its
/// denial state (`liveActivityUnavailable`) is tracked independently of
/// `notificationPermissionDenied` since the two permissions can differ, but both point the user
/// at the same iOS Settings app page, so they share one "Open iOS Settings" button/footer.
struct SettingsView: View {
    @Environment(UnitsSettings.self) private var unitsSettings
    @Environment(\.dismiss) private var dismiss
    let locationManager: CurrentLocationManager
    /// Notifications work package: the location `SkyNotificationScheduler` schedules ISS/aurora
    /// alerts against — the first saved location, per that type's own doc comment. `nil` when
    /// there are no saved locations yet, in which case toggling either notification ON still
    /// requests system authorization (harmless, and needed before the location list is non-empty
    /// anyway) but schedules nothing until a location exists.
    var firstSavedLocation: SavedLocation?

    @State private var attribution: WeatherAttributionInfo?
    @State private var attributionError = false

    /// Notifications work package: both toggles persist straight to `UserDefaults` via the exact
    /// keys `SkyNotificationScheduler` reads from — see that type's doc comment on why there's
    /// only one source of truth for "is this feature on," not a separate copy here.
    @AppStorage(SkyNotificationScheduler.issEnabledKey) private var issAlertsEnabled = false
    @AppStorage(SkyNotificationScheduler.auroraEnabledKey) private var auroraAlertsEnabled = false
    /// Both toggles share the same underlying system permission (`UNUserNotificationCenter`
    /// authorization is app-wide, not per-notification-kind — see `SkyNotificationScheduler`'s
    /// doc comment), so one denial-explanation row serves both rather than duplicating it.
    @State private var notificationPermissionDenied = false

    /// ISS Live Activity work package: persists to `ISSActivityManager`'s own key, same
    /// one-source-of-truth pattern as the two toggles above.
    @AppStorage(ISSActivityManager.issLiveActivityEnabledKey) private var issLiveActivityEnabled = false
    /// Separate from `notificationPermissionDenied`: Live Activities have their own system
    /// permission (`ActivityAuthorizationInfo().areActivitiesEnabled`), independent of
    /// notification authorization.
    @State private var liveActivityUnavailable = false

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
                Section {
                    Picker("Temperature", selection: $unitsSettings.unit) {
                        ForEach(TemperatureUnit.allCases) { unit in
                            Text(unit.title).tag(unit)
                        }
                    }
                    .pickerStyle(.inline)
                } header: {
                    // UX polish package ("Cross-screen consistency"): same header tracking as
                    // the Forecast screen's card headers, applied here too.
                    Text("Units").tracking(0.8)
                }

                Section {
                    Toggle(isOn: nightVisionBinding) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Red screen mode")
                            Text("Deep red display preserves your eyes' dark adaptation while stargazing.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("Night Vision").tracking(0.8)
                }

                Section {
                    LabeledContent("Current Location Access", value: locationPermissionLabel)
                    if locationManager.status == .denied {
                        Button("Open iOS Settings") {
                            if let url = URL(string: UIApplication.openSettingsURLString) {
                                UIApplication.shared.open(url)
                            }
                        }
                    }
                } header: {
                    Text("Location").tracking(0.8)
                }

                Section {
                    Toggle(isOn: $issAlertsEnabled) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("ISS pass alerts")
                            Text("10 minutes before visible Space Station passes at your first saved city")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .onChange(of: issAlertsEnabled) { _, newValue in
                        handleISSToggle(newValue)
                    }

                    Toggle(isOn: $auroraAlertsEnabled) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Aurora storm alerts")
                            Text("Only when strong geomagnetic storms are forecast — rare")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .onChange(of: auroraAlertsEnabled) { _, newValue in
                        handleAuroraToggle(newValue)
                    }

                    Toggle(isOn: $issLiveActivityEnabled) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("ISS pass Live Activity")
                            Text("A live countdown and progress on your Lock Screen and Dynamic Island around visible passes.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .onChange(of: issLiveActivityEnabled) { _, newValue in
                        handleISSLiveActivityToggle(newValue)
                    }

                    if notificationPermissionDenied || liveActivityUnavailable {
                        Button("Open iOS Settings") {
                            if let url = URL(string: UIApplication.openSettingsURLString) {
                                UIApplication.shared.open(url)
                            }
                        }
                    }
                } header: {
                    Text("Notifications").tracking(0.8)
                } footer: {
                    // PRD: exactly these three toggles exist, all opt-in — each denial
                    // explanation names the specific permission, so it's clear which toggle to
                    // revisit after re-allowing it in iOS Settings.
                    VStack(alignment: .leading, spacing: 4) {
                        if notificationPermissionDenied {
                            Text("Notifications are turned off for Zenith in iOS Settings. Turn them on there, then try the toggle again.")
                        }
                        if liveActivityUnavailable {
                            Text("Live Activities are turned off for Zenith in iOS Settings. Turn them on there, then try the toggle again.")
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
                    Text("About").tracking(0.8)
                } footer: {
                    // App Store-minimum attribution: the service name plus a single link to
                    // Apple's hosted legal/agency page (`legalPageURL`) — the full per-agency
                    // data-source list belongs behind that link, not dumped inline here.
                    Text("Full data source and legal attribution is available at the link above.")
                }

                Section {
                    LabeledContent("Version", value: appVersion)
                } header: {
                    Text("App").tracking(0.8)
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

    /// Night Vision work package: `NightVisionMode.shared` is a plain `@Observable` singleton
    /// (not a `@Bindable` property here), so a manual `Binding` is the simplest way to hand its
    /// `enabled` property to a `Toggle` — see `NightVisionMode`'s doc comment for why it's a
    /// singleton rather than something threaded in via `@Environment`.
    private var nightVisionBinding: Binding<Bool> {
        Binding(
            get: { NightVisionMode.shared.enabled },
            set: { NightVisionMode.shared.enabled = $0 }
        )
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

    // MARK: - Notifications work package

    /// Toggle ON -> request authorization (contextual, per `SkyNotificationScheduler`'s doc
    /// comment) and schedule immediately from real data; denial flips the toggle back off and
    /// surfaces the explanation row. Toggle OFF -> remove every pending ISS notification.
    private func handleISSToggle(_ newValue: Bool) {
        Task {
            if newValue {
                let granted = await SkyNotificationScheduler.shared.enableISS(location: firstSavedLocation)
                if granted {
                    notificationPermissionDenied = false
                } else {
                    issAlertsEnabled = false
                    notificationPermissionDenied = true
                }
            } else {
                await SkyNotificationScheduler.shared.disableISS()
            }
        }
    }

    /// Mirrors `handleISSToggle` for the Aurora toggle.
    private func handleAuroraToggle(_ newValue: Bool) {
        Task {
            if newValue {
                let granted = await SkyNotificationScheduler.shared.enableAurora(location: firstSavedLocation)
                if granted {
                    notificationPermissionDenied = false
                } else {
                    auroraAlertsEnabled = false
                    notificationPermissionDenied = true
                }
            } else {
                await SkyNotificationScheduler.shared.disableAurora()
            }
        }
    }

    /// ISS Live Activity work package: mirrors `handleISSToggle`'s shape exactly, but against
    /// `ISSActivityManager`'s own separate Live Activity permission rather than
    /// `UNUserNotificationCenter` authorization.
    private func handleISSLiveActivityToggle(_ newValue: Bool) {
        Task {
            if newValue {
                let granted = await ISSActivityManager.enable(location: firstSavedLocation)
                if granted {
                    liveActivityUnavailable = false
                } else {
                    issLiveActivityEnabled = false
                    liveActivityUnavailable = true
                }
            } else {
                await ISSActivityManager.disable()
            }
        }
    }
}
