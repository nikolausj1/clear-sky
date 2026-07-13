import SwiftUI

/// PLACEHOLDER — Phase 5 ("Doodle layer system with programmatic placeholder layers") replaces
/// this view's internals with the full five-layer grammar (base scene / season skin / weather
/// condition / time-of-day lighting / special-day overlay) from PRD Section 7. For Phase 2 this
/// is a single self-contained view: a gradient reacting to condition + isDaylight, a horizon
/// silhouette standing in for the "base scene" layer, an SF Symbol for the current condition,
/// and a caption slot the Phase 4 phrase bank will eventually fill (passed `nil` here — no
/// dry-wit copy is written in this phase).
struct DoodleHeaderView: View {
    let current: CurrentConditions?
    /// Phase 4 fills this from the phrase bank. `nil` renders nothing.
    let caption: String?

    private static let height: CGFloat = 220

    private var palette: (top: Color, bottom: Color) {
        guard let current else {
            return (Color(.systemGray3), Color(.systemGray5))
        }
        let code = current.conditionCode.lowercased()

        if !current.isDaylight {
            if code.contains("clear") {
                return (
                    Color(red: 0.05, green: 0.06, blue: 0.22),
                    Color(red: 0.18, green: 0.20, blue: 0.44)
                )
            }
            return (
                Color(red: 0.11, green: 0.12, blue: 0.20),
                Color(red: 0.24, green: 0.26, blue: 0.34)
            )
        }

        if code.contains("thunder") || code.contains("rain") || code.contains("drizzle") {
            return (
                Color(red: 0.29, green: 0.35, blue: 0.44),
                Color(red: 0.58, green: 0.63, blue: 0.68)
            )
        }
        if code.contains("snow") || code.contains("flurries") || code.contains("sleet") || code.contains("hail") || code.contains("ice") {
            return (
                Color(red: 0.68, green: 0.79, blue: 0.90),
                Color(red: 0.93, green: 0.96, blue: 0.99)
            )
        }
        if code.contains("fog") || code.contains("haze") || code.contains("smok") {
            return (
                Color(red: 0.60, green: 0.64, blue: 0.66),
                Color(red: 0.82, green: 0.84, blue: 0.85)
            )
        }
        if code.contains("cloud") || code.contains("overcast") || code.contains("breezy") || code.contains("windy") {
            return (
                Color(red: 0.40, green: 0.54, blue: 0.68),
                Color(red: 0.70, green: 0.80, blue: 0.88)
            )
        }
        // Default: clear-day warm blue.
        return (
            Color(red: 0.20, green: 0.56, blue: 0.93),
            Color(red: 0.56, green: 0.81, blue: 0.98)
        )
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            LinearGradient(colors: [palette.top, palette.bottom], startPoint: .top, endPoint: .bottom)

            horizonSilhouette

            VStack(spacing: 8) {
                if let current {
                    Image(systemName: current.symbolName)
                        .font(.system(size: 54))
                        .symbolRenderingMode(.multicolor)
                        .shadow(color: .black.opacity(0.15), radius: 6, y: 2)
                }
                if let caption {
                    Text(caption)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.white.opacity(0.92))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                }
            }
            .padding(.bottom, 36)
        }
        .frame(height: Self.height)
        .frame(maxWidth: .infinity)
    }

    /// Stand-in for Phase 5's "base scene" layer — a fixed, simple horizon shape. Deliberately
    /// generic (no season/weather variation) since that variation is exactly what Phase 5 adds.
    private var horizonSilhouette: some View {
        GeometryReader { proxy in
            let w = proxy.size.width
            let h = proxy.size.height
            Path { path in
                path.move(to: CGPoint(x: 0, y: h * 0.86))
                path.addCurve(
                    to: CGPoint(x: w * 0.52, y: h * 0.72),
                    control1: CGPoint(x: w * 0.20, y: h * 0.95),
                    control2: CGPoint(x: w * 0.36, y: h * 0.64)
                )
                path.addCurve(
                    to: CGPoint(x: w, y: h * 0.84),
                    control1: CGPoint(x: w * 0.70, y: h * 0.82),
                    control2: CGPoint(x: w * 0.86, y: h * 0.68)
                )
                path.addLine(to: CGPoint(x: w, y: h))
                path.addLine(to: CGPoint(x: 0, y: h))
                path.closeSubpath()
            }
            .fill(Color.white.opacity(0.16))
        }
    }
}

#Preview("Clear day") {
    DoodleHeaderView(
        current: CurrentConditions(
            date: Date(), temperature: Measurement(value: 87, unit: .fahrenheit),
            feelsLike: Measurement(value: 90, unit: .fahrenheit), conditionCode: "clear",
            conditionDescription: "Clear", symbolName: "sun.max.fill", humidity: 0.4,
            windSpeed: Measurement(value: 5, unit: .milesPerHour),
            windDirection: Measurement(value: 0, unit: .degrees), uvIndexValue: 6,
            uvIndexCategory: "High", isDaylight: true
        ),
        caption: nil
    )
}
