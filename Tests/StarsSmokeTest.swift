import Foundation

// Bright-star catalog smoke test — validates Sources/Sky/Astronomy/BrightStars.swift against
// (a) internal catalog-integrity invariants and (b) reference alt/az values computed live on
// 2026-07-20 with the National Astronomical Observatory of Japan's "Altitude / Azimuth of
// Stars" tool (https://eco.mtk.nao.ac.jp/cgi-bin/koyomi/cande/horizontal_rhip_en.cgi), an
// independent J2000/Hipparcos-based calculator, for the observer site Tomah, WI
// (43.98°N, 90.50°W, height 280 m — same site AstronomySmokeTest.swift uses).
//
// Run via the engine-test recipe (see Project Build Guide.md):
//   T=$(mktemp -d) && xattr -cr Sources && cp Tests/StarsSmokeTest.swift "$T/main.swift" && \
//     swiftc -O Sources/Sky/Astronomy/*.swift "$T/main.swift" -o "$T/t" && "$T/t"; rm -rf "$T"

var totalChecks = 0
var passedChecks = 0

func checkValue(_ label: String, expected: Double, actual: Double, tolerance: Double, unit: String = "") {
    totalChecks += 1
    let ok = abs(actual - expected) <= tolerance
    if ok { passedChecks += 1 }
    let status = ok ? "PASS" : "FAIL"
    print("\(status)  \(label): expected \(fmt(expected))\(unit), got \(fmt(actual))\(unit) (Δ\(String(format: "%+.3f", actual - expected))\(unit), tolerance ±\(tolerance)\(unit))")
}

/// Circular difference between two azimuths (degrees), correctly handling the 0/360 wraparound
/// (e.g. 359° vs 1° should read as Δ2°, not Δ358°).
func azimuthDelta(_ a: Double, _ b: Double) -> Double {
    var d = (a - b).truncatingRemainder(dividingBy: 360)
    if d > 180 { d -= 360 }
    if d < -180 { d += 360 }
    return abs(d)
}

func checkAzimuth(_ label: String, expected: Double, actual: Double, tolerance: Double) {
    totalChecks += 1
    let delta = azimuthDelta(expected, actual)
    let ok = delta <= tolerance
    if ok { passedChecks += 1 }
    let status = ok ? "PASS" : "FAIL"
    print("\(status)  \(label): expected \(fmt(expected))°, got \(fmt(actual))° (Δ\(fmt(delta))°, tolerance ±\(tolerance)°)")
}

func checkBool(_ label: String, expected: Bool, actual: Bool) {
    totalChecks += 1
    let ok = expected == actual
    if ok { passedChecks += 1 }
    print("\(ok ? "PASS" : "FAIL")  \(label): expected \(expected), got \(actual)")
}

func checkTrue(_ label: String, _ condition: Bool) {
    totalChecks += 1
    if condition { passedChecks += 1 }
    print("\(condition ? "PASS" : "FAIL")  \(label)")
}

func fmt(_ x: Double) -> String { String(format: "%.3f", x) }

/// Builds a `Date` from calendar components in a named IANA time zone.
func makeDate(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int, timeZoneID: String) -> Date {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: timeZoneID)!
    var c = DateComponents()
    c.year = year; c.month = month; c.day = day; c.hour = hour; c.minute = minute
    return cal.date(from: c)!
}

func makeUTCDate(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int) -> Date {
    makeDate(year, month, day, hour, minute, timeZoneID: "UTC")
}

func star(named name: String) -> BrightStars.Star {
    guard let s = BrightStars.all.first(where: { $0.name == name }) else {
        fatalError("catalog missing expected star \(name)")
    }
    return s
}

// MARK: - Location: Tomah, WI (same site as AstronomySmokeTest.swift)

let tomahLat = 43.98
let tomahLonEast = -90.50 // this engine takes longitude positive-EAST; Tomah is 90.50°W

print("================================================================")
print(" Bright-star catalog smoke test")
print("================================================================\n")

// MARK: 1. Catalog integrity

print("--- Catalog integrity ---")

