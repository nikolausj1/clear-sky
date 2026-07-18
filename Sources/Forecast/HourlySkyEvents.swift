import SwiftUI

/// Per-hour event-icon bucketing (Forecast-surface overhaul, work item 3): maps tonight's ISS
/// passes, aurora best window, meteor prime window, and upcoming rocket launches onto the
/// hourly list's displayed-hour rows, for the Events chip's icon row and the default hourly
/// view's trailing inline icon.
///
/// Pure bucketing/mapping logic only — no networking of its own. `ForecastPageView` gathers the
/// underlying data from `SkyTonightService` (ISS passes + aurora outlook, already fetched/cached
/// once per evening for `TonightSkyCard`/`DoodleHeaderView`) and `LaunchesUpcoming
/// .cachedNextLaunchesIfFresh` (launches, cache-only — see that function's doc comment for why
/// this deliberately never triggers a new network fetch of its own) and hands both here.
enum HourlySkyEvents {
    /// One event, ready for display. SF Symbol choices (documented per work order):
    /// - `issPass` renders the real `ISSGlyph` miniature (see `glyph` below) everywhere it's
    ///   shown (the default hourly view's inline icon, the Events chip's pills); `symbolName`
    ///   below is the plain-SF fallback for any future context with only a symbol-name slot.
    /// - `launch`: `paperplane.fill`, rotated -45° by the caller (a view-layer concern — this
    ///   type only names the symbol) to read as a liftoff rather than a message icon.
    /// - `aurora`: `light.max` — a soft glow reads closer to "aurora" than a waveform would.
    /// - `meteor`: `sparkle` (singular) — deliberately distinct from the Sky chip's own
    ///   `sparkles` (plural) chip icon, so the two don't look like the same mark at a glance.
    enum Icon: Identifiable, Equatable {
        case issPass(ISSPass)
        case launch(UpcomingLaunch)
        case aurora
        case meteor

        var id: String {
            switch self {
            case .issPass(let pass): return "iss-\(pass.startTime.timeIntervalSince1970)"
            case .launch(let launch): return "launch-\(launch.id)"
            case .aurora: return "aurora"
            case .meteor: return "meteor"
            }
        }

        var symbolName: String {
            switch self {
            case .issPass: return "arrow.up.forward.circle"
            case .launch: return "paperplane.fill"
            case .aurora: return "light.max"
            case .meteor: return "sparkle"
            }
        }

        var tintColor: Color {
            switch self {
            case .issPass: return .primary
            case .launch: return .orange
            case .aurora: return .green
            case .meteor: return .purple
            }
        }

        /// The matching glossary entry (work item 4: "tap anywhere on an icon ... explainer
        /// popover"). `launch` injects this specific launch's own details, per work order.
        // (See `glyph` below, in the file-scope extension, for the actual rendered icon.)
        var explainer: ExplainerContent {
            switch self {
            case .issPass: return Explainers.issPass
            case .launch(let launch): return Explainers.rocketLaunch(launch)
            case .aurora: return Explainers.aurora
            case .meteor: return Explainers.meteorShower
            }
        }
    }

    /// One displayed hour's events, capped at 3 (work order: "max 3 icons/hour").
    struct Bucket {
        var icons: [Icon] = []
        var isEmpty: Bool { icons.isEmpty }
    }

    private static let maxIconsPerHour = 3

    /// One contiguous span a displayed row "owns" — from that row's own date up to (but not
    /// including) the next row's date, or +24h for the last row (there is no "next" row to bound
    /// it, and no displayed row is ever meant to swallow more than a day's worth of events).
    private static func rowSpans(_ sortedRows: [Date]) -> [(row: Date, start: Date, end: Date)] {
        sortedRows.enumerated().map { index, date in
            let end = index + 1 < sortedRows.count ? sortedRows[index + 1] : date.addingTimeInterval(24 * 3600)
            return (row: date, start: date, end: end)
        }
    }

