import SwiftUI

/// PRD Section 6, item 2: "Large current temperature, feels-like temperature, condition text."
struct CurrentConditionsView: View {
    let current: CurrentConditions

    var body: some View {
        VStack(spacing: 2) {
            Text(ForecastMetric.formattedTemp(current.temperature))
                .font(.system(size: 64, weight: .thin))
                .foregroundStyle(.primary)
            Text("Feels like \(ForecastMetric.formattedTemp(current.feelsLike))")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text(current.conditionDescription)
                .font(.headline)
                .foregroundStyle(.primary)
        }
        .frame(maxWidth: .infinity)
    }
}

/// PRD Section 6, items 4-5: the dry-wit summary and comparison lines are Phase 4 (phrase
/// bank) content. This phase renders neutral placeholder slots only — no invented copy.
struct PlaceholderCopyLines: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Phase 4: phrase bank fills the summary line here.
            Text("\u{2014}")
            // Phase 4: phrase bank fills the comparison line here.
            Text("\u{2014}")
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
