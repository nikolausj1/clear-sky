import SwiftUI

/// PRD Section 6, item 9 / Section 9: Apple Weather attribution, visible on the Forecast screen
/// "without any additional tap or scroll gate." A footer at the end of the scroll content
/// satisfies that per the PRD's own note ("a footer at the end of the scroll content is
/// acceptable and standard").
///
/// Header/chrome refinements (work package "five UI refinements", item 2): minimized to one
/// discreet, tappable caption line — the required trademark stays present as text (the Apple
/// logo glyph, `U+F8FF`, paired with the service name — the standard text-only substitute for
/// Apple's combined image mark when a compact single line is wanted), it just no longer
/// competes visually with the hero/sheet content below it. The previous `AsyncImage`-loaded
/// combined mark (light/dark aware) is gone; Settings (`SettingsView`) keeps its own fuller
/// attribution block unchanged — this is Forecast-surface only.
struct AttributionFooter: View {
    let attribution: WeatherAttributionInfo

    var body: some View {
        Link(destination: attribution.legalPageURL) {
            Text("\u{F8FF} \(attribution.serviceName) · Legal")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
                .multilineTextAlignment(.center)
        }
        .buttonStyle(.plain)
        .padding(.vertical, 20)
    }
}
