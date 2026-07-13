import SwiftUI

/// PRD Section 6, item 2: "Large current temperature, feels-like temperature, condition text."
struct CurrentConditionsView: View {
    @Environment(UnitsSettings.self) private var unitsSettings
    let current: CurrentConditions

    var body: some View {
        VStack(spacing: 2) {
            Text(TemperatureFormatting.string(current.temperature, unit: unitsSettings.unit))
                .font(.system(size: 64, weight: .thin))
                .foregroundStyle(.primary)
            Text("Feels like \(TemperatureFormatting.string(current.feelsLike, unit: unitsSettings.unit))")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text(current.conditionDescription)
                .font(.headline)
                .foregroundStyle(.primary)
        }
        .frame(maxWidth: .infinity)
    }
}

/// PRD Section 6, items 4-5: the dry-wit summary line and the yesterday-comparison line,
/// both filled from the Phase 4 phrase bank (`PhraseBank.swift`). `comparison` is `nil`
/// whenever `ForecastViewModel.comparisonLine` has no yesterday reference point yet (first
/// day of use) — PRD: "the line is omitted rather than faked," so this view renders only the
/// summary line in that case rather than an empty second line.
struct CopyLinesView: View {
    let summary: String
    let comparison: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(summary)
            if let comparison {
                Text(comparison)
            }
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
