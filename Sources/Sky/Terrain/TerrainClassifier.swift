import Foundation

/// Which of the four header-illustration landscape sets (see
/// `Sources/Doodle/Layers/IllustratedLandscapeLayer.swift`) best matches a location.
enum TerrainClass: String, CaseIterable {
    case mountains
    case desert
    case coast
    /// The existing default landscape (rolling green hills) — what every location gets
    /// unless it lands in one of the curated regions below.
    case hills
}

/// Coarse, offline, deterministic lat/lon → `TerrainClass` classifier for the doodle header
/// illustration.
///
/// **This is an artistic choice, not geography homework.** The goal is "what landscape would
/// a person picture for this city," not an accurate biome/elevation/coastline model. A real
/// terrain classifier would need a DEM and a coastline dataset; this needs neither — it's a
/// curated table of bounding boxes good enough to make Phoenix look like a desert and Tomah,
/// WI look like the hills it's always looked like. Boxes are generously sized and sometimes
/// overlap on purpose; precedence (below) resolves the overlaps.
///
/// **Precedence: desert > mountains > coast > hills.** Applied as a global rule across the
/// whole table, independent of the order regions happen to be listed in. This specifically
/// matters where boxes overlap:
/// - Seattle sits inside both the Cascades mountain box and the Pacific Northwest coast strip.
///   Mountains wins — Seattle reads as a mountain city (Rainier/Cascades skyline) before it
///   reads as a beach town, and that's the intended header art.
/// - Phoenix and Tucson sit inside the Arizona desert box only (no coast/mountain box reaches
///   them) — straightforward desert.
/// - Miami sits inside the Eastern Seaboard + Gulf coast strips only — straightforward coast.
/// - Tomah WI, Chicago, and Madison don't fall inside any curated box — they (correctly) fall
///   through to `.hills`, matching the existing default landscape art.
///
/// **Coast, without a coastline dataset.** "Within ~25km of a coastline" is implemented as
/// curated coastal-strip boxes (drawn generously — some strips are wider than a true 25km
/// buffer — since the goal is "this city reads as coastal," not a precise buffer) rather than
/// a real distance-to-coastline calculation, which would need a coastline geometry dataset
/// this classifier deliberately doesn't carry.
///
/// The `regions` table is a single flat, data-driven array of (bounding box, `TerrainClass`,
/// label) entries — adding a new region later is just appending a row; no branching logic to
/// touch. `classify` enforces precedence by scanning the table once per class in priority
/// order, not by relying on table order.
enum TerrainClassifier {
    /// One curated rectangular region and the terrain class it maps to. `label` exists purely
    /// for readability/debugging (e.g. when eyeballing why a coordinate classified a certain
    /// way) and plays no role in the classification logic.
    private struct Region {
        let latRange: ClosedRange<Double>
        let lonRange: ClosedRange<Double>
        let terrainClass: TerrainClass
        let label: String

        func contains(latitude: Double, longitude: Double) -> Bool {
            latRange.contains(latitude) && lonRange.contains(longitude)
        }
    }

    // MARK: - Region table

