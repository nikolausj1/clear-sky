import SwiftUI

/// The horizontal low/high range bar for one daily row (PRD Section 6, item 8; see
/// `IMG_1174.png`). The full track represents the 10-day min-to-max span; this day's segment
/// is positioned within it at `(low, high)`.
struct DailyRangeBar: View {
    let low: Double
    let high: Double
    let globalMin: Double
    let globalMax: Double
    /// Non-nil only for TODAY's row: the current temperature (Fahrenheit) within `[low, high]`,
    /// rendered as a small white "current temp" dot on the bar (UX polish package, "data-mark
    /// discipline").
    var currentTemperatureF: Double? = nil

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let range = max(globalMax - globalMin, 1)
            let startX = ((low - globalMin) / range) * width
            let endX = ((high - globalMin) / range) * width
            let segmentWidth = max(endX - startX, 6)

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color(.quaternarySystemFill))
                    .frame(height: 6)

                // UX polish package ("Data-mark discipline"): one consistent perceptual
                // temperature ramp (`TemperatureRamp`) mapped to this day's ACTUAL low/high
                // values, replacing the old fixed blue->orange gradient every bar used
                // regardless of its real temperatures — a cool day's segment now genuinely
                // reads cool, not just "the left side of every bar."
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [TemperatureRamp.color(forFahrenheit: low), TemperatureRamp.color(forFahrenheit: high)],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: segmentWidth, height: 6)
                    .offset(x: startX)

                if let currentTemperatureF {
                    let clamped = min(max(currentTemperatureF, low), high)
                    let currentX = ((clamped - globalMin) / range) * width
                    ZStack {
                        Circle()
                            .stroke(Color.white, lineWidth: 2)
                            .frame(width: 10, height: 10)
                        Circle()
                            .fill(Color.white)
                            .frame(width: 6, height: 6)
                    }
                    .shadow(color: .black.opacity(0.25), radius: 1, y: 0.5)
                    .offset(x: currentX - 5)
                }
            }
            .frame(maxHeight: .infinity, alignment: .center)
        }
        .frame(height: 20)
    }
}

/// The inline expansion shown when a daily row is tapped (PRD Section 6, item 8): that day's
/// hourly breakdown, total precipitation, daylight sunrise/sunset, and moon phase.
///
/// UX redesign part 2 (density pass): renders 2-hour steps rather than every hour — 12AM, 2AM, …
/// 10PM (see `IMG_1176.png`), midnight-anchored (`hour-of-day % stepHours == 0`) for every day
/// EXCEPT today.
///
/// Forecast-surface overhaul, work item 2 ("today's expanded hourly starts NOW"): TODAY's grid is
/// no longer midnight-anchored — it starts at the current hour and steps forward every
/// `stepHours` to end of day, the same "index 0 is now" technique `HourlyForecastSection` uses
/// for the main list (today's `hours`, passed in by `DailyForecastSection`, only contains entries
/// from the current hour onward — WeatherKit's hourly forecast starts at "now," not midnight, see
/// `WeatherService.fetchWeather` — so striding by index naturally anchors row 1 at "now"). Every
/// other day keeps the original midnight-anchored behavior, since there's no "now" within a
/// future day to anchor to. See `displayedHours`' own doc comment for the exact rule.
struct DailyExpandedDetail: View {
    let day: DailyEntry
    /// The FULL day's hourly entries (every hour WeatherKit returned for this calendar day, not
    /// just the displayed 2-hour subset) — needed as-is for the rain total below and for
    /// `positions`' per-day min/max.
    let hours: [HourlyEntry]
    let metric: ForecastMetric
    /// Forecast-surface overhaul, work item 3: Sky/Events chip data + tap-to-explain wiring.
    /// Defaulted so every existing call site/preview keeps compiling unchanged.
    var skyContext: HourlySkyContext = HourlySkyContext()
    /// Wall-clock "now" — injected for the same TimelineView-driven re-anchoring as the main
    /// hourly list; see `ForecastPageView`.
    var now: Date = Date()

    private static let stepHours = HourlyForecastSection.stepHours
    private static let displayedRowCount = HourlyForecastSection.displayedRowCount

    /// Forecast-surface overhaul, work item 2 ("today's expanded hourly starts NOW"): only
    /// TODAY's row gets the "starts now" treatment — every other day stays midnight-anchored.
    private var isToday: Bool {
        Calendar.current.isDateInToday(day.date)
    }

