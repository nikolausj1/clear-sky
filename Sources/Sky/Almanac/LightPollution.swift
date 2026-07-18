import Foundation

/// Offline, coarse Bortle-class (1-9) estimate for a lat/lon, built from a bundled table of world
/// population centers rather than satellite imagery. See the "Why population data, not satellite
/// imagery" section below for why -- this was a deliberate fallback after a feasibility pass, not
/// the first choice.
///
/// ## Why population data, not satellite imagery
/// The two standard satellite-derived light-pollution datasets were both ruled out for this app:
/// - **Falchi et al. 2016 "World Atlas of Artificial Night Sky Brightness"** (the dataset almost
///   every light-pollution map/app traces back to) is licensed CC BY-NC 4.0 -- noncommercial only
///   (confirmed against the dataset's license page at GFZ Potsdam's data service, `escidoc:1541893`).
///   Not usable in a commercial App Store app.
/// - **Raw VIIRS annual nighttime-lights composites** (NOAA/Colorado School of Mines "VNL" product,
///   the public-domain/CC-BY source Falchi and most others build on) are freely licensed, but as of
///   this research pass (2026-07) the canonical download host (`eogdata.mines.edu`) requires
///   creating an account to download anything -- every listing/download URL 302-redirects to an
///   OAuth login wall. Account creation on the user's behalf is out of scope for an automated
///   pipeline. The alternative fully-open source (raw daily VIIRS orbital swaths on the "World
///   Bank -- Light Every Night" public S3 bucket, `s3://globalnightlight`, no login required) has
///   no pre-built global mosaic -- it's individual per-orbit swaths that would need their own
///   cloud-masking/compositing pipeline to turn into something usable, which is effectively
///   re-deriving the VNL product's own multi-year processing work from scratch, out of scope here.
///   A third option, David Lorenz's "Light Pollution Atlas" (updated yearly from VIIRS), publishes
///   only rendered PNG maps with no stated license (site just asks that Bortle-scale not be
///   conflated with the maps) -- unusable without contacting the author for explicit commercial
///   terms.
///
/// With satellite-derived brightness off the table, this uses a **published, citable
/// population-and-distance model** instead of an ad hoc "big city = bad sky" guess:
///
/// - **Walker's Law** (Walker, M.F. 1977, *Publications of the Astronomical Society of the
///   Pacific*): sky-glow intensity contributed by a city falls off approximately as
///   `population * distance^-2.5`.
/// - The exact constants used here -- the `11,300,000` scale factor, the 60-nanoLambert /
///   21.9 mag-arcsec^2 natural-skyglow baseline, and the population-dependent city radius
///   (2.5-24 km) inside which the falloff switches from inverse-power to linear -- come from
///   Albers, S. & Duriscoe, D. (2001), "Modeling Light Pollution from Population Data and
///   Implications for National Park Service Lands," *The George Wright Forum* 18(4), 56-61,
///   which is itself an applied, NPS-affiliated implementation of Walker's law for exactly this
///   purpose (classifying darkness at a point from population + distance alone).
/// - The resulting brightness is converted to an approximate sky-quality (mag/arcsec^2) figure
///   and bucketed into Bortle classes using the widely-reproduced Bortle-to-SQM correspondence
///   table (see `bortleTable` below) that traces back to Bortle, J. (2001), "Introducing the
///   Bortle Dark-Sky Scale," *Sky & Telescope*, cross-referenced with SQM readings.
///
/// ## Honesty about what this is (and isn't)
/// This is a **population-proxy heuristic, not a measurement and not a satellite reading**. It
/// will systematically miss things a real sky-brightness map would catch:
/// - Low-population-but-heavily-lit places (industrial sites, ports, oil/gas flaring, sports
///   complexes, highway interchanges) look darker than they really are, because nothing here
///   models light *output* -- only population as a stand-in for it.
/// - Sprawling low-density metros (e.g. Phoenix, Denver) tend to come out 1-2 Bortle classes
///   *darker* than satellite-measured reality, because their population is split across many
///   separately-listed suburb entries in the bundled table rather than summed as one basin-wide
///   source the way an actual light-emission measurement would integrate it.
/// - Dark-sky preserves / lighting ordinances near a city (which measurably reduce local skyglow)
///   aren't modeled at all -- this only sees population and distance.
/// Every result is tagged `confidence: .coarse` for exactly this reason. See
/// `Tests/LightPollutionSmokeTest.swift` for the calibration checks and their documented
/// tolerance (+/- 1-2 Bortle classes against known reference locations).
///
/// ## The bundled data
/// `lightpollution_cities.json` is a quantized table of `[latitude, longitude, population]`
/// triples for every populated place with a recorded population in Natural Earth's 1:10m
/// "populated places" dataset (naturalearthdata.com, public domain, no attribution required --
/// see the project's blog and `About` page: "you can use Natural Earth data ... without
/// restriction"). Pipeline: downloaded the public GeoJSON mirror of
/// `ne_10m_populated_places` (7,342 features), dropped entries with no recorded population
/// (`POP_MAX <= 0`, 10 entries), rounded lat/lon to 3 decimal places (~110 m -- far finer than
/// this model's km-scale city radii need) and population to an integer, and stripped every field
/// except those three numbers (the source file carries ~90 columns of name/translation/admin
/// metadata this model doesn't use). Result: 7,332 records, ~157 KB as compact JSON -- well
/// inside the app's size budget. No further filtering by population was applied; a town of a few
/// hundred people still contributes a (correctly tiny) term to the sum.
enum LightPollution {
    // MARK: - Public result type

