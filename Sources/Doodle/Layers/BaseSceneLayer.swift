import SwiftUI

/// Doodle layer 1, "Base scene" (PRD Section 7): "fixed silhouette elements ... that don't
/// change; the stable 'stage' the rest is drawn on." Chosen motif: rolling hills (the PRD's
/// suggested CARROT-adjacent direction), simplified to two soft overlapping ridges — flatter
/// and cleaner than CARROT's reference art, per the build brief.
///
/// This view renders only the **back** ridge, in a fixed neutral slate tone that reads
/// reasonably against any sky color. It never varies by season/weather/time-of-day — that's
/// exactly what layers 2-4 add on top. The front ridge (where season foliage actually lives)
/// is `SeasonSkinLayer`'s `HillsShape`-based fill, sharing this file's shape definitions so
/// both ridges are drawn from the same geometry family.
struct BaseSceneLayer: View {
    var body: some View {
        GeometryReader { proxy in
            HillsShape(profile: .back)
                .fill(Color(red: 0.22, green: 0.27, blue: 0.34).opacity(0.55))
                .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .allowsHitTesting(false)
    }
}

/// A soft rolling-hill ridge silhouette. Two `profile`s (back/front) trace slightly different
/// curves so the two ridges read as distinct depth planes rather than one flat shape.
struct HillsShape: Shape {
    enum Profile {
        case back
        case front
    }

    var profile: Profile

    func path(in rect: CGRect) -> Path {
        let w = rect.width
        let h = rect.height
        var path = Path()

        switch profile {
        case .back:
            path.move(to: CGPoint(x: 0, y: h * 0.62))
            path.addCurve(
                to: CGPoint(x: w * 0.48, y: h * 0.50),
                control1: CGPoint(x: w * 0.16, y: h * 0.70),
                control2: CGPoint(x: w * 0.32, y: h * 0.44)
            )
            path.addCurve(
                to: CGPoint(x: w, y: h * 0.60),
                control1: CGPoint(x: w * 0.68, y: h * 0.58),
                control2: CGPoint(x: w * 0.86, y: h * 0.46)
            )
            path.addLine(to: CGPoint(x: w, y: h))
            path.addLine(to: CGPoint(x: 0, y: h))
            path.closeSubpath()
        case .front:
            path.move(to: CGPoint(x: 0, y: h * 0.86))
            path.addCurve(
                to: CGPoint(x: w * 0.30, y: h * 0.74),
                control1: CGPoint(x: w * 0.10, y: h * 0.94),
                control2: CGPoint(x: w * 0.18, y: h * 0.78)
            )
            path.addCurve(
                to: CGPoint(x: w * 0.62, y: h * 0.80),
                control1: CGPoint(x: w * 0.42, y: h * 0.70),
                control2: CGPoint(x: w * 0.52, y: h * 0.88)
            )
            path.addCurve(
                to: CGPoint(x: w, y: h * 0.72),
                control1: CGPoint(x: w * 0.76, y: h * 0.72),
                control2: CGPoint(x: w * 0.90, y: h * 0.64)
            )
            path.addLine(to: CGPoint(x: w, y: h))
            path.addLine(to: CGPoint(x: 0, y: h))
            path.closeSubpath()
        }
        return path
    }
}

/// A simple flat-vector tree silhouette: a trunk plus a round canopy. `canopyScale` of 0 draws
/// a bare trunk with a couple of thin branch strokes only (winter). Fixed, non-random tree
/// placements live in `SeasonSkinLayer` — this shape just draws one tree at a given size.
struct TreeShape {
    /// Trunk + branches only — used underneath any season's canopy accent so winter can omit
    /// the canopy entirely.
    static func trunkPath(in rect: CGRect) -> Path {
        var path = Path()
        let w = rect.width
        let h = rect.height
        path.addRect(CGRect(x: w * 0.44, y: h * 0.45, width: w * 0.12, height: h * 0.55))
        return path
    }

    static func branchPath(in rect: CGRect) -> Path {
        var path = Path()
        let w = rect.width
        let h = rect.height
        let base = CGPoint(x: w * 0.5, y: h * 0.48)
        path.move(to: base)
        path.addLine(to: CGPoint(x: w * 0.22, y: h * 0.22))
        path.move(to: base)
        path.addLine(to: CGPoint(x: w * 0.78, y: h * 0.26))
        path.move(to: CGPoint(x: w * 0.5, y: h * 0.30))
        path.addLine(to: CGPoint(x: w * 0.30, y: h * 0.08))
        path.move(to: CGPoint(x: w * 0.5, y: h * 0.30))
        path.addLine(to: CGPoint(x: w * 0.68, y: h * 0.06))
        return path
    }

    /// A round, layered canopy (three overlapping circles) for spring/summer/fall.
    static func canopyPath(in rect: CGRect) -> Path {
        var path = Path()
        let w = rect.width
        let h = rect.height
        path.addEllipse(in: CGRect(x: w * 0.10, y: h * 0.10, width: w * 0.55, height: h * 0.55))
        path.addEllipse(in: CGRect(x: w * 0.35, y: h * 0.02, width: w * 0.55, height: h * 0.55))
        path.addEllipse(in: CGRect(x: w * 0.22, y: h * 0.28, width: w * 0.60, height: h * 0.55))
        return path
    }
}
