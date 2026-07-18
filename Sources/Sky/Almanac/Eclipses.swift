import Foundation

/// Curated table of solar and lunar eclipses, 2026-2031, plus "what's next" lookup and a
/// deliberately honest visibility model per eclipse type.
///
/// ## Data source and vintage
/// Every date, type, and peak time below was fetched live on 2026-07-18 from NASA's official
/// eclipse pages (eclipse.gsfc.nasa.gov, the GSFC "Solar/Lunar Eclipses: 2021-2030" and
/// "...2031-2040" decade tables). Each entry in `eclipses.json` carries its own `notes` field
/// citing the specific source consulted (and, for the 2027-08-02 total solar eclipse and the
/// 2026-08-28 partial lunar eclipse, a secondary press source for color -- Sky & Telescope,
/// Space.com). Solar peak times for 2031 are listed by NASA as Terrestrial Dynamical Time
/// rather than UTC; the two differ by roughly a minute at this epoch, which is well inside this
/// table's coarse precision target and is called out per-entry.
///
/// ## Visibility model (deliberately different per eclipse type, per work order)
/// - **Lunar eclipses**: visibility is computed **live**, not bundled. A lunar eclipse is visible
///   from a location if and only if the Moon is above that location's horizon at the eclipse's
///   peak instant (`SunMoon.moonEquatorial` + `equatorialToHorizontal`, the same transform every
///   other engine in this package uses) -- this is both exactly correct (a lunar eclipse is a
///   naked-eye phenomenon visible from literally the entire night-side hemisphere where the Moon
///   is up, no atmospheric-path subtlety involved) and cheap, so there is no reason to bundle a
///   coarse approximation instead.
/// - **Solar eclipses**: visibility is **not** computed geometrically (that would require
///   re-deriving the Moon's shadow-cone footprint on Earth's surface, well beyond this package's
///   "coarse almanac" scope). Instead each solar entry carries a small set of bundled,
///   hand-curated lat/lon bounding boxes (`visibilityRegions`) approximating where NASA's own
///   path-of-visibility description says the eclipse can be seen (totality/annularity corridor
///   plus, where it materially differs, a wider partial-visibility box). These are intentionally
///   coarse rectangles, not the eclipse's true curved path -- good enough to answer "is this
///   eclipse even in the neighborhood of my coordinates," not to plot on a map.
enum Eclipses {

    // MARK: - Types

    enum EclipseType: String, Codable {
        case totalSolar, partialSolar, annularSolar, hybridSolar
        case totalLunar, partialLunar, penumbralLunar

        var isSolar: Bool {
            switch self {
            case .totalSolar, .partialSolar, .annularSolar, .hybridSolar: return true
            case .totalLunar, .partialLunar, .penumbralLunar: return false
            }
        }

        /// Short display label ("Total Solar Eclipse", "Penumbral Lunar Eclipse", ...).
        var displayName: String {
            switch self {
            case .totalSolar: return "Total Solar Eclipse"
            case .partialSolar: return "Partial Solar Eclipse"
            case .annularSolar: return "Annular Solar Eclipse"
            case .hybridSolar: return "Hybrid Solar Eclipse"
            case .totalLunar: return "Total Lunar Eclipse"
            case .partialLunar: return "Partial Lunar Eclipse"
            case .penumbralLunar: return "Penumbral Lunar Eclipse"
            }
        }
    }

    /// A coarse rectangular region used only for solar-eclipse visibility (see type-level doc
    /// comment). Longitude bounds are plain min/max in degrees East (-180...180) and, per work
    /// order's "coarse" mandate, deliberately do NOT handle antimeridian wraparound -- no eclipse
    /// in this table needs a box that crosses it (the widest, "high northern latitudes" for
    /// 2029-06-12, stays within -170...179).
    struct RegionBox: Codable {
        var label: String
        var minLat: Double
        var maxLat: Double
        var minLon: Double
        var maxLon: Double

        func contains(latitude: Double, longitude: Double) -> Bool {
            latitude >= minLat && latitude <= maxLat && longitude >= minLon && longitude <= maxLon
        }
    }

    struct Eclipse: Codable, Identifiable {
        /// Peak/greatest-eclipse instant, UTC (see type-level doc comment on TD vs UTC for the
        /// 2031 entries).
        var peakUTC: Date
        var type: EclipseType
        /// Human-readable visibility description. For solar eclipses this describes the actual
        /// bundled path; for lunar eclipses it's NASA's general global-visibility hemisphere,
        /// kept for color/context even though the authoritative visibility answer for a specific
        /// location comes from `Eclipses.isVisible(_:latitude:longitude:)`, not this string.
        var visibilitySummary: String
        /// Solar-only bundled coarse visibility boxes; `nil`/empty for lunar entries (which are
        /// computed live instead -- see type-level doc comment).
        var visibilityRegions: [RegionBox]?
        var notes: String?

        var id: Date { peakUTC }

        /// `eclipses.json` spells the peak-instant field `date` (per work order's schema
        /// wording); mapped here to the more precise `peakUTC` Swift name.
        private enum CodingKeys: String, CodingKey {
            case peakUTC = "date"
            case type, visibilitySummary, visibilityRegions, notes
        }
    }

