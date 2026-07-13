import SwiftUI

/// Doodle layer 5, "Special-day overlay" (PRD Section 7): "decorative elements for a fixed-
/// date holiday, solstice/equinox, or full moon ... drawn from the static special-day table."
/// Renders additively on top of the fully-resolved weather-accurate scene beneath it — it
/// decorates, never replaces (that's the "hero day" treatment, explicitly post-v1.0).
///
/// A handful of special days get a small bespoke accent (Halloween's jack-o'-lantern, July
/// 4th/New Year's Eve's fireworks, a brightened/ringed moon on full-moon nights). Every other
/// entry in `specialdays.json` gets a small, tasteful SF Symbol badge in the top-trailing
/// corner — enough to be noticed without demanding a unique illustration per holiday, which
/// the PRD explicitly reserves for the v1.x "hero day" phase.
struct SpecialDayOverlayLayer: View {
    let specialDay: SpecialDay
    let timeOfDay: DoodleComposer.TimeOfDay

    var body: some View {
        GeometryReader { proxy in
            switch specialDay.id {
            case "halloween":
                jackOLantern(in: proxy.size)
            case "julyFourth", "newYearsEve":
                fireworks(in: proxy.size)
            case "fullMoon":
                fullMoonGlow(in: proxy.size)
            default:
                badge(in: proxy.size)
            }
        }
        .allowsHitTesting(false)
    }

    // MARK: - Halloween

    private func jackOLantern(in size: CGSize) -> some View {
        let diameter = min(46, size.width * 0.12)
        return ZStack {
            Circle().fill(Color(red: 0.92, green: 0.48, blue: 0.14))
            TriangleShape().fill(Color.black.opacity(0.85)).frame(width: diameter * 0.22, height: diameter * 0.22).offset(x: -diameter * 0.18, y: -diameter * 0.08)
            TriangleShape().fill(Color.black.opacity(0.85)).frame(width: diameter * 0.22, height: diameter * 0.22).offset(x: diameter * 0.18, y: -diameter * 0.08)
            ZigzagMouthShape().fill(Color.black.opacity(0.85)).frame(width: diameter * 0.55, height: diameter * 0.22).offset(y: diameter * 0.20)
            Capsule().fill(Color(red: 0.30, green: 0.55, blue: 0.20)).frame(width: diameter * 0.14, height: diameter * 0.22).offset(y: -diameter * 0.56)
        }
        .frame(width: diameter, height: diameter)
        .position(x: size.width * 0.86, y: size.height * 0.78)
        .shadow(color: .black.opacity(0.25), radius: 3, y: 2)
    }

    // MARK: - Fireworks (July 4th / New Year's Eve)

    private func fireworks(in size: CGSize) -> some View {
        ZStack {
            FireworkBurst(color: Color(red: 0.95, green: 0.30, blue: 0.30), phaseOffset: 0)
                .position(x: size.width * 0.22, y: size.height * 0.24)
            FireworkBurst(color: Color(red: 0.98, green: 0.80, blue: 0.30), phaseOffset: 0.7)
                .position(x: size.width * 0.62, y: size.height * 0.16)
            FireworkBurst(color: Color(red: 0.45, green: 0.65, blue: 0.98), phaseOffset: 1.4)
                .position(x: size.width * 0.82, y: size.height * 0.32)
        }
    }

    // MARK: - Full moon

    private func fullMoonGlow(in size: CGSize) -> some View {
        // Aligns with `CelestialBody`'s night-time moon position (xFraction 0.72, yFraction
        // 0.18). `CelestialBody` already draws a near-full disc on a genuine full-moon night
        // (its own phase calculation agrees), but this layer makes "prominent" unmissable: an
        // opaque full disc (eclipsing any residual sliver from the phase approximation) plus a
        // soft halo ring — the additive decoration `SpecialDayOverlayLayer` exists to add.
        let position = CGPoint(x: size.width * 0.72, y: size.height * (timeOfDay == .night ? 0.18 : 0.16))
        return ZStack {
            Circle()
                .stroke(Color.white.opacity(0.4), lineWidth: 4)
                .frame(width: 62, height: 62)
                .blur(radius: 5)
            Circle()
                .fill(Color(red: 0.96, green: 0.97, blue: 0.93))
                .frame(width: 30, height: 30)
                .shadow(color: .white.opacity(0.7), radius: 14)
        }
        .position(position)
    }

    // MARK: - Generic badge (all other special days)

    private func badge(in size: CGSize) -> some View {
        Image(systemName: symbolName)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 30, height: 30)
            .background(.black.opacity(0.22), in: Circle())
            .overlay(Circle().stroke(.white.opacity(0.4), lineWidth: 1))
            .position(x: size.width - 26, y: 26)
    }

    private var symbolName: String {
        switch specialDay.id {
        case "newYearsDay": return "sparkles"
        case "groundhogDay": return "pawprint.fill"
        case "valentinesDay": return "heart.fill"
        case "stPatricksDay": return "leaf.fill"
        case "earthDay": return "globe.americas.fill"
        case "juneteenth": return "star.fill"
        case "thanksgiving": return "fork.knife"
        case "christmas": return "gift.fill"
        case "springEquinox", "fallEquinox": return "leaf.fill"
        case "summerSolstice": return "sun.max.fill"
        case "winterSolstice": return "snowflake"
        default: return "star.fill"
        }
    }
}

private struct TriangleShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

private struct ZigzagMouthShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let teeth = 5
        let step = rect.width / CGFloat(teeth)
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        for i in 0..<teeth {
            let x = rect.minX + step * CGFloat(i + 1)
            let y = i.isMultiple(of: 2) ? rect.maxY : rect.minY
            path.addLine(to: CGPoint(x: x, y: y))
        }
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.closeSubpath()
        return path
    }
}

/// A tiny radiating firework burst: fixed rays + a soft pulse (opacity/scale loop) so it reads
/// as "sparkling" without any per-frame drawing cost.
private struct FireworkBurst: View {
    let color: Color
    let phaseOffset: Double
    @State private var expanded = false

    var body: some View {
        ZStack {
            ForEach(0..<6, id: \.self) { i in
                Capsule()
                    .fill(color)
                    .frame(width: 2, height: 10)
                    .offset(y: -10)
                    .rotationEffect(.degrees(Double(i) * 60))
            }
            Circle().fill(color).frame(width: 5, height: 5)
        }
        .opacity(expanded ? 0.95 : 0.55)
        .scaleEffect(expanded ? 1.15 : 0.85)
        .onAppear {
            withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true).delay(phaseOffset)) {
                expanded = true
            }
        }
    }
}
