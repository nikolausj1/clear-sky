import SwiftUI

/// Doodle layer 3, "Weather condition layer" (PRD Section 7): "visual elements for the current
/// condition (sun, cloud cover, rain, snow, fog), drawn as simple shapes/gradients." Sun/moon
/// live in `TimeOfDayLightingLayer` (their position/color is a time-of-day concern; this layer
/// only dims them — see `CelestialBody.opacity`). This file covers clouds, precipitation, fog,
/// and a storm's lightning accent.
///
/// Split into two view structs for correct paint order in `DoodleSceneView`: `WeatherClouds`
/// sits *behind* the hills (drifting across the sky), `WeatherPrecipitation` sits *in front of*
/// the hills (rain/snow falling toward the viewer, fog washing over the ground). Both are
/// no-ops for `.clear`.
struct WeatherClouds: View {
    let condition: DoodleComposer.ConditionCategory

    private static let puffs: [(CGFloat, CGFloat, CGFloat)] = [
        (0.16, 0.22, 1.0), (0.46, 0.14, 0.75), (0.74, 0.26, 0.9),
    ]

    var body: some View {
        Group {
            if condition != .clear {
                GeometryReader { proxy in
                    ForEach(Array(Self.puffs.enumerated()), id: \.offset) { index, puff in
                        DriftingCloud(tint: cloudColor, phaseOffset: Double(index) * 3.5)
                            .frame(width: proxy.size.width * 0.34 * puff.2, height: proxy.size.height * 0.16 * puff.2)
                            .position(x: proxy.size.width * puff.0, y: proxy.size.height * puff.1)
                    }
                }
            }
        }
        .allowsHitTesting(false)
    }

    private var cloudColor: Color {
        switch condition {
        case .clear: return .clear
        case .cloudy: return Color.white.opacity(0.92)
        case .rain, .fog: return Color(red: 0.62, green: 0.67, blue: 0.72)
        case .snow: return Color.white.opacity(0.95)
        case .storm: return Color(red: 0.30, green: 0.32, blue: 0.38)
        }
    }
}

/// One puffy cloud (three overlapping ellipses), gently swaying left/right forever — a cheap,
/// seamless Core-Animation loop (`autoreverses: true` so there's no jump-cut at the loop
/// boundary), not a per-frame redraw.
private struct DriftingCloud: View {
    let tint: Color
    let phaseOffset: Double
    @State private var drifted = false

    var body: some View {
        GeometryReader { proxy in
            let w = proxy.size.width
            let h = proxy.size.height
            ZStack {
                Ellipse().fill(tint).frame(width: w * 0.6, height: h * 0.8).offset(x: -w * 0.18)
                Ellipse().fill(tint).frame(width: w * 0.7, height: h)
                Ellipse().fill(tint).frame(width: w * 0.55, height: h * 0.7).offset(x: w * 0.22, y: h * 0.08)
            }
        }
        .offset(x: drifted ? 10 : -10)
        .onAppear {
            withAnimation(.easeInOut(duration: 14).repeatForever(autoreverses: true).delay(phaseOffset)) {
                drifted = true
            }
        }
    }
}

