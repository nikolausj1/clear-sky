import CoreLocation
import Foundation

/// Sim-verify launch-arg hook (Project Build Guide's autostart-hook pattern): `-seedLocations
/// "Tomah,WI;Madison,WI;Seattle,WA"` seeds `SavedLocation` rows at launch so a screenshot can
/// show a populated saved-locations list, Forecast paging, and a page indicator without needing
/// real taps through search (`simctl` can't tap). Only a small fixed set of demo cities is
/// resolved (no network geocode at launch — deterministic and instant); an unrecognized name is
/// skipped rather than guessed.
enum DemoSeeding {
    /// "City,ST" -> coordinate. Deliberately small: just the cities named in the Phase 3 build
    /// brief plus a couple of extras useful for later phases' seeding (e.g. Rankings screenshots).
    private static let knownCities: [String: CLLocationCoordinate2D] = [
        "Tomah,WI": CLLocationCoordinate2D(latitude: 43.9814, longitude: -90.5040),
        "Madison,WI": CLLocationCoordinate2D(latitude: 43.0731, longitude: -89.4012),
        "Seattle,WA": CLLocationCoordinate2D(latitude: 47.6062, longitude: -122.3321),
        "Chicago,IL": CLLocationCoordinate2D(latitude: 41.8781, longitude: -87.6298),
        "New York,NY": CLLocationCoordinate2D(latitude: 40.7128, longitude: -74.0060),
        "Springfield,IL": CLLocationCoordinate2D(latitude: 39.7817, longitude: -89.6501),
        // Phase 6 (Rankings): hot/dry vs. Seattle's wet gives the seeded ranking score spread
        // room to show a real order, not four cities clustered in the same band.
        "Phoenix,AZ": CLLocationCoordinate2D(latitude: 33.4484, longitude: -112.0740),
        // Location terrain integration sim-verify: the coast terrain case (Seattle already
        // covers mountains, Phoenix covers desert, Tomah covers the hills default).
        "Miami,FL": CLLocationCoordinate2D(latitude: 25.7617, longitude: -80.1918),
    ]

    static func parse(_ raw: String) -> [(name: String, coordinate: CLLocationCoordinate2D)] {
        raw.split(separator: ";")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .compactMap { entry -> (String, CLLocationCoordinate2D)? in
                guard let coordinate = knownCities[entry] else { return nil }
                let displayName = String(entry.split(separator: ",").first ?? Substring(entry))
                return (displayName, coordinate)
            }
    }

    static func seedLocationsFromLaunchArgs() -> [(name: String, coordinate: CLLocationCoordinate2D)] {
        let args = CommandLine.arguments
        guard let flagIndex = args.firstIndex(of: "-seedLocations"), flagIndex + 1 < args.count else { return [] }
        return parse(args[flagIndex + 1])
    }
}