    private static let regions: [Region] = [
        // MARK: Desert

        // US Southwest, US-detailed per the brief.
        Region(latRange: 31.0...37.0, lonRange: -114.8...(-108.0), terrainClass: .desert,
               label: "US Southwest: Arizona / western New Mexico (Phoenix, Tucson)"),
        Region(latRange: 34.5...39.0, lonRange: -118.5...(-114.0), terrainClass: .desert,
               label: "US Southwest: Nevada / SE California Mojave (Las Vegas)"),
        Region(latRange: 36.5...39.0, lonRange: -114.0...(-108.8), terrainClass: .desert,
               label: "US Southwest: southern Utah (St. George / Moab high desert)"),
        Region(latRange: 32.0...34.0, lonRange: -116.4...(-114.0), terrainClass: .desert,
               label: "US Southwest: SE California Colorado Desert (Imperial / Coachella)"),

        // Coarse global deserts.
        Region(latRange: 15.0...32.0, lonRange: -17.0...36.0, terrainClass: .desert,
               label: "Sahara band (North Africa, incl. Cairo)"),
        Region(latRange: 15.0...30.0, lonRange: 36.0...56.0, terrainClass: .desert,
               label: "Arabian Peninsula"),
        Region(latRange: -30.0...(-20.0), lonRange: 122.0...141.0, terrainClass: .desert,
               label: "Central Australian outback"),
        Region(latRange: 38.0...46.0, lonRange: 90.0...110.0, terrainClass: .desert,
               label: "Gobi Desert"),
        Region(latRange: -30.0...(-18.0), lonRange: -71.0...(-68.0), terrainClass: .desert,
               label: "Atacama strip"),

        // MARK: Mountains

        // US Mountain West, US-detailed per the brief.
        Region(latRange: 35.0...49.0, lonRange: -112.5...(-104.5), terrainClass: .mountains,
               label: "US Rockies corridor (Denver, Salt Lake City)"),
        Region(latRange: 44.5...49.5, lonRange: -124.0...(-120.0), terrainClass: .mountains,
               label: "US Cascades, PNW (Seattle, Portland — wins over the coast strip below)"),
        Region(latRange: 36.0...44.5, lonRange: -120.5...(-118.0), terrainClass: .mountains,
               label: "US Sierra Nevada, California"),
        Region(latRange: 34.0...44.0, lonRange: -84.0...(-77.0), terrainClass: .mountains,
               label: "Appalachian high spine (coarse — GA to VT)"),

        // Coarse global ranges.
        Region(latRange: 45.0...48.0, lonRange: 6.0...16.0, terrainClass: .mountains,
               label: "Alps (incl. Zurich)"),
        Region(latRange: -55.0...11.0, lonRange: -76.0...(-66.0), terrainClass: .mountains,
               label: "Andes corridor"),
        Region(latRange: 27.0...36.0, lonRange: 72.0...95.0, terrainClass: .mountains,
               label: "Himalaya"),

        // MARK: Coast

        // US coastal strips, US-detailed per the brief. Deliberately generous widths — this is
        // "reads as a coastal city," not a precise 25km buffer.
        Region(latRange: 25.0...45.0, lonRange: -81.0...(-69.0), terrainClass: .coast,
               label: "US Eastern Seaboard strip (Miami, Boston)"),
        Region(latRange: 24.0...31.0, lonRange: -98.0...(-80.0), terrainClass: .coast,
               label: "US Gulf strip"),
        Region(latRange: 32.0...37.5, lonRange: -122.8...(-117.0), terrainClass: .coast,
               label: "US coastal California strip (San Diego)"),
        Region(latRange: 42.0...49.0, lonRange: -125.0...(-122.0), terrainClass: .coast,
               label: "US Pacific Northwest coast strip (loses to the Cascades mountain box above for Seattle/Portland)"),

        // Island / known-coastal-city boxes, global.
        Region(latRange: 18.5...22.5, lonRange: -160.5...(-154.5), terrainClass: .coast,
               label: "Hawaiian islands (Honolulu)"),
        Region(latRange: -35.0...(-33.0), lonRange: 150.5...152.0, terrainClass: .coast,
               label: "Sydney / SE Australia coast"),
        Region(latRange: -23.5...(-22.0), lonRange: -44.0...(-42.5), terrainClass: .coast,
               label: "Rio de Janeiro coast"),
        Region(latRange: 34.0...36.0, lonRange: 139.0...140.5, terrainClass: .coast,
               label: "Tokyo Bay coast"),
        Region(latRange: -34.5...(-33.5), lonRange: 18.0...19.0, terrainClass: .coast,
               label: "Cape Town coast"),
    ]

    /// Precedence order the classifier resolves overlapping regions with: a coordinate that
    /// matches a desert box is desert even if it also matches a coast box, and so on down the
    /// list. Anything matching none of the three curated classes falls through to `.hills`.
    private static let precedence: [TerrainClass] = [.desert, .mountains, .coast]

    /// Classifies a location for the header illustration. Pure, deterministic, offline —
    /// no network access, no state, same input always gives the same output.
    static func classify(latitude: Double, longitude: Double) -> TerrainClass {
        for terrainClass in precedence {
            let matches = regions.contains {
                $0.terrainClass == terrainClass && $0.contains(latitude: latitude, longitude: longitude)
            }
            if matches {
                return terrainClass
            }
        }
        return .hills
    }
}
