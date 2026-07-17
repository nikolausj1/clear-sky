import Foundation

// ISS visible-pass predictor smoke test.
//
// Build/run per the Build Guide engine-test recipe:
//   swiftc -O Sources/Sky/ISS/*.swift Tests/ISSSmokeTest.swift -o /tmp/t && /tmp/t
//
// Three sections:
//   1. SGP4 correctness vs. published Vallado/STR#3 verification vectors
//      (tcppver.out), TLEs 00005 and 06251, 13 and 25 epochs respectively.
//   2. Live sanity check: fetch the current ISS TLE from Celestrak,
//      propagate to "now", check altitude/speed are physically plausible.
//   3. Pass-prediction sanity for Tomah, WI (43.98, -90.50).
//
// Every check prints PASS/FAIL; a final summary line reports overall status
// and the process exit code reflects it (0 = all green).

var failureCount = 0
var totalCount = 0

func record(_ ok: Bool, _ label: String) {
    totalCount += 1
    if !ok { failureCount += 1 }
    print("[\(ok ? "PASS" : "FAIL")] \(label)")
}

print("==================================================================")
print(" SECTION 1: SGP4 vs. published Vallado/STR#3 verification vectors")
print("==================================================================")

struct RefVec { let t: Double; let r: Vector3; let v: Vector3 }

func verifySGP4(name: String, line1: String, line2: String, refs: [RefVec]) {
    do {
        let tle = try TLE(line1: line1, line2: line2)
        let prop = try SGP4Propagator(tle: tle)
        print("  TLE \(name): period = \(String(format: "%.3f", prop.periodMinutes)) min (near-Earth)")
        for ref in refs {
            let state = try prop.propagate(minutesSinceEpoch: ref.t)
            let dr = (state.position - ref.r).magnitude
            let dv = (state.velocity - ref.v).magnitude
            let ok = dr < 1.0 // km tolerance per work package spec
            record(ok, "SGP4 \(name) t=\(ref.t) min: dR=\(String(format: "%.6f", dr)) km, dV=\(String(format: "%.6f", dv)) km/s (tolerance 1 km)")
        }
    } catch {
        record(false, "SGP4 \(name): threw unexpected error \(error)")
    }
}

let refs00005: [RefVec] = [
    RefVec(t: 0.0, r: Vector3(7022.46529266, -1400.08296755, 0.03995155), v: Vector3(1.893841015, 6.405893759, 4.534807250)),
    RefVec(t: 360.0, r: Vector3(-7154.03120202, -3783.17682504, -3536.19412294), v: Vector3(4.741887409, -4.151817765, -2.093935425)),
    RefVec(t: 720.0, r: Vector3(-7134.59340119, 6531.68641334, 3260.27186483), v: Vector3(-4.113793027, -2.911922039, -2.557327851)),
    RefVec(t: 1080.0, r: Vector3(5568.53901181, 4492.06992591, 3863.87641983), v: Vector3(-4.209106476, 5.159719888, 2.744852980)),
    RefVec(t: 1440.0, r: Vector3(-938.55923943, -6268.18748831, -4294.02924751), v: Vector3(7.536105209, -0.427127707, 0.989878080)),
    RefVec(t: 1800.0, r: Vector3(-9680.56121728, 2802.47771354, 124.10688038), v: Vector3(-0.905874102, -4.659467970, -3.227347517)),
    RefVec(t: 2160.0, r: Vector3(190.19796988, 7746.96653614, 5110.00675412), v: Vector3(-6.112325142, 1.527008184, -0.139152358)),
    RefVec(t: 2520.0, r: Vector3(5579.55640116, -3995.61396789, -1518.82108966), v: Vector3(4.767927483, 5.123185301, 4.276837355)),
    RefVec(t: 2880.0, r: Vector3(-8650.73082219, -1914.93811525, -3007.03603443), v: Vector3(3.067165127, -4.828384068, -2.515322836)),
    RefVec(t: 3240.0, r: Vector3(-5429.79204164, 7574.36493792, 3747.39305236), v: Vector3(-4.999442110, -1.800561422, -2.229392830)),
    RefVec(t: 3600.0, r: Vector3(6759.04583722, 2001.58198220, 2783.55192533), v: Vector3(-2.180993947, 6.402085603, 3.644723952)),
    RefVec(t: 3960.0, r: Vector3(-3791.44531559, -5712.95617894, -4533.48630714), v: Vector3(6.668817493, -2.516382327, -0.082384354)),
    RefVec(t: 4320.0, r: Vector3(-9060.47373569, 4658.70952502, 813.68673153), v: Vector3(-2.232832783, -4.110453490, -3.157345433)),
]

verifySGP4(
    name: "00005 (TEME example)",
    line1: "1 00005U 58002B   00179.78495062  .00000023  00000-0  28098-4 0  4753",
    line2: "2 00005  34.2682 348.7242 1859667 331.7664  19.3264 10.82419157413667",
    refs: refs00005
)