    /// How much to trust a `classify(...)` result. Currently always `.coarse` -- this exists as
    /// an enum (rather than being baked into the label text) so a future, better-sourced estimate
    /// could report a tighter confidence without changing the API shape.
    enum Confidence: Equatable {
        /// Population-and-distance heuristic, not a satellite measurement. Expect the true Bortle
        /// class to be within +/- 1-2 of this estimate for most locations (see the smoke test for
        /// worked examples and known failure modes like sprawling low-density metros).
        case coarse
    }

    struct BortleEstimate: Equatable {
        /// 1 (darkest, pristine) ... 9 (brightest, inner-city).
        let bortleClass: Int
        /// Human-readable, honest about the estimate's nature -- always mentions it's an estimate,
        /// never presented as a measurement. e.g. "Roughly Bortle 6 -- bright suburban sky.
        /// Estimate from population data, not a measurement."
        let label: String
        let confidence: Confidence
        /// Approximate sky quality in mag/arcsec^2 implied by the population model, before
        /// bucketing into a Bortle class. Exposed for debugging/transparency, not meant to be
        /// shown to users as a precise reading -- see the type-level doc comment's honesty notes.
        let skyQualityEstimate: Double
    }

    // MARK: - Bundled city table

    struct City: Equatable {
        let latitude: Double
        let longitude: Double
        let population: Double
    }

    /// Decodes the bundled table from raw JSON `Data` (each row is `[latitude, longitude,
    /// population]`) -- pure function, kept separate from disk/bundle access so it can be
    /// exercised with canned JSON in tests without touching `Bundle.main`.
    static func decode(data: Data) throws -> [City] {
        let rows = try JSONDecoder().decode([[Double]].self, from: data)
        return rows.compactMap { row in
            guard row.count == 3 else { return nil }
            return City(latitude: row[0], longitude: row[1], population: row[2])
        }
    }

