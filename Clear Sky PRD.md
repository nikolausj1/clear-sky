---
title: "Weather App PRD"
created: 2026-07-12
modified: 2026-07-12
version: 1.0
author: Claude
tags:
---

# Weather App - Product Requirements Document

| | |
|---|---|
| **Product** | Clear Sky (provisional name - display name may change later) - an iPhone weather app with a daily-doodle header and a dry-wit written voice |
| **Platform** | iOS (iPhone only, iOS 18 minimum) |
| **Status** | v1.0 PRD - agreed 2026-07-12 |
| **Companion docs** | `Project Build Guide.md` (accounts, stack, deployment, Apple signing, sim-verify workflow - follow it, do not restate it) |

> **Revision Notes (2026-07-17).** Justin approved the "Tonight's Sky" feature (full scope) after v1.0 shipped to his device: a card at the bottom of the Forecast screen with moon phase/rise/set, naked-eye planet visibility (on-device Meeus ephemerides), a daily sky-almanac line, aurora likelihood (NOAA SWPC), and ISS visible passes (Celestrak TLE + on-device SGP4). This amends the former "zero runtime network calls other than WeatherKit" rule: two additional endpoint families are sanctioned — NOAA SWPC (aurora data) and Celestrak (ISS orbital elements) — both free, keyless, government/public services with on-disk caching and graceful offline degradation (sky rows render "—" when unreachable; on-device rows always render). No accounts, no backend, no runtime AI, no analytics — unchanged.

## 1. Overview and Vision

**The problem.** Weather apps are functionally interchangeable. Everyone reads the same handful of data providers, so the numbers on screen are never the differentiator - yet checking the weather is one of the most repeated rituals on a phone, often performed even when the user already has a good guess at the answer. Apple's own app is silent utility. CARROT proved that voice can carry a weather app, but its jokes lean aggressive and can wear thin. There is room for a weather app that treats the daily check-in as a small, low-stakes moment of delight rather than either pure data retrieval or a bit that punches down.

**The one-liner.** A weather app whose header artwork changes every day - by date, season, holiday, current conditions, and time of day, like a Google Doodle crossed with a Snoopy watch face - paired with a dry, deadpan written voice that comments on the forecast instead of just reporting it.

**Why this approach wins.** The data is a commodity (WeatherKit gives every app the same forecast); the presentation is not. Two independent hooks - a visual one (the doodle) and a verbal one (the voice) - reinforce each other and give a reason to open the app even on an unremarkable day. Both hooks are cheap to justify architecturally: the doodle is a deterministic layered composite (no per-day art production required at v1), and the voice is a pre-written phrase bank (no runtime AI cost or App Review risk). The result should feel closer to a daily comic strip than a dashboard.

## 2. Users

**Primary user: Justin (owner).** An iPhone owner who already checks a weather app most days as a habit - before leaving the house, out of idle curiosity, or to settle a "is it actually going to rain" question. Comfortable with standard iOS interaction patterns (swipe, tap-to-expand, pull-to-refresh). Wants the actual forecast fast and un-obscured; the doodle and the voice are a bonus layered on top, never a tax on getting the temperature. Appreciates understated humor and would be turned off by anything mean, try-hard, or slow to load because it's animating something cute.

**Secondary users (later phases): family/friends via TestFlight, then the App Store.** Same profile assumed by default - general iPhone owners who want a fast, accurate, quietly funny forecast. No persona work beyond Justin is needed for v1 since the audience for this PRD is Claude Code building for a single real user first.

**Device and context.** iPhone only, portrait orientation, one-handed use, short repeated sessions (a few seconds to tens of seconds per open), frequently outdoors with variable network quality - which is why offline/stale-cache behavior matters as much as the live path.

## 3. Goals and Success Criteria

**Goals:**

- Make checking the weather feel like a small daily treat instead of a chore.
- Prove that a deterministic phrase bank plus a layered art system can produce a full year of variety without visible repetition or production overhead per day.
- Ship an App Store-credible weather app - correct attribution, correct privacy strings, all v1 functionality - built entirely on-device with no backend and no accounts.
- Establish a placeholder-first art pipeline so the app is fully lovable on programmatic art alone, before any curated AI-generated art layers exist.

**Success criteria:**

