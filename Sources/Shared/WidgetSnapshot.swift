import Foundation

/// The entire data handoff between the app and `ZenithWidgets` (widget work package). The app
/// writes one of these to the shared app-group container whenever `SkyTonightService` resolves
/// for the first saved location (see `Sources/Notifications/WidgetSnapshotWriter.swift` — the
/// app-only type that builds and writes it, hooked from the same `NavigationShell` trigger that
/// already refreshes the ISS/aurora notifications). The widget extension only ever READS this
/// file — no network, no astronomy/engine computation on the extension side, per the work
/// order's "keep the extension lean" instruction. Every field here is therefore a plain,
/// pre-computed value, never an engine type (`SkyTonight.MoonInfo`, `ISSPass`, etc.) — those types
/// live in app-only files (`Sources/Sky/...`) that are deliberately NOT compiled into the widget
/// target, so this struct only depends on Foundation.
struct WidgetSnapshot: Codable {
    /// One of tonight's featured objects for the medium widget's Gantt-style rows — a name, a
    /// coarse `kind` (for a future glyph/color choice; unused by v1's plain bar), and the time
    /// window it's worth looking for it in.
    struct ObjectWindow: Codable, Identifiable {
        enum Kind: String, Codable {
            case planet
            case moon
            case iss
        }

        var name: String
        var kind: Kind
        var windowStart: Date
        var windowEnd: Date

        var id: String { name }
    }

    /// When the app last wrote this snapshot — the widget's own placeholder/staleness reasoning
    /// doesn't currently use this (WidgetKit's own timeline entries carry the "as of" date for
    /// display), but it's kept for `v5-snapshot-proof.txt` and any future staleness UI.
    var generatedAt: Date
    /// `TonightHeadline`'s hero line (or this file's own best-effort equivalent — see
    /// `WidgetSnapshotWriter`'s doc comment on why the widget's copy of it is computed with less
    /// context than the Forecast card's), already trimmed to `TonightHeadline.textCharacterBudget`
    /// -ish length so the rectangular/small/medium widgets can lay it out directly.
    var headline: String
    /// 0 (new) ... 1 (full) illuminated fraction, matching `MoonPhaseDisc.illumination`'s own
    /// contract exactly (`SkyTonight.MoonInfo.illuminatedPercent / 100` — **not**
    /// `MoonInfo.phaseFraction`, which is a different 0...1 quarter-cycle convention where 0.5
    /// means full; using that one here would draw the wrong-looking disc).
    var moonIlluminatedFraction: Double
    var moonWaxing: Bool
    /// Up to 3 of tonight's featured objects, soonest-starting first — see
    /// `WidgetSnapshotWriter.topObjects(...)` for the selection rule.
    var topObjects: [ObjectWindow]
    var terrainClass: TerrainClass
    /// Whether tonight cleared `TonightHeadline.Kind.isEvent` (ISS pass / aurora / meteor peak /
    /// conjunction) — reserved for a future "something's happening" widget accent; not yet drawn
    /// on by any of the four v1 widget views, but written now so it doesn't need a second
    /// snapshot-schema bump later.
    var isEventNight: Bool

    // MARK: - App-group storage

    /// Matches the App Groups entitlement on both targets (`ClearSky.entitlements` and
    /// `Widgets/ZenithWidgets.entitlements`) and `project.yml`'s target setup.
    static let appGroupIdentifier = "group.com.levelup.clearsky"
    private static let userDefaultsKey = "clearSky.widgetSnapshot.v1"

    /// Called only from the app (`WidgetSnapshotWriter`). Silently no-ops if the app-group
    /// container isn't reachable (e.g. a simulator/build that hasn't been granted the
    /// entitlement) rather than crashing — the widget just keeps showing its last-known snapshot,
    /// or the placeholder if none was ever written.
    static func write(_ snapshot: WidgetSnapshot) {
        guard let defaults = UserDefaults(suiteName: appGroupIdentifier) else { return }
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        defaults.set(data, forKey: userDefaultsKey)
    }

    /// Called only from the widget extension's `TimelineProvider` (and the app's own
    /// `-widgetPreview` debug screen, which renders the real widget views outside a gallery — see
    /// `Sources/Debug/WidgetPreviewView.swift`). `nil` before the app has ever resolved
    /// `SkyTonightService` once (fresh install, widget added before first launch) — callers fall
    /// back to `.placeholder`.
    static func read() -> WidgetSnapshot? {
        guard let defaults = UserDefaults(suiteName: appGroupIdentifier) else { return nil }
        guard let data = defaults.data(forKey: userDefaultsKey) else { return nil }
        return try? JSONDecoder().decode(WidgetSnapshot.self, from: data)
    }

    /// WidgetKit's own placeholder pass (redacted shimmer) never actually shows this data, but
    /// `getSnapshot`/`getTimeline` also fall back to it when `read()` returns `nil` — plausible,
    /// clearly-labeled sample content is friendlier than a widget that renders empty/dashes on
    /// first install.
    static let placeholder = WidgetSnapshot(
        generatedAt: Date(),
        headline: "Clear skies tonight — good visibility after dusk.",
        moonIlluminatedFraction: 0.5,
        moonWaxing: true,
        topObjects: [
            ObjectWindow(name: "Venus", kind: .planet, windowStart: Date().addingTimeInterval(1 * 3600), windowEnd: Date().addingTimeInterval(2 * 3600)),
            ObjectWindow(name: "Jupiter", kind: .planet, windowStart: Date().addingTimeInterval(2 * 3600), windowEnd: Date().addingTimeInterval(5 * 3600)),
            ObjectWindow(name: "ISS", kind: .iss, windowStart: Date().addingTimeInterval(3 * 3600), windowEnd: Date().addingTimeInterval(3 * 3600 + 300)),
        ],
        terrainClass: .hills,
        isEventNight: false
    )
}
