import SwiftUI

/// Display-layer-only vehicle -> silhouette-class mapping for the all-dark Space tab (the "rocket
/// silhouettes" work item). Deliberately NOT added to `Sources/Sky/Launches/LaunchSchedule.swift`
/// — same don't-modify-engine-logic rule that file's own doc comments already establish for
/// display-only concerns (see `SpaceView.LaunchRowView.extraProviderAbbreviations`, which follows
/// the identical pattern): `UpcomingLaunch` has no "vehicle class" of its own, and doesn't need
/// one — this is purely how the Space tab chooses which of the four bundled silhouette assets to
/// draw next to a launch, not a fact about the launch itself.
///
/// **Mapping (best-effort heuristic on vehicle/provider name substrings, documented per work
/// order):**
/// - **Superheavy** — Starship, SLS (Space Launch System).
/// - **Heavy** — Falcon Heavy, Delta IV Heavy, New Glenn, Vulcan.
/// - **Medium** — Falcon 9, Soyuz, Ariane 6, H3, Long March 5/6/7 ("LM-5-7").
/// - **Small** — Electron, and any other small-sat-class name (Long March 2-4, and any vehicle
///   name/provider not otherwise matched — see the `default` case below, which folds "genuinely
///   unrecognized" into medium instead, per the work order's explicit "unknown -> medium" rule).
enum LaunchVehicleClass: String {
    case small
    case medium
    case heavy
    case superheavy

    /// The bundled `Sources/Assets.xcassets` imageset name for this class (single-scale PNGs,
    /// each with a transparent surround and a soft warm glow already baked into their alpha —
    /// see `RocketSilhouette` below for how that's used with `.renderingMode(.template)`).
    var imageName: String {
        switch self {
        case .small: return "RocketSmall"
        case .medium: return "RocketMedium"
        case .heavy: return "RocketHeavy"
        case .superheavy: return "RocketSuperheavy"
        }
    }

    /// Best-effort heuristic on `vehicle`/`provider` name substrings (case-insensitive) — see the
    /// type-level doc comment for the documented mapping table. Order matters: superheavy/heavy
    /// checks run before the medium/small ones so e.g. "Falcon Heavy" doesn't fall through to a
    /// bare "Falcon" -> medium match.
    static func classify(vehicle: String, provider: String) -> LaunchVehicleClass {
        let v = vehicle.lowercased()
        let p = provider.lowercased()

        if v.contains("starship") || v.contains("sls") || v.contains("space launch system") {
            return .superheavy
        }
        if v.contains("falcon heavy") || v.contains("delta iv heavy") || v.contains("new glenn") || v.contains("vulcan") {
            return .heavy
        }
        if v.contains("falcon 9") || v.contains("soyuz") || v.contains("ariane 6") || v.contains("h3")
            || v.contains("long march 5") || v.contains("long march 6") || v.contains("long march 7")
            || v.contains("lm-5") || v.contains("lm-6") || v.contains("lm-7") {
            return .medium
        }
        if v.contains("electron") || p.contains("rocket lab")
            || v.contains("long march 2") || v.contains("long march 3") || v.contains("long march 4") {
            return .small
        }
        // Unknown vehicle/provider: per work order, folds to medium — the most common real-world
        // launch class, and a safer visual default than guessing small or heavy for a name this
        // table has never seen.
        return .medium
    }
}

/// The class silhouette image, tinted per the work order ("white 0.85" for launch rows; the
/// next-launch hero renders its own tint/glow separately — see `SpaceView`). `.renderingMode(
/// .template)` turns the asset's own alpha channel (which already carries a soft glow — see the
/// imageset doc comment above) into a solid-color silhouette with a naturally soft edge, rather
/// than flattening it to a hard-edged shape.
struct RocketSilhouette: View {
    let vehicleClass: LaunchVehicleClass
    var size: CGFloat = 30
    var tint: Color = .white.opacity(0.85)

    var body: some View {
        Image(vehicleClass.imageName)
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            .foregroundStyle(tint)
    }
}
