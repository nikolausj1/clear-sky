import SwiftUI

/// UX redesign part 1 (hero header): the standalone `CurrentConditionsView` that used to render
/// PRD Section 6 item 2 (big temperature, feels-like, condition text) has been removed — that
/// content now lives inside `DoodleHeaderView`'s hero overlay, directly on the sky scene, per
/// the redesign spec. This file is kept (rather than deleted) because `CopyLinesView` below is
/// still very much in use on the content sheet (`ForecastPageView`).
///
/// PRD Section 6, items 4-5: the dry-wit summary line and the yesterday-comparison line,
/// both filled from the Phase 4 phrase bank (`PhraseBank.swift`). `comparison` is `nil`
/// whenever `ForecastViewModel.comparisonLine` has no yesterday reference point yet (first
/// day of use) — PRD: "the line is omitted rather than faked," so this view renders only the
/// summary line in that case rather than an empty second line.
///
/// Redesign part 1 gives this a touch more presence now that it breathes directly on the sheet
/// with no card around it — summary in body/medium/primary, comparison in subheadline/secondary.
struct CopyLinesView: View {
    let summary: String
    let comparison: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(summary)
                .font(.body.weight(.medium))
                .foregroundStyle(.primary)
            if let comparison {
                Text(comparison)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