checkTrue("Catalog has 23 entries (22 brightest + Polaris)", BrightStars.all.count == 23)

for s in BrightStars.all {
    checkTrue("\(s.name): RA in [0, 360)", s.raDegJ2000 >= 0 && s.raDegJ2000 < 360)
    checkTrue("\(s.name): Dec in [-90, 90]", s.decDegJ2000 >= -90 && s.decDegJ2000 <= 90)
}

checkValue("Sirius magnitude ≈ -1.46 (canonical value)", expected: -1.46, actual: star(named: "Sirius").magnitude, tolerance: 0.1)

// Magnitudes should be in ascending (brightest-first) plausible order across the catalog,
// i.e. every entry is at least as bright as the previous — the catalog is hand-ordered
// brightest-to-faintest, so this also doubles as a "did I typo a magnitude" check.
do {
    var monotonic = true
    for i in 1..<BrightStars.all.count where BrightStars.all[i].magnitude < BrightStars.all[i - 1].magnitude {
        monotonic = false
    }
    checkTrue("Catalog entries are ordered brightest-first by magnitude", monotonic)
}

// No fact line may exceed 110 characters or contain "!" (product copy-register requirement).
for s in BrightStars.all {
    checkTrue("\(s.name): factLine ≤110 chars (\(s.factLine.count))", s.factLine.count <= 110)
    checkTrue("\(s.name): factLine has no \"!\"", !s.factLine.contains("!"))
}

// Every star must have a non-empty designation and color note (basic data-completeness check).
for s in BrightStars.all {
    checkTrue("\(s.name): designation non-empty", !s.designation.isEmpty)
    checkTrue("\(s.name): colorNote non-empty", !s.colorNote.isEmpty)
    checkTrue("\(s.name): distanceLy > 0", s.distanceLy > 0)
}

// MARK: 2. Position checks vs NAOJ ECO calculator (independent reference)
// Source: https://eco.mtk.nao.ac.jp/cgi-bin/koyomi/cande/horizontal_rhip_en.cgi — inputs were
// each star's own J2000 RA/Dec (as re-keyed by that tool from its internal Hipparcos catalog,
// which matches the Wikipedia-sourced values in BrightStars.swift to within a few arcseconds),
// site Lat 43.9800° Lon −90.5000° Hgt 280.0m, refraction ON. Fetched live 2026-07-20.

print("\n--- Position checks vs NAOJ ECO Altitude/Azimuth calculator (Tomah, WI) ---")

do {
    // Vega, 2026-07-20 04:00 UTC: NAOJ reports Alt 79.6300°, Azi 115.7668°.
    let date = makeUTCDate(2026, 7, 20, 4, 0)
    let pos = BrightStars.horizontalPosition(star: star(named: "Vega"), date: date, latitudeDeg: tomahLat, longitudeDeg: tomahLonEast)
    checkValue("Vega altitude, 2026-07-20 04:00 UTC (NAOJ 79.630°)", expected: 79.630, actual: pos.altitudeDeg, tolerance: 1.5, unit: "°")
    checkAzimuth("Vega azimuth, 2026-07-20 04:00 UTC (NAOJ 115.767°)", expected: 115.7668, actual: pos.azimuthDeg, tolerance: 1.5)
}

do {
    // Sirius, 2026-01-15 07:00 UTC (winter night, Sirius well up): NAOJ reports
    // Alt 24.2472°, Azi 209.1776°.
    let date = makeUTCDate(2026, 1, 15, 7, 0)
    let pos = BrightStars.horizontalPosition(star: star(named: "Sirius"), date: date, latitudeDeg: tomahLat, longitudeDeg: tomahLonEast)
    checkValue("Sirius altitude, 2026-01-15 07:00 UTC (NAOJ 24.247°)", expected: 24.2472, actual: pos.altitudeDeg, tolerance: 1.5, unit: "°")
    checkAzimuth("Sirius azimuth, 2026-01-15 07:00 UTC (NAOJ 209.178°)", expected: 209.1776, actual: pos.azimuthDeg, tolerance: 1.5)
}

