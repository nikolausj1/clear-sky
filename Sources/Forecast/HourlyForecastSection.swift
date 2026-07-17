import SwiftUI

/// One row of the hourly list: time label, a condition-change label shown only when the
/// condition differs from the previous row, and a positional pill on a full-width track (PRD
/// Section 6, item 7 + the "Positional pill spec"). `position` is the pre-computed, clamped
/// `[0, 1]` value from `PositionalPillTrack`.
struct HourlyPillRow: View {
    @Environment(UnitsSettings.self) private var unitsSettings
    let entry: HourlyEntry
    /// UX redesign part 2: the main hourly list's anchor row reads "Now" instead of a formatted
    /// time — this is the only row that isn't a real 2-hour step, so it's called out explicitly
    /// rather than trying to make "h a" produce that string. `DailyExpandedDetail`'s
    /// midnight-anchored grid never sets this (every one of its rows is a real, formattable time).
    var isFirstRow: Bool = false
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

    private var timeLabel: String {
        isFirstRow ? "Now" : Self.hourFormatter.string(from: entry.date)
    }

    var body: some View {
        HStack(spacing: 10) {
            Text(timeLabel)
                .font(.subheadline)
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
///
/// UX redesign part 2 (density pass): renders 2-hour steps starting at the current hour, 12 rows
/// total (the next 24 hours) — see `IMG_1173.png`. `hours` is assumed to already start at the
/// current hour (that's how `WeatherKit`'s `hourlyForecast.forecast` — and therefore
/// `CachedWeather.hourly` — is ordered; see `WeatherService.fetchWeather`), so "every other
/// entry starting at index 0" is exactly "2-hour steps from now."
struct HourlyForecastSection: View {
    let hours: [HourlyEntry]
    let metric: ForecastMetric

    static let stepHours = 2
    static let displayedRowCount = 12

    /// The subset actually rendered: every `stepHours`-th entry of `hours`, capped at
    /// `displayedRowCount` rows. Index 0 (the anchor/"Now" row) is always included.
    private var displayedHours: [HourlyEntry] {
        Self.displayedIndices(for: hours).map { hours[$0] }
    }

    /// Pill positions are computed from the FULL-resolution hourly data — every hour of each
    /// calendar day, not just the displayed 2-hour subset — so the day's min/max (and therefore
    /// each pill's position) stays honest regardless of how sparsely the list renders rows. See
    /// `PositionalPillTrack`'s doc comment for the per-day normalization this relies on.
    private var positions: [Date: Double] {
        PositionalPillTrack.positions(for: hours, metric: metric)
    }

    var body: some View {
        // UX redesign part 1: the "Hourly Forecast" headline used to render here; it's now the
        // small uppercase header provided by the enclosing card chrome
        // (`ForecastSheetCard` in `ForecastPageView`), so this view renders rows only.
        VStack(alignment: .leading, spacing: 0) {
            let rows = Array(displayedHours.enumerated())
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

    /// The indices into the FULL `hours` array that get rendered as rows: `0, stepHours,
    /// 2*stepHours, ...` up to `displayedRowCount` entries (clamped to however many hours exist).
    static func displayedIndices(for hours: [HourlyEntry]) -> [Int] {
        Array(stride(from: 0, to: hours.count, by: stepHours).prefix(displayedRowCount))
    }

    /// Sim-verify only: `-scrollToHour N` used to index straight into the (1-hour-resolution)
    /// `hours` array. Now that the list only renders every `stepHours`-th entry, `N` is
    /// reinterpreted as the Nth DISPLAYED row and remapped back to its real index in `hours`
    /// (clamped to the actual displayed range), so the launch arg still lands on a visible row.
    static func hourlyIndex(forDisplayedRow displayedRow: Int, hours: [HourlyEntry]) -> Int? {
        let indices = displayedIndices(for: hours)
        guard !indices.isEmpty else { return nil }
        let clamped = max(0, min(displayedRow, indices.count - 1))
        return indices[clamped]
    }
}
