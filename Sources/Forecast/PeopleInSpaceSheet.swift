import SwiftUI

/// The "People in Space" sheet (Tonight's Sky card work package): tapping the "N people in space
/// right now" row (see `TonightSkyCard.peopleInSpaceRow`) opens this — one row per person
/// currently in space, sorted by current-mission days descending (`PeopleInSpace.summarize`'s own
/// sort order, consumed as-is here, not re-derived).
///
/// Dark-styled like `LaunchDetailSheet` (this reuses that same Space-tab chrome —
/// `SpaceDarkBackground`/`SpaceHairlineDivider` — rather than a plain `.systemGroupedBackground`
/// sheet) since it's presenting the same "space" domain content the Space tab's own sheets do, and
/// the app is dark-only end to end regardless (see `ClearSkyApp`).
///
/// **Text-only v1, deliberately:** no astronaut photos. LL2 does provide
/// `profile_image`/`profile_image_thumbnail` on the wire model, but per the work order's policy
/// decision this sheet doesn't fetch or render them.
///
/// Register check (Observatory Guide: clear, warm, factual, no jokes/exclamations) — every static
/// string here was written fresh for this sheet and re-read against that bar before shipping.
struct PeopleInSpaceSheet: View {
    let summary: PeopleInSpaceSummary

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("People in space right now")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.white)
                    Text(Self.countSubtitle(summary.count))
                        .font(.subheadline)
                        .foregroundStyle(Color.white.opacity(0.65))
                }

                SpaceHairlineDivider()

                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(summary.people.enumerated()), id: \.element.id) { index, person in
                        personRow(person)
                        if index < summary.people.count - 1 {
                            SpaceHairlineDivider()
                                .padding(.vertical, 10)
                        }
                    }
                }

                SpaceHairlineDivider()

                Text("Crew data from Launch Library; updates daily.")
                    .font(.caption)
                    .foregroundStyle(Color.white.opacity(0.5))
            }
            .padding(20)
        }
        .scrollContentBackground(.hidden)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        // Night Vision work package: `.presentationBackground` renders behind the sheet's own
        // content view, outside the tree `.nightVisionAware()` (applied by the caller, at this
        // sheet's `.sheet(isPresented:)` call site in `TonightSkyCard`) wraps — it does NOT
        // inherit that effect automatically, an escape hatch discovered during sim-verify (the
        // background stayed navy-blue while everything else in the sheet went red). Wrapped here
        // too so the background itself goes red along with the rest.
        .presentationBackground { SpaceDarkBackground().nightVisionAware() }
    }

    private func personRow(_ person: SpacePerson) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    if let flag = Self.leadingFlag(person.nationality) {
                        Text(flag)
                            .font(.subheadline)
                    }
                    Text(person.name)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                }
                Text(person.agencyAbbrev)
                    .font(.caption)
                    .foregroundStyle(Color.white.opacity(0.65))
                if let careerTimeInSpace = person.careerTimeInSpace {
                    Text(careerTimeInSpace)
                        .font(.caption2)
                        .foregroundStyle(Color.white.opacity(0.5))
                }
            }
            Spacer(minLength: 8)
            if let daysText = Self.daysUpText(person.daysInSpaceCurrent) {
                Text(daysText)
                    .font(.subheadline)
                    .monospacedDigit()
                    .foregroundStyle(Color.white.opacity(0.75))
            }
        }
        .padding(.vertical, 6)
    }

    private static func countSubtitle(_ count: Int) -> String {
        count == 1 ? "1 person currently in space." : "\(count) people currently in space."
    }

    /// "233 days up" for anything past their first day; "day 1" for a 0-1 day count (per work
    /// order) rather than "0 days up"/"1 days up", which would both read oddly for someone who
    /// launched today or yesterday. `nil` (rendering nothing) when `daysInSpaceCurrent` itself is
    /// `nil` — `SpacePerson`'s own doc comment: that happens when LL2's `last_flight` is missing,
    /// unparsable, or (defensively) in the future, and there's no honest number to show instead.
    private static func daysUpText(_ days: Int?) -> String? {
        guard let days else { return nil }
        if days <= 1 { return "day 1" }
        return "\(days) days up"
    }

    /// `SpacePerson.nationality` is display-ready as a whole (`PeopleInSpace.displayNationality`)
    /// -- `"🇺🇸 American"` when the demonym has a curated flag, otherwise the plain demonym or
    /// `"Unknown"` with no flag at all. This sheet's row only wants the flag glyph next to the
    /// name (not the demonym text too, which would crowd the name-forward layout the work order
    /// asks for) — a flag emoji is always exactly 2 Unicode scalars (a pair of regional-indicator
    /// symbols), so splitting on the first space and checking the scalar count is a reliable way
    /// to recover just the flag without a second lookup table.
    private static func leadingFlag(_ nationality: String) -> String? {
        guard let spaceIndex = nationality.firstIndex(of: " ") else { return nil }
        let prefix = String(nationality[..<spaceIndex])
        return prefix.unicodeScalars.count == 2 ? prefix : nil
    }
}
