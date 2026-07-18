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

    private static let mainAreaHeight: CGFloat = 18
    private static let planetBarHeight: CGFloat = 3
    private static let moonBandHeight: CGFloat = 4
    private static let planetRowHeight: CGFloat = 18

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            timeLabels
            marksCanvas
        }
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

    // MARK: - All marks, one deterministic Canvas

    /// Every mark (track, moon band, aurora wash, ISS ticks, now cursor, planet bars + their
    /// direct labels) is drawn in a single `Canvas` from the canvas's own `size` — no measured
    /// `@State` width, no `offset`-in-`ZStack` composition. The previous implementation computed
    /// correct per-bar metrics but rendered them through a measure-then-reflow pass whose
    /// settling could visibly mis-place bars (lead-QC defect: bars drawn with each other's
    /// geometry); a Canvas has no second pass to get wrong.
    private var marksCanvas: some View {
        Canvas { context, size in
            let width = size.width
            let trackMidY = Self.mainAreaHeight / 2

            func xSpan(_ start: Date?, _ end: Date?) -> (x: CGFloat, width: CGFloat)? {
                guard let start, let end, end > start, width > 0 else { return nil }
                let s = fraction(for: start)
                let e = fraction(for: end)
                guard e > s else { return nil }
                return (x: s * width, width: max(2, (e - s) * width))
            }

            // Base track
            let track = CGRect(x: 0, y: trackMidY - 1, width: width, height: 2)
            context.fill(Path(roundedRect: track, cornerRadius: 1), with: .color(.white.opacity(0.15)))

            // Moon-above-horizon band
            if let span = xSpan(moonRise, moonSet) {
                let rect = CGRect(x: span.x, y: trackMidY - Self.moonBandHeight / 2,
                                  width: span.width, height: Self.moonBandHeight)
                context.fill(Path(roundedRect: rect, cornerRadius: Self.moonBandHeight / 2),
                             with: .color(.white.opacity(0.35)))
            }

            // Aurora wash
            if let aurora = auroraWindow, let span = xSpan(aurora.start, aurora.end) {
                let h = Self.moonBandHeight + 2
                let rect = CGRect(x: span.x, y: trackMidY - h / 2, width: span.width, height: h)
                context.fill(Path(roundedRect: rect, cornerRadius: h / 2),
                             with: .color(.green.opacity(0.25)))
            }

            // ISS pass ticks (diamond + soft glow)
            for time in issPassTimes {
                let x = fraction(for: time) * width
                var diamond = Path()
                diamond.move(to: CGPoint(x: x, y: trackMidY - 4))
                diamond.addLine(to: CGPoint(x: x + 4, y: trackMidY))
                diamond.addLine(to: CGPoint(x: x, y: trackMidY + 4))
                diamond.addLine(to: CGPoint(x: x - 4, y: trackMidY))
                diamond.closeSubpath()
                var glow = context
                glow.addFilter(.blur(radius: 3))
                glow.fill(diamond, with: .color(.white.opacity(0.85)))
                context.fill(diamond, with: .color(.white))
            }

            // Now cursor
            if window.contains(now) {
                let x = fraction(for: now) * width
                let cursor = CGRect(x: x - 0.5, y: 0, width: 1, height: Self.mainAreaHeight)
                context.fill(Path(cursor), with: .color(Color.clearSkyAccentOnDark))
                let dot = CGRect(x: x - 2.5, y: 0, width: 5, height: 5)
                context.fill(Path(ellipseIn: dot), with: .color(Color.clearSkyAccentOnDark))
            }

            // Planet visibility rows (below the main track), direct labels only where they fit
            for (index, bar) in planetBars.enumerated() {
                guard let span = xSpan(bar.start, bar.end) else { continue }
                let rowTop = Self.mainAreaHeight + 4 + CGFloat(index) * Self.planetRowHeight
                let color = TrueSkyLayer.dotColor(for: bar.body)
                let rect = CGRect(x: span.x, y: rowTop, width: span.width, height: Self.planetBarHeight)
                var glow = context
                glow.addFilter(.blur(radius: 2))
                glow.fill(Path(roundedRect: rect, cornerRadius: Self.planetBarHeight / 2),
                          with: .color(color.opacity(0.7)))
                context.fill(Path(roundedRect: rect, cornerRadius: Self.planetBarHeight / 2),
                             with: .color(color))

                if span.width > 46 {
                    let label = Text(bar.body.displayName).font(.caption2).foregroundStyle(color)
                    let resolved = context.resolve(label)
                    let labelSize = resolved.measure(in: CGSize(width: span.width, height: 14))
                    // Keep the label inside the canvas even for a bar hugging the right edge.
                    let labelX = min(span.x, width - labelSize.width)
                    context.draw(resolved, in: CGRect(x: labelX,
                                                      y: rowTop + Self.planetBarHeight + 2,
                                                      width: labelSize.width,
                                                      height: labelSize.height))
                }
            }
        }
        .frame(height: Self.mainAreaHeight + 4 + CGFloat(planetBars.count) * Self.planetRowHeight)
        .accessibilityHidden(true)
    }

    // MARK: - Shared geometry helpers

    /// Fractional (0...1) position of `date` within `window`, clamped to the window's bounds.
    private func fraction(for date: Date) -> CGFloat {
        let total = window.duration
        guard total > 0 else { return 0 }
        let clamped = min(max(date.timeIntervalSince(window.start), 0), total)
        return CGFloat(clamped / total)
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        return formatter
    }()
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
