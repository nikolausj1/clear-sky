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
            Text(metric.title)
                .font(.subheadline.weight(.medium))
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(
                    Capsule().fill(isSelected ? Color.accentColor : Color.clear)
                )
                .overlay(
                    Capsule().stroke(Color.accentColor, lineWidth: isSelected ? 0 : 1.25)
                )
                .foregroundStyle(isSelected ? Color.white : Color.accentColor)
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    MetricChipsRow(selected: .constant(.temp))
        .padding()
}
