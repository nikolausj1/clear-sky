import SwiftUI

/// The dusk-to-dawn timeline strip under `TonightSkyCard`'s headline row (Editor's-Choice
/// sky-surfaces elevation, spec item A.2): a compact horizontal visualization of the whole
/// night — a base track, a moon-above-horizon band, an aurora wash, ISS pass ticks, a "now"
/// cursor, and (below the main track) up to 3 thin planet-visibility-window rows. Everything is
/// direct-labeled (no legend), rendered light-on-dark for the inverted night panel, and thin/
/// recessive per the app's dataviz discipline — the marks are supporting texture, not the point.
///
/// Assumes `window` is a valid, positive-duration interval; `TonightSkyCard` is responsible for
/// not constructing this view at all when tonight's dusk/dawn times are unavailable (polar edge
/// cases) — see `SkyTonightService.duskDawnWindow`'s doc comment.
struct NightSkyTimelineStrip: View {
    struct PlanetBar: Identifiable {
        let body: Planets.Body
        let start: Date
        let end: Date
        var id: Planets.Body { body }
    }

    let window: DateInterval
    let moonRise: Date?
    let moonSet: Date?
    /// Up to 3 bars, brightest-first — selection is `TonightSkyCard`'s job (see
    /// `TonightSkyCard.timelinePlanetBars`), this view just draws whatever it's handed.
    let planetBars: [PlanetBar]
    let issPassTimes: [Date]
    /// Only passed non-`nil` when the band clears `.fair` (spec: "Aurora best window when band
    /// >= .fair") — `TonightSkyCard` decides that, this view just draws the span it's given.
    let auroraWindow: DateInterval?
    let now: Date

    @State private var measuredWidth: CGFloat = 0

