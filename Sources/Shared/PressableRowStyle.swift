import SwiftUI

/// UX polish package ("row press states"): a shared pressed-state highlight for tappable list
/// rows — the daily forecast rows and ranking rows both adopt this so a tap gives a subtle
/// system-fill flash instead of the default `.plain` button style's total lack of feedback.
struct PressableRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .contentShape(Rectangle())
            .background(Color(.systemFill).opacity(configuration.isPressed ? 0.5 : 0))
    }
}
