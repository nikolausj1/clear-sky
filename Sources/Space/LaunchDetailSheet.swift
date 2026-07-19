import SwiftUI

/// The Space tab's launch detail sheet (work item 4): tapping a launch row opens this — mission
/// name, provider/vehicle/class glyph, pad + location, T-0 (with a precision caveat when the NET
/// isn't exact), status, and LL2's mission description when the model carries one. Dark-styled,
/// matching the rest of the all-dark Space tab rather than the system sheet background — this is
/// the one sheet in the app that stays in the Space tab's own always-dark identity rather than
/// following system light/dark mode.
///
/// Register check (Observatory Guide: clear, warm, factual, no jokes/exclamations) — every static
/// string here was written fresh for this sheet and re-read against that bar before shipping.
struct LaunchDetailSheet: View {
    let launch: UpcomingLaunch

    private var vehicleClass: LaunchVehicleClass {
        LaunchVehicleClass.classify(vehicle: launch.vehicle, provider: launch.provider)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .top, spacing: 14) {
                    RocketSilhouette(vehicleClass: vehicleClass, size: 44, tint: .white.opacity(0.85))
                        .padding(.top, 2)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(launch.missionName)
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(.white)
                        Text("\(launch.providerAbbrev) \u{00B7} \(launch.vehicle)")
                            .font(.subheadline)
                            .foregroundStyle(Color.white.opacity(0.65))
                    }
                    Spacer(minLength: 0)
                    LaunchStatusChip(status: launch.status)
                }

                SpaceHairlineDivider()

                VStack(alignment: .leading, spacing: 14) {
                    detailRow(label: "T-0", value: Self.t0Text(for: launch))
                    detailRow(label: "PAD", value: launch.padName)
                    detailRow(label: "LOCATION", value: launch.locationDisplay)
                }

                if let description = launch.missionDescription, !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    SpaceHairlineDivider()
                    VStack(alignment: .leading, spacing: 6) {
                        Text("MISSION")
                            .font(.caption2.weight(.semibold))
                            .tracking(0.6)
                            .foregroundStyle(Color.white.opacity(0.5))
                        Text(description)
                            .font(.subheadline)
                            .foregroundStyle(Color.white.opacity(0.85))
                    }
                }
            }
            .padding(20)
        }
        .scrollContentBackground(.hidden)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        // Night Vision work package: `.presentationBackground` renders behind the sheet's own
        // content view, outside the tree `.nightVisionAware()` (applied by the caller, at this
        // sheet's `.sheet(item:)` call site in `SpaceView`) wraps — it does NOT inherit that
        // effect automatically, an escape hatch discovered during sim-verify (the background
        // stayed navy-blue while everything else in the sheet went red). Wrapped here too so the
        // background itself goes red along with the rest.
        .presentationBackground { SpaceDarkBackground().nightVisionAware() }
    }

    private func detailRow(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption2.weight(.semibold))
                .tracking(0.6)
                .foregroundStyle(Color.white.opacity(0.5))
            Text(value)
                .font(.subheadline)
                .monospacedDigit()
                .foregroundStyle(.white)
        }
    }

    /// "Jul 22, 2:14 PM" for an exact NET; "Jul 22 (date approximate)" for a coarser one — same
    /// "hedge, don't fake precision" spirit as `LaunchSchedule.LaunchTimePrecision`'s own doc
    /// comment.
    private static func t0Text(for launch: UpcomingLaunch) -> String {
        switch launch.netPrecision {
        case .exact:
            return dateTimeFormatter.string(from: launch.net)
        case .approximate:
            return "\(dateOnlyFormatter.string(from: launch.net)) (date approximate)"
        }
    }

    private static let dateTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, h:mm a"
        return formatter
    }()

    private static let dateOnlyFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d"
        return formatter
    }()
}

/// The GO/HOLD/TBD status chip — shared between `SpaceView`'s launch rows and this detail sheet
/// so the two surfaces always agree on the same colors. Dark-surface contrast pass (work order):
/// GO stays accent-filled with white text (already AA-safe: `Color.clearSkyAccent` is a saturated
/// blue, white text on it is well above 4.5:1); HOLD is brightened to a solid orange fill with
/// black text (an orange fill with light text measured poorly on a dark surface — black text on
/// solid orange comfortably clears AA); TBD becomes a plain white-0.15 fill with white-0.75 text
/// (the old `.tertiarySystemFill`/`.secondary` pairing resolves against the SYSTEM color scheme,
/// which is wrong here since this screen forces a dark identity regardless of device appearance).
struct LaunchStatusChip: View {
    let status: LaunchStatus

    var body: some View {
        Text(label)
            .font(.caption2.weight(.bold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(fill, in: Capsule())
            .foregroundStyle(foreground)
    }

    private var label: String {
        switch status {
        case .go: return "GO"
        case .hold: return "HOLD"
        case .tbd: return "TBD"
        }
    }

    private var fill: Color {
        switch status {
        case .go: return Color.clearSkyAccent
        case .hold: return Color.orange
        case .tbd: return Color.white.opacity(0.15)
        }
    }

    private var foreground: Color {
        switch status {
        case .go: return .white
        case .hold: return .black
        case .tbd: return Color.white.opacity(0.75)
        }
    }
}
