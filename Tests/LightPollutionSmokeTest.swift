import Foundation

// Smoke test for Sources/Sky/Almanac/LightPollution.swift. Build Guide engine-test recipe:
//   T=$(mktemp -d) && xattr -cr Sources && cp Tests/LightPollutionSmokeTest.swift "$T/main.swift" && \
//     swiftc -O Sources/Sky/Almanac/*.swift "$T/main.swift" -o "$T/t" && "$T/t"; rm -rf "$T"
//
// NOTE: `swiftc -O Sources/Sky/Almanac/*.swift` pulls in every file currently in that directory,
// not just LightPollution.swift -- if other Almanac work (Comets, Eclipses, BestNight, OnThisDay)
// is present, this recipe compiles them all together. That's expected; this test only exercises
// the LightPollution API.
//
// This test deliberately never calls `LightPollution.classify(latitude:longitude:)` (the
// Bundle.main-backed convenience overload) or touches `LightPollution.bundledCities` --
// `Bundle.main` isn't meaningful for a bare `swiftc`-compiled binary outside an app bundle, and
// the bundled-table loader's `assertionFailure` fallback would fire under `-O`. Instead:
//  1. It loads the real `lightpollution_cities.json` straight off disk (relative to the repo
//     root, which is this recipe's cwd when it runs the compiled binary -- see the Build Guide)
//     and decodes it with `LightPollution.decode(data:)`, exercising the real shipped data file.
//  2. It runs `LightPollution.classify(latitude:longitude:cities:)` -- the injectable overload --
//     against that real, full city table for a set of known reference locations.
// Every check prints PASS or FAIL; the process exits non-zero if anything failed.

var passCount = 0
var failCount = 0

func check(_ name: String, _ condition: @autoclosure () -> Bool, _ detail: @autoclosure () -> String = "") {
    if condition() {
        passCount += 1
        print("PASS: \(name)")
    } else {
        failCount += 1
        let d = detail()
        print("FAIL: \(name)" + (d.isEmpty ? "" : " -- \(d)"))
    }
}

/// Asserts the estimated Bortle class for a known location falls within an expected range.
/// Ranges are deliberately +/- 1-2 classes wide -- this is a population-proxy heuristic, not a
/// measurement (see the doc comment on `LightPollution`), and is documented as such.
func checkBortle(_ name: String, _ lat: Double, _ lon: Double, expected: ClosedRange<Int>, cities: [LightPollution.City]) {
    let estimate = LightPollution.classify(latitude: lat, longitude: lon, cities: cities)
    check(
        "\(name) -> Bortle \(estimate.bortleClass) (expected \(expected))",
        expected.contains(estimate.bortleClass),
        "got \(estimate.bortleClass), sqm~\(String(format: "%.2f", estimate.skyQualityEstimate))"
    )
}

print("================================================================")
print(" Clear Sky -- Light pollution (Bortle estimate) smoke test")
print("================================================================\n")

// MARK: - 1. Load and decode the real bundled dataset

print("--- Bundled dataset ---")
let cities: [LightPollution.City]
do {
    let url = URL(fileURLWithPath: "Sources/Sky/Almanac/lightpollution_cities.json")
    let data = try Data(contentsOf: url)
    cities = try LightPollution.decode(data: data)
    check("lightpollution_cities.json loads and decodes", true)
    check("record count is in the expected ballpark (Natural Earth 10m populated places, pop > 0)", cities.count > 7000 && cities.count < 7500, "got \(cities.count) records")
} catch {
    check("lightpollution_cities.json loads and decodes", false, "\(error)")
    cities = []
}

// Sanity: every decoded row should have plausible lat/lon/population.
let allPlausible = cities.allSatisfy { $0.latitude >= -90 && $0.latitude <= 90 && $0.longitude >= -180 && $0.longitude <= 180 && $0.population > 0 }
check("all decoded rows have plausible lat/lon/population", allPlausible)

// MARK: - 2. decode(data:) unit checks (malformed rows)

