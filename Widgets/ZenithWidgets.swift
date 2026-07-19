import SwiftUI
import WidgetKit

/// Widget work package: "tonight's sky" on the home and lock screen, v1 scope (see the work
/// order this was built from — Sources/Shared/WidgetSnapshot.swift carries the full rationale
/// for the app<->extension data handoff). Four glanceable, non-interactive widgets, all reading
/// the same `WidgetSnapshot` the app writes to the `group.com.levelup.clearsky` app-group
/// container: no network, no astronomy/engine computation happens in this extension — see
/// `WidgetSnapshot`'s own doc comment for why that boundary matters.
@main
struct ZenithWidgetsBundle: WidgetBundle {
    var body: some Widget {
        MoonPhaseCircularWidget()
        TonightRectangularWidget()
        TonightSmallWidget()
        TonightMediumWidget()
        // ISS Live Activity work package: `Widgets/ISSPassLiveActivity.swift` — a
        // `Widget`-conforming type just like the four above, just backed by `ActivityConfiguration`
        // instead of `StaticConfiguration`, so it belongs in the same bundle.
        ISSPassLiveActivity()
    }
}

// MARK: - Shared timeline

/// One rendering of "tonight" at a given moment — every widget in this bundle shares the same
/// entry/provider shape, since all four just read one `WidgetSnapshot` and lay it out differently
/// per family; there is no per-widget-kind data to fetch separately.
struct ZenithEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot
}

/// Reads the app-group snapshot only — never fetches, never computes. `getTimeline` builds hourly
/// entries from "now" through ~noon tomorrow (per the work order: "hourly refreshes until ~noon
/// tomorrow"), all carrying the SAME snapshot payload (there's nothing to interpolate — the
/// snapshot itself doesn't carry a per-hour schedule beyond `topObjects`' own start/end windows,
/// which the views already render directly against `entry.date`), then hands back with `.atEnd` so
/// WidgetKit re-invokes this provider (and therefore re-reads whatever the app most recently
/// wrote) once the last entry's time passes, rather than this extension ever polling on its own.
struct ZenithTimelineProvider: TimelineProvider {
    func placeholder(in context: Context) -> ZenithEntry {
        ZenithEntry(date: Date(), snapshot: .placeholder)
    }

    func getSnapshot(in context: Context, completion: @escaping (ZenithEntry) -> Void) {
        completion(ZenithEntry(date: Date(), snapshot: WidgetSnapshot.read() ?? .placeholder))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<ZenithEntry>) -> Void) {
        let snapshot = WidgetSnapshot.read() ?? .placeholder
        let now = Date()

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let tomorrowStart = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))
            ?? now.addingTimeInterval(86_400)
        let noonTomorrow = calendar.date(bySettingHour: 12, minute: 0, second: 0, of: tomorrowStart) ?? tomorrowStart

        var entries = [ZenithEntry(date: now, snapshot: snapshot)]
        var cursor = now
        while let next = calendar.date(byAdding: .hour, value: 1, to: cursor), next < noonTomorrow {
            entries.append(ZenithEntry(date: next, snapshot: snapshot))
            cursor = next
        }

        completion(Timeline(entries: entries, policy: .atEnd))
    }
}

// MARK: - Lock-screen circular: moon phase

struct MoonPhaseCircularWidget: Widget {
    let kind = "ZenithMoonPhaseCircular"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: ZenithTimelineProvider()) { entry in
            MoonPhaseCircularView(snapshot: entry.snapshot)
        }
        .configurationDisplayName("Moon Phase")
        .description("Tonight's moon phase.")
        .supportedFamilies([.accessoryCircular])
    }
}

// MARK: - Lock-screen rectangular: headline

struct TonightRectangularWidget: Widget {
    let kind = "ZenithTonightRectangular"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: ZenithTimelineProvider()) { entry in
            TonightRectangularView(snapshot: entry.snapshot)
        }
        .configurationDisplayName("Tonight's Sky")
        .description("Tonight's headline sky event.")
        .supportedFamilies([.accessoryRectangular])
    }
}

// MARK: - Home-screen small: mini night scene

struct TonightSmallWidget: Widget {
    let kind = "ZenithTonightSmall"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: ZenithTimelineProvider()) { entry in
            TonightSmallView(snapshot: entry.snapshot)
        }
        .configurationDisplayName("Tonight's Sky")
        .description("A mini night scene with tonight's moon and headline.")
        .supportedFamilies([.systemSmall])
    }
}

// MARK: - Home-screen medium: scene + top 3 objects

struct TonightMediumWidget: Widget {
    let kind = "ZenithTonightMedium"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: ZenithTimelineProvider()) { entry in
            TonightMediumView(snapshot: entry.snapshot)
        }
        .configurationDisplayName("Tonight's Sky")
        .description("Tonight's night scene plus the top sky objects to watch for.")
        .supportedFamilies([.systemMedium])
    }
}