    // MARK: - Loading

    /// Decodes an eclipse table from raw JSON `Data` (the `eclipses.json` array). Exposed as a
    /// pure function, separate from the bundle-backed `all` below, specifically so tests and
    /// tooling can feed it a JSON file read from an arbitrary path (e.g. straight off disk in a
    /// CLI smoke test) without needing an app `Bundle` -- same reasoning as every other
    /// bundle-backed content table in this app (`SpecialDayTable`, `PhraseBank`), just made
    /// testable instead of asserting into an empty array on failure.
    static func decode(data: Data) throws -> [Eclipse] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([Eclipse].self, from: data)
    }

    /// The bundled table, loaded once from `eclipses.json` in the app bundle. Empty (with an
    /// assertion in debug builds) if the resource is missing or fails to decode -- same
    /// fail-soft-in-release contract as `SpecialDayTable.ContentStore`.
    static let all: [Eclipse] = {
        guard let url = Bundle.main.url(forResource: "eclipses", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let decoded = try? decode(data: data) else {
            assertionFailure("eclipses.json missing or failed to decode -- check project.yml resource wiring")
            return []
        }
        return decoded
    }()

    // MARK: - Visibility

    /// Whether `eclipse` is visible from `latitude`/`longitude` (degrees, longitude positive
    /// east). See the type-level doc comment for why lunar and solar use entirely different
    /// models.
    static func isVisible(_ eclipse: Eclipse, latitude: Double, longitude: Double) -> Bool {
        if eclipse.type.isSolar {
            guard let regions = eclipse.visibilityRegions else { return false }
            return regions.contains { $0.contains(latitude: latitude, longitude: longitude) }
        } else {
            let jd = AstroTime.julianDay(eclipse.peakUTC)
            let moonEq = SunMoon.moonEquatorial(date: eclipse.peakUTC)
            let horizontal = equatorialToHorizontal(moonEq, latitude: latitude, longitudeEast: longitude, jd: jd)
            return horizontal.altitude > 0
        }
    }

    // MARK: - Next eclipse lookup

    struct NextEclipse {
        var eclipse: Eclipse
        /// Whole days from `after` to `eclipse.peakUTC`, rounded down (so "later today" reads as
        /// 0, matching the intuitive "days until" a user expects rather than always rounding up).
        var daysUntil: Int
        var isVisibleFromLocation: Bool
        /// Human-facing sentence combining `isVisibleFromLocation` with `eclipse.visibilitySummary`
        /// -- see `nextEclipse` doc comment for why a non-visible eclipse is still returned
        /// (with this string saying so) rather than silently skipped.
        var visibilityDescription: String
    }

    /// The next eclipse (solar or lunar) chronologically after `date`, regardless of whether it's
    /// actually visible from `latitude`/`longitude` -- plus how many days away it is and an
    /// honest visibility verdict/description for that location.
    ///
    /// **Design choice, documented because the parameter name invites the other reading:** this
    /// does NOT filter the table down to only eclipses visible from the given location before
    /// picking "next." A user's very next eclipse is often not visible from where they live (most
    /// solar eclipses; roughly half of any given lunar eclipse's global window, if it falls during
    /// their daytime) -- silently skipping ahead to the next *visible* one could jump months or
    /// years past a genuinely next, newsworthy eclipse the user would still want to know about
    /// ("total solar eclipse next Tuesday -- not visible from here, but here's what it affects").
    /// `visibleFrom` supplies the observer's location purely to compute the visibility verdict
    /// for whichever eclipse actually comes next.
    static func nextEclipse(visibleFrom latitude: Double, longitude: Double, after date: Date, in eclipses: [Eclipse] = Eclipses.all) -> NextEclipse? {
        guard let next = eclipses
            .filter({ $0.peakUTC > date })
            .min(by: { $0.peakUTC < $1.peakUTC })
        else { return nil }

        let daysUntil = Int(next.peakUTC.timeIntervalSince(date) / 86400.0)
        let visible = isVisible(next, latitude: latitude, longitude: longitude)
        let verdict = visible ? "Visible from your location." : "Not visible from your location."
        return NextEclipse(
            eclipse: next,
            daysUntil: daysUntil,
            isVisibleFromLocation: visible,
            visibilityDescription: "\(verdict) \(next.visibilitySummary)"
        )
    }

    /// Every eclipse (solar or lunar) whose peak UTC instant falls on the same **calendar day**
    /// as `date`, evaluated in `timeZone`. Used by `BestNight` to flag an eclipse night without
    /// pulling in visibility logic -- the flag is a "heads up, something's happening" bonus, not
    /// a claim that the eclipse is visible from the caller's location (see `BestNight`'s own doc
    /// comment on special-event flags).
    static func eclipses(onCalendarDay date: Date, timeZone: TimeZone, in eclipses: [Eclipse] = Eclipses.all) -> [Eclipse] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let targetDay = calendar.startOfDay(for: date)
        return eclipses.filter { calendar.startOfDay(for: $0.peakUTC) == targetDay }
    }
}
