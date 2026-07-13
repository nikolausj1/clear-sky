import CoreLocation
import MapKit
import Observation

/// PRD Screen B / Section 9: "MKLocalSearch for autocomplete." `MKLocalSearchCompleter` drives
/// suggestions as the user types (debounced); a chosen completion is resolved to coordinates via
/// `MKLocalSearch`.
@MainActor
@Observable
final class LocationSearchService: NSObject, MKLocalSearchCompleterDelegate {
    struct ResolvedLocation {
        var name: String
        var coordinate: CLLocationCoordinate2D
    }

    private(set) var suggestions: [MKLocalSearchCompletion] = []
    private(set) var errorMessage: String?

    private let completer = MKLocalSearchCompleter()
    private var debounceTask: Task<Void, Never>?

    override init() {
        super.init()
        completer.resultTypes = [.address, .pointOfInterest]
        completer.delegate = self
    }

    /// Debounced as the user types (PRD Section 6 build brief: "Debounce input").
    func updateQuery(_ text: String) {
        debounceTask?.cancel()
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            suggestions = []
            completer.queryFragment = ""
            return
        }
        debounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            self?.completer.queryFragment = trimmed
        }
    }

    func clear() {
        debounceTask?.cancel()
        suggestions = []
        completer.queryFragment = ""
    }

    func resolve(_ completion: MKLocalSearchCompletion) async throws -> ResolvedLocation {
        let request = MKLocalSearch.Request(completion: completion)
        let search = MKLocalSearch(request: request)
        let response = try await search.start()
        guard let item = response.mapItems.first else {
            throw ResolveError.noResult
        }
        return ResolvedLocation(name: Self.displayName(for: item, completion: completion), coordinate: item.placemark.coordinate)
    }

    private static func displayName(for item: MKMapItem, completion: MKLocalSearchCompletion) -> String {
        let placemark = item.placemark
        if let locality = placemark.locality {
            if let admin = placemark.administrativeArea {
                return "\(locality), \(admin)"
            }
            return locality
        }
        if let name = item.name {
            return name
        }
        return completion.title
    }

    enum ResolveError: LocalizedError {
        case noResult
        var errorDescription: String? { "No location found for that search result." }
    }

    // MARK: - MKLocalSearchCompleterDelegate

    nonisolated func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        let results = completer.results
        Task { @MainActor in
            self.suggestions = results
            self.errorMessage = nil
        }
    }

    nonisolated func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        Task { @MainActor in
            self.errorMessage = error.localizedDescription
        }
    }
}
