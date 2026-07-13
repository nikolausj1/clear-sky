import Foundation
import SwiftData

/// A location the user has saved (or the CoreLocation-derived current-location entry).
/// Mirrors PRD Section 8's `SavedLocation`.
@Model
final class SavedLocation {
    @Attribute(.unique) var id: UUID
    var name: String
    var latitude: Double
    var longitude: Double
    var sortOrder: Int
    var isCurrentLocation: Bool

    init(
        id: UUID = UUID(),
        name: String,
        latitude: Double,
        longitude: Double,
        sortOrder: Int,
        isCurrentLocation: Bool = false
    ) {
        self.id = id
        self.name = name
        self.latitude = latitude
        self.longitude = longitude
        self.sortOrder = sortOrder
        self.isCurrentLocation = isCurrentLocation
    }
}
