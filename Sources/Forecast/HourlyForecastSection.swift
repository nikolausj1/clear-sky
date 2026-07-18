import SwiftUI

/// Everything an hourly row needs beyond its own `HourlyEntry`/pill position — the Sky/Events
/// chips' per-hour intelligence (Forecast-surface overhaul, work item 3) plus the tap-to-explain
/// wiring (work item 4). A value type with every field defaulted, so any existing call site or
/// preview that doesn't care about sky intelligence keeps compiling unchanged.
struct HourlySkyContext {
    var location: SavedLocation?
    var issPasses: [ISSPass]
    var auroraOutlook: AuroraOutlook?
    var meteorOutlook: MeteorShowers.MeteorOutlook?
    var launches: [UpcomingLaunch]
    var onExplain: (ExplainerContent) -> Void

    init(
        location: SavedLocation? = nil,
        issPasses: [ISSPass] = [],
        auroraOutlook: AuroraOutlook? = nil,
        meteorOutlook: MeteorShowers.MeteorOutlook? = nil,
        launches: [UpcomingLaunch] = [],
        onExplain: @escaping (ExplainerContent) -> Void = { _ in }
    ) {
        self.location = location
        self.issPasses = issPasses
        self.auroraOutlook = auroraOutlook
        self.meteorOutlook = meteorOutlook
        self.launches = launches
        self.onExplain = onExplain
    }

    /// Stargazing Score for every hour in `hours` (Sky chip). A `nil` location returns an empty
    /// map — the Sky chip then simply shows no positioned pills rather than guessing a
    /// location. `StargazingScore` is cheap, synchronous, pure math (see its own doc comment),
    /// so recomputing this per render is fine.
    func stargazingScores(for hours: [HourlyEntry]) -> [Date: StargazingScore.HourScore] {
        guard let location else { return [:] }
        let inputs = hours.map {
            StargazingScore.HourInput(date: $0.date, conditionCode: $0.conditionCode, precipChance: $0.precipChance)
        }
        let scores = StargazingScore.hourlyScores(hours: inputs, latitude: location.latitude, longitude: location.longitude)
        return Dictionary(uniqueKeysWithValues: scores.map { ($0.date, $0) })
    }

    /// Event-icon buckets for a specific set of displayed row dates (Events chip + the default
    /// view's inline icon) — see `HourlySkyEvents.compute`'s doc comment for the bucketing rule.
    func eventBuckets(displayedHours: [Date]) -> [Date: HourlySkyEvents.Bucket] {
        HourlySkyEvents.compute(
            displayedHours: displayedHours,
            issPasses: issPasses,
            auroraOutlook: auroraOutlook,
            meteorOutlook: meteorOutlook,
            launches: launches
        )
    }
}

/// One row of the hourly list: time label, a condition-change label shown only when the
/// condition differs from the previous row, and — depending on `metric` — either a positional
/// pill on a full-width track (PRD Section 6, item 7 + the "Positional pill spec"), a
/// Stargazing-Score pill on a darkness-tinted track (`.sky`), or an event-icon row (`.events`).
/// `position` is the pre-computed, clamped `[0, 1]` value from `PositionalPillTrack`, used only
/// by the default (weather-metric) track.
struct HourlyPillRow: View {
    @Environment(UnitsSettings.self) private var unitsSettings
    let entry: HourlyEntry
    /// UX redesign part 2: the main hourly list's anchor row reads "Now" instead of a formatted
    /// time — this is the only row that isn't a real 2-hour step, so it's called out explicitly
    /// rather than trying to make "h a" produce that string. `DailyExpandedDetail`'s
    /// midnight-anchored grid never sets this (every one of its rows is a real, formattable
    /// time); its TODAY grid (Forecast-surface overhaul: "today's expanded hourly starts NOW")
    /// does, for the same reason the main list does.
    var isFirstRow: Bool = false
    let previousConditionDescription: String?
    let metric: ForecastMetric
    let position: Double
    /// Non-nil only when meaningful for `.sky` — this hour's Stargazing Score. `nil` renders a
    /// quiet "–" pill rather than a fabricated zero, distinguishing "no location to score
    /// against" from "scored 0" (a real, honest daytime value).
    var stargazingScore: StargazingScore.HourScore? = nil
    /// This hour's event bucket, independent of `metric` — read both by the Events chip's icon
    /// row and the default view's trailing inline icon (work item 3: "Inline event icons in the
    /// DEFAULT hourly view").
    var eventBucket: HourlySkyEvents.Bucket? = nil
    var onExplain: (ExplainerContent) -> Void = { _ in }

