import SwiftUI

/// A reusable "tap-to-explain" glossary sheet (Forecast-surface overhaul, work item 4): a small
/// `.medium`-detent sheet with a title and a handful of short paragraphs, written in the app's
/// Observatory Guide register (clear, warm, factual, explanatory — no jokes, no exclamation
/// marks). Every event icon in the hourly list, the Sky chip's score explainer, and `TonightSkyCard`'s
/// ISS section all present the same sheet shape via `Explainers`' static library below, so a user
/// only ever learns "how to read a popover" once.
struct ExplainerContent: Identifiable, Equatable {
    var id: String
    var title: String
    /// 2-4 short paragraphs, rendered in order. Deliberately plain `String`s, not attributed
    /// text or markdown — the register is calm and factual, no need for inline emphasis.
    var paragraphs: [String]
}

struct ExplainerSheet: View {
    let content: ExplainerContent

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(content.title)
                    .font(.title3.weight(.semibold))
                    .padding(.top, 4)

                ForEach(Array(content.paragraphs.enumerated()), id: \.offset) { _, paragraph in
                    Text(paragraph)
                        .font(.body)
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(20)
        }
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
    }
}

/// The fixed glossary content library (work item 4). Every entry is written once, here, in the
/// Observatory Guide register — no per-call-site copy improvisation. `rocketLaunch(_:)` is a
/// function rather than a stored constant since it injects that specific hour's launch details
/// (mission/provider/pad), per work order: "launch icon injects that hour's launch details."
enum Explainers {
    static let issPass = ExplainerContent(
        id: "issPass",
        title: "What's an ISS pass?",
        paragraphs: [
            "The International Space Station orbits about 250 miles up, circling the whole Earth roughly every 90 minutes. When it passes overhead during the hours around dusk or dawn, sunlight still reaches it even though the ground below is already dark — so it reflects sunlight back down and becomes visible.",
            "It looks like a bright, steady star gliding smoothly across the sky over a few minutes — no blinking, no flickering, and moving noticeably faster than a plane. It fades out as it enters Earth's shadow, or dims near the horizon as it sets.",
            "A pass typically lasts two to six minutes from first appearing to fading out. No equipment is needed — it's an easy naked-eye sight if you know when and where to look.",
        ]
    )

    static let aurora = ExplainerContent(
        id: "aurora",
        title: "What sets tonight's aurora odds?",
        paragraphs: [
            "Aurora forecasts are built from NOAA's geomagnetic activity index (Kp), which measures how much the solar wind is currently disturbing Earth's magnetic field. A higher Kp value means the aurora oval — the ring of activity around the magnetic pole — pushes farther from the poles and becomes visible at lower latitudes.",
            "Your odds also depend on latitude: the same Kp value that puts on a show in northern Canada may only produce a faint glow, or nothing at all, farther south.",
            "When conditions are favorable, look north, away from bright lights, and give your eyes 10 to 15 minutes to adjust to the dark. A clear, moonless sky helps — even a bright aurora can be washed out by light pollution or a full moon.",
        ]
    )

    static let meteorShower = ExplainerContent(
        id: "meteorShower",
        title: "What am I looking at during a meteor shower?",
        paragraphs: [
            "Meteor showers happen when Earth passes through a trail of dust and debris left behind by a comet. Each of those tiny particles burns up in the atmosphere in a fraction of a second, leaving a brief streak of light.",
            "The rates shown here (meteors per hour) assume ideal conditions — a clear, moonless sky far from city lights. A bright Moon or hazy sky can cut the number you'll actually see well below that on-paper figure.",
            "Meteors appear to radiate outward from a single point in the sky (the shower's namesake constellation), but they're just as visible, and often easier to spot, looking somewhat away from that point — especially if the Moon is near it.",
        ]
    )

    static func stargazingScore(_ score: Int? = nil) -> ExplainerContent {
        ExplainerContent(
            id: "stargazingScore",
            title: "How is the Stargazing Score built?",
            paragraphs: [
                "Each hour's score, 0 to 10, combines three factors: how dark the sky actually is at that hour (daylight and twilight both count against it), how much cloud is in the way, and how much the Moon is washing things out.",
                "All three factors have to line up for a high score — a perfectly clear, moonless hour still scores 0 in broad daylight, and a dark, moonless hour still scores low under heavy cloud.",
                "Daytime hours scoring 0 is expected and correct — the score only rates how good stargazing conditions are, not the weather in general.",
            ]
        )
    }

    static let brightness = ExplainerContent(
        id: "brightness",
        title: "How bright is \"bright\"?",
        paragraphs: [
            "Astronomers measure brightness on the magnitude scale, where lower (and negative) numbers mean brighter — each step of about 5 magnitudes is a difference of roughly 100 times in actual brightness.",
            "In plain terms: brighter than -3 outshines every star in the night sky; -1 to 0.5 is as bright as the brightest stars up there; 0.5 to 1.5 is a prominent, easy-to-spot star; and anything fainter than about 3 is a modest point of light best seen away from city lights.",
        ]
    )

    /// Injects `launch`'s own mission/provider/pad details, per work order ("launch icon injects
    /// that hour's launch details"). Notes plainly that a launch elsewhere on Earth generally
    /// isn't visible from the user's own location — this row is reporting a fact about the
    /// world, not a personal viewing opportunity, unless the pad happens to be nearby.
    static func rocketLaunch(_ launch: UpcomingLaunch) -> ExplainerContent {
        let timeText = Self.timeFormatter.string(from: launch.net)
        return ExplainerContent(
            id: "rocketLaunch-\(launch.id)",
            title: "A rocket launch somewhere on Earth",
            paragraphs: [
                "\(launch.missionName), a \(launch.vehicle) mission from \(launch.providerAbbrev), is scheduled to launch around \(timeText) from \(launch.locationDisplay).",
                "This is a global schedule — unless that launch site happens to be near you, it will not be visible from your location. It's shown here as a fact about the world during this hour, not a local viewing opportunity.",
            ]
        )
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        return formatter
    }()

    /// Sim-verify only: `-showExplainer issPass|aurora|meteorShower|stargazingScore|brightness|
    /// rocketLaunch` (see `NavigationShell`) — `simctl` can't tap through to an icon to open its
    /// sheet for a screenshot, mirroring every other `-show*`/`-force*` hook in this codebase.
    /// `rocketLaunch` uses a small synthetic launch (this hook has no real launch to inject).
    static func forLaunchArgKey(_ key: String) -> ExplainerContent? {
        switch key {
        case "issPass": return issPass
        case "aurora": return aurora
        case "meteorShower": return meteorShower
        case "stargazingScore": return stargazingScore()
        case "brightness": return brightness
        case "rocketLaunch":
            return rocketLaunch(UpcomingLaunch(
                id: "sim-verify-launch",
                missionName: "Starlink Group 12-4",
                provider: "SpaceX",
                providerAbbrev: "SpaceX",
                vehicle: "Falcon 9 Block 5",
                padName: "SLC-40",
                locationDisplay: "Cape Canaveral, FL",
                net: Date().addingTimeInterval(3600),
                netPrecision: .exact,
                status: .go,
                isCrewed: false,
                webcastLive: true,
                imageURL: nil,
                missionDescription: "A batch of Starlink satellites to low Earth orbit."
            ))
        default: return nil
        }
    }
}
