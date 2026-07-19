import Foundation
import UserNotifications

/// PRD Revision Notes (2026-07-18, night-first expansion): exactly TWO opt-in local
/// notifications are sanctioned app-wide, both default-off — "ISS pass in 10 minutes" and
/// "Aurora storm tonight" (G3+ forecasts only). No others, ever; that restraint is itself a
/// stated product feature, not an oversight. This type owns both, end to end: authorization,
/// scheduling, dedupe, and removal.
///
/// **Authorization is contextual only** — mirrors `CurrentLocationManager`'s own documented
/// pattern (permission requested only from an explicit user action, never at app launch): this
/// type never calls `requestAuthorization` on its own; only `enableISS`/`enableAurora` do, and
/// only because `SettingsView` calls them from the moment the user flips a toggle ON. If the
/// system denies (or the user has previously denied), the caller is expected to flip its own
/// toggle back off and show a short explanation — see `SettingsView`'s toggle handlers.
///
/// **Foreground-only scheduling — an honest, documented limitation.** There is no
/// `BGTaskScheduler`/background-refresh wiring here: passes and aurora outlooks are only
/// (re)scheduled when this type is actually asked to, which happens from two triggers, both of
/// which require the app to be running:
/// 1. `NavigationShell`'s `scenePhase` handler, on every transition to `.active` (app
///    foreground).
/// 2. `TonightSkyCard.load()`, right where it resolves `SkyTonightService.shared.state(...)` for
///    the first saved location — see that file's `onSkyStateResolved` callback.
/// If the user doesn't open the app on a given day, no alert fires that day, even if a real pass
/// or storm was forecast. A future background-refresh phase (`BGAppRefreshTask`) could close
/// this gap; it is explicitly out of scope here.
///
/// **Idempotency / dedupe**, per notification kind:
/// - ISS: every refresh removes ALL previously-scheduled `iss-`-prefixed pending requests, then
///   reschedules from scratch off whatever pass data was just resolved. This is simpler and more
///   correct than trying to diff against the previous schedule (passes can shift bucket-to-bucket
///   as new TLE data arrives), at the cost of a brief remove+re-add on every refresh — negligible
///   since refreshes are foreground-triggered, not high-frequency.
/// - Aurora: identifier is `aurora-YYYY-MM-DD` (the calendar date the notification fires for,
///   this device's time zone) — a fixed, content-independent identifier, so a second refresh the
///   same evening (e.g. app re-foregrounded after the first alert already fired) never
///   duplicates or re-fires it. Checked against both pending AND delivered notifications before
///   scheduling.
///
/// Every method here is `@MainActor` (this type is annotated as a whole) because
/// `SkyTonightService`, which every real refresh path calls into, is itself `@MainActor`.
@MainActor
final class SkyNotificationScheduler: NSObject {
    static let shared = SkyNotificationScheduler()

    /// Notification-tap deep link (Sky Finder ingress #5): set by `NavigationShell` at launch.
    /// Tapping an ISS-pass notification routes straight into the Sky Finder targeting the ISS —
    /// the highest-intent moment for the finder there is. Main-actor: UI routing.
    var onOpenFinderForISS: (@MainActor () -> Void)?

    /// `SettingsView`'s toggles persist to these exact keys via `@AppStorage`, so this type's
    /// own `UserDefaults.standard.bool(forKey:)` reads always see the toggle's current value —
    /// one source of truth, no separate "is this feature on" state duplicated here.
    static let issEnabledKey = "clearSky.notifications.issEnabled"
    static let auroraEnabledKey = "clearSky.notifications.auroraEnabled"

    private static let issIdentifierPrefix = "iss-"
    private static let auroraIdentifierPrefix = "aurora-"

    /// "ISS pass in 10 minutes" is the notification's own name — the lead time it's scheduled at.
    private static let issLeadTime: TimeInterval = 10 * 60

    private let center = UNUserNotificationCenter.current()

