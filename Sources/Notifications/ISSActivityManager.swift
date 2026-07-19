import ActivityKit
import Foundation

/// ISS Pass Live Activity work package: starts/ends the single `ISSActivityAttributes` Live
/// Activity from real pass data. Companion to `SkyNotificationScheduler` — same "first saved
/// location, foreground + post-fetch triggers" hook shape (see `NavigationShell.handleForeground`/
/// `.handleSkyStateResolved`) — but a fully separate permission model: Live Activities need
/// `ActivityAuthorizationInfo().areActivitiesEnabled`, not `UNUserNotificationCenter`
/// authorization, so this type never touches `SkyNotificationScheduler`'s notification-permission
/// path, and vice versa.
///
/// **Design principle (lead-locked): ZERO-update activity.** Every clock-driven element the
/// widget draws is a native ActivityKit timer view — see `ISSPassLiveActivity`'s and
/// `ISSActivityAttributes`'s doc comments. This manager's job is narrow: decide WHEN to start one
/// activity (with its start/end/direction/brightness data baked in once, at start time) and when
/// to end it. It never pushes a `ContentState` update mid-lifecycle because `ContentState` carries
/// nothing that ever changes.
///
/// **Start gate** (`refresh(location:)`): an activity starts only when ALL of:
/// - the "ISS pass Live Activity" Settings toggle is ON (`issLiveActivityEnabledKey`, default OFF)
/// - `ActivityAuthorizationInfo().areActivitiesEnabled` is true
/// - the first saved location's next visible ISS pass starts within 45 minutes from now
/// - no activity is already running (this app never shows more than one at a time)
///
/// **Staleness / single-activity invariant**: an activity's `staleDate` is `pass.endTime + 5 min`.
/// Every call to `refresh` first ends any activity whose pass has already gone stale (one left
/// over from a previous foreground whose pass has since finished) via `endStaleActivities()`,
/// before considering whether to start a new one.
@MainActor
enum ISSActivityManager {
    /// `SettingsView`'s toggle persists to this exact key via `@AppStorage` — the same
    /// one-source-of-truth pattern `SkyNotificationScheduler.issEnabledKey`/`.auroraEnabledKey`
    /// already establish.
    static let issLiveActivityEnabledKey = "clearSky.notifications.issLiveActivityEnabled"

    /// A pass must start within this long from `now` to be worth an activity at all — "around
    /// visible passes," not hours in advance where a countdown would just sit idle and stale.
    private static let startWithinInterval: TimeInterval = 45 * 60
    /// How long past `endTime` the activity stays visible/valid before the system may hide it as
    /// stale — long enough to see the pass through its very last moments without lingering.
    private static let staleBuffer: TimeInterval = 5 * 60

    // MARK: - Settings entry points (toggle ON/OFF)