    private static let hourFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "h a"
        return formatter
    }()

    private var showsConditionLabel: Bool {
        entry.conditionDescription != previousConditionDescription
    }

    private var timeLabel: String {
        isFirstRow ? "Now" : Self.hourFormatter.string(from: entry.date)
    }

    var body: some View {
        HStack(spacing: 10) {
            Text(timeLabel)
                .font(.subheadline)
                .monospacedDigit()
                // Widened from 52->58 (redesign part 2): "12 AM"/"Now" at 2-hour-step density
                // sit alongside each other more than the old 1-hour list did, and 52pt clipped
                // "12 AM" at some Dynamic Type sizes.
                .frame(width: 58, alignment: .leading)

            Text(showsConditionLabel ? entry.conditionDescription : "")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(width: 78, alignment: .leading)
                .lineLimit(1)
                .minimumScaleFactor(0.8)

            GeometryReader { proxy in
                switch metric {
                case .events:
                    eventsTrack
                case .sky:
                    skyTrack(proxy: proxy)
                default:
                    defaultTrack(proxy: proxy)
                }
            }
            .frame(height: 30)

            // Inline event icon (work item 3): shown for every chip EXCEPT `.events` itself
            // (which already renders the full icon row in place of the pill — a second copy
            // there would be redundant). Only the single most notable icon shows inline (the
            // Events chip is where the full set lives); tapping it opens the matching explainer.
            if metric != .events, let icon = eventBucket?.icons.first {
                Button {
                    onExplain(icon.explainer)
                } label: {
                    icon.glyph
                        .font(.caption)
                        .foregroundStyle(icon.tintColor)
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 5)
    }

    // MARK: - Default (weather-metric) track + positional pill

    private func defaultTrack(proxy: GeometryProxy) -> some View {
        let pillWidth: CGFloat = 56
        let travel = max(proxy.size.width - pillWidth, 0)
        return ZStack(alignment: .leading) {
            // UX polish package ("Data-mark discipline"): recessive per mark-discipline —
            // thinner (0.75pt) and the low-contrast `separator` color rather than
            // `secondary`, so the track reads as scaffolding, not data.
            Rectangle()
                .fill(Color(.separator).opacity(0.5))
                .frame(height: 0.75)
                .frame(maxWidth: .infinity)

            Text(metric.displayString(for: entry, unit: unitsSettings.unit))
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .padding(.horizontal, 8)
                .frame(width: pillWidth, height: 30)
                // UX polish package: the "Now" row's pill gets the accent tint at 15%
                // opacity with accent-colored text, so the anchor row visually pops
                // against the otherwise-neutral list.
                .background(Capsule().fill(isFirstRow ? Color.clearSkyAccent.opacity(0.15) : Color(.tertiarySystemFill)))
                .foregroundStyle(isFirstRow ? Color.clearSkyAccent : Color.primary)
                .offset(x: travel * position)
        }
        .frame(maxHeight: .infinity, alignment: .center)
    }

    // MARK: - Sky chip

    /// Space-first design batch, item 6: the Stargazing Score pill is replaced by a per-hour
    /// horizontal bar — a subtle full-width track, an accent fill from the left sized to
    /// `score/10` (opacity keyed to quality, plus a glow at `.excellent`), a right-aligned
    /// "N · Quality" label, and — when one factor clearly dominates the score — a small reason
    /// glyph at the fill's leading edge. The previous darkness-tinted track is deliberately gone
    /// (spec: "the bars carry the info; remove the tint to reduce noise").
    private func skyTrack(proxy: GeometryProxy) -> some View {
        let score = stargazingScore
        let isDaytimeZero = score?.tier == .day
        let fillFraction = min(1, max(0, Double(score?.score ?? 0) / 10.0))
        let labelWidth: CGFloat = 78
        let spacing: CGFloat = 8
        let barWidth = max(0, proxy.size.width - labelWidth - spacing)
        let barHeight: CGFloat = 6
        let fillWidth = barWidth * fillFraction
        let reason = Self.reasonGlyph(for: score)

        return HStack(spacing: spacing) {
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(0.08))
                    .frame(width: barWidth, height: barHeight)

                if fillFraction > 0, let score {
                    Capsule()
                        .fill(Color.clearSkyAccent.opacity(Self.skyBarFillOpacity(quality: score.quality)))
                        .frame(width: max(barHeight, fillWidth), height: barHeight)
                        .shadow(
                            color: score.quality == .excellent ? Color.clearSkyAccent.opacity(0.6) : .clear,
                            radius: score.quality == .excellent ? 4 : 0
                        )
                }

                if let reason {
                    Button {
                        onExplain(Explainers.stargazingScore(score?.score))
                    } label: {
                        Image(systemName: reason.symbolName)
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(.black.opacity(0.65))
                            .frame(width: 13, height: 13)
                            .background(Circle().fill(Color.white.opacity(0.95)))
                    }
                    .buttonStyle(.plain)
                    .offset(x: min(max(fillWidth, 6), barWidth) - 6.5)
                }
            }
            .frame(width: barWidth, height: max(barHeight, 13), alignment: .leading)

            Self.skyBarLabel(score: score, isDaytimeZero: isDaytimeZero)
                .frame(width: labelWidth, alignment: .trailing)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxHeight: .infinity, alignment: .center)
    }

    /// Accent opacity per quality tier (spec): poor 0.35, fair 0.55, good 0.8, excellent 1.0 +
    /// glow (the glow itself is applied by the caller above, keyed off the same quality check).
    private static func skyBarFillOpacity(quality: StargazingScore.QualityLabel) -> Double {
        switch quality {
        case .poor: return 0.35
        case .fair: return 0.55
        case .good: return 0.8
        case .excellent: return 1.0
        }
    }

    /// "8 · Excellent" — monospaced-digit score + a secondary quality word, built as two `Text`
    /// segments so each keeps its own weight/size (spec: "monospacedDigit number + quality word
    /// .caption2 secondary"). `nil` score (no location to score against) renders a quiet "–"
    /// rather than a fabricated value; a real score of 0 in daylight renders "0 · Daytime" (spec:
    /// "honest") instead of "0 · Poor", since a daylight hour was never a stargazing candidate.
    private static func skyBarLabel(score: StargazingScore.HourScore?, isDaytimeZero: Bool) -> Text {
        guard let score else {
            return Text("–").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
        }
        let qualityWord = isDaytimeZero ? "Daytime" : Self.qualityWord(score.quality)
        return Text("\(score.score)").font(.subheadline.weight(.semibold)).monospacedDigit().foregroundStyle(.primary)
            + Text(" \u{00B7} \(qualityWord)").font(.caption2).foregroundStyle(.secondary)
    }

    private static func qualityWord(_ quality: StargazingScore.QualityLabel) -> String {
        switch quality {
        case .poor: return "Poor"
        case .fair: return "Fair"
        case .good: return "Good"
        case .excellent: return "Excellent"
        }
    }

    /// One dominant-factor glyph, priority sun > cloud > moon (spec) — `nil` score (no location)
    /// shows no glyph at all. Reads straight off `HourScore`'s own transparency fields, no
    /// re-derivation needed.
    private static func reasonGlyph(for score: StargazingScore.HourScore?) -> ReasonGlyph? {
        guard let score else { return nil }
        if score.tier == .day { return .sun }
        if score.cloudFactor <= 0.3 { return .cloud }
        if score.moonFactor <= 0.5 { return .moon }
        return nil
    }

    private enum ReasonGlyph {
        case sun, cloud, moon

        var symbolName: String {
            switch self {
            case .sun: return "sun.max.fill"
            case .cloud: return "cloud.fill"
            case .moon: return "moon.fill"
            }
        }
    }

    // MARK: - Events chip

    /// Pills replaced entirely by event presence (spec): the hour's icons (up to 3, leading-
    /// aligned), or a single quiet dot when nothing's happening this hour.
    private var eventsTrack: some View {
        HStack(spacing: 8) {
            let icons = eventBucket?.icons ?? []
            if icons.isEmpty {
                Circle()
                    .fill(Color(.tertiaryLabel))
                    .frame(width: 4, height: 4)
            } else {
                ForEach(icons) { icon in
                    Button {
                        onExplain(icon.explainer)
                    } label: {
                        icon.glyph
                            .font(.footnote)
                            .foregroundStyle(icon.tintColor)
                    }
                    .buttonStyle(.plain)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(maxHeight: .infinity, alignment: .center)
    }
}

/// PRD Section 6, item 7: "Hourly forecast list ... Show ~24-48 hours."
///
/// UX redesign part 2 (density pass): renders 2-hour steps starting at the current hour, 12 rows
/// total (the next 24 hours) — see `IMG_1173.png`. `hours` is assumed to already start at the
/// current hour (that's how `WeatherKit`'s `hourlyForecast.forecast` — and therefore
/// `CachedWeather.hourly` — is ordered; see `WeatherService.fetchWeather`), so "every other
/// entry starting at index 0" is exactly "2-hour steps from now."
struct HourlyForecastSection: View {
    let hours: [HourlyEntry]
    let metric: ForecastMetric
    /// Forecast-surface overhaul, work item 3: Sky/Events chip data + tap-to-explain wiring.
    /// Defaulted so every existing call site/preview keeps compiling unchanged.
    var skyContext: HourlySkyContext = HourlySkyContext()
    /// Wall-clock "now" for anchoring the first row — injected (rather than `Date()` inline) so
    /// the enclosing `TimelineView` can drive minute-level re-anchoring; see `ForecastPageView`.
    var now: Date = Date()

    static let stepHours = 2
    static let displayedRowCount = 12

    /// The subset actually rendered: every `stepHours`-th entry of `hours`, capped at
    /// `displayedRowCount` rows. Index 0 (the anchor/"Now" row) is always included.
    private var displayedHours: [HourlyEntry] {
        Self.displayedIndices(for: hours, now: now).map { hours[$0] }
    }

    /// Pill positions are computed from the FULL-resolution hourly data — every hour of each
    /// calendar day, not just the displayed 2-hour subset — so the day's min/max (and therefore
    /// each pill's position) stays honest regardless of how sparsely the list renders rows. See
    /// `PositionalPillTrack`'s doc comment for the per-day normalization this relies on. Only
    /// meaningful for the default (weather-metric) chips; `.sky`/`.events` ignore it.
    private var positions: [Date: Double] {
        PositionalPillTrack.positions(for: hours, metric: metric)
    }

    private var stargazingScores: [Date: StargazingScore.HourScore] {
        skyContext.stargazingScores(for: hours)
    }

    private var eventBuckets: [Date: HourlySkyEvents.Bucket] {
        skyContext.eventBuckets(displayedHours: displayedHours.map(\.date))
    }

    var body: some View {
        // UX redesign part 1: the "Hourly Forecast" headline used to render here; it's now the
        // small uppercase header provided by the enclosing card chrome
        // (`ForecastSheetCard` in `ForecastPageView`), so this view renders rows only.
        VStack(alignment: .leading, spacing: 0) {
            // Space-first design batch, item 6: a "Best window: 11 PM–1 AM" header line under the
            // card's own "HOURLY FORECAST" title when the Sky chip is active — the longest
            // contiguous run of hours scoring >= 7. Work item 4's "Stargazing Score" + info-circle
            // discoverability row stays directly beneath it, unchanged.
            if metric == .sky {
                VStack(alignment: .leading, spacing: 2) {
                    Text(Self.bestWindowLine(Array(stargazingScores.values)))
                        .font(.subheadline.weight(.medium))
                    HStack(spacing: 4) {
                        Text("Stargazing Score")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                        Button {
                            skyContext.onExplain(Explainers.stargazingScore())
                        } label: {
                            Image(systemName: "info.circle")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.bottom, 6)
            }

            let rows = Array(displayedHours.enumerated())
            let scores = stargazingScores
            let buckets = eventBuckets
            ForEach(rows, id: \.element.id) { index, entry in
                HourlyPillRow(
                    entry: entry,
                    isFirstRow: index == 0,
                    // Condition-change labels compare consecutive DISPLAYED rows (the 2-hour
                    // subset), not raw hourly neighbors — the anchor row (index 0) always shows
                    // its condition; later rows only when it differs from the previous
                    // *displayed* row's condition.
                    previousConditionDescription: index > 0 ? rows[index - 1].element.conditionDescription : nil,
                    metric: metric,
                    position: positions[entry.date] ?? 0.5,
                    stargazingScore: scores[entry.date],
                    eventBucket: buckets[entry.date],
                    onExplain: skyContext.onExplain
                )
                .id(Self.rowId(for: entry))
                if index < rows.count - 1 {
                    Divider()
                }
            }
        }
    }

    /// Sim-verify only: a stable scroll-target id for `ScrollViewProxy.scrollTo` (see
    /// `ForecastView.scrollTargetHourIndex`).
    static func rowId(for entry: HourlyEntry) -> Date {
        entry.date
    }

    /// The indices into the FULL `hours` array that get rendered as rows: starting at the first
    /// entry at-or-after the top of the CURRENT hour, then every `stepHours`-th entry, up to
    /// `displayedRowCount` rows.
    ///
    /// User-reported defect fix ("the hourly forecast start time is still wrong"): the previous
    /// implementation strode from index 0, assuming `hours[0]` is the current hour. That holds
    /// only for a freshly-fetched payload — a CACHED payload's hours begin at its fetch time, so
    /// an app opened hours later anchored "Now" (and every row after it) to a stale morning hour.
    /// Filtering by wall-clock `now` instead of trusting index 0 makes the anchor correct no
    /// matter how old the cache is. (The simulator masked this: its canned WeatherKit data has a
    /// fixed clock, so index-0 anchoring looked right in every sim-verify screenshot.)
    static func displayedIndices(for hours: [HourlyEntry], now: Date = Date()) -> [Int] {
        let currentHourStart = floorToHour(now)
        let firstCurrent = hours.firstIndex { $0.date >= currentHourStart } ?? hours.count
        return Array(stride(from: firstCurrent, to: hours.count, by: stepHours).prefix(displayedRowCount))
    }

    static func floorToHour(_ date: Date) -> Date {
        let interval = date.timeIntervalSinceReferenceDate
        return Date(timeIntervalSinceReferenceDate: (interval / 3600).rounded(.down) * 3600)
    }

    /// "Best window: 11 PM–1 AM" (Sky chip header line, item 6): the longest contiguous run of
    /// `scores` (any order in) with `score >= 7`, where "contiguous" means each hour is exactly
    /// one hour after the previous one in the run — matching `HourlyEntry`'s hourly cadence.
    /// Ties on run length keep the earliest run (first found while scanning chronologically).
    /// "No strong stargazing window tonight." when no hour clears the bar at all.
    static func bestWindowLine(_ scores: [StargazingScore.HourScore]) -> String {
        let sorted = scores.sorted { $0.date < $1.date }
        var bestRun: [StargazingScore.HourScore] = []
        var currentRun: [StargazingScore.HourScore] = []
        for score in sorted {
            guard score.score >= 7 else {
                currentRun = []
                continue
            }
            if let last = currentRun.last, score.date.timeIntervalSince(last.date) > 3600.5 {
                currentRun = [score]
            } else {
                currentRun.append(score)
            }
            if currentRun.count > bestRun.count {
                bestRun = currentRun
            }
        }
        guard let first = bestRun.first, let last = bestRun.last else {
            return "No strong stargazing window tonight."
        }
        let end = last.date.addingTimeInterval(3600)
        return "Best window: \(bestWindowHourFormatter.string(from: first.date))–\(bestWindowHourFormatter.string(from: end))"
    }

    private static let bestWindowHourFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "h a"
        return formatter
    }()

    /// Sim-verify only: `-scrollToHour N` used to index straight into the (1-hour-resolution)
    /// `hours` array. Now that the list only renders every `stepHours`-th entry, `N` is
    /// reinterpreted as the Nth DISPLAYED row and remapped back to its real index in `hours`
    /// (clamped to the actual displayed range), so the launch arg still lands on a visible row.
    static func hourlyIndex(forDisplayedRow displayedRow: Int, hours: [HourlyEntry], now: Date = Date()) -> Int? {
        let indices = displayedIndices(for: hours, now: now)
        guard !indices.isEmpty else { return nil }
        let clamped = max(0, min(displayedRow, indices.count - 1))
        return indices[clamped]
    }
}
