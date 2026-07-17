import SwiftUI

/// The horizontal low/high range bar for one daily row (PRD Section 6, item 8; see
/// `IMG_1174.png`). The full track represents the 10-day min-to-max span; this day's segment
/// is positioned within it at `(low, high)`.
struct DailyRangeBar: View {
    let low: Double
    let high: Double
    let globalMin: Double
    let globalMax: Double

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let range = max(globalMax - globalMin, 1)
            let startX = ((low - globalMin) / range) * width
            let endX = ((high - globalMin) / range) * width
            let segmentWidth = max(endX - startX, 6)

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color(.systemGray5))
                    .frame(height: 6)

                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [.blue.opacity(0.55), .orange.opacity(0.75)],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: segmentWidth, height: 6)
                    .offset(x: startX)
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
        .transition(.opacity.combined(with: .move(edge: .top)))
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
                        .foregroundStyle(.blue)
                        .frame(width: 32, alignment: .leading)

                    Image(systemName: day.symbolName)
                        .symbolRenderingMode(.multicolor)
                        .frame(width: 22)

                    Text(TemperatureFormatting.string(day.low, unit: unitsSettings.unit))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(width: 36, alignment: .trailing)

                    DailyRangeBar(
                        low: day.low.converted(to: .fahrenheit).value,
                        high: day.high.converted(to: .fahrenheit).value,
                        globalMin: globalMin,
                        globalMax: globalMax
                    )

                    Text(TemperatureFormatting.string(day.high, unit: unitsSettings.unit))
                        .font(.subheadline.weight(.semibold))
                        .frame(width: 36, alignment: .trailing)

                    Image(systemName: "chevron.down")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isExpanded ? 180 : 0))
                }
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                DailyExpandedDetail(day: day, hours: hourlyForDay, metric: metric)
            }
        }
    }
}

/// PRD Section 6, item 8: 10-day forecast with expandable day rows.
struct DailyForecastSection: View {
    let daily: [DailyEntry]
    let hourly: [HourlyEntry]
    let metric: ForecastMetric
    @Binding var expandedDayId: Date?

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
                    onTap: {
                        withAnimation {
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
