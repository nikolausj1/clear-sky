import ActivityKit
import Foundation

/// ISS Pass Live Activity work package: the ActivityKit contract shared between the app (which
/// starts/ends the activity via `ISSActivityManager`) and `ZenithWidgets` (which renders it via
/// `ISSPassLiveActivity`) — compiled into BOTH targets, same rationale `WidgetSnapshot.swift`
/// documents: a plain value type with no engine dependency, so it's safe to share without
/// dragging `SkyTonightService`'s full engine stack into the extension.
///
/// **Design principle (lead-locked): ZERO-update activity.** Every clock-driven element the
/// widget draws — the "rises in" countdown, the pass-progress bar — renders via ActivityKit's own
/// native timer views (`Text(timerInterval:)`, `ProgressView(timerInterval:)`), which run
/// entirely system-side for the activity's whole lifecycle once started. That is exactly why
/// `ContentState` below carries no time-varying field at all: this activity is started once, with
/// every fact about the pass baked into `ISSActivityAttributes` at that moment, and never needs a
/// mid-lifecycle push or local update to keep its countdown/progress display correct.
struct ISSActivityAttributes: ActivityAttributes {
    /// Deliberately empty — every ActivityAttributes conformance needs a `ContentState` type, but
    /// this activity has nothing that changes turn over the pass's lifetime (see type doc
    /// comment above). `Hashable` (in addition to the `Codable` the protocol requires) costs
    /// nothing here and matches `Equatable`/`Hashable`-friendly conventions used elsewhere in this
    /// file's sibling shared types.
    struct ContentState: Codable, Hashable {}

    /// When the pass rises above the visibility floor (10°) — the moment `ISSPass.startTime`
    /// marks. The "before" phase's countdown counts down to this.
    var startTime: Date
    /// When the pass drops back below the visibility floor — `ISSPass.endTime`. The "during"
    /// phase's progress bar spans `startTime...endTime`.
    var endTime: Date
    /// `ISSPass.peakAltitudeDeg` — how high overhead the station gets at its highest point.
    var peakAltitudeDeg: Double
    /// Compass direction the pass rises from — `ISSPass.startAzimuthCompass`.
    var startDirection: String
    /// Compass direction the pass sets toward — `ISSPass.endAzimuthCompass`.
    var endDirection: String
    /// Plain-language brightness note derived from `ISSPass.brightness` (see
    /// `ISSActivityManager.brightnessNote(_:)`) — baked into text once at start time rather than
    /// carrying the raw `ISSBrightness` enum, since that engine type isn't compiled into the
    /// widget extension target.
    var brightnessNote: String
}