    private override init() {
        super.init()
        // Set as early as possible (this singleton is touched once, deliberately, at the very
        // top of `NavigationShell.bootstrap()` for exactly this reason) so a foreground-delivered
        // notification — real or `-forceNotifTest` — always has a delegate installed to present
        // it as a banner rather than silently swallowing it (the system default while the app is
        // frontmost is no banner, no sound, nothing).
        center.delegate = self
    }

    // MARK: - Settings entry points (toggle ON/OFF)

    /// Called from `SettingsView` the instant the ISS toggle flips ON. Requests authorization if
    /// not already determined; on success, immediately schedules from whatever pass data is
    /// available for `location` (typically the first saved location — see `refreshISS`'s doc
    /// comment). Returns `false` on denial, so the caller can flip its own toggle back off.
    @discardableResult
    func enableISS(location: SavedLocation?) async -> Bool {
        guard await requestAuthorizationIfNeeded() else { return false }
        if let location {
            await refreshISS(location: location)
        }
        return true
    }

    /// Called from `SettingsView` the instant the ISS toggle flips OFF. Removes every pending
    /// `iss-`-prefixed request; already-delivered banners are left alone (nothing to "unsend").
    func disableISS() async {
        await removePending(prefix: Self.issIdentifierPrefix)
    }

    /// Mirrors `enableISS` for the Aurora toggle. Both toggles share the same underlying system
    /// permission (`UNUserNotificationCenter` authorization is app-wide, not per-notification-
    /// kind) — if the ISS toggle already obtained authorization, this resolves immediately
    /// without a second system prompt.
    @discardableResult
    func enableAurora(location: SavedLocation?) async -> Bool {
        guard await requestAuthorizationIfNeeded() else { return false }
        if let location {
            await refreshAurora(location: location)
        }
        return true
    }

    /// Mirrors `disableISS` for the Aurora toggle.
    func disableAurora() async {
        await removePending(prefix: Self.auroraIdentifierPrefix)
    }

    // MARK: - Authorization