let refs06251: [RefVec] = [
    RefVec(t: 0.0, r: Vector3(3988.31022699, 5498.96657235, 0.90055879), v: Vector3(-3.290032738, 2.357652820, 6.496623475)),
    RefVec(t: 120.0, r: Vector3(-3935.69800083, 409.10980837, 5471.33577327), v: Vector3(-3.374784183, -6.635211043, -1.942056221)),
    RefVec(t: 240.0, r: Vector3(-1675.12766915, -5683.30432352, -3286.21510937), v: Vector3(5.282496925, 1.508674259, -5.354872978)),
    RefVec(t: 360.0, r: Vector3(4993.62642836, 2890.54969900, -3600.40145627), v: Vector3(0.347333429, 5.707031557, 5.070699638)),
    RefVec(t: 480.0, r: Vector3(-1115.07959514, 4015.11691491, 5326.99727718), v: Vector3(-5.524279443, -4.765738774, 2.402255961)),
    RefVec(t: 600.0, r: Vector3(-4329.10008198, -5176.70287935, 409.65313857), v: Vector3(2.858408303, -2.933091792, -6.509690397)),
    RefVec(t: 720.0, r: Vector3(3692.60030028, -976.24265255, -5623.36447493), v: Vector3(3.897257243, 6.415554948, 1.429112190)),
    RefVec(t: 840.0, r: Vector3(2301.83510037, 5723.92394553, 2814.61514580), v: Vector3(-5.110924966, -0.764510559, 5.662120145)),
    RefVec(t: 960.0, r: Vector3(-4990.91637950, -2303.42547880, 3920.86335598), v: Vector3(-0.993439372, -5.967458360, -4.759110856)),
    RefVec(t: 1080.0, r: Vector3(642.27769977, -4332.89821901, -5183.31523910), v: Vector3(5.720542579, 4.216573838, -2.846576139)),
    RefVec(t: 1200.0, r: Vector3(4719.78335752, 4798.06938996, -943.58851062), v: Vector3(-2.294860662, 3.492499389, 6.408334723)),
    RefVec(t: 1320.0, r: Vector3(-3299.16993602, 1576.83168320, 5678.67840638), v: Vector3(-4.460347074, -6.202025196, -0.885874586)),
    RefVec(t: 1440.0, r: Vector3(-2777.14682335, -5663.16031708, -2462.54889123), v: Vector3(4.915493146, 0.123328992, -5.896495091)),
    RefVec(t: 1560.0, r: Vector3(4992.31573893, 1716.62356770, -4287.86065581), v: Vector3(1.640717189, 6.071570434, 4.338797931)),
    RefVec(t: 1680.0, r: Vector3(-8.22384755, 4662.21521668, 4905.66411857), v: Vector3(-5.891011274, -3.593173872, 3.365100460)),
    RefVec(t: 1800.0, r: Vector3(-4966.20137963, -4379.59155037, 1349.33347502), v: Vector3(1.763172581, -3.981456387, -6.343279443)),
    RefVec(t: 1920.0, r: Vector3(2954.49390331, -2080.65984650, -5754.75038057), v: Vector3(4.895893306, 5.858184322, 0.375474825)),
    RefVec(t: 2040.0, r: Vector3(3363.28794321, 5559.55841180, 1956.05542266), v: Vector3(-4.587378863, 0.591943403, 6.107838605)),
    RefVec(t: 2160.0, r: Vector3(-4856.66780070, -1107.03450192, 4557.21258241), v: Vector3(-2.304158557, -6.186437070, -3.956549542)),
    RefVec(t: 2280.0, r: Vector3(-497.84480071, -4863.46005312, -4700.81211217), v: Vector3(5.960065407, 2.996683369, -3.767123329)),
    RefVec(t: 2400.0, r: Vector3(5241.61936096, 3910.75960683, -1857.93473952), v: Vector3(-1.124834806, 4.406213160, 6.148161299)),
    RefVec(t: 2520.0, r: Vector3(-2451.38045953, 2610.60463261, 5729.79022069), v: Vector3(-5.366560525, -5.500855666, 0.187958716)),
    RefVec(t: 2640.0, r: Vector3(-3791.87520638, -5378.82851382, -1575.82737930), v: Vector3(4.266273592, -1.199162551, -6.276154080)),
    RefVec(t: 2760.0, r: Vector3(4730.53958356, 524.05006433, -4857.29369725), v: Vector3(2.918056288, 6.135412849, 3.495115636)),
    RefVec(t: 2880.0, r: Vector3(1159.27802897, 5056.60175495, 4353.49418579), v: Vector3(-5.968060341, -2.314790406, 4.230722669)),
]

verifySGP4(
    name: "06251 (DELTA 1 DEB, moderate drag)",
    line1: "1 06251U 62025E   06176.82412014  .00008885  00000-0  12808-3 0  3985",
    line2: "2 06251  58.0579  54.0425 0030035 139.1568 221.1854 15.56387291  6774",
    refs: refs06251
)

