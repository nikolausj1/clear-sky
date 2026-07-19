import SwiftUI

/// Bright-star work package: the Sky Finder's "Stars" chip destination — a compact dark list of
/// tonight's currently-up bright stars, brightest-first, with Polaris pinned to the top
/// regardless of its own brightness rank (see `SkyFinderView.visibleStarsNow`'s doc comment for
/// why). Tapping a row targets that star and dismisses the sheet. Presented as a sheet layered on
/// top of the already-full-screen Sky Finder scene — same dark styling and `.nightVisionAware()`
/// standing rule `SkyJournalView` already applies for a sheet over this same feature.
struct StarPickerSheet: View {
    let stars: [(star: BrightStars.Star, azimuthDeg: Double, altitudeDeg: Double)]
    var onSelect: (BrightStars.Star) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if stars.isEmpty {
                    VStack(spacing: 8) {
                        Text("No bright stars are up high enough right now.")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white)
                        Text("Check back later tonight as the sky turns.")
                            .font(.footnote)
                            .foregroundStyle(Color.white.opacity(0.6))
                    }
                    .multilineTextAlignment(.center)
                    .padding(24)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(stars, id: \.star.name) { entry in
                        Button {
                            onSelect(entry.star)
                        } label: {
                            row(for: entry)
                        }
                        .listRowBackground(Color.clear)
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                }
            }
            .background(Color(red: 0.03, green: 0.03, blue: 0.08).ignoresSafeArea())
            .navigationTitle("Stars")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationBackground { Color(red: 0.03, green: 0.03, blue: 0.08).ignoresSafeArea() }
        .nightVisionAware()
    }

    private func row(for entry: (star: BrightStars.Star, azimuthDeg: Double, altitudeDeg: Double)) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.star.name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                Text(entry.star.designation)
                    .font(.caption)
                    .foregroundStyle(Color.white.opacity(0.55))
                if entry.star.name == "Polaris" {
                    Text("Find true north — it barely moves all night.")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(Color.clearSkyAccentOnDark)
                }
            }
            Spacer(minLength: 8)
            Text(Self.magnitudeSimile(entry.star.magnitude))
                .font(.caption)
                .foregroundStyle(Color.white.opacity(0.6))
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: 118, alignment: .trailing)
        }
        .padding(.vertical, 4)
    }

    /// A brightness-in-words simile for the list row — same register as
    /// `SkyFinderTarget.magnitudeSimile` uses for planets, but its own (separate) scale: stars in
    /// this catalog only ever run from Sirius (−1.46) down to Polaris (1.98), a much narrower
    /// band than the planets' own simile function assumes, so a dedicated mapping reads more
    /// honestly across that range than reusing the planet one verbatim would.
    private static func magnitudeSimile(_ magnitude: Double) -> String {
        if magnitude < -1.0 { return "Brilliant" }
        if magnitude < 0.5 { return "Very bright" }
        if magnitude < 1.2 { return "Bright" }
        return "Modest, but clear"
    }
}