- Cold launch (app not in memory) to a fresh, populated forecast screen in under 3 seconds on a physical device.
- The app is fully functional (forecast for a searched city, locations management, rankings, settings) with location permission denied - verified by testing with the permission explicitly off.
- Runtime network calls limited to exactly three sanctioned endpoint families: WeatherKit, NOAA SWPC (aurora), and Celestrak (ISS TLE) - verified by inspecting network traffic during normal use; no analytics, no ad calls, no other endpoints. (Amended 2026-07-17 for Tonight's Sky; see Revision Notes.)
- The doodle header is visibly different (different combination of season/weather/time-of-day/special-day layers) across two consecutive days under normal conditions - verified by forcing distinct dates via launch arguments.
- The phrase bank produces no repeated line in the same slot (summary, caption, comparison, ranking verdict) across 7 consecutive simulated days for the three most common condition/season combinations for the app's primary locale.
- Apple Weather attribution is visible on the forecast screen without any additional navigation, on every load.
- Every build phase (Section 10) ends with a passing sim-verify screenshot before moving to the next phase.

**The one-sentence test:** Justin opens the app on an ordinary Tuesday morning already knowing it's going to be 71 and cloudy because he glanced out the window - and opens it anyway, just to see what today's doodle looks like and what the caption says about it.

## 4. Scope

**In scope (v1):**

1. **Forecast screen** - daily-doodle header with caption, current conditions, dry-wit summary and comparison line, advisory banner when relevant, hourly forecast with metric-chip switching and positional temperature pills, 10-day daily forecast with expandable day detail.
2. **Locations** - current-location via CoreLocation (contextual request, not at launch), city search via MKLocalSearch with autocomplete, save/reorder/delete, switch active location.
3. **City Power Rankings** - saved cities ranked daily by a deterministic "pleasantness" score, each with a phrase-bank verdict line.
4. **Settings/About** - units (F/C, defaulted from locale), attribution and legal, app version.

**Out of scope (non-goals):**

- **Radar.** Big dependency (map tiles, animation, storage) for a feature other weather apps already own; it doesn't serve either hook (art or voice).
- **Push notifications and Live Activities.** Deliberately deferred - the product's restraint (never nagging) is part of its future positioning ("we won't cry wolf"); shipping notifications in v1 would undercut that before it's earned.
- **Widgets and Apple Watch.** Real feature surface, but each is its own design pass (glanceable doodle at widget scale, watch face energy translated to an actual watch face) that would delay v1.
- **iPad layout.** This is an iPhone-first, portrait-first product; a tablet layout is a distinct design problem.
- **Runtime AI/LLM calls.** Never, at any version - locked by the Project Build Guide (no per-user inference cost, nothing for App Review to question, no key-in-client risk).
- **Accounts/backend.** Never for v1 - on-device only, no server to build or operate, no sync problem to solve.

**Deferred (v2+ candidates):**

- Shareable forecast card
- "Complaint Button" (one-tap gripe about the weather, phrase-bank powered)
- Timeline scrubber for the hourly/daily views
- Streaks, records, and recaps ("Weather Story")
- Purpose modes (e.g., "should I run today")
- Clothing suggestions
- Widgets
- Apple Watch app
- Push notifications / Live Activities
- iPad layout
- Curated AI-generated art layers (replacing/augmenting programmatic placeholders) - its own build phase, see Section 10
- Full unique illustrations for a small set of "hero days" - targeted for v1.x, not v1.0; see Section 6 and Open Questions for which days qualify

## 5. Product Principles

- **Info before the bit.** The joke never delays or obscures the actual forecast data. Temperature, conditions, and alerts are always legible at a glance; voice and art are a layer on top, never a gate in front.
- **Placeholder-first.** The app must feel good on programmatic placeholder art alone. Curated art is an enhancement, never a dependency for the app to be worth using.
- **Never mean, never nagging.** Dry wit stays understated. No profanity, no insulting the user, no punching down at people or places. No push notifications in v1, in service of the same restraint.
- **Deterministic over random.** The same inputs (date, location, conditions) always produce the same, explainable output - for phrase selection, art layer resolution, and ranking scores alike - so behavior is testable and debuggable, and so "why did it pick that line" always has an answer.
- **On-device only.** No accounts, no backend, no runtime AI calls, ever.

## 6. Functional Requirements

### Navigation structure

A floating bottom bar on the Forecast screen (mirroring the pill-shaped bar in the reference screenshots): **Forecast** and **Rankings** as the two primary destinations, plus a **search/locations button** (magnifier) that opens the Locations screen as a sheet. **Settings** opens from an ellipsis button in the Forecast screen's top-right corner (also as in the reference screenshots). The active location's name is the Forecast screen's title, top center. There is no radar tab and no third primary destination in v1.

### Voice register (canonical)

These six lines are the canon for dry wit in this product. Every phrase-bank line is checked against them; if a new line is meaner, louder, or more try-hard than these, it doesn't ship.

1. "88° again. Bold choice, July."
2. "Rain at 2pm. The sky checked its calendar."
3. "Six degrees warmer than yesterday. Progress, technically."
4. "Clear all day. Enjoy it; this is not a rehearsal."
5. "That 40% chance of rain could flip either way. Plan accordingly, or don't."
6. "Springfield takes the top spot today. Not everywhere can say that."

### Screen A: Forecast (main screen, default on launch)

Top to bottom:

1. **Doodle header.** Layered artwork (see Section 7 for the layer grammar) filling the top of the screen, with a one-line dry-wit caption keyed to date + current conditions overlaid or immediately below it (e.g., "88° again. Bold choice, July.").
2. **Current conditions.** Large current temperature, feels-like temperature, condition text/icon.
3. **Advisory banner** (present only when a WeatherKit alert is active for the location). Tappable - opens alert detail with the full agency text and the required Apple attribution link. If multiple alerts are active simultaneously, the banner shows the most severe one; the detail view lists any additional active alerts.
4. **Dry-wit summary line** - plain-language read on the day's conditions from the phrase bank.
5. **Comparison line** - a phrase-bank line comparing today to a reference point, e.g. "Six degrees warmer than yesterday. Progress, technically." Data source: WeatherKit's historical/daily comparison data where available, with yesterday's cached actuals (see `CachedWeather.dailyActuals`, Section 8) as the fallback; if neither exists yet (first day of use), the line is omitted rather than faked.
6. **Metric chips row** - horizontally scrollable chip selector: Temp, Precip Chance, Precip Amount, Feels Like, Wind, UV. Selecting a chip changes what the hourly list below displays (see below). Temp is the default selection on every load.
7. **Hourly forecast list.** Vertically scrollable rows, each showing: time label, a condition-change label when the condition changes from the previous row (e.g., "Light Rain") and blank otherwise, and a temperature (or selected-metric) pill. See the positional pill spec below - this is the signature interaction detail.
8. **Daily forecast (10 days).** One row per day: day-of-week label, precipitation percentage, condition icon, low/high temperatures with a horizontal range bar. Tapping a day expands it inline to show that day's hourly breakdown, total precipitation, daylight start/end times, and moon phase.
9. **Attribution.** Apple Weather attribution (via the WeatherService attribution API), visible on this screen without any additional tap or scroll gate - not buried in Settings.

**Refresh behavior.** Pull-to-refresh on the Forecast screen forces an immediate re-fetch regardless of cache age; the automatic 30-minute staleness rule (Section 8) covers everything else. A refresh in flight never blanks existing data - stale data stays visible until fresh data replaces it.

**Positional pill spec (hourly list).** Each row's pill sits on a horizontal track that spans the row's available width. The track's left edge represents the day's minimum value for the currently selected metric; the right edge represents the day's maximum. The pill's horizontal center is placed at `(value - dayMin) / (dayMax - dayMin)` along that track, clamped to `[0, 1]`. "Day" here means the calendar day containing that hour, so the track recalculates at each midnight boundary within the scrolling list. When the selected metric is Precip Chance or Precip Amount (values that can legitimately be flat at zero for a whole day), the track floor is 0 and the ceiling is the day's actual maximum for that metric, or a small non-zero minimum ceiling (e.g. 10% / 0.01") to avoid a degenerate all-zero track. Reference for the overall interaction: the CARROT-style screenshots in `design inspiration/` (see Section 7).

### Screen B: Locations

- **Current location entry** (top of list, when permission is granted): live current-location weather, requested contextually (first time the user opens Locations or taps a location-permission affordance - not at first launch).
- **Search field** with MKLocalSearch-backed autocomplete as the user types.
- **Saved locations list**, reorderable (drag) and deletable (swipe), each row showing city name and current temperature/condition where available.
- Selecting a search result adds it to saved locations (or, if already saved, switches to it - no duplicate entries for the same place).
- Tapping any saved location makes it the active location on the Forecast screen. The Forecast screen also supports horizontal swipe to page between saved locations directly, with a page indicator; Locations is the picker/management view for search, reorder, and delete.

### Screen C: City Power Rankings

- Lists the user's saved locations ranked by a composite "pleasantness" score, highest first, recalculated daily.
- Each row shows rank, city name, the score (or a simple representation of it), and a one-line deadpan verdict from the phrase bank (e.g., "Springfield: 74° and agreeable. Not everywhere can say that today.").
- Requires at least 2 saved locations to produce a ranking. See Section 8 for the default scoring formula and Section 12 for tie-breaking.

### Screen D: Settings/About

- Units toggle (Fahrenheit/Celsius), defaulted from the device locale.
- Attribution and legal (Apple Weather attribution restated here is fine in addition to the Forecast screen, not instead of it).
- App version.

### States (apply per screen per the table below)

| State | Screen A: Forecast | Screen B: Locations | Screen C: Rankings | Screen D: Settings |
|---|---|---|---|---|
| **Loading, first launch, no cache** | Full-screen placeholder doodle (season + time-of-day layers only, no weather layer yet) with a dry-wit loading line (e.g., "Consulting the sky."); no forecast numbers shown yet. | Spinner on the current-location row while resolving; search results load per keystroke. | Skeleton rows while first scores compute. | No loading state needed (static content). |
| **Offline / stale cache** | Show last cached forecast with an "as of [time]" banner; doodle uses the cached condition. Re-fetch automatically if the cache is older than 30 minutes and network is available. | Saved list still renders from cache (no network needed to display it); search is disabled with a short explanatory message if offline. | Show cached scores with an "as of" timestamp per the same 30-minute staleness rule. | Fully static; unaffected. |
| **WeatherKit error (no usable cache)** | Full error state: dry-wit error line, retry action. | Per-row fetch failure shows "--" with a retry affordance; does not block the rest of the list. | A location whose data failed to load shows as unavailable with a dry-wit inline note; other rows still rank normally. | Unaffected. |
| **Location permission denied** | Fully usable via a searched/saved city; if no city is active yet, show an empty state prompting search. | Current-location row is hidden/disabled with a short explanation and a link to iOS Settings; search-and-save remains fully available. | Unaffected beyond whatever cities are saved. | Shows permission status and a shortcut to iOS Settings. |
| **No saved locations** | N/A if a searched city is active; otherwise same as "permission denied" empty state. | Empty state prompting the user to search for a first city. | Empty state: dry-wit nudge to add a rival city (requires 2+ to rank; with exactly 1 saved, show that city with a note that ranking needs one more). | N/A |
| **Alerts absent / present** | Absent: no banner, normal layout. Present: banner shown between current conditions and the summary line, tappable to detail. | N/A | A ranked city with an active alert shows a small indicator on its row. | N/A |

## 7. Visual and Design Spec

**Tone.** Editorial and understated, not cartoonish or "gamey." The doodle is the personality; the surrounding UI (lists, chips, numbers) should read as clean, standard iOS weather-app chrome so the data stays fast to scan.

**Reference for layout mechanics.** The three CARROT screenshots in `design inspiration/` (`IMG_1173.png`, `IMG_1174.png`, `IMG_1176.png`) are the reference for: the positional hourly pill track, the daily range bar, the metric-chip row, the inline-expanding day detail, and the advisory banner placement above the hourly list. Match these interaction patterns, not CARROT's voice or its blue-gradient hero scene - CARROT's jokes run meaner than this product's register (see Section 5, "never mean"), and its header art is generic, not date-driven.

**Reference for the doodle concept.** Google Doodles (a base logo/scene reworked daily for date/occasion) crossed with a Snoopy-style animated watch face (a character/scene that reacts to time and conditions). The doodle is the one area where full illustrative creativity is expected, within the layer grammar below.

**Placeholder-first requirement.** v1.0 ships with programmatic placeholder art only: SwiftUI shapes, gradients, and simple geometric elements that already react correctly to season, weather condition, and time of day per the layer grammar. The app must feel good and look intentional on placeholders alone - not like an obvious stand-in for art that hasn't arrived yet. Curated AI-generated art is a later, separate phase (Section 10).

**Doodle layer grammar.** Five layers, composited bottom to top:

1. **Base scene** - fixed silhouette elements (ground line, simple skyline/horizon shapes) that don't change; the stable "stage" the rest is drawn on.
2. **Season skin** - palette and ground/foliage treatment for the current season (e.g., bare/snow-dusted in winter, blossom accents in spring, full green in summer, warm leaf tones in fall).
3. **Weather condition layer** - visual elements for the current condition (sun, cloud cover, rain, snow, fog), drawn as simple shapes/gradients rather than photographic assets.
4. **Time-of-day lighting** - a color-grade gradient and sun/moon position reflecting dawn, day, dusk, or night.
5. **Special-day overlay** - decorative elements for a fixed-date holiday, solstice/equinox, or full moon (e.g., a small pumpkin silhouette near Halloween), drawn from the static special-day table (Section 8).

**Resolution order.** Layers 1-4 always render together (a scene always has a season, a weather condition, and a time of day - there's no "off" state for these). Layer 5 renders additively on top when a special day applies; it decorates rather than replaces the weather-accurate scene beneath it. Where the *caption/copy* has to pick a single thing to talk about on a given day, the priority order is: **special day > active weather alert > season > time of day** (a Halloween caption wins over a generic autumn one; an active advisory wins over a season note; a season note wins over a plain time-of-day observation). A small set of "hero days" (Section 12, open question) get a unique full illustration replacing the layered composite entirely - v1.x, not v1.0.

**Typography, color, spacing.** Follow standard iOS system type (SF Pro via SwiftUI defaults) and Dynamic Type support; no custom typeface for v1. Color is otherwise driven by the doodle/season system for the header and standard semantic system colors (label, secondaryLabel, systemBackground, systemRed for alerts) for the data chrome below it, supporting both light and dark mode.

## 8. Data Model

**SavedLocation** (SwiftData)
- `id: UUID`
- `name: String` (display name, e.g. "Springfield, IL")
- `latitude: Double`
- `longitude: Double`
- `sortOrder: Int`
- `isCurrentLocation: Bool` (true for the CoreLocation-derived entry, if any; excluded from manual reorder/delete)

**CachedWeather** (SwiftData or lightweight file cache, one per `SavedLocation`)
- `locationId: UUID`
- `fetchedAt: Date`
- `currentConditions: JSON blob` (temperature, feels-like, condition code, wind, humidity, UV)
- `hourly: [HourlyEntry]` (time, temperature, feels-like, precip chance, precip amount, wind, UV, condition code)
- `daily: [DailyEntry]` (date, low, high, precip %, condition code, sunrise/sunset, moon phase)
- `activeAlerts: [AlertSummary]` (severity, title, agency text, effective/expires, Apple attribution link)
- `dailyActuals: [DailyActual]` (date, observed high/low, dominant condition) - a rolling record of what actually happened, kept for the trailing 7 days per location; the fallback data source for the comparison line (Section 6) when WeatherKit's historical comparison data is unavailable
- **Staleness rule:** data is considered stale after 30 minutes. Stale data is still shown (with an "as of [time]" indicator) rather than blanked; a re-fetch is attempted automatically whenever the app is foregrounded or a screen depending on that location is viewed and network is available.

**PhraseBank** (static JSON, bundled)
- Top-level keys per slot: `summary`, `doodleCaption`, `comparison`, `rankingVerdict`, `emptyState`, `errorState`.
- Each slot contains an array of template entries keyed by `condition` (e.g. `rain`, `clear`, `snow`), `tempBand` (e.g. `cold`/`mild`/`hot`), and optionally `season` or `specialDayId`.
- Each template is a string with named slots (`{temp}`, `{delta}`, `{city}`, `{condition}`) filled at render time.
- **Selection is deterministic**, seeded by the calendar date (plus location and slot key, so different cities don't show identical lines on the same day): the same line is shown all day for a given slot. Rotation, not random draw: each key's variants are walked in a date-seeded shuffled order, so a line cannot repeat until every variant for that key has been shown. **Minimum 8 variants per common key** (enforced at content-review time), which is what makes the 7-day no-repeat success criterion (Section 3) hold by construction.
- **Content workflow:** Claude drafts the full phrase bank with wide per-key variant coverage; Justin reviews and approves the register via the `_review/` workflow before it ships (same pattern as art curation). Updates to phrasing ship as part of a normal app version - there is no remote/dynamic content update path, since there is no backend.

**SpecialDayTable** (static JSON, bundled)
- Entries: `{ id, month, day (or rule for computed dates like equinoxes/solstices/full moons), label, tier: "overlay" | "hero" }`.
- All entries are computable offline (fixed-date holidays, solstices/equinoxes, full moons); no entry requires a network lookup.
- `tier: "hero"` entries are the small set slated for a unique full illustration in v1.x (Section 12); all other entries get the standard layer-5 overlay treatment in v1.0.

**No user accounts.** All data above lives on-device only.

## 9. Tech Stack and Architecture

Per the Project Build Guide's iOS section: SwiftUI, XcodeGen-managed project, Apple Developer team `6A4J2GTB6F`, standard sim-verify workflow. Project-specific decisions below.

- **Bundle ID:** `com.levelup.clearsky` (locked 2026-07-12). The display name "Clear Sky" is provisional and may change before launch; the bundle ID stays regardless (it is never user-visible), so a rename costs nothing.
- **Weather data: Apple WeatherKit, native Swift framework** (not the REST API). Rejected the REST API: the native framework avoids per-request JWT signing and is the officially supported path for an on-device Swift app. Rejected third-party providers (e.g. Tomorrow.io, OpenWeather): unnecessary cost and API-key management for a project committed to no backend, and WeatherKit's 500k free calls/month is ample for this app's traffic. Known WeatherKit limits to design around: no air quality data; minute-precipitation and alerts are region-limited (the alert banner will simply stay empty outside covered regions - no error state needed for that case beyond the normal "alerts absent" state).
- **Location search:** MKLocalSearch for autocomplete; CoreLocation for current location, requested when-in-use and only contextually (first Locations-screen visit or explicit affordance), never at launch.
- **Persistence:** SwiftData for saved locations and cached weather - chosen over Core Data for a small, simple local-only model with no legacy migration burden.
- **UI:** SwiftUI throughout (chosen over UIKit for declarative, state-driven views that suit the layered doodle compositing and the metric-chip-driven hourly list).

**Architecture (component view):**

```
SwiftUI Views (Forecast / Locations / Rankings / Settings)
        |
   ViewModels (per screen)
        |
   +----+-----------------------------------------------+
   |              |              |             |         |
WeatherService  LocationStore  PhraseBank   DoodleComposer  SpecialDayTable
(WeatherKit      (SwiftData)   (JSON,        (resolves      (JSON, static
 wrapper +                      deterministic  the layer     lookup)
 CachedWeather)                 selection)     stack)
```

`DoodleComposer` and `PhraseBank` both depend on the current date, the active location's cached conditions, and `SpecialDayTable` lookups - they are the two places the "special day > weather > season > time of day" priority order (Section 7) is implemented, and should share that priority logic rather than each re-deriving it.

## 10. Build Phases

0. **App ID + WeatherKit capability registration** (longest-lead, riskiest item - do first), repo creation, folder scaffolding, XcodeGen project, empty app boots in the simulator. Bundle ID: `com.levelup.clearsky`. Exit: empty app launches in sim under the registered bundle ID.
1. **Weather service layer + models + caching.** Exit: a smoke test prints real WeatherKit data for a hardcoded coordinate (per the Build Guide's engine-test recipe).
2. **Forecast screen with placeholder art + real data, all states.** Exit: sim-verify screenshots covering loading, offline/stale, error, permission-denied, alert-present, and normal states.
3. **Locations (search/save/switch) + Settings.** Exit: sim-verify screenshots of search, save, reorder, delete, and the switch-location swipe.
4. **Phrase bank system + voice pass.** Exit: sim-verify with forced-condition launch arguments showing distinct summary/caption/comparison lines per forced condition.
5. **Doodle layer system with programmatic placeholder layers.** Exit: sim-verify screenshots across forced dates/conditions showing all five layers responding correctly, including at least one forced special day.
6. **City Power Rankings.** Exit: sim-verify with 2+ seeded locations showing a ranked list and verdict lines; and the under-2-locations empty state.
7. **Polish, attribution, privacy strings, app icon, TestFlight build.** Exit: TestFlight build uploaded, attribution visible on Forecast, privacy strings present and accurate.
8. **(Post-v1.0) Curated AI art pass.** Replace/augment programmatic placeholder layers with curated AI-generated art via the `_review/` candidate-and-approve workflow; includes the small hero-day full-illustration set. Its own phase, explicitly after v1.0 ships.

## 11. Acceptance Criteria

- Forecast screen renders current conditions, feels-like, condition, doodle header with caption, summary line, and comparison line for any valid location.
- Metric chips (Temp, Precip Chance, Precip Amount, Feels Like, Wind, UV) each correctly re-render the hourly list and its positional pill track per the spec in Section 6.
- Daily forecast shows 10 days with low/high range bars; tapping any day expands it to hourly breakdown, rain total, daylight times, and moon phase.
- Advisory banner appears only when a WeatherKit alert is active, is tappable to a detail view with full agency text and the Apple-required link, and correctly handles multiple simultaneous alerts (most severe shown first, others listed in detail).
- All six states in the Section 6 state table are implemented and visually distinct for each applicable screen.
- Current-location permission is requested contextually (not at launch) and the app is fully usable via search when denied.
- City search returns MKLocalSearch autocomplete results; saving, reordering, and deleting locations all persist via SwiftData across app relaunch.
- City Power Rankings requires 2+ saved locations to rank, shows a deterministic score and a phrase-bank verdict per city, and shows the correct empty/under-2 state otherwise.
- Settings shows units toggle (defaulting from locale), attribution/legal, and app version; changing units updates Forecast, Locations, and Rankings consistently.
- Apple Weather attribution is visible on the Forecast screen without extra navigation.
- No phrase-bank slot repeats its previous day's line for the same location.
- No network call is made at runtime other than to the three sanctioned endpoint families - WeatherKit, NOAA SWPC, Celestrak (verified by traffic inspection). Sky rows degrade to "—" offline; on-device sky rows (moon, planets, almanac) render regardless of connectivity.
- Cold launch to populated forecast is under 3 seconds on a physical device.
- App builds and sim-verifies at the end of every phase in Section 10 before proceeding to the next.

## 12. Risks and Open Questions

**Risks:**

- **WeatherKit entitlement/auth flakiness.** Mitigation: register the App ID and WeatherKit capability first (Build Phase 0), and test against real WeatherKit on a physical device early (Phase 1), not just the simulator.
- **Art production scope creep.** Mitigation: placeholder-first is a hard requirement, not a suggestion; the layer grammar (Section 7) caps the number of variants per layer so "just one more art pass" doesn't become open-ended before v1.0 ships.
- **Phrase bank going stale or repetitive with real-world use.** Mitigation: require a minimum variant count per phrase-bank key at review time, and enforce date-seeded rotation with no-repeat-yesterday as a hard rule, not a best effort.
- **App Review rejection over attribution.** Mitigation: Apple Weather attribution lives on the main Forecast screen itself (Section 6), not in Settings, satisfying the requirement without relying on the reviewer to dig for it.
- **Dry wit drifting mean over time** (new contributors to the phrase bank, or Claude drafting new lines later, might miss the register). Mitigation: the "Voice register (canonical)" block at the top of Section 6 is the canon - any new line is checked against those six before shipping.

**Open questions (non-blocking):**

- **Final app name.** RESOLVED provisionally 2026-07-12: "Clear Sky", chosen by Justin with the expectation it may change before launch. Bundle ID `com.levelup.clearsky` is locked and survives any display-name change. (Original candidates for the record: Deadpan Weather, Doodlecast, Gray Area, Partly, Same Sky.)
- **Composite "pleasantness" score formula.** This PRD's smallest-sensible default: a weighted average of four 0-100 normalized components - temperature comfort (peak at 70-75°F, tapering to 0 below 20°F or above 100°F), precipitation (100 minus precip probability %), wind (100 at calm, tapering to 0 at 30+ mph sustained), and humidity (100 at 40-50% RH, penalized more heavily above 60%) - weighted 40/30/15/15 respectively. Exact weights and curve shapes are tunable post-launch; the shape and inputs above are the v1.0 starting point.
- **Ranking tie-break rule.** When two cities land on the exact same score, this PRD's default is alphabetical by city name (deterministic, no extra state needed).
- **Which days qualify as "hero days"** for a unique full illustration (v1.x, not v1.0). Not specified upstream; candidates worth considering when that phase starts: New Year's Day, Halloween, Christmas, July 4th - to be confirmed with Justin before that phase, not decided unilaterally. (The season's first snow was considered and dropped as a hero-day candidate: hero days are resolved from the date-computed special-day table, and "first snow" is weather-triggered, which would need a separate mechanism.)
- **Exact privacy-string wording** for the location permission prompt. Apple requires this text to be clear and accurate above all else; this PRD assumes a plain, clear string (a touch of voice is fine if it doesn't compromise clarity) rather than a fully deadpan one, to avoid App Review friction.