    /// The subset actually rendered.
    ///
    /// For TODAY: `hours` (per this type's own original doc note, still true) only contains
    /// entries from the current hour onward — WeatherKit's hourly forecast starts at "now," not
    /// midnight. Striding by INDEX from position 0 (the same "index 0 is now, every other entry
    /// after that" technique `HourlyForecastSection` itself uses for the main list — see that
    /// type's doc comment: "2-hour steps from now") therefore anchors row 1 at the current hour
    /// and runs every 2 hours to end of day, rather than snapping back to a midnight-aligned
    /// clock-hour grid that would either repeat hours already in the past or skip several hours
    /// ahead to the next even clock hour.
    ///
    /// For every other day: unchanged, midnight-anchored (`hour-of-day % stepHours == 0`) —
    /// 12AM, 2AM, 4AM, … — so a future day's grid always lands on the same clock slots
    /// regardless of what time "now" happens to be.
    private var displayedHours: [HourlyEntry] {
        if isToday {
            // User-reported defect fix: do NOT trust index 0 to be "now" — a cached payload's
            // hours start at fetch time, not the current hour. Anchor by wall clock instead
            // (same fix as `HourlyForecastSection.displayedIndices`).
            let currentHourStart = HourlyForecastSection.floorToHour(now)
            let start = hours.firstIndex { $0.date >= currentHourStart } ?? hours.count
            return Array(
                stride(from: start, to: hours.count, by: Self.stepHours)
                    .prefix(Self.displayedRowCount)
                    .map { hours[$0] }
            )
        }
        return Array(
            hours
                .filter { Calendar.current.component(.hour, from: $0.date) % Self.stepHours == 0 }
                .prefix(Self.displayedRowCount)
        )
    }

    /// Pill positions come from the FULL-resolution `hours` (every hour of the day), same
    /// honesty rule as the main hourly list — see `HourlyForecastSection.positions`.
    private var positions: [Date: Double] {
        PositionalPillTrack.positions(for: hours, metric: metric)
    }

    private var stargazingScores: [Date: StargazingScore.HourScore] {
        skyContext.stargazingScores(for: hours)
    }

    private var eventBuckets: [Date: HourlySkyEvents.Bucket] {
        skyContext.eventBuckets(displayedHours: displayedHours.map(\.date))
    }

    /// Unaffected by the 2-hour display subsetting: always the FULL day's hourly precip total.
    private var totalPrecip: Measurement<UnitLength> {
        hours.reduce(Measurement(value: 0, unit: UnitLength.inches)) { total, hour in
            total + hour.precipAmount.converted(to: .inches)
        }
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        return formatter
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            let rows = Array(displayedHours.enumerated())
            let scores = stargazingScores
            let buckets = eventBuckets
            // The expanded day's strip is independent of the main hourly list's — its own
            // first/last caps (`isFirst`/`isLast` below are scoped to THIS `rows` array), so an
            // expanded day always shows one complete, self-contained bar regardless of how the
            // main list above it happens to be capped.
            VStack(alignment: .leading, spacing: 0) {
                ForEach(rows, id: \.element.id) { index, hour in
                    ConditionStripRow(entry: hour, isFirst: index == 0, isLast: index == rows.count - 1) {
                        HourlyPillRow(
                            entry: hour,
                            // TODAY's grid starts at "now" (see `displayedHours`), so its first
                            // row is a real anchor row exactly like the main hourly list's —
                            // shows "Now" instead of a formatted time. Every other day stays
                            // midnight-anchored with no anchor row (every row is a real,
                            // formattable clock time).
                            isFirstRow: isToday && index == 0,
                            // Same displayed-subset condition-label rule as the main hourly
                            // list: the first displayed row is the anchor (always shows its
                            // condition); later rows only when different from the previous
                            // DISPLAYED row.
                            previousConditionDescription: index > 0 ? rows[index - 1].element.conditionDescription : nil,
                            metric: metric,
                            position: positions[hour.date] ?? 0.5,
                            stargazingScore: scores[hour.date],
                            eventBucket: buckets[hour.date],
                            onExplain: skyContext.onExplain
                        )
                        .padding(.leading, ConditionStripLayout.contentInset)
                    }
                }
            }

            Divider().padding(.vertical, 4)

            VStack(alignment: .leading, spacing: 6) {
                Label(
                    "Rain \(totalPrecip.formatted(.measurement(width: .narrow, numberFormatStyle: .number.precision(.fractionLength(2)))))",
                    systemImage: "drop"
                )
                if let sunrise = day.sunrise, let sunset = day.sunset {
                    Label(
                        "Daylight \(Self.timeFormatter.string(from: sunrise)) to \(Self.timeFormatter.string(from: sunset))",
                        systemImage: "sun.max"
                    )
                }
                Label(day.moonPhaseDescription, systemImage: "moon")
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
            .padding(.bottom, 4)
        }
        .padding(.leading, 8)
        .padding(.top, 4)
        // Fade only: a `.move(edge: .top)` here inserts the detail displaced ABOVE its final
        // frame, so during the expand animation it visibly slides over the day rows above
        // (user-reported defect). The clean unfold comes from the row's animated height +
        // `.clipped()` in `DailyForecastRow` — the detail just fades in beneath the row.
        .transition(.opacity)
    }
}

