import Foundation
import WidgetKit

/// Widget work package: builds a `WidgetSnapshot` (`Sources/Shared/WidgetSnapshot.swift`) for the
/// first saved location and writes it to the app-group container, then asks WidgetKit to reload
/// every widget's timeline. App-only — this file imports `SkyTonightService`, `TonightHeadline`,
/// and `TerrainClassifier` (the full engine + region-table stack), none of which are compiled into
/// `ZenithWidgets` (see that target's `sources` list in `project.yml`: only the plain
/// `WidgetSnapshot`/`TerrainClass`/`MoonPhaseDisc` files are shared). The widget extension only
/// ever reads what this writes; it never recomputes astronomy itself.
///
/// **Hook**, per the widget work order ("whenever `SkyTonightService` resolves"): called from
/// `NavigationShell.handleSkyStateResolved`, the exact same trigger `SkyNotificationScheduler`'s
/// `refreshISS`/`refreshAurora` already use — same "first saved location only" guard, so the
/// widget always reflects whichever location the two sanctioned notifications are also scoped to
/// (there's no per-location picker for widgets in v1; a single "tonight" snapshot is the whole
/// point of a glanceable widget).
///
/// **Headline honesty note:** `TonightSkyCard`'s own `TonightHeadline.generate` call has cloud
/// cover and a peak-stargazing-score on hand (from the Forecast view model's weather fetch); this
/// writer does not (`NavigationShell.handleSkyStateResolved` only ever receives a `SavedLocation`,
/// not that weather data — see that method's doc comment). So this writer's headline can pick a
/// different tier-3 fact than the card shows for the same night (e.g. it can't say "Overcast
/// tonight" or "Good stargazing after 9" since it has no cloud data), but strong events (ISS pass,
/// aurora, meteor peak, conjunction) and the moon/planet facts are identical to the card's, since
/// those tiers don't depend on weather at all. Documented v1 limitation, not a bug.
@MainActor
enum WidgetSnapshotWriter {
    /// Builds and writes a fresh snapshot for `location`, then reloads every widget's timeline.
    /// Cheap in the common case: `SkyTonightService.shared.state(...)` hits its own per-(location,
    /// evening) in-memory cache almost every time this runs (the caller just resolved this exact
    /// key for `TonightSkyCard`/`SkyNotificationScheduler` moments earlier).
    static func refresh(location: SavedLocation) async {
        let now = Date()
        let timeZone = TimeZone.current
        let astro = SkyTonightService.astronomy(latitude: location.latitude, longitude: location.longitude, date: now, timeZone: timeZone)
        let (meteor, pairings) = SkyTonightService.meteorAndPairings(
            latitude: location.latitude, longitude: location.longitude, date: now, timeZone: timeZone
        )
        let state = await SkyTonightService.shared.state(
            locationId: location.id, latitude: location.latitude, longitude: location.longitude, date: now, timeZone: timeZone
        )

        let window = SkyTonightService.duskDawnWindow(latitude: location.latitude, longitude: location.longitude, date: now, timeZone: timeZone)
            ?? DateInterval(start: now, end: now.addingTimeInterval(8 * 3600))

        let headline = TonightHeadline.generate(TonightHeadline.Inputs(
            moment: state.bestMoment,
            meteorOutlook: meteor,
            planets: astro.planets,
            moon: astro.moon,
            tonightWindow: window,
            timeZone: timeZone
        ))

        let snapshot = WidgetSnapshot(
            generatedAt: now,
            headline: headline.text,
            moonIlluminatedFraction: astro.moon.illuminatedPercent / 100,
            moonWaxing: astro.moon.waxing,
            topObjects: Self.topObjects(astronomy: astro, iss: SkyTonightService.availableValue(state.iss) ?? []),
            terrainClass: TerrainClassifier.classify(latitude: location.latitude, longitude: location.longitude),
            isEventNight: headline.kind.isEvent
        )
        _ = pairings // consumed only via `state.bestMoment`/`headline` above; kept for parity with TonightSkyCard.load()'s own call shape.

        WidgetSnapshot.write(snapshot)
        WidgetCenter.shared.reloadAllTimelines()
    }

    /// Up to 3 objects for the medium widget's Gantt-style rows, soonest-starting first.
    /// **Selection rule (documented, not spec-mandated beyond "top 3"):** a visible ISS pass
    /// tonight is always included first if one exists — a one-shot, time-critical event is the
    /// most "worth a Gantt bar" thing tonight — then the brightest visible planets (by apparent
    /// magnitude, same tie-break `TonightHeadline.brightestVisiblePlanet` uses) fill the
    /// remaining slots, each needing a real best-viewing window (both edges non-nil) to be
    /// eligible, same bar `TonightSkyCard.timelinePlanetBars` already applies for its own strip.
    private static func topObjects(astronomy: SkyTonight.TonightSky, iss: [ISSPass]) -> [WidgetSnapshot.ObjectWindow] {
        var objects: [WidgetSnapshot.ObjectWindow] = []

        if let firstPass = iss.first {
            objects.append(WidgetSnapshot.ObjectWindow(name: "ISS", kind: .iss, windowStart: firstPass.startTime, windowEnd: firstPass.endTime))
        }

        let planetSlots = 3 - objects.count
        if planetSlots > 0 {
            let brightestFirst = astronomy.planets
                .filter { $0.isVisibleTonight && $0.apparentMagnitude != nil }
                .compactMap { planet -> (planet: SkyTonight.PlanetVisibility, start: Date, end: Date)? in
                    guard let start = planet.bestViewingStart, let end = planet.bestViewingEnd, end > start else { return nil }
                    return (planet, start, end)
                }
                .sorted { ($0.planet.apparentMagnitude ?? 99) < ($1.planet.apparentMagnitude ?? 99) }
                .prefix(planetSlots)
            for entry in brightestFirst {
                objects.append(WidgetSnapshot.ObjectWindow(name: entry.planet.body.displayName, kind: .planet, windowStart: entry.start, windowEnd: entry.end))
            }
        }

        return objects.sorted { $0.windowStart < $1.windowStart }
    }
}
