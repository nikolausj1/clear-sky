import SwiftUI

/// PRD Section 6, item 9 / Section 9: Apple Weather attribution, visible on the Forecast screen
/// "without any additional tap or scroll gate." A footer at the end of the scroll content
/// satisfies that per the PRD's own note ("a footer at the end of the scroll content is
/// acceptable and standard").
///
/// Renders the official Apple Weather mark (light/dark aware, via `WeatherAttributionInfo`'s
/// `combinedMarkLightURL`/`combinedMarkDarkURL`) rather than plain text, per Apple's attribution
/// guidelines — falling back to the plain "Weather data provided by <serviceName>" text if the
/// mark image hasn't loaded (or fails to), so attribution is never silently missing.
struct AttributionFooter: View {
    @Environment(\.colorScheme) private var colorScheme
    let attribution: WeatherAttributionInfo

    private var markURL: URL {
        colorScheme == .dark ? attribution.combinedMarkDarkURL : attribution.combinedMarkLightURL
    }

    var body: some View {
        Link(destination: attribution.legalPageURL) {
            VStack(spacing: 6) {
                AsyncImage(url: markURL) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFit()
                            .frame(height: 20)
                    default:
                        Text("Weather data provided by \(attribution.serviceName)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Text("Legal")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
    }
}
