import Foundation

/// Loader + deterministic picker for `skyfacts.json` — the "Tonight's Sky" card's one-line
/// "sky note" (PRD Revision Notes 2026-07-17): 200+ dry, informational space facts, each
/// ≤140 characters, no tag dimension to bucket on (planets/moon/stars/ISS/aurora/deep
/// space/space history, all mixed into one rotation pool).
///
/// Deliberately a flat `[String]` rather than `PhraseBank`'s tagged-entry shape — there's
/// nothing to query by (no condition/tempBand/etc. here) — but rotation reuses
/// `PhraseBank.pick(from:bucketKey:locationId:date:)` directly rather than reimplementing its
/// FNV-1a-seeded Fisher-Yates rotation, so this gets the exact same guarantee the rest of the
/// phrase bank has: same day + same location -> same fact, a full cycle through all 200+ facts
/// before any repeat (well past the PRD's 7-day no-repeat bar), and no immediate day-to-day
/// repeat.
enum SkyFacts {
    private static let facts: [String] = {
        guard let url = Bundle.main.url(forResource: "skyfacts", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([String].self, from: data) else {
            assertionFailure("skyfacts.json missing or malformed — check project.yml resource wiring")
            return ["Tonight's sky is up there somewhere. Clouds permitting."]
        }
        return decoded
    }()

    /// Tonight's fact, deterministic by (date, location) per the rotation guarantee above.
    static func tonight(date: Date, locationId: UUID) -> String {
        guard !facts.isEmpty else { return "Tonight's sky is up there somewhere. Clouds permitting." }
        return PhraseBank.pick(from: facts, bucketKey: "skyFact", locationId: locationId, date: date)
    }
}
