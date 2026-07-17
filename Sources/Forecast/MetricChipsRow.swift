import SwiftUI

/// PRD Section 6, item 6: horizontally scrollable segmented chip selector (Temp, Precip
/// Chance, Precip Amount, Feels Like, Wind, UV) that drives what the hourly list's pill shows.
struct MetricChipsRow: View {
    @Binding var selected: ForecastMetric

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(ForecastMetric.allCases) { metric in
                    chip(for: metric)
                }
            }
            .padding(.vertical, 2)
        }
    }

    private func chip(for metric: ForecastMetric) -> some View {
        let isSelected = selected == metric
        return Button {
            selected = metric
        } label: {
            HStack(spacing: 4) {
                Image(systemName: metric.symbolName)
                    .font(.caption2)
                Text(metric.title)
                    .font(.subheadline.weight(.medium))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            // UX polish package ("Data-mark discipline"): unselected chips drop the outline
            // stroke entirely in favor of a flat `tertiarySystemFill` background — cleaner than
            // the previous bordered-capsule look, and consistent with the hourly pills' neutral
            // fill treatment.
            .background(
                Capsule().fill(isSelected ? Color.clearSkyAccent : Color(.tertiarySystemFill))
            )
            .foregroundStyle(isSelected ? Color.white : Color.primary)
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    MetricChipsRow(selected: .constant(.temp))
        .padding()
}
