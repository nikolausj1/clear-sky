# PhraseBank (Phase 4)

Static, bundled dry-wit copy per PRD Section 8 ("PhraseBank"). No runtime AI, ever — every
line below is hand-written and shipped in `phrasebank.json`. `PhraseBank.swift` is the
deterministic selection engine that picks which pre-written line renders, per slot, per day.

## Files

- `phrasebank.json` — the content. Bundled as an app resource (see `project.yml`).
- `PhraseBank.swift` — the loader + deterministic selection engine (`Sources/PhraseBank/`).

## JSON schema

Top-level object, one key per slot:

```json
{
  "summary": [ { "tags": { "condition": "rain", "tempBand": "hot" }, "text": "..." }, ... ],
  "doodleCaption": [ ... ],
  "comparison": [ ... ],
  "rankingVerdict": [ ... ],
  "emptyState": [ ... ],
  "errorState": [ ... ],
  "skyPlanet": [ ... ],
  "skyNoPlanets": [ ... ],
  "skyAurora": [ ... ],
  "skyISSPass": [ ... ],
  "skyNoISS": [ ... ],
  "skyMoon": [ ... ],
  "skyMeteor": [ ... ],
  "skyPairing": [ ... ]
}
```

Each entry is `{ "tags": { ...string:string pairs... }, "text": "..." }`. `tags` is a small,
per-slot key vocabulary (below) — the engine matches on tags, not on slot-specific Swift
structs, so all twelve slots share one lookup/fallback implementation.

### Tag vocabulary per slot

| Slot | Tag keys | Values |
|---|---|---|
| `summary` | `condition`, `tempBand` | condition: `clear`, `cloudy`, `rain`, `snow`, `fog`, `wind`, `storm`. tempBand: `cold`, `mild`, `hot` |
| `doodleCaption` | `condition`, `tempBand` | same as `summary` |
| `comparison` | `direction`, `magnitude` | direction: `warmer`, `cooler`, `same`. magnitude: `slight`, `moderate`, `large` (omit/`none` for `same`) |
| `rankingVerdict` | `position`, `pleasantness` | position: `top`, `middle`, `bottom`. pleasantness: `great`, `fine`, `rough` |
| `emptyState` | `context` | `noLocations`, `rankingsNeedOneMore`, `rankingsNoCities`, `searchOffline` |
| `errorState` | `context` | `weatherFetchFailed`, `locationRowFailed`, `rankingRowFailed`, `generic` |
| `skyPlanet` | `planet` | `mercury`, `venus`, `mars`, `jupiter`, `saturn` (mirrors `Planets.Body.rawValue`) |
| `skyNoPlanets` | none | untagged only — zero-visible-planets row |
| `skyAurora` | `band` | `none`, `low`, `fair`, `good`, `strong` (mirrors `AuroraBand.description`) |
| `skyISSPass` | none | untagged only — shown alongside a visible ISS pass |
| `skyNoISS` | none | untagged only — no visible pass tonight |
| `skyMoon` | `phase` | `new`, `waxing`, `full`, `waning` — coarser than the Moon row's own 8-phase name/symbol, which `TonightSkyCard` computes directly from the engine's `phaseFraction`/`illuminatedPercent` |
| `skyMeteor` | `interference` | `none`, `some`, `severe` (mirrors `MeteorShowers.MoonInterference`). Every variant uses the `{shower}` token (see below) rather than naming a shower directly, since the same pool backs whichever shower is active tonight |
| `skyPairing` | none | untagged only — shown alongside tonight's closest visible pairing; deliberately generic since the row's own text already names the specific bodies/separation |

A missing tag key on an entry (or the literal fallback entries with fewer tags — see
"Fallback" below) means "matches anything for that key." The universal safety-net entries
for `summary`/`doodleCaption` carry no `tags` at all so they match any condition/tempBand as
a last resort.

### "Tonight's Sky" content (PRD Revision Notes 2026-07-17; sky-intelligence rows added in
work package WP-F)

The eight slots above (`skyPlanet`, `skyNoPlanets`, `skyAurora`, `skyISSPass`, `skyNoISS`,
`skyMoon`, `skyMeteor`, `skyPairing`) back the "Tonight's Sky" card
(`Sources/Forecast/TonightSkyCard.swift`), fed by the on-device Astronomy engine plus the
networked ISS/Aurora engines and the on-device meteor-shower/conjunction engines (`Sources/Sky/`).
These lines are deliberately the *wit*, not the *teaching* — the planet row's inline expansion
also shows a static, non-witty "find it" blurb (`Sources/Forecast/SkyFindItGuide.swift`) and a
brightness-in-plain-English helper string; the phrase-bank line is the dry tail on top of both,
same "fact first, wit as a tail" register as everything else in this file. `skyMeteor`/
`skyPairing` follow the same split: the meteor/conjunction rows' own text carries the facts (rate,
window, separation, direction), and the phrase-bank line underneath is the wit only.

