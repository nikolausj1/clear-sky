import SwiftUI

/// Current-month moon-phase grid for the Space tab's MOON CALENDAR card (engine-integration work
/// package). Pure on-device computation — `SunMoon.moonPhase(date:)` sampled once at local noon
/// per day of the month, same sampling convention `SkyCalendar.moonPhaseEvents` already uses for
/// its own full/new-moon day detection, just rendered as a full grid here instead of picking out
/// the two extremes.
///
/// v1, deliberately: current month only, no prev/next navigation (per work order) — `referenceDate`
/// is always "now" (or a `-forceDate` override), so there's no state to page through yet.
struct MoonCalendarGrid: View {
    let referenceDate: Date
    let timeZone: TimeZone

    private var calendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        return cal
    }

    private static let columns = Array(repeating: GridItem(.flexible(), spacing: 2), count: 7)
    private static let weekdaySymbols = ["S", "M", "T", "W", "T", "F", "S"]

    private static let monthFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMMM yyyy"
        return formatter
    }()

    /// One entry per grid cell: `nil` for the leading blanks before the 1st falls on the correct
    /// weekday column, a real calendar `Date` (local midnight) for every day of the month.
    private var monthCells: [Date?] {
        guard let monthInterval = calendar.dateInterval(of: .month, for: referenceDate) else { return [] }
        let firstDay = monthInterval.start
        // `weekday` is 1 = Sunday...7 = Saturday, matching this grid's Sunday-first header row.
        let leadingBlanks = calendar.component(.weekday, from: firstDay) - 1
        let daysInMonth = calendar.range(of: .day, in: .month, for: referenceDate)?.count ?? 30

        var cells: [Date?] = Array(repeating: nil, count: max(0, leadingBlanks))
        for offset in 0..<daysInMonth {
            if let day = calendar.date(byAdding: .day, value: offset, to: firstDay) {
                cells.append(day)
            }
        }
        return cells
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(Self.monthFormatter.string(from: referenceDate))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)

            LazyVGrid(columns: Self.columns, spacing: 4) {
                ForEach(Self.weekdaySymbols.indices, id: \.self) { index in
                    Text(Self.weekdaySymbols[index])
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Color.white.opacity(0.4))
                        .frame(maxWidth: .infinity)
                }
            }

            LazyVGrid(columns: Self.columns, spacing: 6) {
                ForEach(Array(monthCells.enumerated()), id: \.offset) { _, day in
                    if let day {
                        dayCell(day)
                    } else {
                        Color.clear.frame(height: 32)
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }

    /// One day's mini `MoonPhaseDisc` (12pt, spec) + day number below it. Today is ringed in the
    /// app accent; full/new-moon days (illuminated fraction within 3% of either extreme) render
    /// slightly bolder/brighter, both text and disc, as the spec's "subtly emphasized" ask.
    private func dayCell(_ day: Date) -> some View {
        let sampleInstant = calendar.date(byAdding: .hour, value: 12, to: day) ?? day
        let phase = SunMoon.moonPhase(date: sampleInstant)
        let isToday = calendar.isDate(day, inSameDayAs: referenceDate)
        let isExtremePhase = phase.illuminatedFraction >= 0.97 || phase.illuminatedFraction <= 0.03
        let dayNumber = calendar.component(.day, from: day)

        return VStack(spacing: 3) {
            MoonPhaseDisc(
                illumination: phase.illuminatedFraction,
                waxing: phase.waxing,
                diameter: 12,
                style: .dark,
                showsRim: phase.illuminatedFraction <= 0.03
            )
            .opacity(isExtremePhase ? 1.0 : 0.8)
            .overlay {
                if isToday {
                    Circle()
                        .stroke(Color.clearSkyAccentOnDark, lineWidth: 1.5)
                        .frame(width: 18, height: 18)
                }
            }
            Text("\(dayNumber)")
                .font(.caption2)
                .fontWeight(isExtremePhase ? .semibold : .regular)
                .monospacedDigit()
                .foregroundStyle(isExtremePhase ? .white : Color.white.opacity(0.55))
        }
        .frame(maxWidth: .infinity)
    }
}