    /// Requests authorization only if the system hasn't been asked yet (`.notDetermined`);
    /// otherwise reports the existing status without prompting again. `true` for
    /// `.authorized`/`.provisional`/`.ephemeral`, `false` for `.denied` (including a denial from
    /// this very call) or any future unknown case.
    @discardableResult
    func requestAuthorizationIfNeeded() async -> Bool {
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return true
        case .denied:
            return false
        case .notDetermined:
            do {
                return try await center.requestAuthorization(options: [.alert, .sound, .badge])
            } catch {
                return false
            }
        @unknown default:
            return false
        }
    }

    private func isCurrentlyAuthorized() async -> Bool {
        let status = await center.notificationSettings().authorizationStatus
        return status == .authorized || status == .provisional
    }

    // MARK: - ISS refresh (foreground + post-fetch triggers)

    /// Schedules tonight's + tomorrow night's visible ISS passes for `location`, at
    /// `startTime - 10 min` each, provided that lead time hasn't already passed. Called from:
    /// - `NavigationShell`'s `scenePhase` handler, on every foreground.
    /// - `TonightSkyCard.load()`, immediately after it resolves `SkyTonightService`'s state for
    ///   the first saved location (the "hook where `SkyTonightService` resolves passes" this
    ///   type's own work order calls for) — see that file's `onSkyStateResolved` callback.
    ///
    /// Both call sites hit `SkyTonightService`'s own per-(location, evening) in-memory cache for
    /// "tonight," so the common case (this method already ran once this evening) is cheap; only
    /// "tomorrow night" is a guaranteed-fresh fetch the first time each day.
    ///
    /// No-ops (leaves any existing schedule untouched) when the toggle is off. If the toggle is
    /// on but the system permission has since been revoked from iOS Settings (outside this app),
    /// flips the toggle back off itself — via the same `UserDefaults` key `SettingsView`'s
    /// `@AppStorage` reads — so the UI doesn't keep claiming a permission it no longer has.
    func refreshISS(location: SavedLocation) async {
        guard UserDefaults.standard.bool(forKey: Self.issEnabledKey) else { return }
        guard await isCurrentlyAuthorized() else {
            UserDefaults.standard.set(false, forKey: Self.issEnabledKey)
            return
        }

        let now = Date()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: now) ?? now.addingTimeInterval(86_400)

        async let tonightState = SkyTonightService.shared.state(
            locationId: location.id, latitude: location.latitude, longitude: location.longitude, date: now
        )
        async let tomorrowState = SkyTonightService.shared.state(
            locationId: location.id, latitude: location.latitude, longitude: location.longitude, date: tomorrow
        )
        let (tonight, nextNight) = await (tonightState, tomorrowState)

        var passes: [ISSPass] = []
        if case .available(let tonightPasses) = tonight.iss { passes.append(contentsOf: tonightPasses) }
        if case .available(let tomorrowPasses) = nextNight.iss { passes.append(contentsOf: tomorrowPasses) }

        await scheduleISS(passes: passes)
    }

    /// Dedupe (per this file's type-level doc comment): removes every previously-scheduled
    /// `iss-`-prefixed request, then reschedules fresh from `passes`. A pass whose `startTime -
    /// 10 min` lead time is already in the past (or exactly now) is silently skipped — per work
    /// order, "don't schedule passes already <10 min away or past."
    private func scheduleISS(passes: [ISSPass]) async {
        await removePending(prefix: Self.issIdentifierPrefix)
        let now = Date()
        for pass in passes {
            let fireDate = pass.startTime.addingTimeInterval(-Self.issLeadTime)
            guard fireDate > now else { continue }

            let content = UNMutableNotificationContent()
            content.title = "ISS pass in 10 minutes"
            content.body = Self.issBody(for: pass)
            content.sound = .default

            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: fireDate.timeIntervalSince(now), repeats: false)
            let request = UNNotificationRequest(identifier: Self.issIdentifier(for: pass), content: content, trigger: trigger)
            try? await center.add(request)
        }
    }

    /// One identifier per pass, keyed on its `startTime` — stable across re-scheduling the same
    /// pass (e.g. two foregrounds the same evening resolve the same TLE-derived pass) without
    /// colliding across different passes/nights.
    private static func issIdentifier(for pass: ISSPass) -> String {
        issIdentifierPrefix + ISO8601DateFormatter().string(from: pass.startTime)
    }

    /// "Look west-northwest at 9:42 — visible for about 4 minutes. It looks like a bright, steady
    /// star." — Observatory Guide register (factual, no exclamations), reusing
    /// `TonightHeadline.compassWord`/`.shortTime` so the notification's wording matches the
    /// Tonight's Sky card's own ISS language exactly rather than a second, potentially-drifting
    /// copy of it.
    private static func issBody(for pass: ISSPass) -> String {
        let direction = TonightHeadline.compassWord(pass.startAzimuthCompass)
        let time = TonightHeadline.shortTime(pass.startTime, timeZone: .current)
        let minutes = max(1, Int((pass.endTime.timeIntervalSince(pass.startTime) / 60.0).rounded()))
        let durationText = minutes == 1 ? "1 minute" : "\(minutes) minutes"
        return "Look \(direction) at \(time) — visible for about \(durationText). It looks like a bright, steady star."
    }

    // MARK: - Aurora refresh (foreground + post-fetch triggers)

    /// Schedules tonight's single aurora alert for `location` if — and only if — tonight's
    /// outlook clears the G3+ gate below. Called from the same two triggers as `refreshISS`
    /// (foreground + `TonightSkyCard.load()`'s post-fetch hook for the first saved location).
    ///
    /// **The exact gate** (documented per work order): `outlook.band == .strong` OR
    /// `outlook.tonightPeakKp >= 7`. Kp 7 is NOAA's own G3 threshold on the standard G-scale (G1
    /// = Kp5, G2 = Kp6, G3 = Kp7, G4 = Kp8, G5 = Kp9 — the same Kp table
    /// `AuroraLikelihood.kpVisibilityTable` already rides on). `.strong` is included as an OR
    /// rather than relied on alone because `AuroraBand` also factors in the live OVATION
    /// `chanceNow` nowcast (see `AuroraLikelihood.outlook`'s doc comment: a bright nowcast can
    /// raise the band independent of the Kp forecast) — so a currently-bright reading that hasn't
    /// yet shown up as a Kp-7+ forecast bucket still qualifies, and a Kp-7+ forecast that hasn't
    /// yet band-classified as `.strong` (e.g. a marginal geomagnetic-latitude margin) also still
    /// qualifies. Either condition alone is real G3+ storm signal.
    func refreshAurora(location: SavedLocation) async {
        guard UserDefaults.standard.bool(forKey: Self.auroraEnabledKey) else { return }
        guard await isCurrentlyAuthorized() else {
            UserDefaults.standard.set(false, forKey: Self.auroraEnabledKey)
            return
        }

        let now = Date()
        let result = await SkyTonightService.shared.state(
            locationId: location.id, latitude: location.latitude, longitude: location.longitude, date: now
        )
        guard case .available(let outlook) = result.aurora else { return }
        guard Self.auroraGateMet(outlook) else { return }

        // Dedupe per calendar night: never re-fire for the same night, whether it's still
        // pending (scheduled but hasn't fired yet) or already delivered (fired earlier this
        // evening, and the app was simply foregrounded again).
        let identifier = Self.auroraIdentifier(for: now)
        let pending = await center.pendingNotificationRequests()
        if pending.contains(where: { $0.identifier == identifier }) { return }
        let delivered = await center.deliveredNotifications()
        if delivered.contains(where: { $0.request.identifier == identifier }) { return }

        // Fire at civil dusk tonight, or immediately (a few seconds out, so `UNTimeInterval-
        // NotificationTrigger`'s positive-interval requirement is still met) if civil dusk has
        // already passed for today.
        let fireDate: Date
        if let civilDusk = result.astronomy.sun.civilDusk, civilDusk > now {
            fireDate = civilDusk
        } else {
            fireDate = now.addingTimeInterval(5)
        }

        let content = UNMutableNotificationContent()
        content.title = "Aurora possible tonight"
        content.body = Self.auroraBody(for: outlook)
        content.sound = .default

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, fireDate.timeIntervalSince(now)), repeats: false)
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)
        try? await center.add(request)
    }

    private static func auroraGateMet(_ outlook: AuroraOutlook) -> Bool {
        outlook.band == .strong || outlook.tonightPeakKp >= 7
    }

    private static func auroraIdentifier(for date: Date) -> String {
        auroraIdentifierPrefix + dateOnlyFormatter.string(from: date)
    }

    /// "Geomagnetic storm conditions are forecast. Best window 11:15–1:30 — look north from
    /// somewhere dark." Observatory Guide register — factual, no exclamations, no fake urgency.
    private static func auroraBody(for outlook: AuroraOutlook) -> String {
        let start = TonightHeadline.shortTime(outlook.bestViewingWindow.start, timeZone: .current)
        let end = TonightHeadline.shortTime(outlook.bestViewingWindow.end, timeZone: .current)
        return "Geomagnetic storm conditions are forecast. Best window \(start)–\(end) — look north from somewhere dark."
    }

    private static let dateOnlyFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        return formatter
    }()

    // MARK: - Shared removal helper

    /// `UNUserNotificationCenter` has no "remove by prefix" API — this lists every pending
    /// request, filters by identifier prefix, then removes just that subset, leaving the other
    /// notification kind's schedule (and any future non-sky notification, though none exist —
    /// see this file's type-level doc comment) untouched.
    private func removePending(prefix: String) async {
        let pending = await center.pendingNotificationRequests()
        let ids = pending.map(\.identifier).filter { $0.hasPrefix(prefix) }
        guard !ids.isEmpty else { return }
        center.removePendingNotificationRequests(withIdentifiers: ids)
    }

    // MARK: - Sim-verify hooks

    /// `-forceNotifTest` (see `NavigationShell`'s doc comment): schedules one test ISS
    /// notification 15 seconds out, bypassing every real pass/location lookup, so a
    /// foreground-delivered banner can be screenshotted without waiting for a real pass. Requests
    /// authorization itself if not yet determined — sim-verify convenience only; the real
    /// ISS/aurora paths above never request authorization implicitly, only `enableISS`/
    /// `enableAurora` (called from an explicit Settings toggle) do.
    ///
    /// **Deliberately NOT `iss-`-prefixed** (caught during sim-verify): the app foregrounding for
    /// this very launch also fires `NavigationShell`'s real `refreshISS` trigger, which removes
    /// every `iss-`-prefixed pending request as part of its own dedupe sweep (this file's
    /// type-level doc comment) before rescheduling from real pass data — an identifier under that
    /// prefix would very likely get swept and removed before its 15-second timer ever fires,
    /// exactly the race that happened the first time this was tested. A distinct prefix makes the
    /// test notification immune to both real removal sweeps (ISS's and Aurora's).
    private static let testIdentifier = "notiftest-iss"

    func scheduleTestNotification() async {
        guard await requestAuthorizationIfNeeded() else { return }
        let content = UNMutableNotificationContent()
        content.title = "ISS pass in 10 minutes"
        content.body = "Look west-northwest at 9:42 — visible for about 4 minutes. It looks like a bright, steady star."
        content.sound = .default
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 15, repeats: false)
        let request = UNNotificationRequest(identifier: Self.testIdentifier, content: content, trigger: trigger)
        try? await center.add(request)
    }

    /// `-dumpPendingNotifs` (see `NavigationShell`'s doc comment): prints every pending local
    /// notification request — identifier, an approximate fire date derived from its
    /// `UNTimeIntervalNotificationTrigger`, title, and body — to the console. `print(...)` output
    /// only reaches a terminal when the process is launched via `xcrun simctl launch --console`
    /// (or `--console-pty`); a plain `simctl launch` discards stdout entirely.
    func dumpPendingRequests() async {
        let pending = await center.pendingNotificationRequests().sorted { $0.identifier < $1.identifier }
        let now = Date()
        print("SkyNotificationScheduler: \(pending.count) pending request(s)")
        for request in pending {
            let fireDescription: String
            if let trigger = request.trigger as? UNTimeIntervalNotificationTrigger {
                fireDescription = ISO8601DateFormatter().string(from: now.addingTimeInterval(trigger.timeInterval))
            } else {
                fireDescription = "unknown-trigger"
            }
            print("  \(request.identifier) fires ~\(fireDescription) — \(request.content.title): \(request.content.body)")
        }
    }
}

