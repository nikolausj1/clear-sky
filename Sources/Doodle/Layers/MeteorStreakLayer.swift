import SwiftUI

/// Header space-event layer: brief meteor streaks on nights an actual shower is active — one of
/// the three "space-event" additions to the doodle hero (siblings: `TrueSkyLayer`'s conjunction-
/// scene addition, `LaunchContrailLayer`). Night/dusk + `.clear` sky only (a shower's streaks
/// need a genuinely dark, unobstructed sky — this composer's `ConditionCategory` doesn't
/// distinguish "partly cloudy" from "overcast" within its single `.cloudy` bucket, so gating on
/// `.clear` alone is the simplest correct rule rather than guessing which `.cloudy` nights are
/// clear enough).
///
/// **Cadence, not a redraw loop:** a single `TimelineView(.periodic(from:by:))` ticks once every
/// `period` seconds (~6s on a peak, dark, high-rate night down to ~15s on a modest one — scaled
/// from `MeteorShowers.MeteorOutlook.estimatedVisiblePerHour`), matching the
/// `TrueSkyLayer`/`WeatherConditionLayer` house style of "one cheap timer/animation per element,
/// never a per-frame body re-evaluation." Each tick mounts a fresh `MeteorStreak` (keyed by the
/// tick's own cycle index via `.id`), which re-triggers its own onAppear draw-then-fade animation
/// — the same "onAppear-triggered `withAnimation`, no internal `Date()` polling" idiom
/// `TrueSkyLayer.ISSStreak` already uses.
///
/// **Determinism:** each streak's screen position/angle/length is derived from a seed combining
/// the tick's real-world calendar minute with its cycle index within that minute — a
/// pseudo-random *function* of (minute, cycle), not `Int.random`, so a screenshot taken during a
/// given run reflects a stable, reproducible position for that minute rather than a fresh coin
/// flip on every SwiftUI re-render (see `MeteorStreak.seed`/`pseudoFraction` below). Two
/// screenshots several seconds apart still show a different streak, since the cycle index (and
/// often the minute) has moved on — precisely the "screenshot, then 5s later, streak moved" check
/// this work package's sim-verify plan asks for.
struct MeteorStreakLayer: View {
    let timeOfDay: DoodleComposer.TimeOfDay
    let condition: DoodleComposer.ConditionCategory
    let outlook: MeteorShowers.MeteorOutlook?
    /// `-forceMeteorStreaks` — bypasses the "is a shower actually active" gate below (still
    /// respects night/dusk + `.clear`, per work order: the flag forces the shower data, not the
    /// time-of-day/condition scene itself) using `DoodleComposer`'s already-forced synthetic
    /// outlook (see `DoodleComposer.resolve`'s `forceMeteorStreaks` parameter) — this layer only
    /// needs to know the resulting `outlook` is non-nil, same as the real path.
    var forced: Bool = false

    private var isEligible: Bool {
        guard timeOfDay == .night || timeOfDay == .dusk else { return false }
        guard condition == .clear else { return false }
        return outlook != nil
    }

    /// Seconds between streaks. `MeteorShowers.MeteorOutlook.estimatedVisiblePerHour` ranges
    /// roughly 5 (a modest, moon-washed-out shower) to 80+ (a peak, dark-sky major shower) in
    /// practice; linearly mapped (clamped) to a 15s floor down to a 6s ceiling per work-order
    /// spec ("peak+dark night = every ~6s, modest = ~15s").
    private var period: Double {
        guard let rate = outlook?.estimatedVisiblePerHour else { return 15 }
        let clamped = min(max(rate, 5), 80)
        let t = (clamped - 5) / (80 - 5)
        return 15 - t * (15 - 6)
    }

    var body: some View {
        if isEligible {
            TimelineView(.periodic(from: Self.epoch, by: period)) { context in
                GeometryReader { proxy in
                    MeteorStreak(seed: Self.seed(for: context.date, period: period))
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .id(Self.cycleIndex(for: context.date, period: period))
                }
            }
            .allowsHitTesting(false)
        }
    }

