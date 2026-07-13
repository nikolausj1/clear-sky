import SwiftUI

/// PRD Section 6, item 9 / Section 9: Apple Weather attribution, visible on the Forecast screen
/// "without any additional tap or scroll gate." A footer at the end of the scroll content
/// satisfies that per the PRD's own note ("a footer at the end of the scroll content is
/// acceptable and standard").
struct AttributionFooter: View {
    let attribution: WeatherAttributionInfo

    var body: some View {
        VStack(spacing: 4) {
            Text("Weather data provided by \(attribution.serviceName)")
                .font(.caption)
                .foregroundStyle(.secondary)
            Link(destination: attribution.legalPageURL) {
                Text("Legal")
                    .font(.caption.weight(.medium))
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
    }
}
