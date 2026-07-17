import Foundation

/// Static, informational (not witty) "how to find it" blurbs for each naked-eye planet — shown
/// only inside a planet row's inline expansion in `TonightSkyCard`, alongside (not instead of)
/// the dry-wit `PhraseBank.skyPlanet` line. PRD ask (Section 3, "Content"): "1-2 sentences per
/// planet, informational not witty... These teach; the wit lines entertain. Keep them separate."
///
/// Hand-written, not phrase-bank-rotated — there's exactly one blurb per planet, not a variant
/// pool, so there's nothing to rotate.
enum SkyFindItGuide {
    static func blurb(for body: Planets.Body) -> String {
        switch body {
        case .mercury:
            return "Low near the horizon, close to where the Sun just set or will soon rise — the trickiest of the five to catch, since it never strays far from the twilight glow."
        case .venus:
            return "The brilliant white point low in the west after sunset, or low in the east before sunrise — brighter than anything in the sky but the Moon."
        case .mars:
            return "A steady reddish-orange point, dimmer than Venus or Jupiter but distinctly warm in color, and not twinkling the way nearby stars do."
        case .jupiter:
            return "A very bright, steady white point, often the brightest thing in the sky after Venus and the Moon. A steady pair of binoculars can even show its four largest moons as tiny dots."
        case .saturn:
            return "A steady, pale gold point of medium brightness. Its famous rings are real, but need a telescope to see — to the naked eye it just looks like an unusually calm star."
        }
    }
}