    private static let epoch = Date(timeIntervalSince1970: 0)

    private static func cycleIndex(for date: Date, period: Double) -> Int {
        Int(date.timeIntervalSince1970 / period)
    }

    /// Combines the tick's real calendar minute (per work-order spec: "seed from date + minute")
    /// with its cycle index within that minute, so consecutive streaks in the same minute still
    /// land at different, but repeatable, positions.
    private static func seed(for date: Date, period: Double) -> UInt64 {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let comps = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        let minuteStamp = Int64(comps.year ?? 0) * 100_000_000
            + Int64(comps.month ?? 0) * 1_000_000
            + Int64(comps.day ?? 0) * 10_000
            + Int64(comps.hour ?? 0) * 100
            + Int64(comps.minute ?? 0)
        let cycle = Int64(cycleIndex(for: date, period: period))
        return UInt64(bitPattern: minuteStamp &* 2_654_435_761 &+ cycle)
    }
}

/// One meteor: a thin (1pt), ~30pt-long, diagonal streak that draws in and fades — sized/angled/
/// positioned deterministically from `seed` (see `pseudoFraction` below), and re-triggers its own
/// draw-then-fade `withAnimation` sequence every time SwiftUI mounts a fresh instance (driven by
/// `MeteorStreakLayer`'s per-tick `.id`).
private struct MeteorStreak: View {
    let seed: UInt64

    @State private var opacity: Double = 0
    @State private var drawFraction: CGFloat = 0

    /// Upper-sky band: below `TrueSkyLayer.topInsetFraction`'s chrome-avoidance ceiling, well
    /// above the illustrated hill line — meteors are a high-sky phenomenon, and streaking through
    /// the horizon band would visually collide with the landscape art.
    private var xFraction: CGFloat { 0.12 + CGFloat(Self.pseudoFraction(seed, salt: 1)) * 0.76 }
    private var yFraction: CGFloat { 0.16 + CGFloat(Self.pseudoFraction(seed, salt: 2)) * 0.22 }
    /// Falling diagonally left-to-right or right-to-left, both realistic — picked per streak.
    private var angleDegrees: Double { Self.pseudoFraction(seed, salt: 3) > 0.5 ? 145 : 125 }
    /// ~30pt per work order, ±20% for a little visual variety.
    private var length: CGFloat { 24 + CGFloat(Self.pseudoFraction(seed, salt: 4)) * 12 }

    var body: some View {
        GeometryReader { proxy in
            LinearGradient(colors: [.white.opacity(0), .white.opacity(0.9)], startPoint: .leading, endPoint: .trailing)
                .frame(width: length * drawFraction, height: 1)
                .rotationEffect(.degrees(angleDegrees), anchor: .leading)
                .position(x: proxy.size.width * xFraction, y: proxy.size.height * yFraction)
                .opacity(opacity)
        }
        .onAppear {
            withAnimation(.easeOut(duration: 0.18)) {
                opacity = 0.9
                drawFraction = 1
            }
            withAnimation(.easeIn(duration: 0.4).delay(0.18)) {
                opacity = 0
            }
        }
    }

    /// splitmix64's finalizer mix — a small, dependency-free deterministic "hash to [0, 1)"
    /// function. Not cryptographic, not needed to be; just a repeatable stand-in for
    /// `Double.random(in:)` so the same (seed, salt) pair always produces the same fraction.
    private static func pseudoFraction(_ seed: UInt64, salt: UInt64) -> Double {
        var x = seed &+ salt &* 0x9E37_79B9_7F4A_7C15
        x ^= x >> 30; x = x &* 0xBF58_476D_1CE4_E5B9
        x ^= x >> 27; x = x &* 0x94D0_49BB_1331_11EB
        x ^= x >> 31
        return Double(x % 1_000_000) / 1_000_000.0
    }
}
