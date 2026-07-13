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
struct DailyExpandedDetail: View {
    let day: DailyEntry
    let hours: [HourlyEntry]
    let metric: ForecastMetric

    private var positions: [Date: Double] {
        PositionalPillTrack.positions(for: hours, metric: metric)
    }

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
            let rows = Array(hours.enumerated())
            ForEach(rows, id: \.element.id) { index, hour in
                HourlyPillRow(
                    entry: hour,
                    previousConditionDescription: index > 0 ? hours[index - 1].conditionDescription : nil,
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

                    Text(ForecastMetric.formattedTemp(day.low))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(width: 36, alignment: .trailing)

                    DailyRangeBar(
                        low: day.low.converted(to: .fahrenheit).value,
                        high: day.high.converted(to: .fahrenheit).value,
                        globalMin: globalMin,
                        globalMax: globalMax
                    )

                    Text(ForecastMetric.formattedTemp(day.high))
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
        VStack(alignment: .leading, spacing: 0) {
            Text("10-Day Forecast")
                .font(.headline)
                .padding(.bottom, 8)

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