    /// Buckets every event into whichever displayed row's span contains it (point events: ISS
    /// pass start, launch T-0) or overlaps it (window events: aurora best window, meteor prime
    /// window) — a window can span multiple displayed rows, so it lights up every row it
    /// touches, not just the first.
    static func buckets(
        displayedHours: [Date],
        issPasses: [ISSPass],
        auroraWindow: DateInterval?,
        meteorWindow: DateInterval?,
        launches: [UpcomingLaunch]
    ) -> [Date: Bucket] {
        let sorted = displayedHours.sorted()
        let spans = rowSpans(sorted)
        guard !spans.isEmpty else { return [:] }

        var result: [Date: Bucket] = [:]

        func spanRow(containing date: Date) -> Date? {
            if let match = spans.first(where: { date >= $0.start && date < $0.end }) {
                return match.row
            }
            // A point event before the very first displayed row (shouldn't normally happen —
            // displayed rows start at "now" — but handled defensively) is attributed to the
            // first row rather than silently dropped.
            return date < spans[0].start ? spans[0].row : nil
        }

        func overlappingRows(_ interval: DateInterval) -> [Date] {
            spans.filter { $0.start < interval.end && $0.end > interval.start }.map(\.row)
        }

        func append(_ icon: Icon, toRow row: Date) {
            result[row, default: Bucket()].icons.append(icon)
        }

        for pass in issPasses {
            if let row = spanRow(containing: pass.startTime) {
                append(.issPass(pass), toRow: row)
            }
        }
        for launch in launches {
            if let row = spanRow(containing: launch.net) {
                append(.launch(launch), toRow: row)
            }
        }
        if let auroraWindow {
            for row in overlappingRows(auroraWindow) {
                append(.aurora, toRow: row)
            }
        }
        if let meteorWindow {
            for row in overlappingRows(meteorWindow) {
                append(.meteor, toRow: row)
            }
        }

        for row in result.keys where result[row]!.icons.count > maxIconsPerHour {
            result[row]!.icons = Array(result[row]!.icons.prefix(maxIconsPerHour))
        }
        return result
    }

    /// Orchestrates `buckets(...)` from the raw engine/service data `ForecastPageView` already
    /// has in hand — the aurora/meteor "is this even worth showing" gates (`.fair`+ band,
    /// peak-night only) mirror `TonightSkyCard`'s own timeline-strip/headline gates, so the
    /// hourly Events chip agrees with the night panel about what counts as a real event.
    static func compute(
        displayedHours: [Date],
        issPasses: [ISSPass],
        auroraOutlook: AuroraOutlook?,
        meteorOutlook: MeteorShowers.MeteorOutlook?,
        launches: [UpcomingLaunch]
    ) -> [Date: Bucket] {
        let auroraWindow: DateInterval? = {
            guard let auroraOutlook, auroraOutlook.band >= .fair else { return nil }
            return auroraOutlook.bestViewingWindow
        }()
        let meteorWindow: DateInterval? = {
            guard let meteorOutlook, meteorOutlook.isPeakNight else { return nil }
            return meteorOutlook.bestWindow
        }()
        return buckets(
            displayedHours: displayedHours,
            issPasses: issPasses,
            auroraWindow: auroraWindow,
            meteorWindow: meteorWindow,
            launches: launches
        )
    }
}

extension HourlySkyEvents.Icon {
    /// The rendered glyph for this icon: the new `ISSGlyph` miniature for `issPass` (Space-first
    /// design batch, item 4 — replaces the previous `arrow.up.forward.circle` SF Symbol
    /// fallback), a plain SF Symbol for `aurora`/`meteor`, and `launch` rotated -45° (spec:
    /// "launch = `paperplane.fill` rotated -45°") so it reads as liftoff rather than a message
    /// icon. Callers apply their own `.font`/`.foregroundStyle` (this view intentionally carries
    /// no styling of its own, so it fits inline icon, Events chip pill, and any future context
    /// identically) — `ISSGlyph` is a plain `Shape` under the hood, so `.foregroundStyle` tints
    /// it exactly the same way it tints the `Image(systemName:)` cases.
    @ViewBuilder
    var glyph: some View {
        switch self {
        case .issPass:
            ISSGlyph(size: CGSize(width: 16, height: 9))
        case .launch:
            Image(systemName: symbolName).rotationEffect(.degrees(-45))
        case .aurora, .meteor:
            Image(systemName: symbolName)
        }
    }
}
