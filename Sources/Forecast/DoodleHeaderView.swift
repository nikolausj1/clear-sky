import SwiftUI
import UIKit

/// Phase 5 ("Doodle layer system with programmatic placeholder layers") — PRD Section 7's full
/// five-layer grammar (base scene / season skin / weather condition / time-of-day lighting /
/// special-day overlay), resolved by `DoodleComposer` and painted by `DoodleSceneView`
/// (`Sources/Doodle/`).
///
/// **Public interface preserved from Phase 2:** `current` + `caption` remain the two
/// parameters every existing call site (`ForecastPageView`'s loading/error/empty states,
/// previews) passes — none of those needed to change. The additional parameters below
/// (`date`, `sunrise`, `sunset`, `forcedCondition`, `forcedTimeOfDay`) are all defaulted, purely
/// additive, and only exercised by the one call site that has real data + sim-verify forcing
/// to offer (`ForecastPageView.loadedView`) — see that file's `DoodleHeaderView(...)` call.
///
/// **UX redesign part 1 (hero header):** this view is now a full-bleed hero — it sizes itself to
/// roughly `heightFraction` of the screen height (including the status-bar region it extends
/// under; the actual safe-area bleed is handled by its host — `ForecastPageView`'s ScrollViews
/// and `ForecastView`'s TabView both apply `ignoresSafeArea(edges: .top)`, and both are needed:
/// see the comments at those two sites). When `current` is supplied it also overlays the big
/// condition-symbol + temperature + feels-like group that used to live in the standalone
/// `CurrentConditionsView` (removed — see that file's doc comment).
struct DoodleHeaderView: View {
    let current: CurrentConditions?
    /// Phase 4 fills this from the phrase bank. `nil` renders nothing.
    let caption: String?
    /// Date fed into `DoodleComposer` (season + special-day resolution). Defaults to "now";
    /// callers pass `viewModel.phraseBankDate` so `-forceDate` sim-verify screenshots move the
    /// doodle scene and the phrase-bank copy in lockstep.
    var date: Date = Date()
    /// Today's real sunrise/sunset, when known (`DailyEntry.sunrise`/`.sunset` for today) —
    /// sharpens `DoodleComposer`'s time-of-day resolution beyond the isDaylight+hour fallback.
    var sunrise: Date? = nil
    var sunset: Date? = nil
    /// Sim-verify hook: `-forceCondition clear|rain|snow|cloudy|fog|storm` (the same launch
    /// argument Phase 4 already uses for the phrase bank) also forces which weather-condition
    /// scene renders, via `DoodleComposer.ConditionCategory(phraseBankGroup:)`.
    var forcedCondition: DoodleComposer.ConditionCategory? = nil
    /// Sim-verify hook: `-forceTimeOfDay dawn|day|dusk|night` (new this phase).
    var forcedTimeOfDay: DoodleComposer.TimeOfDay? = nil

    @Environment(UnitsSettings.self) private var unitsSettings

    /// Roughly 40-45% of screen height including the top safe area, per the redesign spec —
    /// the extra height contributed by `ignoresSafeArea(edges: .top)` (the status bar / Dynamic
    /// Island inset) lands this in that range on real devices without hand-tuning per model.
    private static let heightFraction: CGFloat = 0.40

    static var heroHeight: CGFloat {
        UIScreen.main.bounds.height * heightFraction
    }

    /// How far the content sheet (`ForecastPageView`) is pulled up to overlap this scene's
    /// bottom edge. Exposed so `ForecastPageView` can keep its own sheet-surface math and the
    /// caption's bottom clearance in lockstep with this single value.
    static let sheetOverlap: CGFloat = 24

    /// Fixed allowance for the status bar/Dynamic Island plus the (transparent, white-styled)
    /// navigation bar, so the temperature group sits "in the upper-middle area of the scene,
    /// clear of the status bar and city title" rather than butting up against them. A constant
    /// rather than `GeometryReader.safeAreaInsets.top` because this view renders inside
    /// ScrollViews that themselves `ignoresSafeArea(edges: .top)` — in that configuration the
    /// proxy reports a top inset of 0, which would park the group under the Dynamic Island.
    private static let topChromeClearance: CGFloat = 108

