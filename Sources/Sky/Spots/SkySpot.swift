import Foundation

/// One entry in the curated "Sky Spots" atlas -- a real-world place worth knowing about for one
/// of three reasons: it's an active rocket-launch site, it sits under (or close to) the auroral
/// oval, or it's a globally recognized dark-sky destination. This is the static reference data
/// only; `SkySpots.swift` layers tonight's live conditions (next scheduled launch, aurora
/// outlook, moon note, saved-city ranking) on top of it.
///
/// Mirrors the "leaf dependency" shape the rest of `Sources/Sky/` content tables already use
/// (`Comets.Comet`, `Eclipses.Eclipse`, `LightPollution.City`): a pure `Codable` struct, no
/// networking, no `Date()` default, decodable straight from `skyspots.json` via
/// `SkySpotsAtlas.decode(data:)` so a CLI smoke test can exercise the real bundled file without
/// an app `Bundle` -- see `Tests/SpotsSmokeTest.swift`, which follows
/// `Tests/LightPollutionSmokeTest.swift`'s documented pattern of loading the JSON straight off
/// disk (relative to the repo root) instead of going through `Bundle.main`.
struct SkySpot: Codable, Identifiable, Equatable {
    enum Category: String, Codable, CaseIterable {
        case launchSite
        case auroraSpot
        case darkSky
    }

    var id: String
    var name: String
    var category: Category
    /// 1-2 factual sentences: what happens here, or why it's on this list. Register per work
    /// order: factual, no exclamations.
    var blurb: String
    var latitude: Double
    var longitude: Double
    /// `launchSite` entries only: case-insensitive substrings matched against
    /// `UpcomingLaunch.padName`/`.locationDisplay` to find this site's next scheduled launch --
    /// see `SkySpots.launchSiteNext(spot:launches:)`. Empty array for `auroraSpot`/`darkSky`
    /// entries, which have no launch-matching concept.
    var matchKeys: [String]
    /// `darkSky` entries only, where a Bortle-class (or equivalent "Gold tier"/"Class 1")
    /// estimate is well documented for that specific site by a recognized source (DarkSky
    /// International certification, park service literature, etc.). `nil` when no reliably
    /// sourced figure exists for the site, rather than guessing one.
    var bortleNote: String?

    init(
        id: String,
        name: String,
        category: Category,
        blurb: String,
        latitude: Double,
        longitude: Double,
        matchKeys: [String] = [],
        bortleNote: String? = nil
    ) {
        self.id = id
        self.name = name
        self.category = category
        self.blurb = blurb
        self.latitude = latitude
        self.longitude = longitude
        self.matchKeys = matchKeys
        self.bortleNote = bortleNote
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, category, blurb, latitude, longitude, matchKeys, bortleNote
    }

    /// Custom decoding so `matchKeys` (which `auroraSpot`/`darkSky` entries in `skyspots.json`
    /// simply omit, rather than spelling out as `"matchKeys": []`) defaults to an empty array
    /// instead of the synthesized `Decodable` conformance's default behavior of requiring every
    /// non-Optional key to be present.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        category = try container.decode(Category.self, forKey: .category)
        blurb = try container.decode(String.self, forKey: .blurb)
        latitude = try container.decode(Double.self, forKey: .latitude)
        longitude = try container.decode(Double.self, forKey: .longitude)
        matchKeys = try container.decodeIfPresent([String].self, forKey: .matchKeys) ?? []
        bortleNote = try container.decodeIfPresent(String.self, forKey: .bortleNote)
    }
}

/// Loading/decoding for the bundled `skyspots.json` atlas. A separate (non-nested) enum from
/// `SkySpot` itself, same split `Comets`/`Eclipses` use between their nested content struct and
/// the enum that owns `decode(data:)`/`all` -- kept here in the model file rather than in
/// `SkySpots.swift` since it's JSON I/O, not live-data binding logic.
enum SkySpotsAtlas {
    /// Decodes a spots table from raw JSON `Data` -- pure function, same testability rationale
    /// as `Eclipses.decode(data:)`/`Comets.decode(data:)`: callers (including CLI smoke tests)
    /// can feed it a file read from an arbitrary path, not just the app bundle.
    static func decode(data: Data) throws -> [SkySpot] {
        try JSONDecoder().decode([SkySpot].self, from: data)
    }

    /// The bundled table, loaded once from `skyspots.json` in the app bundle. Empty (with a
    /// debug-build assertion) if the resource is missing or fails to decode -- same
    /// fail-soft-in-release contract as `Comets.all`/`Eclipses.all`.
    ///
    /// NOTE: `Bundle.main` isn't meaningful for a bare `swiftc`-compiled CLI binary outside an
    /// app bundle -- `Tests/SpotsSmokeTest.swift` never touches this property; it loads
    /// `skyspots.json` straight off disk via `decode(data:)` instead (see that file).
    static let all: [SkySpot] = {
        guard let url = Bundle.main.url(forResource: "skyspots", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let decoded = try? decode(data: data) else {
            assertionFailure("skyspots.json missing or failed to decode -- check project.yml resource wiring")
            return []
        }
        return decoded
    }()
}
