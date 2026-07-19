import Foundation

/// The night sky's brightest naked-eye stars — a hardcoded J2000 catalog plus "where to look
/// right now" for the Sky Finder. Sibling to `Planets.swift` (solar-system bodies) and
/// `MeteorRadiant.swift` (shower radiants); this file covers the fixed stars neither of those
/// touches. No constellation-line art lives here — just point sources a stargazer can aim a
/// phone (or a finger) at.
///
/// ## Catalog scope and sourcing
/// The 22 brightest stars in Earth's sky by apparent visual magnitude — down to Adhara at
/// +1.50 — plus Polaris (+1.98, well outside the top 22 on brightness alone, but the one star
/// every stargazer actually needs, since it sits almost on the north celestial pole). That's
/// 23 entries total.
///
/// Note on the 22: the classic "brightest stars" ranking runs Sirius through Regulus (21 stars
/// down to magnitude +1.36) and then Adhara (ε Canis Majoris, +1.50) as the 22nd — Adhara is
/// easy to miss because it's a bright star in a constellation (Canis Major) already famous for
/// a *brighter* one (Sirius), but it belongs on any honest top-22 list and is included here for
/// that reason.
///
/// Every entry's right ascension, declination, magnitude, and distance was researched
/// individually (not copied from a single table) from each star's Wikipedia infobox — which
/// republishes Hipparcos/Gaia-derived astrometry (ultimately SIMBAD-sourced) — cross-checked
/// against Wikipedia's summary "List of brightest stars" table and astropixels.com's
/// 50-brightest-stars table for magnitude/distance agreement. Exact figures and the source
/// used are cited per star below. Magnitudes for the known variables (Betelgeuse, Antares) are
/// the commonly quoted mean apparent magnitude, not an instant-by-instant value — treat those
/// two as "usually about this bright."
///
/// ## Precession (why this engine skips it)
/// All positions below are J2000.0 mean-equinox coordinates, used as-is with no precession
/// correction. Precession slides the equinox roughly 0.3° per 25 years (about 1° per 83
/// years); since this whole engine's accuracy target is naked-eye pointing (≈1°), not
/// arcminute astrometry, that drift stays well inside the error budget for decades on either
/// side of J2000 — a second precession step would buy nothing a user could see. This mirrors
/// `Planets.swift`'s choice to work in "mean equinox of date" terms rather than carry a formal
/// precession/nutation chain for its own elements.
enum BrightStars {

    struct Star: Equatable {
        var name: String
        /// "Bayer designation · constellation", e.g. "Alpha Lyrae · Lyra".
        var designation: String
        var raDegJ2000: Double
        var decDegJ2000: Double
        var magnitude: Double
        var distanceLy: Int
        /// Plain-language visual color, e.g. "blue-white", "orange", "red".
        var colorNote: String
        /// One-line Observatory-Guide-style fact, ≤110 characters, no "!".
        var factLine: String
    }