do {
    // Sirius, 2026-07-20 04:00 UTC (midsummer — Sirius is deep below the horizon):
    // NAOJ reports Alt −60.2698°, Azi 331.8997°.
    let date = makeUTCDate(2026, 7, 20, 4, 0)
    let pos = BrightStars.horizontalPosition(star: star(named: "Sirius"), date: date, latitudeDeg: tomahLat, longitudeDeg: tomahLonEast)
    checkValue("Sirius altitude, 2026-07-20 04:00 UTC (NAOJ -60.270°, below horizon)", expected: -60.2698, actual: pos.altitudeDeg, tolerance: 1.5, unit: "°")
}

do {
    // Polaris, 2026-01-15 07:00 UTC: NAOJ reports Alt 44.0736°, Azi 359.1430°.
    let date = makeUTCDate(2026, 1, 15, 7, 0)
    let pos = BrightStars.horizontalPosition(star: star(named: "Polaris"), date: date, latitudeDeg: tomahLat, longitudeDeg: tomahLonEast)
    checkValue("Polaris altitude, 2026-01-15 07:00 UTC (NAOJ 44.074°)", expected: 44.0736, actual: pos.altitudeDeg, tolerance: 1.5, unit: "°")
    checkAzimuth("Polaris azimuth, 2026-01-15 07:00 UTC (NAOJ 359.143°, essentially due N)", expected: 359.1430, actual: pos.azimuthDeg, tolerance: 1.5)
}

// MARK: 3. The classic Polaris-altitude-≈-latitude check
// Because Polaris sits only ~0.74° from the north celestial pole, its altitude as seen from
// any northern-hemisphere site stays within about that same ~0.74° of the site's latitude, at
// literally any date or time (no diurnal or seasonal swing worth mentioning at this engine's
// accuracy target) — the textbook "find your latitude from Polaris's altitude" trick. Sampled
// across four very different dates/times below; every one should land within ±1° of
// Tomah's 43.98° latitude.

print("\n--- Polaris altitude ≈ observer latitude (Tomah, 43.98°N) ---")

do {
    let polaris = star(named: "Polaris")
    let samples: [(String, Date)] = [
        ("2026-01-15 07:00 UTC (winter, pre-dawn)", makeUTCDate(2026, 1, 15, 7, 0)),
        ("2026-07-20 04:00 UTC (summer, before dawn)", makeUTCDate(2026, 7, 20, 4, 0)),
        ("2026-04-01 12:00 UTC (spring, midday)", makeUTCDate(2026, 4, 1, 12, 0)),
        ("2026-10-10 20:00 UTC (autumn, evening)", makeUTCDate(2026, 10, 10, 20, 0)),
    ]
    for (label, date) in samples {
        let pos = BrightStars.horizontalPosition(star: polaris, date: date, latitudeDeg: tomahLat, longitudeDeg: tomahLonEast)
        checkValue("Polaris altitude ≈ latitude, \(label)", expected: tomahLat, actual: pos.altitudeDeg, tolerance: 1.0, unit: "°")
    }
}

// MARK: 4. Southern stars never rise from Tomah
// A star is permanently below the horizon at latitude φ (northern hemisphere) whenever its
// declination is more negative than −(90° − φ) — i.e. its highest possible altitude, at upper
// transit, is still negative: maxAltitude = 90° − |φ − dec| for a southern object never clears
// 0° once dec < −(90 − φ). For Tomah (φ = 43.98°), that threshold is dec < −46.02°. Both
// Canopus (dec −52.70°) and Acrux (dec −63.10°) are well past it, so they must show altitude
// < 0 at every sampled time — checked across four times spanning a full day/season range.

print("\n--- Southern stars (Canopus, Acrux) always below horizon from Tomah ---")

