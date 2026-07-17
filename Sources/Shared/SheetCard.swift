import SwiftUI

/// A white (`.secondarySystemGroupedBackground`, so dark mode inverts correctly) rounded card on
/// a `.systemGroupedBackground` sheet surface, with a small tracked uppercase header and a
/// hairline divider — originally Forecast-only chrome (`ForecastPageView`'s hourly/daily cards);
/// the UX polish package promotes it to a shared component so Rankings' ranked list adopts the
/// identical card look (cross-screen consistency: same corner radius, same header tracking).
struct SheetCard<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    @Environment(\.colorScheme) private var colorScheme

    static var cornerRadius: CGFloat { 16 }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.footnote.weight(.semibold))
                .tracking(0.8)
                .foregroundStyle(.secondary)
            Divider()
            content
        }
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous))
        // UX polish package ("depth & motion"): a soft card shadow in light mode only — dark
        // mode's already-dark surface makes a black shadow read as a muddy smudge rather than
        // depth, so it's skipped there.
        .shadow(color: colorScheme == .dark ? .clear : .black.opacity(0.05), radius: 8, y: 2)
    }
}
