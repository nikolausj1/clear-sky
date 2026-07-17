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
/// UX redesign part 2 (density pass): renders 2-hour steps anchored to midnight — 12AM, 2AM, …
/// 10PM (see `IMG_1176.png`) — rather than every hour. The grid is anchored to the clock hour
/// (`hour-of-day % stepHours == 0`), not to "first entry in `hours`," so it lands on the same
/// 12/2/4/…-o'clock slots for every day INCLUDING today: today's `hours` (passed in by
/// `DailyForecastSection`) only contains entries from the current hour onward (WeatherKit's
/// hourly forecast starts at "now," not midnight — see `WeatherService.fetchWeather`), so early
/// slots before the current hour simply have no matching entry and are skipped; the grid itself
/// never shifts to a "from now" basis the way the main hourly list's does.
struct DailyExpandedDetail: View {
    let day: DailyEntry
    /// The FULL day's hourly entries (every hour WeatherKit returned for this calendar day, not
    /// just the displayed 2-hour subset) — needed as-is for the rain total below and for
    /// `positions`' per-day min/max.
    let hours: [HourlyEntry]
    let metric: ForecastMetric

    private static let stepHours = HourlyForecastSection.stepHours
    private static let displayedRowCount = HourlyForecastSection.displayedRowCount

    /// The subset actually rendered: entries whose hour-of-day is a multiple of `stepHours`
    /// (12AM, 2AM, 4AM, …), capped at `displayedRowCount` rows.
    private var displayedHours: [HourlyEntry] {
        Array(
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
            ForEach(rows, id: \.element.id) { index, hour in
                HourlyPillRow(
                    entry: hour,
                    // Same displayed-subset condition-label rule as the main hourly list: the
                    // first displayed row is the anchor (always shows its condition); later rows
                    // only when different from the previous DISPLAYED row.
                    previousConditionDescription: index > 0 ? rows[index - 1].element.conditionDescription : nil,
                    metric: metric,
                    position: positions[hour.date] ?? 0.5
                )
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
    let metric: ForecastMetric
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
                DailyExpandedDetail(day: day, hours: hourlyForDay, metric: metric)
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
    let hourly: [HourlyEntry]
    let metric: ForecastMetric
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
                    metric: metric,
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