struct WeatherPrecipitation: View {
    let condition: DoodleComposer.ConditionCategory

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                switch condition {
                case .rain:
                    rainStreaks(in: proxy.size)
                case .storm:
                    rainStreaks(in: proxy.size, heavy: true)
                    lightningBolt(in: proxy.size)
                case .snow:
                    snowflakes(in: proxy.size)
                case .fog:
                    fogBands(in: proxy.size)
                case .clear, .cloudy:
                    EmptyView()
                }
            }
        }
        .clipped()
        .allowsHitTesting(false)
    }

    // MARK: - Rain

    private func rainStreaks(in size: CGSize, heavy: Bool = false) -> some View {
        let columns = heavy ? 10 : 7
        return ForEach(0..<columns, id: \.self) { i in
            FallingStreak(
                xFraction: (CGFloat(i) + 0.5) / CGFloat(columns),
                verticalSpan: size.height * 1.3,
                startYFraction: -0.15,
                duration: heavy ? 0.55 : 0.75,
                delay: Double(i) * 0.09,
                sway: 0
            ) {
                Capsule()
                    .fill(Color(red: 0.72, green: 0.80, blue: 0.90).opacity(heavy ? 0.8 : 0.6))
                    .frame(width: 2.4, height: size.height * 0.14)
                    .rotationEffect(.degrees(12))
            }
        }
    }

    // MARK: - Snow

    private func snowflakes(in size: CGSize) -> some View {
        ForEach(0..<9, id: \.self) { i in
            FallingStreak(
                xFraction: (CGFloat(i) + 0.5) / 9,
                verticalSpan: size.height * 1.2,
                startYFraction: -0.1,
                duration: 3.2 + Double(i % 3) * 0.6,
                delay: Double(i) * 0.4,
                sway: 8
            ) {
                Circle()
                    .fill(Color.white.opacity(0.9))
                    .frame(width: 5, height: 5)
            }
        }
    }

    // MARK: - Fog
    //
    // Fog needs to read as "visibly hazy," not just "a bit cloudy" — a full-frame whitening
    // wash (heavier toward the ground, where fog banks are thickest) does that far more
    // clearly than a few translucent bands ever could, plus two denser horizontal bands
    // sitting right at the hill line for texture.

    private func fogBands(in size: CGSize) -> some View {
        ZStack {
            LinearGradient(
                colors: [Color.white.opacity(0.10), Color.white.opacity(0.55)],
                startPoint: .top,
                endPoint: .bottom
            )
            VStack(spacing: size.height * 0.05) {
                ForEach(0..<2, id: \.self) { i in
                    Capsule()
                        .fill(Color.white.opacity(0.6 - Double(i) * 0.15))
                        .frame(height: size.height * 0.13)
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, -20)
                        .blur(radius: 10)
                }
            }
            .offset(y: size.height * 0.24)
        }
    }

    // MARK: - Lightning (storm only, static — see doc comment)

    /// A single semi-static lightning bolt with a soft glow. Real flicker/flash animation was
    /// deliberately skipped: SwiftUI's simple two-state `repeatForever` only supports a smooth
    /// pulse, not an actual flash, and a slow pulsing bolt reads as janky rather than stormy —
    /// per the build brief, "a static-but-beautiful layer beats a janky animation." The rain
    /// streaks above already carry the storm's motion.
    private func lightningBolt(in size: CGSize) -> some View {
        LightningBoltShape()
            .fill(Color(red: 1.0, green: 0.96, blue: 0.75).opacity(0.85))
            .shadow(color: Color(red: 1.0, green: 0.95, blue: 0.6).opacity(0.7), radius: 6)
            .frame(width: size.width * 0.09, height: size.height * 0.38)
            .position(x: size.width * 0.34, y: size.height * 0.30)
    }
}

private struct LightningBoltShape: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width
        let h = rect.height
        var path = Path()
        path.move(to: CGPoint(x: w * 0.55, y: 0))
        path.addLine(to: CGPoint(x: w * 0.15, y: h * 0.55))
        path.addLine(to: CGPoint(x: w * 0.45, y: h * 0.55))
        path.addLine(to: CGPoint(x: w * 0.25, y: h))
        path.addLine(to: CGPoint(x: w * 0.85, y: h * 0.40))
        path.addLine(to: CGPoint(x: w * 0.55, y: h * 0.40))
        path.closeSubpath()
        return path
    }
}

/// Shared "fall from top to bottom, loop forever" driver used by both rain and snow. Uses a
/// single animated `CGFloat` fraction (0...1) driven by `withAnimation(repeatForever)` rather
/// than `TimelineView`, so it costs one Core Animation interpolation per element, not a
/// per-frame SwiftUI body re-evaluation. `autoreverses: false` is fine here (unlike the cloud
/// drift) because the reset snap happens just above/below the visible, clipped bounds. `sway`
/// adds a gentle horizontal drift (used by snow, not rain) as a function of the same fraction.
private struct FallingStreak<Content: View>: View {
    let xFraction: CGFloat
    let verticalSpan: CGFloat
    let startYFraction: CGFloat
    let duration: Double
    let delay: Double
    let sway: CGFloat
    @ViewBuilder let content: () -> Content

    @State private var fraction: CGFloat = 0

    var body: some View {
        GeometryReader { proxy in
            content()
                .position(
                    x: proxy.size.width * xFraction + sin(fraction * .pi * 2) * sway,
                    y: proxy.size.height * startYFraction + fraction * verticalSpan
                )
        }
        .onAppear {
            withAnimation(.linear(duration: duration).repeatForever(autoreverses: false).delay(delay)) {
                fraction = 1
            }
        }
    }
}