/// Foreground presentation: the system's default behavior for a notification that fires while
/// the app is already frontmost is to show NOTHING (no banner, no sound) unless a delegate opts
/// in. Both sanctioned notifications should still surface as a banner even if the app happens to
/// be open when they fire (an ISS pass 10 minutes out, or an aurora storm window, is exactly as
/// relevant then as when the app is backgrounded) — so this always presents `.banner`, `.sound`,
/// and `.list`. `nonisolated` because `UNUserNotificationCenter` calls delegate methods from an
/// arbitrary (non-main-actor) context; this implementation needs no isolated state, so it can
/// answer directly without a `Task { @MainActor in ... }` hop (the pattern `CurrentLocationManager`
/// -- a `nonisolated` delegate method on a `@MainActor` type -- uses when it DOES need to touch
/// isolated state).
extension SkyNotificationScheduler: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound, .list])
    }

    /// Tapping an ISS-pass notification opens the Sky Finder locked on the ISS (aurora
    /// notifications just open the app normally — there's no single object to point at).
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let identifier = response.notification.request.identifier
        if identifier.hasPrefix("iss-") || identifier.hasPrefix("notiftest-iss") {
            Task { @MainActor in
                SkyNotificationScheduler.shared.onOpenFinderForISS?()
            }
        }
        completionHandler()
    }
}