print("\n--- decode(data:) malformed-row handling ---")
do {
    let malformedJSON = Data("[[1.0, 2.0, 3.0], [1.0, 2.0], [4.0, 5.0, 6.0]]".utf8)
    let decoded = try LightPollution.decode(data: malformedJSON)
    check("decode(data:) drops rows that aren't exactly 3 numbers", decoded.count == 2, "got \(decoded.count) rows")
} catch {
    check("decode(data:) drops rows that aren't exactly 3 numbers", false, "\(error)")
}

// MARK: - 3. Bortle estimates for known reference locations, against the real dataset

guard !cities.isEmpty else {
    print("\nNo cities loaded -- skipping classify() checks (dataset load already failed above).")
    print("\n================================================================")
    print(" Summary: \(passCount)/\(passCount + failCount) checks passed")
    print("================================================================")
    exit(failCount == 0 ? 0 : 1)
}

print("\n--- Reference locations (per work-order test cases) ---")
checkBortle("Downtown Chicago, IL", 41.8781, -87.6298, expected: 6...9, cities: cities)
checkBortle("Rural Wisconsin (Tomah)", 43.9800, -90.5001, expected: 2...5, cities: cities)

print("\n--- Additional US reference locations ---")
checkBortle("Manhattan, NYC", 40.7831, -73.9712, expected: 7...9, cities: cities)
checkBortle("Los Angeles, CA", 34.0522, -118.2437, expected: 6...9, cities: cities)
checkBortle("Suburb: Naperville, IL", 41.7508, -88.1535, expected: 4...8, cities: cities)
checkBortle("Small town: Ames, IA", 42.0308, -93.6319, expected: 2...6, cities: cities)
checkBortle("Death Valley, CA (dark-sky park)", 36.5323, -117.0794, expected: 1...3, cities: cities)
checkBortle("Cherry Springs, PA (dark-sky park)", 41.6628, -77.8261, expected: 1...3, cities: cities)
checkBortle("Rural Montana", 47.0, -109.0, expected: 1...3, cities: cities)

print("\n--- International reference locations ---")
checkBortle("Central London, UK", 51.5074, -0.1278, expected: 6...9, cities: cities)
checkBortle("Sydney, Australia", -33.8688, 151.2093, expected: 6...9, cities: cities)
checkBortle("Rural Australian outback", -25.0, 133.0, expected: 1...2, cities: cities)
checkBortle("Antarctica interior", -80.0, 0.0, expected: 1...2, cities: cities)

print("\n--- Edge cases ---")
checkBortle("Mid-Pacific Ocean (no nearby population)", 20.0, -150.0, expected: 1...1, cities: cities)
checkBortle("International Date Line crossing (near Fiji)", -17.7, 178.0, expected: 1...2, cities: cities)

// Monotonicity sanity: a demonstrably darker place should never come out brighter than a
// demonstrably brighter place. This is a stronger, more structural check than any single
// absolute-class assertion above.
let manhattan = LightPollution.classify(latitude: 40.7831, longitude: -73.9712, cities: cities)
let ruralMontana = LightPollution.classify(latitude: 47.0, longitude: -109.0, cities: cities)
check(
    "Manhattan (Bortle \(manhattan.bortleClass)) is brighter than rural Montana (Bortle \(ruralMontana.bortleClass))",
    manhattan.bortleClass > ruralMontana.bortleClass
)

// Label honesty: every label must say "estimate," never claim to be a measurement.
let sampleLabelEstimate = LightPollution.classify(latitude: 41.8781, longitude: -87.6298, cities: cities)
check(
    "label is honestly hedged (mentions 'Estimate', not phrased as a measurement)",
    sampleLabelEstimate.label.contains("Estimate") && !sampleLabelEstimate.label.lowercased().contains("measured"),
    sampleLabelEstimate.label
)
check("confidence is always .coarse (this model has no path to a tighter confidence yet)", sampleLabelEstimate.confidence == .coarse)

print("\n================================================================")
print(" Summary: \(passCount)/\(passCount + failCount) checks passed")
print("================================================================")

if failCount == 0 {
    print(" ALL CHECKS PASSED")
    exit(0)
} else {
    print(" \(failCount) CHECK(S) FAILED -- see FAIL lines above")
    exit(1)
}
