import SwiftUI

/// Doodle layers 1+2 combined, "Base scene" + "Season skin" (PRD Section 7), now rendered from
/// AI-illustrated landscape art rather than the programmatic `HillsShape`/`TreeShape` geometry
/// those two layers used to draw (see the git history for `BaseSceneLayer.swift` and
/// `SeasonSkinLayer.swift`, both removed when this layer replaced them).
///
/// Each season has one 1536x1024 illustration (`LandscapeSummer`/`LandscapeFall`/
/// `LandscapeWinter`/`LandscapeSpring` in `Assets.xcassets`) painted with a transparent top
/// ~45% and an opaque landscape strip filling the bottom ~55% — the transparent region lets
/// `TimeOfDaySkyBackground` (painted behind this layer) show through as the sky, so the two
/// layers read as one continuous illustration rather than a pasted-in image with a visible
/// seam. Pinning the image to the bottom edge at full width and letting `scaledToFit` derive
/// its height from the 3:2 aspect ratio puts the actual painted strip in roughly the bottom
/// 40% of the hero — matching the footprint the old programmatic hills occupied.
///
/// **Time-of-day tinting.** A flat illustration with a fixed daytime palette would look wrong
/// composited under a night sky — it needs to visually recede the way the real hills would in
/// low light. `.compositingGroup()` flattens the resized image to a single layer so the tint
/// overlay's `.sourceAtop` blend mode only paints over pixels the image actually covers
/// (respecting its alpha shape instead of tinting a rectangle), giving a warm dawn/dusk wash or
/// a cool night dimming without disturbing the transparent sky region above the strip. Winter's
/// night tint is intentionally lighter than the other seasons' (0.45 vs 0.55) so the snow stays
/// readable instead of going muddy under the indigo.
struct IllustratedLandscapeLayer: View {
    let season: DoodleComposer.Season
    let timeOfDay: DoodleComposer.TimeOfDay

    var body: some View {
        GeometryReader { proxy in
            Image(imageName)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: proxy.size.width)
                .compositingGroup()
                .overlay(tintColor.blendMode(.sourceAtop))
                .frame(width: proxy.size.width, height: proxy.size.height, alignment: .bottom)
        }
        .allowsHitTesting(false)
    }

    private var imageName: String {
        switch season {
        case .winter: return "LandscapeWinter"
        case .spring: return "LandscapeSpring"
        case .summer: return "LandscapeSummer"
        case .fall: return "LandscapeFall"
        }
    }

    /// Dark indigo, matching the night sky's own palette (`TimeOfDaySkyBackground.skyColors`)
    /// so the tinted landscape reads as "the same night" rather than a mismatched overlay.
    private static let nightTint = Color(red: 10.0 / 255.0, green: 14.0 / 255.0, blue: 40.0 / 255.0)
    private static let goldenHourTint = Color(red: 0.99, green: 0.62, blue: 0.28)

    private var tintColor: Color {
        switch timeOfDay {
        case .day:
            return .clear
        case .dawn:
            return Self.goldenHourTint.opacity(0.15)
        case .dusk:
            return Self.goldenHourTint.opacity(0.20)
        case .night:
            return Self.nightTint.opacity(season == .winter ? 0.45 : 0.55)
        }
    }
}
