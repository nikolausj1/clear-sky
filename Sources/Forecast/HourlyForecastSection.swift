import SwiftUI

/// One row of the hourly list: time label, a condition-change label shown only when the
/// condition differs from the previous row, and a positional pill on a full-width track (PRD
/// Section 6, item 7 + the "Positional pill spec"). `position` is the pre-computed, clamped
/// `[0, 1]` value from `PositionalPillTrack`.
struct HourlyPillRow: View {
    @Environment(UnitsSettings.self) private var unitsSettings
    let entry: HourlyEntry
    let previousConditionDescription: String?
    let metric: ForecastMetric
    let position: Double

    private static let hourFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "h a"
        return formatter
    }()

    private var showsConditionLabel: Bool {
        entry.conditionDescription != previousConditionDescription
    }

    var body: some View {
        HStack(spacing: 10) {
            Text(Self.hourFormatter.string(from: entry.date))
                .font(.subheadline)
                .frame(width: 52, alignment: .leading)

            Text(showsConditionLabel ? entry.conditionDescription : "")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(width: 78, alignment: .leading)
                .lineLimit(1)
                .minimumScaleFactor(0.8)

            GeometryReader { proxy in
                let pillWidth: CGFloat = 56
                let travel = max(proxy.size.width - pillWidth, 0)
                ZStack(alignment: .leading) {
                    Rectangle()
                        .fill(Color.secondary.opacity(0.25))
                        .frame(height: 1)
                        .frame(maxWidth: .infinity)

                    Text(metric.displayString(for: entry, unit: unitsSettings.unit))
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .padding(.horizontal, 8)
                        .frame(width: pillWidth, height: 30)
                        .background(Capsule().fill(Color(.secondarySystemFill)))
                        .offset(x: travel * position)
                }
                .frame(maxHeight: .infinity, alignment: .center)
            }
            .frame(height: 30)
        }
        .padding(.vertical, 5)
    }
}

/// PRD Section 6, item 7: "Hourly forecast list ... Show ~24-48 hours."
struct HourlyForecastSection: View {
    let hours: [HourlyEntry]
    let metric: ForecastMetric

    private static let displayLimit = 48

    private var limitedHours: [HourlyEntry] {
        Array(hours.prefix(Self.displayLimit))
    }

    private var positions: [Date: Double] {
        PositionalPillTrack.positions(for: limitedHours, metric: metric)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Hourly Forecast")
                .font(.headline)
                .padding(.bottom, 8)

            let rows = Array(limitedHours.enumerated())
            ForEach(rows, id: \.element.id) { index, entry in
                HourlyPillRow(
                    entry: entry,
                    previousConditionDescription: index > 0 ? limitedHours[index - 1].conditionDescription : nil,
                    metric: metric,
                    position: positions[entry.date] ?? 0.5
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
}
