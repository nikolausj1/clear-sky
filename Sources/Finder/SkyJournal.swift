import Foundation
import Observation
import SwiftUI

/// UserDefaults-backed log of everything Sky Finder has helped the user actually find and
/// confirm ("Seen ✓") — a lightweight collection log, not a full observing journal. One entry
/// per distinct object (`objectId`), tracking the first time it was ever logged and how many
/// times since. Same storage philosophy as `NightVisionMode`/`UnitsSettings`: a plain
/// `UserDefaults`-backed `@Observable` singleton rather than SwiftData, since this is small,
/// device-local, non-relational data with no query/sync needs.
@Observable
final class SkyJournalStore {
    static let shared = SkyJournalStore()

    struct Entry: Codable, Identifiable, Equatable {
        var objectId: String
        var name: String
        var firstSeenDate: Date
        var count: Int
        var id: String { objectId }
    }

    private static let storageKey = "skyJournalEntries"
    private let userDefaults: UserDefaults

    private(set) var entries: [Entry]

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        if let data = userDefaults.data(forKey: Self.storageKey),
           let decoded = try? JSONDecoder().decode([Entry].self, from: data) {
            entries = decoded
        } else {
            entries = []
        }
        // Sim-verify only: `-seedJournal` seeds a deterministic, populated journal (mirrors
        // `DemoSeeding.seedLocationsFromLaunchArgs`'s rationale) — `simctl` can't tap through
        // Sky Finder's "Seen ✓" button enough times to populate one for a screenshot.
        if CommandLine.arguments.contains("-seedJournal"), entries.isEmpty {
            seedDemoEntries()
        }
    }

    /// Logs a sighting: bumps `count` and leaves `firstSeenDate` untouched for an object already
    /// in the journal; inserts a fresh entry (count 1, `firstSeenDate: date`) otherwise.
    func logSighting(objectId: String, name: String, date: Date = Date()) {
        if let index = entries.firstIndex(where: { $0.objectId == objectId }) {
            entries[index].count += 1
        } else {
            entries.append(Entry(objectId: objectId, name: name, firstSeenDate: date, count: 1))
            entries.sort { $0.firstSeenDate < $1.firstSeenDate }
        }
        persist()
    }

    func hasLogged(objectId: String) -> Bool {
        entries.contains { $0.objectId == objectId }
    }

    /// "4 of 5 naked-eye planets found" — the journal sheet's header tally. Counts how many of
    /// the 5 naked-eye planet ids appear in the journal at all (Mercury/Venus/Mars/Jupiter/Saturn
    /// — matches `Planets.Body.allCases`), independent of the Moon/ISS/other satellite entries.
    var planetsFoundCount: Int {
        Planets.Body.allCases.filter { body in entries.contains { $0.objectId == "planet-\(body.rawValue)" } }.count
    }

    /// Bright-star work package: how many distinct stars have ever been logged — `objectId`s
    /// prefixed `"star-"` per `SkyFinderTarget.Kind`'s id scheme. Unlike `planetsFoundCount`
    /// (a fraction of a fixed set of 5), this is an open-ended count against the 23-star catalog,
    /// so the journal tally just reports the raw number rather than "N of 23."
    var starsFoundCount: Int {
        entries.filter { $0.objectId.hasPrefix("star-") }.count
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        userDefaults.set(data, forKey: Self.storageKey)
    }

    private func seedDemoEntries() {
        let now = Date()
        let calendar = Calendar.current
        entries = [
            Entry(objectId: "planet-venus", name: "Venus", firstSeenDate: calendar.date(byAdding: .day, value: -3, to: now) ?? now, count: 5),
            Entry(objectId: "planet-jupiter", name: "Jupiter", firstSeenDate: calendar.date(byAdding: .day, value: -1, to: now) ?? now, count: 2),
            Entry(objectId: "moon", name: "Moon", firstSeenDate: calendar.date(byAdding: .day, value: -6, to: now) ?? now, count: 9),
            Entry(objectId: "sat-25544", name: "ISS", firstSeenDate: now, count: 1),
            // Bright-star work package: demo star entries so `-seedJournal` screenshots show the
            // journal tally's new "· N stars" suffix populated, not stuck at zero.
            Entry(objectId: "star-Vega", name: "Vega", firstSeenDate: calendar.date(byAdding: .day, value: -2, to: now) ?? now, count: 3),
            Entry(objectId: "star-Sirius", name: "Sirius", firstSeenDate: calendar.date(byAdding: .day, value: -5, to: now) ?? now, count: 4),
            Entry(objectId: "star-Polaris", name: "Polaris", firstSeenDate: calendar.date(byAdding: .day, value: -6, to: now) ?? now, count: 2),
        ]
        persist()
    }
}

/// The journal sheet — reachable both from a small book icon inside Sky Finder and a JOURNAL row
/// at the bottom of the Tonight's Sky night panel. Dark-styled to match the rest of the Finder
/// feature (this is night-observing content, same rationale `TonightSkyCard`'s own always-dark
/// night panel already establishes) and `.nightVisionAware()` per this project's standing rule
/// for every sheet root.
struct SkyJournalView: View {
    let store: SkyJournalStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Sky Journal")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.white)
                    Text(tallyLine)
                        .font(.subheadline)
                        .foregroundStyle(Color.white.opacity(0.65))
                }

                Rectangle()
                    .fill(Color.white.opacity(0.12))
                    .frame(height: 1)

                if store.entries.isEmpty {
                    Text("Nothing logged yet. Use Sky Finder to point at something tonight, then tap \u{201C}Seen\u{201D} once you've spotted it.")
                        .font(.footnote)
                        .foregroundStyle(Color.white.opacity(0.65))
                } else {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(store.entries.sorted { $0.firstSeenDate > $1.firstSeenDate }.enumerated()), id: \.element.id) { index, entry in
                            entryRow(entry)
                            if index < store.entries.count - 1 {
                                Rectangle()
                                    .fill(Color.white.opacity(0.12))
                                    .frame(height: 1)
                                    .padding(.vertical, 10)
                            }
                        }
                    }
                }
            }
            .padding(20)
        }
        .scrollContentBackground(.hidden)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationBackground { Color(red: 0.03, green: 0.03, blue: 0.08).ignoresSafeArea().nightVisionAware() }
        .nightVisionAware()
    }

    private var tallyLine: String {
        let found = store.planetsFoundCount
        let stars = store.starsFoundCount
        return "\(found) of 5 naked-eye planets found · \(stars) star\(stars == 1 ? "" : "s")"
    }

    private func entryRow(_ entry: SkyJournalStore.Entry) -> some View {
        HStack(spacing: 10) {
            Circle()
                .fill(Color.white.opacity(0.12))
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                Text("First seen \(Self.dateFormatter.string(from: entry.firstSeenDate)) · \(entry.count) sighting\(entry.count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(Color.white.opacity(0.65))
            }
            Spacer(minLength: 8)
        }
        .padding(.vertical, 6)
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d"
        return formatter
    }()
}
