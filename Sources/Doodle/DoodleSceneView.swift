import SwiftUI

/// Renders a resolved `DoodleComposer.Scene` as the composited five-layer illustration (PRD
/// Section 7). This is the "paint order" half of the layer grammar; `DoodleComposer` is the
/// "resolve order" half.
///
/// **Paint order vs. grammar order.** The PRD numbers the layers 1-5 bottom to top. Taken
/// completely literally that would mean painting layer 4 (time-of-day: a sky gradient) as one
/// opaque rectangle on top of the hills and weather — which would just hide the whole scene
/// under a solid color. Instead this view paints in the order that actually produces a
/// coherent illustration (sky, then things in the sky, then the ground, then things in front
/// of the ground, then decoration on top), while still keeping each of the five layers as an
/// independent, individually testable view type sourced from one resolved `Scene`:
///
/// 1. `TimeOfDaySkyBackground` — sky gradient + stars (time-of-day, back-most)
/// 2. `CelestialBody` — sun/moon (time-of-day; dimmed per weather condition)
/// 3. `WeatherClouds` — drifting clouds (weather condition; behind the hills)
/// 4. `BaseSceneLayer` — the stable back hill ridge (base scene)
/// 5. `SeasonSkinLayer` — the front hill ridge + trees, colored by season (season skin)
/// 6. `WeatherPrecipitation` — rain/snow/fog in front of the hills (weather condition)
/// 7. `SpecialDayOverlayLayer` — additive decoration (special day), only when one applies
struct DoodleSceneView: View {
    let scene: DoodleComposer.Scene

    var body: some View {
        ZStack {
            TimeOfDaySkyBackground(timeOfDay: scene.timeOfDay)
            CelestialBody(timeOfDay: scene.timeOfDay, condition: scene.condition, date: scene.date)
            WeatherClouds(condition: scene.condition)
            BaseSceneLayer()
            SeasonSkinLayer(season: scene.season)
            WeatherPrecipitation(condition: scene.condition)
            if let specialDay = scene.specialDay {
                SpecialDayOverlayLayer(specialDay: specialDay, timeOfDay: scene.timeOfDay)
            }
        }
        .clipped()
    }
}