    /// The bundled table, loaded once from `lightpollution_cities.json`. Empty (with a debug-build
    /// assertion) if the resource is missing or fails to decode -- `classify` degrades gracefully
    /// in that case by falling back to the natural-skyglow baseline everywhere (see below), rather
    /// than crashing.
    static let bundledCities: [City] = {
        guard let url = Bundle.main.url(forResource: "lightpollution_cities", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let decoded = try? decode(data: data) else {
            assertionFailure("lightpollution_cities.json missing or failed to decode -- check project.yml resource wiring")
            return []
        }
        return decoded
    }()

    // MARK: - Model constants (Albers & Duriscoe 2001, applying Walker's Law 1977)

    /// Scale constant from Albers & Duriscoe (2001) eq. 1: `I = 11,300,000 * p * r^-2.5`, `I` in
    /// nanoLamberts, `p` population, `r` distance in meters.
    private static let walkerScale = 11_300_000.0
    /// Natural (no artificial light) zenith skyglow, in nanoLamberts, at solar minimum -- Albers &
    /// Duriscoe's adopted baseline, equivalent to V = 21.9 mag/arcsec^2.
    private static let naturalSkyglowNanoLamberts = 60.0
    private static let naturalSkyglowSQM = 21.9
    /// Beyond this distance, even the largest real-world city's Walker's-Law contribution is many
    /// orders of magnitude below the natural-skyglow floor (a population-18M city at 1,000 km
    /// contributes well under 0.1 nanoLambert against a 60 nanoLambert baseline) -- cutting the sum
    /// off here is a performance optimization, not an accuracy one.
    private static let cutoffDistanceMeters = 1_000_000.0
    /// Earth radius used for the haversine distance below (mean radius, meters).
    private static let earthRadiusMeters = 6_371_000.0

    /// Population-dependent "city radius" (meters) inside which Walker's inverse-power falloff is
    /// replaced by the paper's linear interior model (see `contribution(of:distanceMeters:)`).
    /// Albers & Duriscoe state this ranges "from 2.5 km to 24 km" by city population but don't
    /// publish their exact interpolation curve; this uses a log-population linear ramp between
    /// their two stated endpoints (pop 1,000 -> 2.5 km, pop 10,000,000 -> 24 km, clamped outside
    /// that range), which reproduces the two named endpoints exactly and behaves reasonably
    /// in between.
    private static func cityRadiusMeters(population: Double) -> Double {
        let minRadiusKm = 2.5
        let maxRadiusKm = 24.0
        let logPop = log10(max(population, 1))
        let t = min(max((logPop - 3.0) / (7.0 - 3.0), 0.0), 1.0)
        return (minRadiusKm + (maxRadiusKm - minRadiusKm) * t) * 1000
    }

    /// One city's Walker's-Law contribution to zenith skyglow at `distanceMeters`, in
    /// nanoLamberts. Outside the city's radius this is the straightforward inverse-2.5-power law;
    /// inside it, distance-based division would blow up as `r -> 0`; the model plausibly avoids
    /// that with a *linear* interior ramp instead, per Albers & Duriscoe: brightness stays fixed
    /// at the radius-boundary value at the edge of the disc and increases linearly to 2.5x that
    /// value at dead center. That keeps a large nearby city meaningfully brighter overhead than
    /// standing at its outskirts (matching the real experience of e.g. downtown Chicago vs. its
    /// exurbs) without a numerical singularity at r=0.
    private static func contribution(of city: City, distanceMeters: Double) -> Double {
        let radius = cityRadiusMeters(population: city.population)
        if distanceMeters >= radius {
            return walkerScale * city.population * pow(distanceMeters, -2.5)
        }
        let boundaryValue = walkerScale * city.population * pow(radius, -2.5)
        let interiorFactor = 1.0 + 1.5 * (1.0 - distanceMeters / radius)
        return boundaryValue * interiorFactor
    }

    /// Great-circle distance between two lat/lon points, in meters.
    private static func haversineMeters(lat1: Double, lon1: Double, lat2: Double, lon2: Double) -> Double {
        let phi1 = lat1 * .pi / 180
        let phi2 = lat2 * .pi / 180
        let dPhi = (lat2 - lat1) * .pi / 180
        let dLambda = (lon2 - lon1) * .pi / 180
        let a = sin(dPhi / 2) * sin(dPhi / 2) + cos(phi1) * cos(phi2) * sin(dLambda / 2) * sin(dLambda / 2)
        return 2 * earthRadiusMeters * asin(min(1, sqrt(a)))
    }

    // MARK: - Bortle <-> SQM table

    /// Lower SQM (mag/arcsec^2) bound for each Bortle class, brightest-first, per the widely
    /// reproduced Bortle-to-SQM correspondence (traceable to Bortle 2001 plus subsequent SQM-meter
    /// cross-referencing; the same table appears e.g. on Wikipedia's "Bortle scale" article).
    /// Classes 8/9 aren't numerically bounded in the commonly published table (it just says
    /// "< 18.00" for class 8 and doesn't give class 9 a number); this splits that open-ended tail
    /// at 17.0 so genuinely extreme urban cores (Times-Square-grade, historically measured down
    /// around SQM 15-17) land in class 9 rather than everything below 18.0 flattening into one
    /// bucket.
    private static let bortleTable: [(sqmLowerBound: Double, bortleClass: Int)] = [
        (21.76, 1), (21.6, 2), (21.3, 3), (20.8, 4),
        (19.25, 5), (18.5, 6), (18.0, 7), (17.0, 8),
    ]

    private static let bortleDescriptions: [Int: String] = [
        1: "excellent dark-sky site", 2: "typical truly dark site", 3: "rural sky",
        4: "rural/suburban transition", 5: "suburban sky", 6: "bright suburban sky",
        7: "suburban/urban transition", 8: "city sky", 9: "inner-city sky",
    ]

    private static func bortleClass(forSQM sqm: Double) -> Int {
        for entry in bortleTable where sqm >= entry.sqmLowerBound {
            return entry.bortleClass
        }
        return 9
    }

    // MARK: - Public API

    /// Estimates the Bortle class at a location from the bundled world city/population table.
    /// Pure, deterministic, offline -- no networking, no caching beyond the one-time bundled-table
    /// load above.
    static func classify(latitude: Double, longitude: Double) -> BortleEstimate {
        classify(latitude: latitude, longitude: longitude, cities: bundledCities)
    }

    /// Testable entry point that takes an explicit city table rather than reading
    /// `bundledCities`, so tests can exercise the model with small canned tables instead of the
    /// full 7,332-row bundle.
    static func classify(latitude: Double, longitude: Double, cities: [City]) -> BortleEstimate {
        var totalNanoLamberts = naturalSkyglowNanoLamberts
        for city in cities {
            // Cheap prefilter: a 10-degree latitude gap is already >1,000 km, past the cutoff
            // below, so skip the (more expensive) haversine call entirely for those rows.
            guard abs(city.latitude - latitude) <= 10 else { continue }
            let distance = haversineMeters(lat1: latitude, lon1: longitude, lat2: city.latitude, lon2: city.longitude)
            guard distance <= cutoffDistanceMeters else { continue }
            totalNanoLamberts += contribution(of: city, distanceMeters: distance)
        }

        let ratio = totalNanoLamberts / naturalSkyglowNanoLamberts
        let sqmEstimate = naturalSkyglowSQM - 2.5 * log10(ratio)
        let bortle = bortleClass(forSQM: sqmEstimate)
        let description = bortleDescriptions[bortle] ?? "unknown sky"
        let label = "Roughly Bortle \(bortle) -- \(description). Estimate from population data, not a measurement."

        return BortleEstimate(bortleClass: bortle, label: label, confidence: .coarse, skyQualityEstimate: sqmEstimate)
    }
}