The card's headline row ("Step outside at 9:42 PM" + a one-line factual subtitle naming the
moment) is **not** phrase-bank content — it's driven entirely by `BestMoment.bestMoment` (a typed
picker over ISS/aurora/meteor/conjunction/planet/moonrise data, see that file's doc comment) and
rendered as plain factual text in `TonightSkyCard`, with no wit line of its own and no dedicated
"nothing happening" slot — when `bestMoment` is `nil`, the row is simply omitted.

The card's one-line nightly space fact (`Sources/PhraseBank/skyfacts.json`, 200+ entries, each
≤140 characters) is a flat JSON array of strings rather than the tagged-entry shape above — it
has no tag dimension to bucket on, just a single large rotation pool — so it's loaded and
rotated by a separate small loader, `Sources/PhraseBank/SkyFacts.swift`, which reuses this
file's `PhraseBank.pick(from:bucketKey:locationId:date:)` rotation primitive directly rather
than reimplementing the FNV/Fisher-Yates machinery.

### Template tokens

Filled at render time by the caller (`ForecastViewModel` gathers these from `CachedWeather` /
`SavedLocation` / `UnitsSettings`), substituted verbatim into `{token}` placeholders:

| Token | Meaning | Example |
|---|---|---|
| `{temp}` | Current temperature, already formatted with the degree sign per Settings' F/C unit (see `TemperatureFormatting.string`) | `88°` |
| `{feelsLike}` | Current feels-like temperature, same formatting | `92°` |
| `{high}` | Today's forecasted high | `91°` |
| `{low}` | Today's forecasted low | `68°` |
| `{condition}` | Human condition description as reported by WeatherKit | `Light Rain` |
| `{city}` | Active/ranked location's display name | `Springfield` |
| `{delta}` | Absolute temperature difference vs. yesterday, formatted (direction is expressed by the entry's own wording, keyed by `direction`) | `6°` |
| `{chance}` | Precipitation chance, formatted as a percent | `40%` |
| `{time}` | Friendly hour of today's peak precipitation chance (rain/snow lines only); always resolvable — falls back to "later" if no hour clears the threshold | `2 PM` |
| `{rank}` | Ordinal rank position (Rankings) | `1st` |
| `{score}` | Composite pleasantness score, 0-100 (Rankings) | `74` |
| `{shower}` | Tonight's active meteor shower's display name (`skyMeteor` lines only) | `Perseids` |

Not every line uses every token — most use one or two. A token that appears in a line but
isn't supplied by the caller renders as a literal `{token}`; this should never happen in
practice because `ForecastViewModel` always populates the full token set before rendering
(see its `phraseTokens(for:)` helper).

## tempBand thresholds

Defined once, in `PhraseBank.swift`, based on Fahrenheit regardless of the user's display
unit (Settings' F/C toggle only affects `{temp}`-style token *formatting*, never which
bucket of copy is selected — so switching units never silently changes the joke):

- `cold`: below 45°F
- `mild`: 45°F–82°F (inclusive)
- `hot`: above 82°F

## Fallback chain (never renders "—" or empty)

`summary` / `doodleCaption`: exact `(condition, tempBand)` → `(condition, any tempBand)` →
universal (untagged) entries. `comparison`: exact `(direction, magnitude)` → `(direction,
any magnitude)` → universal. `rankingVerdict`: exact `(position, pleasantness)` → `(position,
any pleasantness)` → universal. `emptyState` / `errorState`: exact `context` → universal.
If the JSON itself somehow fails to load or a slot is entirely empty, `PhraseBank.swift`
has one hardcoded Swift-side string per slot as the absolute last resort.

## Deterministic rotation

See `PhraseBank.swift`'s doc comment for the full algorithm. Summary: each *resolved bucket*
(the tag-set that actually matched) gets a fixed pseudo-random permutation of its variant
indices, seeded by a stable (non-randomized) hash of `slot + resolved tags + locationId`.
The day number (days since a fixed epoch) indexes into that permutation modulo the bucket's
size. This guarantees: same day + same location + same bucket -> same line, always (across
app launches, not just within one session); a full cycle through all variants before any
repeat; and no repeat on immediately consecutive days whenever a bucket has 2+ variants.
Different locations get different permutations of the same bucket, so two cities showing the
same bucket on the same day don't necessarily show the same line.

## Content workflow

Per PRD Section 8: Claude drafts, Justin reviews via `_review/phase4-voice-samples.md` before
it ships. Every line here was checked against the six canonical lines in PRD Section 6
("Voice register (canonical)") — understated, deadpan, info before the bit, never mean.