do {
    let samples: [(String, Date)] = [
        ("2026-01-15 06:00 UTC", makeUTCDate(2026, 1, 15, 6, 0)),
        ("2026-04-01 12:00 UTC", makeUTCDate(2026, 4, 1, 12, 0)),
        ("2026-07-20 18:00 UTC", makeUTCDate(2026, 7, 20, 18, 0)),
        ("2026-10-10 00:00 UTC", makeUTCDate(2026, 10, 10, 0, 0)),
    ]
    for starName in ["Canopus", "Acrux"] {
        let s = star(named: starName)
        for (label, date) in samples {
            let pos = BrightStars.horizontalPosition(star: s, date: date, latitudeDeg: tomahLat, longitudeDeg: tomahLonEast)
            checkTrue("\(starName) below horizon at \(label) (alt \(fmt(pos.altitudeDeg))°)", pos.altitudeDeg < 0)
        }
    }
}

// MARK: 5. visibleStars / brightestUp behavior

print("\n--- visibleStars / brightestUp ---")

do {
    // A winter night (2026-01-15 07:00 UTC) when several bright northern-hemisphere stars
    // (Sirius, Capella, Procyon, Betelgeuse, Aldebaran...) are up, and the deep-southern ones
    // (Canopus, Acrux) are not.
    let date = makeUTCDate(2026, 1, 15, 7, 0)
    let visible = BrightStars.visibleStars(date: date, lat: tomahLat, lon: tomahLonEast, minAltitude: 10)

    checkTrue("visibleStars returns a non-empty list on a clear winter night", !visible.isEmpty)

    checkTrue("visibleStars: every result altitude ≥ minAltitude (10°)", visible.allSatisfy { $0.altitudeDeg >= 10 })

    var sortedByMagnitude = true
    for i in 1..<max(visible.count, 1) where i < visible.count && visible[i].star.magnitude < visible[i - 1].star.magnitude {
        sortedByMagnitude = false
    }
    checkTrue("visibleStars: sorted brightest-first by magnitude", sortedByMagnitude)

    checkTrue("visibleStars: excludes Canopus (always below horizon from Tomah)", !visible.contains { $0.star.name == "Canopus" })
    checkTrue("visibleStars: excludes Acrux (always below horizon from Tomah)", !visible.contains { $0.star.name == "Acrux" })

    // Every star this function returns should independently satisfy minAltitude when recomputed
    // directly, as a cross-check that filtering didn't leak a stale/incorrect altitude through.
    let allAboveThreshold = visible.allSatisfy { entry in
        let recomputed = BrightStars.horizontalPosition(star: entry.star, date: date, latitudeDeg: tomahLat, longitudeDeg: tomahLonEast)
        return recomputed.altitudeDeg >= 10
    }
    checkTrue("visibleStars: recomputed altitude confirms each entry respects minAltitude", allAboveThreshold)

    // A stricter minAltitude should never return more stars than a looser one.
    let visibleStrict = BrightStars.visibleStars(date: date, lat: tomahLat, lon: tomahLonEast, minAltitude: 40)
    checkTrue("visibleStars: stricter minAltitude (40°) returns no more stars than 10°", visibleStrict.count <= visible.count)
    checkTrue("visibleStars: stricter minAltitude (40°) results all ≥ 40°", visibleStrict.allSatisfy { $0.altitudeDeg >= 40 })

    let top3 = BrightStars.brightestUp(date: date, lat: tomahLat, lon: tomahLonEast, count: 3, minAltitude: 10)
    checkTrue("brightestUp(count: 3) returns at most 3 stars", top3.count <= 3)
    checkTrue("brightestUp(count: 3) matches the head of visibleStars", Array(top3.map { $0.star.name }) == Array(visible.prefix(3).map { $0.star.name }))

    let top100 = BrightStars.brightestUp(date: date, lat: tomahLat, lon: tomahLonEast, count: 100, minAltitude: 10)
    checkTrue("brightestUp(count: 100) never exceeds the full visible list", top100.count == visible.count)
}

// MARK: - Summary

print("\n================================================================")
print(" Summary: \(passedChecks)/\(totalChecks) checks passed")
print("================================================================")

if passedChecks == totalChecks {
    print(" ALL CHECKS PASSED")
} else {
    print(" \(totalChecks - passedChecks) CHECK(S) FAILED — see FAIL lines above")
}
