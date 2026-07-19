import ActivityKit
import SwiftUI
import WidgetKit

/// ISS Pass Live Activity work package: Lock Screen banner + Dynamic Island presentations for
/// `ISSActivityAttributes`. Every phase transition (before the pass rises vs. during the pass)
/// is read directly off `context.attributes.startTime`/`endTime` compared against `Date()` at
/// render time — WidgetKit re-evaluates this `body` around the same moments its own
/// `Text(timerInterval:)`/`ProgressView(timerInterval:)` views need to redraw, so the "rises in…"
/// -> "crossing…" swap happens on-device with zero pushed updates, per
/// `ISSActivityAttributes`'s type-level doc comment on the zero-update design principle.
struct ISSPassLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: ISSActivityAttributes.self) { context in
            ISSPassLockScreenView(pass: context.attributes)
                .activityBackgroundTint(Color(red: 0.03, green: 0.03, blue: 0.09))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            let pass = context.attributes
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    ISSGlyph(size: CGSize(width: 30, height: 16))
                        .foregroundStyle(.white)
                        .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    ISSPassIslandTrailing(pass: pass)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    ISSPassExpandedBottom(pass: pass)
                }
            } compactLeading: {
                ISSGlyph(size: CGSize(width: 18, height: 10))
                    .foregroundStyle(.white)
            } compactTrailing: {
                ISSPassCompactCountdown(pass: pass)
            } minimal: {
                ISSGlyph(size: CGSize(width: 14, height: 8))
                    .foregroundStyle(.white)
            }
        }
    }
}

// MARK: - Lock screen / banner

/// Before the pass starts: a countdown to rise plus the rise direction. During the pass: a
/// progress bar across the pass window plus the crossing directions and brightness note.
private struct ISSPassLockScreenView: View {
    let pass: ISSActivityAttributes

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                ISSGlyph(size: CGSize(width: 22, height: 12))
                    .foregroundStyle(.white)
                Text("ISS pass")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.65))
                Spacer()
            }

            if Date() < pass.startTime {
                (Text("Rises in ")
                    + Text(timerInterval: Date()...pass.startTime, countsDown: true)
                    + Text(" — look \(pass.startDirection)"))
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white)
                    .monospacedDigit()
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(timerInterval: pass.startTime...pass.endTime)
                        .tint(.white)
                    Text("Crossing \(pass.startDirection)\u{2192}\(pass.endDirection) — \(pass.brightnessNote)")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Dynamic Island: compact

/// Compact trailing: a countdown timer — to rise before the pass starts, to set once it's
/// underway. Fixed width so the Dynamic Island's compact pill doesn't reflow as the digit count
/// changes.
private struct ISSPassCompactCountdown: View {
    let pass: ISSActivityAttributes

    var body: some View {
        Group {
            if Date() < pass.startTime {
                Text(timerInterval: Date()...pass.startTime, countsDown: true)
            } else {
                Text(timerInterval: Date()...pass.endTime, countsDown: true)
            }
        }
        .font(.caption2.monospacedDigit())
        .foregroundStyle(.white)
        .frame(width: 42)
    }
}

// MARK: - Dynamic Island: expanded

private struct ISSPassIslandTrailing: View {
    let pass: ISSActivityAttributes

    var body: some View {
        if Date() < pass.startTime {
            Text(timerInterval: Date()...pass.startTime, countsDown: true)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.white)
        } else {
            Text(pass.endDirection)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.75))
        }
    }
}

private struct ISSPassExpandedBottom: View {
    let pass: ISSActivityAttributes

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if Date() < pass.startTime {
                (Text("Rises in ")
                    + Text(timerInterval: Date()...pass.startTime, countsDown: true)
                    + Text(" — look \(pass.startDirection)"))
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.white)
                    .monospacedDigit()
            } else {
                ProgressView(timerInterval: pass.startTime...pass.endTime)
                    .tint(.white)
                Text("Crossing \(pass.startDirection)\u{2192}\(pass.endDirection) · peaks \(Int(pass.peakAltitudeDeg.rounded()))° up · \(pass.brightnessNote)")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.75))
                    .lineLimit(2)
            }
        }
    }
}

#Preview("ISS pass — before rise", as: .content, using: ISSActivityAttributes(
    startTime: Date().addingTimeInterval(6 * 60),
    endTime: Date().addingTimeInterval(6 * 60 + 4 * 60),
    peakAltitudeDeg: 58,
    startDirection: "NW",
    endDirection: "ENE",
    brightnessNote: "Bright pass — easy to spot"
)) {
    ISSPassLiveActivity()
} contentStates: {
    ISSActivityAttributes.ContentState()
}