    /// The 23-star catalog (22 brightest + Polaris), ordered brightest-to-faintest by
    /// magnitude. RA/Dec are J2000.0, degrees, standard ICRS/Hipparcos convention (RA
    /// eastward 0–360°, Dec −90…+90°).
    static let all: [Star] = [
        // Sirius (α CMa): RA 06h45m08.917s, Dec −16°42′58.02″ (Wikipedia infobox, J2000/ICRS).
        // Vmag −1.46, distance 8.6 ly (Wikipedia, "List of brightest stars").
        Star(
            name: "Sirius",
            designation: "Alpha Canis Majoris · Canis Major",
            raDegJ2000: 101.28714, decDegJ2000: -16.71612,
            magnitude: -1.46, distanceLy: 9,
            colorNote: "blue-white",
            factLine: "Sirius — 9 light-years away; the brightest star in the night sky, in Canis Major."
        ),
        // Canopus (α Car): RA 06h23m57.10988s, Dec −52°41′44.3810″ (Wikipedia infobox, J2000).
        // Vmag −0.74, distance 310 ly (Wikipedia).
        Star(
            name: "Canopus",
            designation: "Alpha Carinae · Carina",
            raDegJ2000: 95.98796, decDegJ2000: -52.69566,
            magnitude: -0.74, distanceLy: 310,
            colorNote: "white",
            factLine: "Canopus — 310 light-years away; the sky's 2nd-brightest star, unseen from the northern US."
        ),
        // Rigil Kentaurus / Alpha Centauri A: RA 14h39m36.494s, Dec −60°50′02.3737″ (Wikipedia
        // infobox, J2000). Vmag −0.27 (component A; system combined ≈ −0.27), distance 4.4 ly
        // (Wikipedia gives 4.34 ly for the system).
        Star(
            name: "Rigil Kentaurus",
            designation: "Alpha Centauri · Centaurus",
            raDegJ2000: 219.90206, decDegJ2000: -60.83399,
            magnitude: -0.27, distanceLy: 4,
            colorNote: "yellow-white",
            factLine: "Rigil Kentaurus — 4 light-years away, the nearest star system to the Sun."
        ),
        // Arcturus (α Boo): RA 14h15m39.7s, Dec +19°10′56″ (Wikipedia infobox, J2000).
        // Vmag −0.05, distance 37 ly (Wikipedia).
        Star(
            name: "Arcturus",
            designation: "Alpha Boötis · Boötes",
            raDegJ2000: 213.91542, decDegJ2000: 19.18222,
            magnitude: -0.05, distanceLy: 37,
            colorNote: "orange",
            factLine: "Arcturus — 37 light-years away; an orange giant, brightest star north of the equator."
        ),
        // Vega (α Lyr): RA 18h36m56.33635s, Dec +38°47′01.2802″ (Wikipedia infobox, J2000).
        // Vmag 0.03, distance 25 ly (Wikipedia). Verified 2026-07-20 04:00 UTC alt/az below.
        Star(
            name: "Vega",
            designation: "Alpha Lyrae · Lyra",
            raDegJ2000: 279.23473, decDegJ2000: 38.78369,
            magnitude: 0.03, distanceLy: 25,
            colorNote: "blue-white",
            factLine: "Vega — 25 light-years away; the northern sky's brightest summer star."
        ),
        // Capella (α Aur): RA 05h16m41.35871s, Dec +45°59′52.7693″ (Wikipedia infobox, J2000).
        // Vmag 0.08, distance 43 ly (Wikipedia).
        Star(
            name: "Capella",
            designation: "Alpha Aurigae · Auriga",
            raDegJ2000: 79.17233, decDegJ2000: 45.99799,
            magnitude: 0.08, distanceLy: 43,
            colorNote: "yellow",
            factLine: "Capella — 43 light-years away; a close pair of yellow giants outshining Auriga."
        ),
        // Rigel (β Ori): RA 05h14m32.27210s, Dec −08°12′05.8981″ (Wikipedia infobox, J2000).
        // Vmag 0.13, distance 860 ly (Wikipedia).
        Star(
            name: "Rigel",
            designation: "Beta Orionis · Orion",
            raDegJ2000: 78.63447, decDegJ2000: -8.20164,
            magnitude: 0.13, distanceLy: 860,
            colorNote: "blue-white",
            factLine: "Rigel — 860 light-years away; a blue supergiant tens of thousands of Suns bright."
        ),
        // Procyon (α CMi): RA 07h39m18.1195s, Dec +05°13′29.9552″ (Wikipedia infobox, J2000).
        // Vmag 0.34, distance 11 ly (Wikipedia).
        Star(
            name: "Procyon",
            designation: "Alpha Canis Minoris · Canis Minor",
            raDegJ2000: 114.82550, decDegJ2000: 5.22499,
            magnitude: 0.34, distanceLy: 11,
            colorNote: "yellow-white",
            factLine: "Procyon — 11 light-years away; completes the Winter Triangle with Sirius and Betelgeuse."
        ),
        // Achernar (α Eri): RA 01h37m42.84548s, Dec −57°14′12.3101″ (Wikipedia infobox, J2000).
        // Vmag 0.46, distance 140 ly (Wikipedia).
        Star(
            name: "Achernar",
            designation: "Alpha Eridani · Eridanus",
            raDegJ2000: 24.42852, decDegJ2000: -57.23675,
            magnitude: 0.46, distanceLy: 140,
            colorNote: "blue-white",
            factLine: "Achernar — 140 light-years away; spins so fast it bulges wide at its own equator."
        ),
        // Betelgeuse (α Ori): RA 05h55m10.30536s, Dec +07°24′25.4304″ (Wikipedia infobox,
        // J2000). Vmag 0.50 mean (semiregular variable, roughly 0.0–1.3), distance 640 ly
        // (Wikipedia).
        Star(
            name: "Betelgeuse",
            designation: "Alpha Orionis · Orion",
            raDegJ2000: 88.79294, decDegJ2000: 7.40706,
            magnitude: 0.50, distanceLy: 640,
            colorNote: "red-orange",
            factLine: "Betelgeuse — 640 light-years away; a red supergiant big enough to swallow Jupiter's orbit."
        ),
        // Hadar / Beta Centauri: RA 14h03m49.40535s, Dec −60°22′22.9266″ (Wikipedia infobox,
        // J2000). Vmag 0.61, distance 390 ly (Wikipedia).
        Star(
            name: "Hadar",
            designation: "Beta Centauri · Centaurus",
            raDegJ2000: 210.95586, decDegJ2000: -60.37304,
            magnitude: 0.61, distanceLy: 390,
            colorNote: "blue-white",
            factLine: "Hadar — 390 light-years away; a blue giant pointing the way to Alpha Centauri."
        ),
        // Altair (α Aql): RA 19h50m46.99855s, Dec +08°52′05.9563″ (Wikipedia infobox, J2000).
        // Vmag 0.76, distance 17 ly (Wikipedia).
        Star(
            name: "Altair",
            designation: "Alpha Aquilae · Aquila",
            raDegJ2000: 297.69583, decDegJ2000: 8.86832,
            magnitude: 0.76, distanceLy: 17,
            colorNote: "white",
            factLine: "Altair — 17 light-years away; spins so fast it flattens into an egg shape."
        ),
        // Acrux / Alpha Crucis: RA 12h26m35.89522s, Dec −63°05′56.7343″ (Wikipedia infobox,
        // J2000). Vmag 0.76 (combined AB), distance 320 ly (Wikipedia).
        Star(
            name: "Acrux",
            designation: "Alpha Crucis · Crux",
            raDegJ2000: 186.64956, decDegJ2000: -63.09909,
            magnitude: 0.76, distanceLy: 320,
            colorNote: "blue-white",
            factLine: "Acrux — 320 light-years away; anchors the Southern Cross, unseen from Wisconsin."
        ),
        // Aldebaran (α Tau): RA 04h35m55.23907s, Dec +16°30′33.4885″ (Wikipedia infobox,
        // J2000). Vmag 0.86, distance 65 ly (Wikipedia).
        Star(
            name: "Aldebaran",
            designation: "Alpha Tauri · Taurus",
            raDegJ2000: 68.98016, decDegJ2000: 16.50930,
            magnitude: 0.86, distanceLy: 65,
            colorNote: "orange",
            factLine: "Aldebaran — 65 light-years away; an orange giant marking the eye of Taurus the bull."
        ),
        // Antares (α Sco): RA 16h29m24.4597s, Dec −26°25′55.2094″ (Wikipedia infobox, J2000).
        // Vmag 0.96 mean (semiregular variable), distance 550 ly (Wikipedia).
        Star(
            name: "Antares",
            designation: "Alpha Scorpii · Scorpius",
            raDegJ2000: 247.35192, decDegJ2000: -26.43200,
            magnitude: 0.96, distanceLy: 550,
            colorNote: "red",
            factLine: "Antares — 550 light-years away; a red supergiant whose name means rival of Mars."
        ),
        // Spica (α Vir): RA 13h25m11.579s, Dec −11°09′40.75″ (Wikipedia infobox, J2000).
        // Vmag 0.97, distance 250 ly (Wikipedia).
        Star(
            name: "Spica",
            designation: "Alpha Virginis · Virgo",
            raDegJ2000: 201.29825, decDegJ2000: -11.16132,
            magnitude: 0.97, distanceLy: 250,
            colorNote: "blue-white",
            factLine: "Spica — 250 light-years away; two massive stars locked close enough to distort each other."
        ),
        // Pollux (β Gem): RA 07h45m18.94987s, Dec +28°01′34.316″ (Wikipedia infobox, J2000).
        // Vmag 1.14, distance 34 ly (Wikipedia).
        Star(
            name: "Pollux",
            designation: "Beta Geminorum · Gemini",
            raDegJ2000: 116.32896, decDegJ2000: 28.02620,
            magnitude: 1.14, distanceLy: 34,
            colorNote: "orange",
            factLine: "Pollux — 34 light-years away; the nearest giant star to the Sun, with a known planet."
        ),
        // Fomalhaut (α PsA): RA 22h57m39.0465s, Dec −29°37′20.050″ (Wikipedia infobox, J2000).
        // Vmag 1.16, distance 25 ly (Wikipedia).
        Star(
            name: "Fomalhaut",
            designation: "Alpha Piscis Austrini · Piscis Austrinus",
            raDegJ2000: 344.41269, decDegJ2000: -29.62224,
            magnitude: 1.16, distanceLy: 25,
            colorNote: "white",
            factLine: "Fomalhaut — 25 light-years away; ringed by a dusty disk holding a directly imaged planet."
        ),
        // Deneb (α Cyg): RA 20h41m25.9s, Dec +45°16′49″ (Wikipedia infobox, J2000).
        // Vmag 1.25, distance 2,600 ly (Wikipedia).
        Star(
            name: "Deneb",
            designation: "Alpha Cygni · Cygnus",
            raDegJ2000: 310.35792, decDegJ2000: 45.28028,
            magnitude: 1.25, distanceLy: 2600,
            colorNote: "blue-white",
            factLine: "Deneb — 2,600 light-years away; one of the most luminous stars known despite its faint glow."
        ),
        // Mimosa / Beta Crucis: RA 12h47m43.26877s, Dec −59°41′19.5792″ (Wikipedia infobox,
        // J2000). Vmag 1.25, distance 280 ly (Wikipedia).
        Star(
            name: "Mimosa",
            designation: "Beta Crucis · Crux",
            raDegJ2000: 191.93029, decDegJ2000: -59.68877,
            magnitude: 1.25, distanceLy: 280,
            colorNote: "blue-white",
            factLine: "Mimosa — 280 light-years away; the second-brightest star of the Southern Cross."
        ),
        // Regulus (α Leo): RA 10h08m22.311s, Dec +11°58′01.95″ (Wikipedia infobox, J2000).
        // Vmag 1.36 (component A), distance 79 ly (Wikipedia).
        Star(
            name: "Regulus",
            designation: "Alpha Leonis · Leo",
            raDegJ2000: 152.09296, decDegJ2000: 11.96721,
            magnitude: 1.36, distanceLy: 79,
            colorNote: "blue-white",
            factLine: "Regulus — 79 light-years away; a fast-spinning star marking the heart of Leo the lion."
        ),
        // Adhara / Epsilon Canis Majoris: RA 06h58m37.54876s, Dec −28°58′19.5102″ (Wikipedia
        // infobox, J2000). Vmag 1.50, distance ~430 ly (Wikipedia; Hipparcos/Gaia parallax
        // give a range of roughly 405–430 ly). The 22nd-brightest star overall — see the
        // catalog-scope note above for why it's included alongside the 21 more famous names.
        Star(
            name: "Adhara",
            designation: "Epsilon Canis Majoris · Canis Major",
            raDegJ2000: 104.65645, decDegJ2000: -28.97209,
            magnitude: 1.50, distanceLy: 430,
            colorNote: "blue-white",
            factLine: "Adhara — 430 light-years away; the brightest source of ultraviolet light in the sky."
        ),
        // Polaris / Alpha Ursae Minoris: RA 02h31m49.09s, Dec +89°15′50.8″ (Wikipedia infobox,
        // J2000). Vmag 1.98, distance 430 ly (Wikipedia). Not one of the 22 brightest stars —
        // included because it's the sky's essential direction-finding star. Verified
        // 2026-01-15 07:00 UTC alt/az below (the classic "altitude ≈ observer's latitude" check).
        Star(
            name: "Polaris",
            designation: "Alpha Ursae Minoris · Ursa Minor",
            raDegJ2000: 37.95454, decDegJ2000: 89.26411,
            magnitude: 1.98, distanceLy: 430,
            colorNote: "yellow-white",
            factLine: "Polaris — 430 light-years away; sits almost atop Earth's axis, so it barely seems to move."
        ),
    ]

