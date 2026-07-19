import SwiftUI

/// The home-screen widgets' (`TonightSmallView`/`TonightMediumView`) mini night scene: the same
/// deep-indigo gradient + static star specks `TonightSkyCard`'s `NightPanelBackground` uses
/// (`Sources/Forecast/TonightSkyCard.swift`), at a much smaller star count since a widget has far
/// less room, plus a flat, dark terrain-class silhouette hint along the bottom edge.
///
/// **Deliberately NOT `IllustratedLandscapeLayer`'s bitmap art.** The work order is explicit about
/// this: bundle-size and render-time discipline for a widget matter more than matching the doodle
/// hero's full illustrated landscape pixel-for-pixel. `HillSilhouette` below is a few dozen bytes
/// of `Path` math, not a 1536x1024 image asset — four of those (one per non-hills terrain class)
/// would meaningfully bloat this extension for a detail most people will glance at for under a
/// second.
struct NightSceneBackground: View {
    var terrainClass: TerrainClass

    /// Far fewer specks than `NightPanelBackground`'s ~14 (spec: "KEEP SIMPLE") — just enough to
    /// read as a starfield at a glance, not a faithful star chart.
    private static let starPositions: [(CGFloat, CGFloat, CGFloat, Double)] = [
        (0.10, 0.14, 1.2, 0.40), (0.28, 0.08, 1.0, 0.30), (0.46, 0.20, 1.2, 0.45),
        (0.66, 0.10, 1.0, 0.35), (0.84, 0.18, 1.2, 0.40), (0.92, 0.32, 1.0, 0.30),
        (0.18, 0.30, 1.0, 0.30),
    ]

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 13.0 / 255.0, green: 17.0 / 255.0, blue: 42.0 / 255.0),
                    Color(red: 24.0 / 255.0, green: 30.0 / 255.0, blue: 66.0 / 255.0),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            GeometryReader { proxy in
                ForEach(Array(Self.starPositions.enumerated()), id: \.offset) { _, star in
                    Circle()
                        .fill(Color.white.opacity(star.3))
                        .frame(width: star.2, height: star.2)
                        .position(x: proxy.size.width * star.0, y: proxy.size.height * star.1)
                }
                HillSilhouette(terrainClass: terrainClass)
                    .fill(Color(red: 6.0 / 255.0, green: 8.0 / 255.0, blue: 20.0 / 255.0))
                    .frame(height: proxy.size.height * 0.32)
                    .frame(maxHeight: .infinity, alignment: .bottom)
            }
        }
    }
}

/// A flat, dark hill-line silhouette hint — one simple `Path` per terrain class, not the doodle
/// hero's illustrated art (see `NightSceneBackground`'s doc comment). Every case fills the same
/// bottom strip; only the curve differs, just enough to read as "hills" vs "mountains" vs "desert"
/// vs "coast" without asking the viewer to squint at a thumbnail-scale illustration.
struct HillSilhouette: Shape {
    var terrainClass: TerrainClass

    func path(in rect: CGRect) -> Path {
        switch terrainClass {
        case .hills:
            return Self.rollingPath(in: rect)
        case .mountains:
            return Self.jaggedPath(in: rect)
        case .desert:
            return Self.dunePath(in: rect)
        case .coast:
            return Self.flatPath(in: rect)
        }
    }

    /// Two gentle rolling bumps.
    private static func rollingPath(in rect: CGRect) -> Path {
        var path = Path()
        let w = rect.width, h = rect.height
        path.move(to: CGPoint(x: 0, y: h * 0.55))
        path.addCurve(
            to: CGPoint(x: w * 0.5, y: h * 0.35),
            control1: CGPoint(x: w * 0.18, y: h * 0.60),
            control2: CGPoint(x: w * 0.32, y: h * 0.30)
        )
        path.addCurve(
            to: CGPoint(x: w, y: h * 0.5),
            control1: CGPoint(x: w * 0.68, y: h * 0.40),
            control2: CGPoint(x: w * 0.85, y: h * 0.62)
        )
        path.addLine(to: CGPoint(x: w, y: h))
        path.addLine(to: CGPoint(x: 0, y: h))
        path.closeSubpath()
        return path
    }

    /// Sharp triangular peaks.
    private static func jaggedPath(in rect: CGRect) -> Path {
        var path = Path()
        let w = rect.width, h = rect.height
        path.move(to: CGPoint(x: 0, y: h * 0.7))
        path.addLine(to: CGPoint(x: w * 0.16, y: h * 0.18))
        path.addLine(to: CGPoint(x: w * 0.32, y: h * 0.5))
        path.addLine(to: CGPoint(x: w * 0.5, y: h * 0.05))
        path.addLine(to: CGPoint(x: w * 0.68, y: h * 0.45))
        path.addLine(to: CGPoint(x: w * 0.84, y: h * 0.22))
        path.addLine(to: CGPoint(x: w, y: h * 0.6))
        path.addLine(to: CGPoint(x: w, y: h))
        path.addLine(to: CGPoint(x: 0, y: h))
        path.closeSubpath()
        return path
    }

    /// One low, wide dune.
    private static func dunePath(in rect: CGRect) -> Path {
        var path = Path()
        let w = rect.width, h = rect.height
        path.move(to: CGPoint(x: 0, y: h * 0.75))
        path.addCurve(
            to: CGPoint(x: w, y: h * 0.65),
            control1: CGPoint(x: w * 0.35, y: h * 0.45),
            control2: CGPoint(x: w * 0.7, y: h * 0.55)
        )
        path.addLine(to: CGPoint(x: w, y: h))
        path.addLine(to: CGPoint(x: 0, y: h))
        path.closeSubpath()
        return path
    }

    /// A near-flat horizon with the faintest wave — the coast reads as "the water line," not a
    /// hill.
    private static func flatPath(in rect: CGRect) -> Path {
        var path = Path()
        let w = rect.width, h = rect.height
        path.move(to: CGPoint(x: 0, y: h * 0.7))
        path.addCurve(
            to: CGPoint(x: w * 0.5, y: h * 0.75),
            control1: CGPoint(x: w * 0.2, y: h * 0.66),
            control2: CGPoint(x: w * 0.35, y: h * 0.78)
        )
        path.addCurve(
            to: CGPoint(x: w, y: h * 0.7),
            control1: CGPoint(x: w * 0.65, y: h * 0.72),
            control2: CGPoint(x: w * 0.8, y: h * 0.66)
        )
        path.addLine(to: CGPoint(x: w, y: h))
        path.addLine(to: CGPoint(x: 0, y: h))
        path.closeSubpath()
        return path
    }
}
