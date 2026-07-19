import Foundation

/// Which of the four header-illustration landscape sets (see
/// `Sources/Doodle/Layers/IllustratedLandscapeLayer.swift`) best matches a location.
///
/// **Widget work package note:** extracted out of `Sources/Sky/Terrain/TerrainClassifier.swift`
/// (which keeps the actual lat/lon region table and `classify(...)` logic, app-only) into this
/// `Sources/Shared` file so `WidgetSnapshot.terrainClass` — written by the app, read by
/// `ZenithWidgets` — compiles in the widget extension target without pulling that region table
/// (and its many bounding-box entries) into the extension's own binary. The widget never
/// classifies a coordinate itself; it only reads whichever case the app already decided.
enum TerrainClass: String, CaseIterable, Codable {
    case mountains
    case desert
    case coast
    /// The existing default landscape (rolling green hills) — what every location gets
    /// unless it lands in one of the curated regions below.
    case hills
}
