import SwiftUI

/// The dusk-to-dawn timeline strip under `TonightSkyCard`'s headline row — a labeled mini-Gantt:
/// a fixed left label rail, an hour-gridded time axis, one lane per applicable sky object (Moon,
/// up to 3 planets, ISS, Aurora), and a "now" cursor through every lane. Rebuilt from the
/// original unlabeled-bars strip (lead-QC feedback: "fails the glance test — no time reference,
/// no row labels") — every mark here is either direct-labeled (the rail) or has an explicit time
/// reference (the gridlines), so nothing on this strip requires a legend.
///
/// Everything (rail labels, gridlines + their labels, dusk/dawn labels, lane bars, the ISS
/// glyph/diamond ticks, the now-cursor) is drawn in a single `Canvas` from the canvas's own
/// `size` — no measured `@State` width, no `offset`-in-`ZStack` composition. That discipline is
/// carried over unchanged from the previous Canvas rewrite (lead-QC fix: a measure-then-reflow
/// pass could visibly mis-place bars; a Canvas has no second pass to get wrong) and extended to
/// every new element this redesign adds, per the work order ("ALL drawn in the single Canvas —
/// established pattern — no measured-state offsets").
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
    /// `TonightSkyCard.timelinePlanetBars`), this view just draws whatever it's handed, one lane
    /// per bar.
    let planetBars: [PlanetBar]
    let issPassTimes: [Date]
    /// Only passed non-`nil` when the band clears `.fair` (spec: "Aurora best window when band
    /// >= .fair") — `TonightSkyCard` decides that, this view just draws the span it's given, and
    /// only shows an Aurora lane at all when this is non-`nil`.
    let auroraWindow: DateInterval?
    let now: Date
    /// Drives both the dusk/dawn end labels and the hour-gridline math below — the window's own
    /// local time zone. Defaults to `.current`, matching every other clock-time render on this
    /// card (`TonightSkyCard.timeZone`).
    var timeZone: TimeZone = .current

    // MARK: - Layout constants

    private static let railWidth: CGFloat = 64
    private static let headerHeight: CGFloat = 16
    private static let hourLabelHeight: CGFloat = 14
    private static let laneHeight: CGFloat = 16
    private static let moonBandHeight: CGFloat = 8
    private static let planetBarHeight: CGFloat = 6
    private static let auroraBandHeight: CGFloat = 8
    /// Below this on-screen gap between consecutive ISS pass ticks, two `ISSGlyph`s would
    /// visually collide — fall back to the old diamond tick for every pass that night instead
    /// (spec: "use the new ISS glyph small, or diamond if <14pt").
    private static let issGlyphMinSpacing: CGFloat = 14
    private static let issGlyphSize = CGSize(width: 14, height: 8)

    // MARK: - Lanes

    private enum LaneKind {
        case moon
        case planet(PlanetBar)
        case iss
        case aurora(DateInterval)
    }

    private struct Lane {
        var kind: LaneKind
        var label: String
        var color: Color
    }

    /// One lane per applicable row, in spec order: Moon, each visible planet bar (brightest
    /// first — already `TonightSkyCard`'s ordering), ISS (only if there's a pass tonight), Aurora
    /// (only if `auroraWindow` is non-`nil`, i.e. already gated at >= `.fair` by the caller).
    private var lanes: [Lane] {
        var result: [Lane] = [Lane(kind: .moon, label: "Moon", color: .white.opacity(0.8))]
        for bar in planetBars {
            result.append(Lane(kind: .planet(bar), label: bar.body.displayName, color: TrueSkyLayer.dotColor(for: bar.body)))
        }
        if !issPassTimes.isEmpty {
            result.append(Lane(kind: .iss, label: "ISS", color: .white))
        }
        if let auroraWindow {
            result.append(Lane(kind: .aurora(auroraWindow), label: "Aurora", color: .green))
        }
        return result
    }

    var body: some View {
        marksCanvas
    }

    // MARK: - All marks, one deterministic Canvas

    private var marksCanvas: some View {
        let allLanes = lanes
        let laneCount = allLanes.count
        let lanesTop = Self.headerHeight + Self.hourLabelHeight
        let totalHeight = lanesTop + CGFloat(laneCount) * Self.laneHeight

        return Canvas { context, size in
            let axisWidth = max(0, size.width - Self.railWidth)
            guard axisWidth > 0 else { return }

            func fractionX(_ date: Date) -> CGFloat {
                Self.railWidth + fraction(for: date) * axisWidth
            }

            func xSpan(_ start: Date?, _ end: Date?) -> (x: CGFloat, width: CGFloat)? {
                guard let start, let end, end > start else { return nil }
                let s = fraction(for: start)
                let e = fraction(for: end)
                guard e > s else { return nil }
                return (x: Self.railWidth + s * axisWidth, width: max(2, (e - s) * axisWidth))
            }

            func drawLabel(_ text: Text, at point: CGPoint, anchor: UnitPoint, maxWidth: CGFloat = 120) {
                let resolved = context.resolve(text)
                let measured = resolved.measure(in: CGSize(width: maxWidth, height: 20))
                let origin = CGPoint(x: point.x - measured.width * anchor.x, y: point.y - measured.height * anchor.y)
                context.draw(resolved, in: CGRect(origin: origin, size: measured))
            }

            // MARK: Dusk/dawn end labels (row A) — spec: "end labels stay".
            let duskDawnFont = Font.caption2.monospacedDigit()
            drawLabel(
                Text("Dusk \u{00B7} \(Self.timeFormatter.string(from: window.start))").font(duskDawnFont).foregroundStyle(.white.opacity(0.5)),
                at: CGPoint(x: Self.railWidth, y: Self.headerHeight / 2), anchor: UnitPoint(x: 0, y: 0.5)
            )
            drawLabel(
                Text("Dawn \u{00B7} \(Self.timeFormatter.string(from: window.end))").font(duskDawnFont).foregroundStyle(.white.opacity(0.5)),
                at: CGPoint(x: size.width, y: Self.headerHeight / 2), anchor: UnitPoint(x: 1, y: 0.5)
            )

            // MARK: Hour gridlines (row B + through every lane below)
            let hourMarks = Self.evenHourMarks(window: window, timeZone: timeZone)
            let hourFormatter = Self.hourLabelFormatter(timeZone: timeZone)
            for (index, mark) in hourMarks.enumerated() {
                let x = fractionX(mark)
                var line = Path()
                line.move(to: CGPoint(x: x, y: Self.headerHeight))
                line.addLine(to: CGPoint(x: x, y: totalHeight))
                context.stroke(line, with: .color(.white.opacity(0.08)), lineWidth: 1)

                // Labels for every OTHER gridline (space permitting) — see the type-level doc
                // comment for why "every other" is applied to these literal even-hour marks
                // rather than the spec parenthetical's illustrative odd-hour example.
                if index.isMultiple(of: 2) {
                    drawLabel(
                        Text(hourFormatter.string(from: mark)).font(.caption2).foregroundStyle(.white.opacity(0.4)),
                        at: CGPoint(x: x, y: Self.headerHeight + Self.hourLabelHeight / 2), anchor: .center, maxWidth: 60
                    )
                }
            }

            // MARK: Lane rail labels + bars
            for (index, lane) in allLanes.enumerated() {
                let rowTop = lanesTop + CGFloat(index) * Self.laneHeight
                let midY = rowTop + Self.laneHeight / 2

                drawLabel(
                    Text(lane.label).font(.caption2).foregroundStyle(lane.color),
                    at: CGPoint(x: 2, y: midY), anchor: UnitPoint(x: 0, y: 0.5), maxWidth: Self.railWidth - 4
                )

                switch lane.kind {
                case .moon:
                    if let span = xSpan(moonRise, moonSet) {
                        let rect = CGRect(x: span.x, y: midY - Self.moonBandHeight / 2, width: span.width, height: Self.moonBandHeight)
                        context.fill(Path(roundedRect: rect, cornerRadius: Self.moonBandHeight / 2), with: .color(.white.opacity(0.35)))
                    }

                case .planet(let bar):
                    if let span = xSpan(bar.start, bar.end) {
                        let color = TrueSkyLayer.dotColor(for: bar.body)
                        let rect = CGRect(x: span.x, y: midY - Self.planetBarHeight / 2, width: span.width, height: Self.planetBarHeight)
                        var glow = context
                        glow.addFilter(.blur(radius: 2))
                        glow.fill(Path(roundedRect: rect, cornerRadius: Self.planetBarHeight / 2), with: .color(color.opacity(0.6)))
                        context.fill(Path(roundedRect: rect, cornerRadius: Self.planetBarHeight / 2), with: .color(color))
                    }

                case .iss:
                    drawISSTicks(context: context, midY: midY, fractionX: fractionX)

                case .aurora(let window):
                    if let span = xSpan(window.start, window.end) {
                        let rect = CGRect(x: span.x, y: midY - Self.auroraBandHeight / 2, width: span.width, height: Self.auroraBandHeight)
                        context.fill(Path(roundedRect: rect, cornerRadius: Self.auroraBandHeight / 2), with: .color(.green.opacity(0.25)))
                    }
                }
            }

            // MARK: Now cursor — one vertical accent line through every lane, dot at the top.
            if window.contains(now) {
                let x = fractionX(now)
                let cursor = CGRect(x: x - 0.5, y: lanesTop, width: 1, height: totalHeight - lanesTop)
                context.fill(Path(cursor), with: .color(Color.clearSkyAccentOnDark))
                let dot = CGRect(x: x - 2.5, y: lanesTop - 2.5, width: 5, height: 5)
                context.fill(Path(ellipseIn: dot), with: .color(Color.clearSkyAccentOnDark))
            }
        }
        .frame(height: totalHeight)
        .accessibilityHidden(true)
    }

    /// ISS pass ticks for the ISS lane: the new mini `ISSGlyph` when consecutive passes have
    /// enough room not to visually collide, else a diamond tick per pass (same shape the
    /// previous strip used for every pass) — see `issGlyphMinSpacing`'s doc comment.
    private func drawISSTicks(context: GraphicsContext, midY: CGFloat, fractionX: (Date) -> CGFloat) {
        let sortedTimes = issPassTimes.sorted()
        let xs = sortedTimes.map(fractionX)
        let minGap = zip(xs, xs.dropFirst()).map { $1 - $0 }.min() ?? .infinity
        let useGlyph = minGap >= Self.issGlyphMinSpacing

        for x in xs {
            if useGlyph {
                let rect = CGRect(
                    x: x - Self.issGlyphSize.width / 2, y: midY - Self.issGlyphSize.height / 2,
                    width: Self.issGlyphSize.width, height: Self.issGlyphSize.height
                )
                context.fill(ISSGlyphShape.path(in: rect), with: .color(.white))
            } else {
                var diamond = Path()
                diamond.move(to: CGPoint(x: x, y: midY - 4))
                diamond.addLine(to: CGPoint(x: x + 4, y: midY))
                diamond.addLine(to: CGPoint(x: x, y: midY + 4))
                diamond.addLine(to: CGPoint(x: x - 4, y: midY))
                diamond.closeSubpath()
                var glow = context
                glow.addFilter(.blur(radius: 3))
                glow.fill(diamond, with: .color(.white.opacity(0.85)))
                context.fill(diamond, with: .color(.white))
            }
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

    /// Every local clock hour divisible by 2 (e.g. 10 PM, 12 AM, 2 AM, 4 AM) within `window`,
    /// computed in `timeZone` — the Gantt's faint vertical gridlines. Every OTHER mark (by
    /// index) also gets a label; see `marksCanvas`'s use of this array's index parity.
    private static func evenHourMarks(window: DateInterval, timeZone: TimeZone) -> [Date] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        var comps = calendar.dateComponents([.year, .month, .day, .hour], from: window.start)
        var hour = comps.hour ?? 0
        if hour % 2 != 0 { hour += 1 }
        comps.hour = hour
        comps.minute = 0
        comps.second = 0
        guard var current = calendar.date(from: comps) else { return [] }
        if current < window.start {
            current = calendar.date(byAdding: .hour, value: 2, to: current) ?? current
        }

        var marks: [Date] = []
        var safety = 0
        while current <= window.end, safety < 48 {
            marks.append(current)
            guard let next = calendar.date(byAdding: .hour, value: 2, to: current) else { break }
            current = next
            safety += 1
        }
        return marks
    }

    private static func hourLabelFormatter(timeZone: TimeZone) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.dateFormat = "h a"
        formatter.timeZone = timeZone
        return formatter
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        return formatter
    }()
}