    /// Called from `SettingsView` the instant the toggle flips ON. Mirrors
    /// `SkyNotificationScheduler.enableISS`'s shape exactly: returns `false` if Live Activities
    /// aren't enabled system-wide, so the caller can flip its own toggle back off and show the
    /// denial explanation. On success, immediately evaluates `refresh` against `location` so a
    /// pass already inside the 45-minute window starts right away rather than waiting for the
    /// next foreground.
    @discardableResult
    static func enable(location: SavedLocation?) async -> Bool {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return false }
        if let location {
            await refresh(location: location)
        }
        return true
    }

    /// Called from `SettingsView` the instant the toggle flips OFF. Ends every currently-running
    /// activity immediately (not just stale ones) — turning the feature off should tear down the
    /// Lock Screen/Dynamic Island presentation right away, not leave it running until its own
    /// `staleDate`.
    static func disable() async {
        for activity in Activity<ISSActivityAttributes>.activities {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }

    // MARK: - Foreground + post-fetch refresh

    /// Called from the same two triggers `SkyNotificationScheduler.refreshISS` uses: app
    /// foreground and `TonightSkyCard.load()`'s post-fetch hook, both already filtered by
    /// `NavigationShell` down to the first saved location. Always ends stale activities first
    /// (regardless of the toggle's current state — a leftover activity from a pass that already
    /// ended should never linger). If the toggle is off, stops there. If the toggle is on but
    /// system authorization has since been revoked, flips the toggle back off itself (mirrors
    /// `SkyNotificationScheduler.refreshISS`'s same self-correcting behavior for a revoked
    /// notification permission) so the Settings UI doesn't keep claiming a permission it no
    /// longer has.
    static func refresh(location: SavedLocation) async {
        await endStaleActivities()

        guard UserDefaults.standard.bool(forKey: issLiveActivityEnabledKey) else { return }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            UserDefaults.standard.set(false, forKey: issLiveActivityEnabledKey)
            return
        }
        guard Activity<ISSActivityAttributes>.activities.isEmpty else { return }

        let now = Date()
        let result = await SkyTonightService.shared.state(
            locationId: location.id, latitude: location.latitude, longitude: location.longitude, date: now
        )
        guard case .available(let passes) = result.iss,
              let nextPass = passes.first(where: { $0.endTime > now })
        else { return }
        guard nextPass.startTime.timeIntervalSince(now) <= startWithinInterval else { return }

        await start(pass: nextPass)
    }

    private static func start(pass: ISSPass) async {
        let attributes = ISSActivityAttributes(
            startTime: pass.startTime,
            endTime: pass.endTime,
            peakAltitudeDeg: pass.peakAltitudeDeg,
            startDirection: pass.startAzimuthCompass,
            endDirection: pass.endAzimuthCompass,
            brightnessNote: brightnessNote(pass.brightness)
        )
        let content = ActivityContent(
            state: ISSActivityAttributes.ContentState(),
            staleDate: pass.endTime.addingTimeInterval(staleBuffer)
        )
        // Best-effort: `request` can throw (e.g. the user has disabled Live Activities for this
        // app specifically, or the system's per-app concurrent-activity budget is exhausted).
        // There's nothing actionable to surface to the user beyond what the Settings toggle
        // already honestly reflects, so this silently no-ops rather than crashing.
        _ = try? Activity<ISSActivityAttributes>.request(attributes: attributes, content: content)
    }

    /// Ends every currently-running activity whose pass has already finished (past its own
    /// `staleDate`, i.e. `endTime + staleBuffer` has already passed) — called at the top of every
    /// `refresh`, per this type's "never more than one active, and never a leftover stale one"
    /// invariant.
    static func endStaleActivities() async {
        let now = Date()
        for activity in Activity<ISSActivityAttributes>.activities {
            if activity.attributes.endTime.addingTimeInterval(staleBuffer) <= now {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
        }
    }

    private static func brightnessNote(_ brightness: ISSBrightness) -> String {
        switch brightness {
        case .bright: return "Bright pass — easy to spot"
        case .moderate: return "Moderate brightness"
        case .dim: return "Dim — a fainter pass"
        }
    }

    // MARK: - Sim-verify

    /// `-forceISSActivity` (see `NavigationShell`'s doc comment): starts a demo activity with a
    /// synthetic pass 2 minutes out, 4-minute duration — bypasses the toggle/authorization/
    /// real-pass gates entirely (sim-verify only; the real `refresh` path above is never
    /// bypassed by this flag). Live Activities DO run on the Simulator, so this activity is real
    /// and screenshot-able, just fed synthetic data instead of a real resolved pass.
    static func startDemoActivity() async {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        for activity in Activity<ISSActivityAttributes>.activities {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
        let now = Date()
        let attributes = ISSActivityAttributes(
            startTime: now.addingTimeInterval(2 * 60),
            endTime: now.addingTimeInterval(2 * 60 + 4 * 60),
            peakAltitudeDeg: 58,
            startDirection: "NW",
            endDirection: "ENE",
            brightnessNote: "Bright pass — easy to spot"
        )
        let content = ActivityContent(
            state: ISSActivityAttributes.ContentState(),
            staleDate: attributes.endTime.addingTimeInterval(staleBuffer)
        )
        _ = try? Activity<ISSActivityAttributes>.request(attributes: attributes, content: content)
    }
}