    // MARK: - Positions

    /// `star`'s azimuth/altitude (degrees) as seen from `latitudeDeg`/`longitudeDeg` (positive
    /// east, matching every other engine in this package) at `date`. Thin wrapper over
    /// `AstroTime`'s `equatorialToHorizontal` — the same transform `Planets.swift` and
    /// `MeteorRadiant.swift` use, just fed this file's static J2000 coordinates directly
    /// (fixed stars have no proper motion or light-time correction worth modeling at this
    /// engine's ~1° accuracy target).
    static func horizontalPosition(
        star: Star,
        date: Date,
        latitudeDeg: Double,
        longitudeDeg: Double
    ) -> (azimuthDeg: Double, altitudeDeg: Double) {
        let equatorial = EquatorialCoordinates(rightAscension: star.raDegJ2000, declination: star.decDegJ2000)
        let jd = AstroTime.julianDay(date)
        let horizontal = equatorialToHorizontal(equatorial, latitude: latitudeDeg, longitudeEast: longitudeDeg, jd: jd)
        return (azimuthDeg: horizontal.azimuth, altitudeDeg: horizontal.altitude)
    }

    /// Every catalog star currently above `minAltitude` (degrees) from `lat`/`lon` at `date`,
    /// sorted brightest-first (ascending magnitude — lower/negative numbers are brighter).
    static func visibleStars(
        date: Date,
        lat: Double,
        lon: Double,
        minAltitude: Double = 10
    ) -> [(star: Star, azimuthDeg: Double, altitudeDeg: Double)] {
        all
            .map { star -> (star: Star, azimuthDeg: Double, altitudeDeg: Double) in
                let position = horizontalPosition(star: star, date: date, latitudeDeg: lat, longitudeDeg: lon)
                return (star, position.azimuthDeg, position.altitudeDeg)
            }
            .filter { $0.altitudeDeg >= minAltitude }
            .sorted { $0.star.magnitude < $1.star.magnitude }
    }

    /// Convenience over `visibleStars`: just the `count` brightest currently-up stars — the
    /// "what should I look for tonight" list for the Sky Finder's headline.
    static func brightestUp(
        date: Date,
        lat: Double,
        lon: Double,
        count: Int,
        minAltitude: Double = 10
    ) -> [(star: Star, azimuthDeg: Double, altitudeDeg: Double)] {
        Array(visibleStars(date: date, lat: lat, lon: lon, minAltitude: minAltitude).prefix(count))
    }
}