    private var scene: DoodleComposer.Scene {
        DoodleComposer.resolve(
            date: date,
            current: current,
            sunrise: sunrise,
            sunset: sunset,
            forcedCondition: forcedCondition,
            forcedTimeOfDay: forcedTimeOfDay
        )
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .bottom) {
                DoodleSceneView(scene: scene)

                VStack(spacing: 14) {
                    Spacer()
                        .frame(height: Self.topChromeClearance)

                    if current != nil {
                        heroTemperatureGroup
                    }

                    Spacer(minLength: 0)
                }
                .frame(width: proxy.size.width, height: proxy.size.height)

                if caption != nil {
                    // Full-width bottom-up scrim, sized independently of the caption text so it
                    // spans the entire header edge-to-edge — a hard-edged box around just the
                    // text (the previous behavior, when the gradient was a `.background()` on
                    // the Text itself) is exactly the visible-box artifact this is fixing.
                    captionScrim
                        .frame(height: Self.scrimHeight)
                        .allowsHitTesting(false)
                }

                if let caption {
                    Text(caption)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                        // Nudged up by `sheetOverlap` beyond its original 14pt clearance so the
                        // caption stays fully visible above the content sheet's curved top edge,
                        // which now overlaps this scene by that same amount.
                        .padding(.bottom, 14 + Self.sheetOverlap)
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .frame(height: Self.heroHeight)
        .frame(maxWidth: .infinity)
        .clipped()
    }

    /// The condition symbol + big temperature + "Feels like" line — PRD Section 6 item 2's
    /// content, moved off the content sheet and into the hero scene per the redesign spec, and
    /// rendered in white (with a soft shadow for legibility over bright scenes) since it now
    /// sits directly on the sky illustration rather than the system background.
    @ViewBuilder
    private var heroTemperatureGroup: some View {
        if let current {
            VStack(spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Image(systemName: current.symbolName)
                        .font(.system(size: 44))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.3), radius: 6, y: 2)

                    Text(TemperatureFormatting.string(current.temperature, unit: unitsSettings.unit))
                        .font(.system(size: 84, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.3), radius: 8, y: 3)
                }
                .lineLimit(1)
                .minimumScaleFactor(0.7)

                Text("Feels like \(TemperatureFormatting.string(current.feelsLike, unit: unitsSettings.unit))")
                    .font(.system(size: 17))
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .frame(maxWidth: .infinity)
        }
    }

    private static let scrimHeight: CGFloat = 112

    /// A full-width, bottom-anchored dark gradient so the caption stays legible over every
    /// season/weather/time-of-day combination — including bright scenes like a snowy winter day
    /// or a pale summer sky, and dark ones like a night scene, where a flat single-opacity
    /// scrim would either wash out or look muddy. Clear at the top edge (no visible seam against
    /// the scene above it), building to a subtle dark base so white text reads reliably without
    /// a boxed-in look.
    private var captionScrim: some View {
        LinearGradient(
            colors: [.black.opacity(0), .black.opacity(0.16), .black.opacity(0.48)],
            startPoint: .top,
            endPoint: .bottom
        )
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
        caption: "Not a cloud in sight. Suspicious, honestly."
    )
    .environment(UnitsSettings())
}

#Preview("Snowy night") {
    DoodleHeaderView(
        current: CurrentConditions(
            date: Date(), temperature: Measurement(value: 22, unit: .fahrenheit),
            feelsLike: Measurement(value: 14, unit: .fahrenheit), conditionCode: "snow",
            conditionDescription: "Snow", symbolName: "snow", humidity: 0.7,
            windSpeed: Measurement(value: 8, unit: .milesPerHour),
            windDirection: Measurement(value: 0, unit: .degrees), uvIndexValue: 0,
            uvIndexCategory: "Low", isDaylight: false
        ),
        caption: "Snow at night. The good kind of quiet."
    )
    .environment(UnitsSettings())
}