/// One row of the 10-day forecast: weekday, precip %, condition icon, low/high with the range
/// bar. Tapping expands it inline via `onTap`.
struct DailyForecastRow: View {
    @Environment(UnitsSettings.self) private var unitsSettings
    let day: DailyEntry
    let globalMin: Double
    let globalMax: Double
    let isExpanded: Bool
    let hourlyForDay: [HourlyEntry]
    var now: Date = Date()
    let metric: ForecastMetric
    var skyContext: HourlySkyContext = HourlySkyContext()
    /// Non-nil only for TODAY's row — see `DailyRangeBar.currentTemperatureF`.
    var currentTemperatureF: Double? = nil
    let onTap: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Button(action: onTap) {
                HStack(spacing: 8) {
                    Text(day.date.formatted(.dateTime.weekday(.abbreviated)).uppercased())
                        .font(.subheadline.weight(.semibold))
                        .frame(width: 40, alignment: .leading)

                    Text(day.precipChance > 0.01 ? "\(Int((day.precipChance * 100).rounded()))%" : "")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(Color.clearSkyAccent)
                        .frame(width: 32, alignment: .leading)

                    Image(systemName: day.symbolName)
                        .symbolRenderingMode(.multicolor)
                        .frame(width: 22)

                    Text(TemperatureFormatting.string(day.low, unit: unitsSettings.unit))
                        .font(.subheadline)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 36, alignment: .trailing)

                    DailyRangeBar(
                        low: day.low.converted(to: .fahrenheit).value,
                        high: day.high.converted(to: .fahrenheit).value,
                        globalMin: globalMin,
                        globalMax: globalMax,
                        currentTemperatureF: currentTemperatureF
                    )

                    Text(TemperatureFormatting.string(day.high, unit: unitsSettings.unit))
                        .font(.subheadline.weight(.semibold))
                        .monospacedDigit()
                        .frame(width: 36, alignment: .trailing)

                    Image(systemName: "chevron.down")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isExpanded ? 180 : 0))
                }
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(PressableRowStyle())

            if isExpanded {
                DailyExpandedDetail(day: day, hours: hourlyForDay, metric: metric, skyContext: skyContext, now: now)
            }
        }
        // Masks the expanding detail to the cell's animated bounds so the reveal unfolds in
        // place under the weekday row instead of painting over neighboring rows mid-animation.
        .clipped()
    }
}

/// PRD Section 6, item 8: 10-day forecast with expandable day rows.
struct DailyForecastSection: View {
    let daily: [DailyEntry]
    /// Wall-clock now, injected for today's now-anchored expansion (see DailyExpandedDetail).
    var now: Date = Date()
    let hourly: [HourlyEntry]
    let metric: ForecastMetric
    var skyContext: HourlySkyContext = HourlySkyContext()
    @Binding var expandedDayId: Date?
    /// Today's actual current temperature (`CachedWeather.currentConditions.temperature`) —
    /// threaded through so `DailyRangeBar` can plot a "current temp" dot on TODAY's row only.
    /// Optional/defaulted so existing callers/previews that don't have it keep compiling.
    var currentTemperature: Measurement<UnitTemperature>? = nil

    private static let dayLimit = 10

    private var limitedDaily: [DailyEntry] {
        Array(daily.prefix(Self.dayLimit))
    }

    private var globalMin: Double {
        limitedDaily.map { $0.low.converted(to: .fahrenheit).value }.min() ?? 0
    }

    private var globalMax: Double {
        limitedDaily.map { $0.high.converted(to: .fahrenheit).value }.max() ?? 1
    }

    var body: some View {
        // UX redesign part 1: the "10-Day Forecast" headline used to render here; it's now the
        // small uppercase "DAILY FORECAST" header provided by the enclosing card chrome
        // (`ForecastSheetCard` in `ForecastPageView`), so this view renders rows only.
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(limitedDaily.enumerated()), id: \.element.id) { index, day in
                DailyForecastRow(
                    day: day,
                    globalMin: globalMin,
                    globalMax: globalMax,
                    isExpanded: expandedDayId == day.date,
                    hourlyForDay: hourly.filter { Calendar.current.isDate($0.date, inSameDayAs: day.date) },
                    now: now,
                    metric: metric,
                    skyContext: skyContext,
                    currentTemperatureF: Calendar.current.isDateInToday(day.date)
                        ? currentTemperature?.converted(to: .fahrenheit).value
                        : nil,
                    onTap: {
                        // UX polish package ("Depth & motion"): a spring replaces the default
                        // implicit animation for the expand/collapse transition.
                        withAnimation(.spring(duration: 0.35)) {
                            expandedDayId = (expandedDayId == day.date) ? nil : day.date
                        }
                    }
                )
                .id(Self.rowId(for: day))
                if index < limitedDaily.count - 1 {
                    Divider()
                }
            }
        }
    }

    /// Sim-verify only: a stable scroll-target id for `ScrollViewProxy.scrollTo` (see
    /// `ForecastView`'s auto-expand + auto-scroll for `-expandDay`). Namespaced separately from
    /// `HourlyForecastSection.rowId` so a daily date can never collide with an hourly one.
    static func rowId(for day: DailyEntry) -> String {
        "daily-\(day.date.timeIntervalSince1970)"
    }
}
