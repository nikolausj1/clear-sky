import SwiftUI

/// Header space-event layer: a quiet, static contrail easter egg on days a `.go`-status launch's
/// T-0 falls today. Dawn/day/dusk only — per work order, "night sky is busy enough" (the true-sky
/// doodle already owns the night scene's attention). A thin diagonal line fading toward its tail
/// with a small bright dot at the head (reads as "climbing away from the ground, upper third of
/// the scene"), deliberately understated — an easter egg for anyone who notices, not a banner
/// announcing the day's launch (that's the Space tab's job — see `SpaceView`'s next-launch hero).
///
/// Static, no animation at all (matches `SpecialDayOverlayLayer`'s non-animated badges more than
/// `TrueSkyLayer`'s single-sweep ISS streak) — a launch is a whole-day fact, not a passing event
/// to sweep across the screen once per render.
struct LaunchContrailLayer: View {
    let timeOfDay: DoodleComposer.TimeOfDay
    let hasGoLaunchToday: Bool

    private var isEligible: Bool {
        hasGoLaunchToday && (timeOfDay == .dawn || timeOfDay == .day || timeOfDay == .dusk)
    }

    /// Upper-third placement, angled up-and-away toward the right — an arbitrary but fixed
    /// direction (this is decoration, not a real trajectory) chosen so the trail reads as
    /// "climbing," not falling.
    private static let tailXFraction: CGFloat = 0.30
    private static let tailYFraction: CGFloat = 0.30
    private static let headXFraction: CGFloat = 0.58
    private static let headYFraction: CGFloat = 0.14

    var body: some View {
        if isEligible {
            GeometryReader { proxy in
                let tail = CGPoint(x: proxy.size.width * Self.tailXFraction, y: proxy.size.height * Self.tailYFraction)
                let head = CGPoint(x: proxy.size.width * Self.headXFraction, y: proxy.size.height * Self.headYFraction)

                Path { path in
                    path.move(to: tail)
                    path.addLine(to: head)
                }
                .stroke(
                    LinearGradient(
                        colors: [Color.white.opacity(0), Color.white.opacity(0.45)],
                        startPoint: .leading,
                        endPoint: .trailing
                    ),
                    style: StrokeStyle(lineWidth: 1.4, lineCap: .round)
                )

                Circle()
                    .fill(
                        RadialGradient(
                            colors: [Color.white.opacity(0.85), Color.white.opacity(0)],
                            center: .center,
                            startRadius: 0,
                            endRadius: 7
                        )
                    )
                    .frame(width: 14, height: 14)
                    .position(head)

                Circle()
                    .fill(Color.white.opacity(0.9))
                    .frame(width: 2.5, height: 2.5)
                    .position(head)
            }
            .allowsHitTesting(false)
        }
    }
}
