import MapKit
import SwiftUI

/// PRD Screen B: current-location row, search-with-autocomplete, reorderable/deletable saved
/// list. Presented as a sheet from the Forecast screen's magnifier button (Section 6,
/// "Navigation structure").
struct LocationsView: View {
    @Environment(UnitsSettings.self) private var unitsSettings
    @Environment(\.dismiss) private var dismiss
    @Bindable var viewModel: LocationsViewModel
    /// Sim-verify hook: when true, forces the search field into "active/focused" appearance so
    /// a screenshot can show the field + suggestions without needing a real tap.
    var forceSearchFocused: Bool = false

    @FocusState private var isSearchFocused: Bool

    var body: some View {
        NavigationStack {
            List {
                if viewModel.isOffline {
                    offlineBanner
                }

                currentLocationSection

                searchSection

                savedLocationsSection
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Locations")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .task {
            await viewModel.onAppear()
            if forceSearchFocused {
                isSearchFocused = true
            }
        }
        .onChange(of: viewModel.locationManager.coordinateUpdateToken) { _, _ in
            guard let coordinate = viewModel.locationManager.coordinate else { return }
            Task { await viewModel.currentLocationCoordinateResolved(coordinate) }
        }
    }

    // MARK: - Offline banner

    private var offlineBanner: some View {
        Label("You're offline. Saved locations show cached data; search is unavailable.", systemImage: "wifi.slash")
            .font(.footnote)
            .foregroundStyle(.secondary)
            .listRowBackground(Color(.secondarySystemFill))
    }

    // MARK: - Current location

    @ViewBuilder
    private var currentLocationSection: some View {
        switch viewModel.locationManager.status {
        case .authorized:
            Section {
                if let entry = viewModel.currentLocationEntry {
                    currentLocationRow(entry)
                } else {
                    HStack {
                        ProgressView()
                        Text("Finding your location\u{2026}")
                            .foregroundStyle(.secondary)
                    }
                }
            }
        case .notDetermined:
            Section {
                HStack {
                    ProgressView()
                    Text("Requesting location access\u{2026}")
                        .foregroundStyle(.secondary)
                }
            }
        case .denied:
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Current location unavailable", systemImage: "location.slash")
                        .font(.subheadline.weight(.semibold))
                    Text("Clear Sky can't use your location because access is turned off. Search for a city instead, or turn location access back on in Settings.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Button("Open iOS Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    }
                    .font(.footnote.weight(.semibold))
                }
                .padding(.vertical, 4)
            }
        }
    }

    private func currentLocationRow(_ location: SavedLocation) -> some View {
        LocationRow(
            name: location.name,
            subtitle: "Current Location",
            state: viewModel.rowState(for: location),
            unit: unitsSettings.unit,
            onRetry: { viewModel.retryRow(location) }
        )
        .contentShape(Rectangle())
        .onTapGesture { viewModel.select(location) }
    }

    // MARK: - Search

    private var searchSection: some View {
        Section {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search for a city", text: $viewModel.searchText)
                    .focused($isSearchFocused)
                    .disabled(viewModel.isOffline)
                    .autocorrectionDisabled()
                if viewModel.isAddingLocation {
                    ProgressView()
                }
            }

            if viewModel.isOffline {
                Text("Search needs a network connection.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else if let error = viewModel.addLocationError {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
            } else {
                ForEach(viewModel.suggestions, id: \.self) { suggestion in
                    Button {
                        Task { await viewModel.selectSuggestion(suggestion) }
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(suggestion.title)
                                .foregroundStyle(.primary)
                            if !suggestion.subtitle.isEmpty {
                                Text(suggestion.subtitle)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Saved locations

    @ViewBuilder
    private var savedLocationsSection: some View {
        if viewModel.manualLocations.isEmpty {
            Section {
                VStack(spacing: 8) {
                    Image(systemName: "mappin.and.ellipse")
                        .font(.system(size: 30))
                        .foregroundStyle(.secondary)
                    Text("No saved locations yet.")
                        .font(.subheadline.weight(.semibold))
                    Text("Search for a city above to add your first one.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            }
        } else {
            Section {
                ForEach(viewModel.manualLocations) { location in
                    LocationRow(
                        name: location.name,
                        subtitle: nil,
                        state: viewModel.rowState(for: location),
                        unit: unitsSettings.unit,
                        onRetry: { viewModel.retryRow(location) }
                    )
                    .contentShape(Rectangle())
                    .onTapGesture { viewModel.select(location) }
                }
                .onDelete(perform: viewModel.delete)
                .onMove(perform: viewModel.move)
            } header: {
                // UX polish package ("Cross-screen consistency"): same header tracking as the
                // Forecast screen's card headers.
                Text("Saved").tracking(0.8)
            }
        }
    }
}

/// One saved-location row: city name, current temp/condition (or "--" + retry on failure).
private struct LocationRow: View {
    let name: String
    let subtitle: String?
    let state: LocationsViewModel.RowFetchState
    let unit: TemperatureUnit
    let onRetry: () -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.body)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            trailing
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var trailing: some View {
        switch state {
        case .loading:
            ProgressView()
        case .loaded(let payload):
            HStack(spacing: 6) {
                Image(systemName: payload.currentConditions.symbolName)
                    .symbolRenderingMode(.multicolor)
                Text(TemperatureFormatting.string(payload.currentConditions.temperature, unit: unit))
                    .font(.subheadline.weight(.medium))
                    .monospacedDigit()
            }
        case .failed:
            HStack(spacing: 8) {
                Text("--")
                    .foregroundStyle(.secondary)
                Button("Retry", action: onRetry)
                    .font(.footnote)
            }
        }
    }
}
