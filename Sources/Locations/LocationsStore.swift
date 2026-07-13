import CoreLocation
import Foundation
import SwiftData

/// SwiftData CRUD for `SavedLocation` (PRD Section 8 / Screen B). Owns reorder (drag),
/// delete (swipe), add-from-search (with dedupe-by-rounded-coordinate), and the single
/// CoreLocation-derived "current location" row (excluded from manual reorder/delete per the
/// `SavedLocation.isCurrentLocation` doc comment).
///
/// Marked `@MainActor` for the same reason as `WeatherStore`: `ModelContext` isn't thread-safe,
/// and every consumer here is main-actor-bound anyway.
@MainActor
final class LocationsStore {
    /// Coordinate rounding for "already saved" dedupe (PRD Screen B: "if it's already saved
    /// (dedupe by rounded coordinate), just switch to it — no duplicate entries"). Two decimal
    /// places (~1.1km) is coarse enough to treat "the same city, slightly different search
    /// result" as a match, without merging genuinely distinct nearby towns.
    static let dedupePrecision = 2

    private let modelContext: ModelContext

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    /// All saved locations sorted for display: the current-location row (if any) always first,
    /// then manual saves in `sortOrder`.
    func fetchAll() -> [SavedLocation] {
        let descriptor = FetchDescriptor<SavedLocation>(
            sortBy: [SortDescriptor(\.sortOrder)]
        )
        return (try? modelContext.fetch(descriptor)) ?? []
    }

    @discardableResult
    func existingMatch(for coordinate: CLLocationCoordinate2D) -> SavedLocation? {
        let target = Self.roundedKey(coordinate)
        return fetchAll().first { !$0.isCurrentLocation && Self.roundedKey($0.coordinate) == target }
    }

    /// Adds a searched location, or returns the existing saved entry if one already matches
    /// (rounded-coordinate dedupe) — never creates a duplicate for the same place.
    @discardableResult
    func addOrFind(name: String, coordinate: CLLocationCoordinate2D) -> SavedLocation {
        if let existing = existingMatch(for: coordinate) {
            return existing
        }
        let manualLocations = fetchAll().filter { !$0.isCurrentLocation }
        let nextSortOrder = (manualLocations.map(\.sortOrder).max() ?? -1) + 1
        let location = SavedLocation(
            name: name,
            latitude: coordinate.latitude,
            longitude: coordinate.longitude,
            sortOrder: nextSortOrder
        )
        modelContext.insert(location)
        try? modelContext.save()
        return location
    }

    func delete(_ location: SavedLocation) {
        guard !location.isCurrentLocation else { return }
        modelContext.delete(location)
        try? modelContext.save()
    }

    /// Persists a new manual order after a drag-reorder. `orderedManualLocations` excludes the
    /// current-location row (it never participates in manual reordering).
    func reorder(_ orderedManualLocations: [SavedLocation]) {
        for (index, location) in orderedManualLocations.enumerated() where !location.isCurrentLocation {
            location.sortOrder = index
        }
        try? modelContext.save()
    }

    /// Creates or updates the single CoreLocation-derived row. Always sorts before every manual
    /// entry (`sortOrder = -1`).
    @discardableResult
    func upsertCurrentLocation(name: String, coordinate: CLLocationCoordinate2D) -> SavedLocation {
        if let existing = fetchAll().first(where: { $0.isCurrentLocation }) {
            existing.name = name
            existing.latitude = coordinate.latitude
            existing.longitude = coordinate.longitude
            try? modelContext.save()
            return existing
        }
        let location = SavedLocation(
            name: name,
            latitude: coordinate.latitude,
            longitude: coordinate.longitude,
            sortOrder: -1,
            isCurrentLocation: true
        )
        modelContext.insert(location)
        try? modelContext.save()
        return location
    }

    func removeCurrentLocationRow() {
        guard let existing = fetchAll().first(where: { $0.isCurrentLocation }) else { return }
        modelContext.delete(existing)
        try? modelContext.save()
    }

    private static func roundedKey(_ coordinate: CLLocationCoordinate2D) -> String {
        let factor = pow(10.0, Double(dedupePrecision))
        let lat = (coordinate.latitude * factor).rounded() / factor
        let lon = (coordinate.longitude * factor).rounded() / factor
        return "\(lat),\(lon)"
    }
}

extension SavedLocation {
    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}
