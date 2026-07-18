import Foundation

// Terrain classifier smoke test — validates Sources/Sky/Terrain against a hand-picked list of
// known cities. This is an artistic classifier (see the doc comment on TerrainClassifier), so
// "correct" here means "matches the intended header-art call for this city," not a geography
// reference. Run via the engine-test recipe (see Project Build Guide.md):
//   T=$(mktemp -d) && xattr -cr Sources && cp Tests/TerrainSmokeTest.swift "$T/main.swift" && \
//     swiftc -O Sources/Sky/Terrain/*.swift "$T/main.swift" -o "$T/t" && "$T/t"; rm -rf "$T"

var totalChecks = 0
var passedChecks = 0

func check(_ city: String, _ lat: Double, _ lon: Double, expected: TerrainClass) {
    totalChecks += 1
    let actual = TerrainClassifier.classify(latitude: lat, longitude: lon)
    let ok = actual == expected
    if ok { passedChecks += 1 }
    let status = ok ? "PASS" : "FAIL"
    print("\(status)  \(city) (\(lat), \(lon)): expected \(expected.rawValue), got \(actual.rawValue)")
}

print("================================================================")
print(" Clear Sky — Terrain classifier smoke test")
print("================================================================\n")

print("--- US mountains ---")
check("Seattle, WA",     47.6062, -122.3321, expected: .mountains) // Cascades box wins over the PNW coast strip.
check("Denver, CO",      39.7392, -104.9903, expected: .mountains)
check("Salt Lake City, UT", 40.7608, -111.8910, expected: .mountains)

print("\n--- US desert ---")
check("Phoenix, AZ",     33.4484, -112.0740, expected: .desert)
check("Las Vegas, NV",   36.1699, -115.1398, expected: .desert)
check("Tucson, AZ",      32.2226, -110.9747, expected: .desert)

print("\n--- US coast ---")
check("Miami, FL",       25.7617,  -80.1918, expected: .coast)
check("Boston, MA",      42.3601,  -71.0589, expected: .coast)
check("San Diego, CA",   32.7157, -117.1611, expected: .coast)
check("Honolulu, HI",    21.3069, -157.8583, expected: .coast)

print("\n--- US hills (default) ---")
check("Tomah, WI",       43.9800,  -90.5001, expected: .hills)
check("Chicago, IL",     41.8781,  -87.6298, expected: .hills)
check("Madison, WI",     43.0731,  -89.4012, expected: .hills)
check("Dallas, TX",      32.7767,  -96.7970, expected: .hills)

print("\n--- Global ---")
check("Cairo, Egypt",    30.0444,   31.2357, expected: .desert)
check("Zurich, Switzerland", 47.3769, 8.5417, expected: .mountains)
check("Sydney, Australia", -33.8688, 151.2093, expected: .coast)
check("London, UK",      51.5074,   -0.1278, expected: .hills)

print("\n================================================================")
print(" Summary: \(passedChecks)/\(totalChecks) checks passed")
print("================================================================")

if passedChecks == totalChecks {
    print(" ALL CHECKS PASSED")
} else {
    print(" \(totalChecks - passedChecks) CHECK(S) FAILED — see FAIL lines above")
}
