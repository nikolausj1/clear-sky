import SwiftUI

/// Space-first design batch, item 4: a recognizable miniature ISS — a central body module, a
/// thin horizontal truss line, and two solar-panel pairs (four small rectangles perpendicular to
/// the truss ends). Replaces the previous `ISSTrajectoryGlyph` (a shallow arc + dot, which read
/// as "a moving object overhead" but not specifically as the space station) everywhere the app
/// names the ISS with an icon: the night panel's ISS row, the hourly Events-chip ISS icon, and
/// the Space-station row (people-in-space) leading icon — the two rows the "SPACE STATION"
/// section header now groups together.
///
/// `ISSGlyphShape.path(in:)` is the single source of the geometry, expressed purely in terms of
/// the rect it's given (no hard-coded point sizes) so it's reusable two ways: as this `View`
/// (a plain `Shape`, so `.foregroundStyle`/`.foregroundColor` tint it exactly like any other SF
/// Symbol-style glyph — "stroke/fill white, caller tints") sized via `size`, and directly inside
/// `NightSkyTimelineStrip`'s single Gantt `Canvas` (`context.fill(ISSGlyphShape.path(in: rect),
/// with: .color(...))`) for the ISS lane's pass ticks, without instantiating a second SwiftUI
/// view per tick or bridging through `Canvas`'s symbol-resolution API.
struct ISSGlyph: View {
    /// ~22×12 nominal (per spec), scalable — callers needing a different size pass their own.
    static let nominalSize = CGSize(width: 22, height: 12)

    var size: CGSize = ISSGlyph.nominalSize

    var body: some View {
        ISSGlyphShape()
            .frame(width: size.width, height: size.height)
    }
}

/// The plain `Shape` a caller can also fill/stroke directly (e.g. `ISSGlyphShape().stroke(...)`)
/// or measure via `ISSGlyphShape.path(in:)` without going through the `View` wrapper above.
struct ISSGlyphShape: Shape {
    func path(in rect: CGRect) -> Path {
        Self.path(in: rect)
    }

    /// All geometry as fractions of `rect`, so this reads correctly at any size — the Gantt lane
    /// tick (~14×8) and the default 22×12 `ISSGlyph` are the same drawing, just scaled.
    static func path(in rect: CGRect) -> Path {
        var path = Path()
        let w = rect.width
        let h = rect.height
        let midY = rect.midY

        // Truss: a thin horizontal bar spanning most of the width — filled (not just stroked)
        // so it reads at small sizes without a separate line-width tuning pass.
        let trussHeight = max(1, h * 0.14)
        path.addRect(CGRect(
            x: rect.minX + w * 0.06, y: midY - trussHeight / 2,
            width: w * 0.88, height: trussHeight
        ))

        // Central body module: a small rounded rect straddling the truss's midpoint.
        let bodyWidth = w * 0.22
        let bodyHeight = h * 0.55
        let bodyRect = CGRect(
            x: rect.minX + (w - bodyWidth) / 2, y: midY - bodyHeight / 2,
            width: bodyWidth, height: bodyHeight
        )
        path.addRoundedRect(in: bodyRect, cornerSize: CGSize(width: bodyWidth * 0.25, height: bodyHeight * 0.25))

        // Two solar-panel pairs, perpendicular to the truss, one pair near each end.
        let panelWidth = max(1, w * 0.06)
        let panelHeight = h * 0.9
        let panelGap = panelWidth * 1.6
        let leftInnerX = rect.minX + w * 0.14
        let rightInnerX = rect.minX + w * 0.86 - panelWidth
        for x in [leftInnerX - panelGap, leftInnerX] {
            path.addRect(CGRect(x: x, y: midY - panelHeight / 2, width: panelWidth, height: panelHeight))
        }
        for x in [rightInnerX, rightInnerX + panelGap] {
            path.addRect(CGRect(x: x, y: midY - panelHeight / 2, width: panelWidth, height: panelHeight))
        }

        return path
    }
}

#Preview("ISS glyph") {
    VStack(spacing: 20) {
        ISSGlyph()
            .foregroundStyle(.white)
        ISSGlyph(size: CGSize(width: 44, height: 24))
            .foregroundStyle(.white)
        ISSGlyph(size: CGSize(width: 88, height: 48))
            .foregroundStyle(.white)
    }
    .padding(40)
    .background(Color.black)
}
