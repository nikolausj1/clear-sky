import SwiftUI

/// The all-dark Space tab's shared chrome (work package: "Space tab redesign — the whole Space
/// screen goes dark in both modes"). Deliberately its own small file rather than folded into
/// `SpaceView.swift` — these three pieces (background, panel card, hairline divider) are used by
/// every card on the screen, including the new next-launch hero.
///
/// **Why not reuse `TonightSkyCard`'s private `NightPanelBackground`/divider directly:** that
/// type is `private` to `TonightSkyCard.swift` by design (that card's doc comment: "this card's
/// chrome ... is bespoke; every other card in the app keeps using `SheetCard` unchanged" — true
/// when it was written, since the Space tab was still light). Rather than widening that card's
/// private access for a second, textually-different use (this background needs to tile edge to
/// edge behind an entire scrollable screen with SPARSER stars, not one compact card), this is a
/// new, independent view sharing only the same two gradient color stops by deliberate constant
/// duplication — a color choice, not shared logic, so duplicating it doesn't create a
/// maintenance hazard the way duplicating real logic would.
struct SpaceDarkBackground: View {
    /// Same deep-indigo stops as the night panel (`TonightSkyCard.NightPanelBackground`) — the
    /// work order's own instruction: "background = the night panel's deep-indigo gradient".
    private static let topColor = Color(red: 13.0 / 255.0, green: 17.0 / 255.0, blue: 42.0 / 255.0)
    private static let bottomColor = Color(red: 24.0 / 255.0, green: 30.0 / 255.0, blue: 66.0 / 255.0)

    /// Sparser than the night panel's ~14 specks over a compact card — spread thin across an
    /// entire screen so they read as ambient texture, not as a busy pattern competing with the
    /// cards on top of them.
    private static let starPositions: [(CGFloat, CGFloat, CGFloat, Double)] = [
        (0.08, 0.04, 1.2, 0.30), (0.32, 0.10, 1.0, 0.25), (0.62, 0.06, 1.3, 0.35),
        (0.85, 0.14, 1.0, 0.28), (0.18, 0.22, 1.0, 0.22), (0.48, 0.28, 1.2, 0.30),
        (0.75, 0.30, 1.0, 0.25), (0.05, 0.42, 1.0, 0.22), (0.92, 0.44, 1.2, 0.30),
        (0.38, 0.52, 1.0, 0.25), (0.60, 0.60, 1.0, 0.20), (0.15, 0.65, 1.2, 0.28),
        (0.82, 0.70, 1.0, 0.22), (0.28, 0.80, 1.0, 0.25), (0.55, 0.86, 1.2, 0.30),
        (0.90, 0.90, 1.0, 0.22), (0.10, 0.95, 1.0, 0.25),
    ]

    var body: some View {
        ZStack {
            LinearGradient(colors: [Self.topColor, Self.bottomColor], startPoint: .top, endPoint: .bottom)
            GeometryReader { proxy in
                ForEach(Array(Self.starPositions.enumerated()), id: \.offset) { _, star in
                    Circle()
                        .fill(Color.white.opacity(star.3))
                        .frame(width: star.2, height: star.2)
                        .position(x: proxy.size.width * star.0, y: proxy.size.height * star.1)
                }
            }
        }
        .ignoresSafeArea()
    }
}

/// A dark-surface panel card — the Space tab's stand-in for `SheetCard` (which resolves to a
/// light `.secondarySystemGroupedBackground` fill unsuited to this screen's always-dark identity;
/// per work order, every Space card becomes "slightly-lighter indigo panels: white 0.06 fill,
/// 16pt radius").
struct SpacePanelCard<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.footnote.weight(.semibold))
                .tracking(0.8)
                .foregroundStyle(Color.white.opacity(0.55))
            SpaceHairlineDivider()
            content
        }
        .padding(16)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

/// Hairline row/section separator, white 0.12 per work order — the Space-tab equivalent of
/// `TonightSkyCard.nightDivider` (that one is `private` to its own file; duplicated here as a
/// tiny, independent view for the same "shared color constant, not shared logic" reason
/// `SpaceDarkBackground`'s doc comment gives).
struct SpaceHairlineDivider: View {
    var body: some View {
        Rectangle()
            .fill(Color.white.opacity(0.12))
            .frame(height: 1)
    }
}
