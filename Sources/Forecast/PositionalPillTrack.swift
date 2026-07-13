import Foundation

/// Implements PRD Section 6's "Positional pill spec" for the hourly list: each row's pill sits
/// at `(value - dayMin) / (dayMax - dayMin)` clamped to `[0, 1]` along a track scoped to the
/// calendar day containing that hour — so the track recalculates at each midnight boundary
/// within the scrolling list, exactly as the spec describes.
enum PositionalPillTrack {
    /// Returns each entry's clamped `[0, 1]` position for `metric`, grouped and normalized
    /// per calendar day.
    static func positions(
        for entries: [HourlyEntry],
        metric: ForecastMetric,
        calendar: Calendar = .current
    ) -> [Date: Double] {
        var result: [Date: Double] = [:]
        let groupedByDay = Dictionary(grouping: entries) { calendar.startOfDay(for: $0.date) }

        for (_, dayEntries) in groupedByDay {
            let values = dayEntries.map { metric.numericValue(for: $0) }
            var dayMin = values.min() ?? 0
            var dayMax = values.max() ?? 0

            if let minimumCeiling = metric.flooredMinimumCeiling {
                // Precip metrics: floor is always 0, ceiling is the day's max or a small
                // non-zero minimum so an all-zero day doesn't produce a degenerate track.
                dayMin = 0
                dayMax = max(dayMax, minimumCeiling)
            }

            let range = dayMax - dayMin
            for entry in dayEntries {
                let value = metric.numericValue(for: entry)
                let position: Double
                if range <= 0 {
                    // Flat day (every hour identical) — center the pill rather than divide by zero.
                    position = 0.5
                } else {
                    position = ((value - dayMin) / range).clamped(to: 0...1)
                }
                result[entry.date] = position
            }
        }

        return result
    }
}

private extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