// Deep-space detection sanity: a known 12h-resonant Molniya TLE (08195) must
// be cleanly refused, not silently mis-propagated.
do {
    let molniya = try TLE(
        line1: "1 08195U 75081A   06176.33215444  .00000099  00000-0  11873-3 0   813",
        line2: "2 08195  64.1586 279.0717 6877146 264.7651  20.2257  2.00491383225656"
    )
    do {
        _ = try SGP4Propagator(tle: molniya)
        record(false, "Deep-space detection: Molniya TLE 08195 should have been refused as deep-space, but was accepted")
    } catch SGP4Error.deepSpaceUnsupported(let period) {
        record(true, "Deep-space detection: Molniya TLE 08195 correctly refused (period \(String(format: "%.1f", period)) min >= 225 min)")
    }
} catch {
    record(false, "Deep-space detection setup: failed to parse Molniya TLE: \(error)")
}

print("")
print("==================================================================")
print(" SECTION 2: Live sanity check (real ISS TLE from Celestrak)")
print("==================================================================")

let cacheDir = FileManager.default.temporaryDirectory.appendingPathComponent("iss-sgp4-smoketest-cache")
let fetcher = TLEFetcher(cacheDirectory: cacheDir)
let now = Date()

var liveTLE: TLE?
do {
    let result = try fetcher.fetch(now: now)
    liveTLE = result.tle
    print("  Fetched ISS TLE via \(result.source.rawValue)\(result.isDegraded ? " (DEGRADED - stale cache)" : "")")
    print("  \(result.tle.line1)")
    print("  \(result.tle.line2)")
    print("  epoch = \(result.tle.epoch)")
    record(true, "TLEFetcher: successfully obtained a live/cached ISS TLE")
} catch {
    record(false, "TLEFetcher: failed to obtain ISS TLE: \(error)")
}

if let tle = liveTLE {
    do {
        let prop = try SGP4Propagator(tle: tle)
        let tsince = tle.minutesSinceEpoch(at: now)
        let state = try prop.propagate(minutesSinceEpoch: tsince)
        let earthRadiusKm = 6378.135
        let altitudeKm = state.position.magnitude - earthRadiusKm
        let speedKmS = state.velocity.magnitude
        print("  tsince = \(String(format: "%.2f", tsince)) min from epoch")
        print("  altitude = \(String(format: "%.2f", altitudeKm)) km, speed = \(String(format: "%.4f", speedKmS)) km/s")
        record(altitudeKm > 300 && altitudeKm < 500, "Live ISS altitude \(String(format: "%.1f", altitudeKm)) km is in plausible range (300-500 km; nominal ISS is ~370-460 km)")
        record(speedKmS > 7.4 && speedKmS < 7.9, "Live ISS speed \(String(format: "%.4f", speedKmS)) km/s is in plausible range (7.4-7.9 km/s; nominal ~7.66 km/s)")
    } catch {
        record(false, "Live ISS propagation to now: threw \(error)")
    }
}

print("")
print("==================================================================")
print(" SECTION 3: Pass-prediction sanity, Tomah, WI (43.98, -90.50)")
print("==================================================================")

if let tle = liveTLE {
    do {
        let windowStart = now
        let windowEnd = now.addingTimeInterval(48 * 3600)
        let passes = try ISSTonight.passes(tle: tle, windowStart: windowStart, windowEnd: windowEnd,
                                            latitudeDeg: 43.98, longitudeDeg: -90.50)

        print("  Search window: \(windowStart) .. \(windowEnd) (48h from now)")
        print("  Found \(passes.count) visible pass(es).")

        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm:ss"
        df.timeZone = TimeZone(identifier: "America/Chicago")

        for (idx, p) in passes.enumerated() {
            let durationSec = p.endTime.timeIntervalSince(p.startTime)
            print("""
              Pass \(idx + 1): \(df.string(from: p.startTime)) CT start (\(p.startAzimuthCompass)) -> \
            peak \(df.string(from: p.peakTime)) CT alt=\(String(format: "%.1f", p.peakAltitudeDeg))deg range=\(String(format: "%.0f", p.peakRangeKm))km -> \
            end \(df.string(from: p.endTime)) CT (\(p.endAzimuthCompass)); duration=\(String(format: "%.0f", durationSec))s; brightness=\(p.brightness.rawValue)
            """)
            record(durationSec >= 60 && durationSec <= 480, "Pass \(idx + 1) duration \(String(format: "%.0f", durationSec))s is in plausible range (1-8 min)")
            record(p.peakAltitudeDeg > 10 && p.peakAltitudeDeg <= 90, "Pass \(idx + 1) peak altitude \(String(format: "%.1f", p.peakAltitudeDeg))deg is in plausible range (10-90 deg)")
        }
        record(passes.count >= 0 && passes.count <= 6, "Pass count \(passes.count) over 48h is in plausible range (0-6; ISS visible passes cluster 1-5/night when geometry allows, across ~2 nights)")
    } catch {
        record(false, "Pass prediction for Tomah WI: threw \(error)")
    }
} else {
    print("  SKIPPED (no live TLE available)")
}

print("")
print("==================================================================")
print(" SUMMARY: \(totalCount - failureCount)/\(totalCount) checks passed")
print("==================================================================")
if failureCount > 0 {
    print(" OVERALL: FAIL (\(failureCount) failing check(s))")
    exit(1)
} else {
    print(" OVERALL: PASS")
}