    private static let mainAreaHeight: CGFloat = 18
    private static let planetBarHeight: CGFloat = 3
    private static let moonBandHeight: CGFloat = 4

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            timeLabels
            mainTrack(width: measuredWidth)
            if !planetBars.isEmpty {
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(planetBars) { bar in
                        planetRow(bar, width: measuredWidth)
                    }
                }
            }
        }
        // Measures the strip's own content width once (and on any resize, e.g. a Dynamic Type
        // change reflowing the card) via a `background` `GeometryReader` — deliberately not a
        // wrapping `GeometryReader` around `body` itself, which would force an explicit height
        // rather than letting this view size naturally to its content.
        .background(
            GeometryReader { proxy in
                Color.clear
                    .onAppear { measuredWidth = proxy.size.width }
                    .onChange(of: proxy.size.width) { _, newValue in measuredWidth = newValue }
            }
        )
    }

    // MARK: - Dusk/dawn labels

    private var timeLabels: some View {
        HStack {
            Text("Dusk \u{00B7} \(Self.timeFormatter.string(from: window.start))")
            Spacer(minLength: 8)
            Text("Dawn \u{00B7} \(Self.timeFormatter.string(from: window.end))")
        }
        .font(.caption2.monospacedDigit())
        .foregroundStyle(Color.white.opacity(0.5))
    }

    // MARK: - Main track

    @ViewBuilder
    private func mainTrack(width: CGFloat) -> some View {
        ZStack(alignment: .leading) {
            Capsule()
                .fill(Color.white.opacity(0.15))
                .frame(width: width, height: 2)

            if let bar = barMetrics(start: moonRise, end: moonSet, width: width) {
                Capsule()
                    .fill(Color.white.opacity(0.35))
                    .frame(width: bar.width, height: Self.moonBandHeight)
                    .offset(x: bar.x)
            }

            if let aurora = auroraWindow, let bar = barMetrics(start: aurora.start, end: aurora.end, width: width) {
                Capsule()
                    .fill(Color.green.opacity(0.25))
                    .frame(width: bar.width, height: Self.moonBandHeight + 2)
                    .offset(x: bar.x)
            }

            ForEach(Array(issPassTimes.enumerated()), id: \.offset) { _, time in
                issTick(width: width, time: time)
            }

            if window.contains(now) {
                nowCursor(width: width)
            }
        }
        .frame(width: width, height: Self.mainAreaHeight)
    }

    private func issTick(width: CGFloat, time: Date) -> some View {
        let x = fraction(for: time) * width
        return Diamond()
            .fill(Color.white)
            .frame(width: 6, height: 6)
            .shadow(color: .white.opacity(0.85), radius: 4)
            .offset(x: x - 3)
    }

    private func nowCursor(width: CGFloat) -> some View {
        let x = fraction(for: now) * width
        return ZStack {
            Rectangle()
                .fill(Color.clearSkyAccentOnDark)
                .frame(width: 1, height: Self.mainAreaHeight)
            Circle()
                .fill(Color.clearSkyAccentOnDark)
                .frame(width: 5, height: 5)
                .offset(y: -Self.mainAreaHeight / 2 + 2.5)
        }
        .offset(x: x - 2.5)
    }

    // MARK: - Planet rows

    private func planetRow(_ bar: PlanetBar, width: CGFloat) -> some View {
        let metrics = barMetrics(start: bar.start, end: bar.end, width: width)
        let color = TrueSkyLayer.dotColor(for: bar.body)
        // Direct label only where it fits without crowding — an ~46pt-wide bar is roughly the
        // narrowest that can hold a short planet name in `.caption2` without truncating.
        let showsLabel = (metrics?.width ?? 0) > 46

        return VStack(alignment: .leading, spacing: 2) {
            ZStack(alignment: .leading) {
                if let metrics {
                    Capsule()
                        .fill(color)
                        // A faint matching glow — same "give a thin recessive mark just enough
                        // presence to read against the gradient" treatment the planet-row leading
                        // dot already uses — since a bare 3pt capsule in Venus/Saturn's pale-cream
                        // tones was hard to spot against the night panel during sim-verify.
                        .shadow(color: color.opacity(0.7), radius: 2)
                        .frame(width: metrics.width, height: Self.planetBarHeight)
                        .offset(x: metrics.x)
                }
            }
            .frame(width: width, height: Self.planetBarHeight)

            // Always-present placeholder line (opacity-toggled, not conditionally included) so
            // every planet row occupies the same height whether or not its label fits — keeps
            // row spacing/alignment stable regardless of which bars happen to be wide enough.
            Text(bar.body.displayName)
                .font(.caption2)
                .foregroundStyle(color)
                .offset(x: metrics?.x ?? 0)
                .opacity(showsLabel ? 1 : 0)
        }
    }

    // MARK: - Shared geometry helpers

    /// Fractional (0...1) position of `date` within `window`, clamped to the window's bounds.
    private func fraction(for date: Date) -> CGFloat {
        let total = window.duration
        guard total > 0 else { return 0 }
        let clamped = min(max(date.timeIntervalSince(window.start), 0), total)
        return CGFloat(clamped / total)
    }

    /// Leading-x and width (in points) of a `start...end` span clamped to `window`, or `nil` if
    /// the span doesn't overlap `window` at all (e.g. a planet's best-viewing window computed
    /// against a slightly different night boundary than this strip's).
    private func barMetrics(start: Date?, end: Date?, width: CGFloat) -> (x: CGFloat, width: CGFloat)? {
        guard let start, let end, end > start, width > 0 else { return nil }
        let s = fraction(for: start)
        let e = fraction(for: end)
        guard e > s else { return nil }
        return (x: s * width, width: max(2, (e - s) * width))
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        return formatter
    }()
}

/// A small rotated-square tick mark for an ISS pass on the main track — brighter and more
/// eye-catching than the thin track/moon-band capsules around it, per spec ("bright 6pt tick/
/// diamond ... with a subtle glow").
private struct Diamond: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.midY))
        path.closeSubpath()
        return path
    }
}

/// A ~20x14pt mini trajectory glyph — a shallow arc with a dot at its peak — for the ISS row's
/// leading icon in `TonightSkyCard` (distinct from the timeline strip's `Diamond` tick above,
/// which marks a pass's *time*; this glyph is just a quiet "this row is about a moving object
/// overhead" indicator).
struct ISSTrajectoryGlyph: View {
    var body: some View {
        Canvas { context, size in
            var arc = Path()
            let start = CGPoint(x: size.width * 0.05, y: size.height * 0.85)
            let end = CGPoint(x: size.width * 0.95, y: size.height * 0.85)
            let control = CGPoint(x: size.width * 0.5, y: size.height * 0.05)
            arc.move(to: start)
            arc.addQuadCurve(to: end, control: control)
            context.stroke(arc, with: .color(.white.opacity(0.7)), lineWidth: 1.5)

            let peak = CGPoint(x: size.width * 0.5, y: size.height * 0.28)
            let dotRect = CGRect(x: peak.x - 1.5, y: peak.y - 1.5, width: 3, height: 3)
            context.fill(Path(ellipseIn: dotRect), with: .color(.white.opacity(0.9)))
        }
        .frame(width: 20, height: 14)
    }
}
