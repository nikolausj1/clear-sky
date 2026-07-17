import SwiftUI

/// PRD Revision Notes (2026-07-17): the "Tonight's Sky" card — moon phase, naked-eye planet
/// visibility, aurora likelihood, and ISS passes — mounted between the daily forecast card and
/// the attribution footer in `ForecastPageView.loadedView`.
///
/// Row order (PRD work order): Moon, Planets, Aurora, ISS, Sky note. Moon/planets are on-device
/// (`SkyTonightService.astronomy`, synchronous) and render immediately; Aurora/ISS are networked
/// (`SkyTonightService.state`, async) and show a skeleton placeholder until resolved, degrading
/// to "—" on failure rather than blocking anything else. Uses the exact same fade + `.clipped()`
/// inline-expand mechanism as `DailyForecastSection`'s day rows for the planet detail expansion.
struct TonightSkyCard: View {
    let location: SavedLocation
    let date: Date
    var forcedOverrides: SkyTonightService.ForcedOverrides? = nil

    @State private var astronomy: SkyTonight.TonightSky?
    @State private var issState: SkyTonightService.SectionState<[ISSPass]> = .loading
    @State private var auroraState: SkyTonightService.SectionState<AuroraOutlook> = .loading
    @State private var expandedPlanet: Planets.Body?

    private var timeZone: TimeZone { .current }

    /// Sim-verify only: `-expandSkyPlanet mercury|venus|mars|jupiter|saturn` (see
    /// `NavigationShell`) pre-expands a planet row at launch — mirrors `-expandDay`'s rationale
    /// on `DailyForecastSection`: `simctl` can't tap through to an expanded row for a screenshot.
    init(
        location: SavedLocation,
        date: Date,
        forcedOverrides: SkyTonightService.ForcedOverrides? = nil,
        initialExpandedPlanet: Planets.Body? = nil
    ) {
        self.location = location
        self.date = date
        self.forcedOverrides = forcedOverrides
        self._expandedPlanet = State(initialValue: initialExpandedPlanet)
    }

    var body: some View {
        SheetCard(title: "TONIGHT'S SKY") {
            VStack(alignment: .leading, spacing: 0) {
                if let astronomy {
                    moonRow(astronomy.moon)
                    Divider()
                    planetsSection(astronomy.planets)
                    Divider()
                    auroraRow
                    Divider()
                    issRow
                    Divider()
                    factRow
                } else {
                    skeletonRows
                }
            }
        }
        .id(Self.cardId)
        .task(id: taskKey) {
            await load()
        }
    }

    /// Sim-verify only: a stable id for `ScrollViewProxy.scrollTo` (see `ForecastPageView`'s
    /// `-scrollToSky` handling, mirroring `-scrollToAttribution`).
    static let cardId = "tonightSkyCard"

    /// Re-runs `load()` whenever the location, calendar evening, or a forced sim-verify override
    /// changes — `.task(id:)` cancels/restarts automatically on any change, same pattern
    /// `ForecastPageView.loadedView`'s `.onChange(of: viewModel.selectedMetric)` relies on
    /// elsewhere for "re-derive when an input changes."
    private var taskKey: String {
        var parts = ["\(location.id)", "\(Calendar.current.startOfDay(for: date).timeIntervalSince1970)"]
        if let overrides = forcedOverrides {
            parts.append("band=\(overrides.auroraBand?.description ?? "nil")")
            parts.append("issPass=\(overrides.issPass)")
            parts.append("noISS=\(overrides.noISS)")
            parts.append("unavailable=\(overrides.unavailable)")
        }
        return parts.joined(separator: "|")
    }

    private func load() async {
        // Astronomy first (synchronous, cheap) so the moon/planet rows render immediately,
        // before the networked sections below even start.
        let astro = SkyTonightService.astronomy(latitude: location.latitude, longitude: location.longitude, date: date, timeZone: timeZone)
        astronomy = astro
        issState = .loading
        auroraState = .loading

        let result = await SkyTonightService.shared.state(
            locationId: location.id,
            latitude: location.latitude,
            longitude: location.longitude,
            date: date,
            timeZone: timeZone,
            overrides: forcedOverrides
        )
        issState = result.iss
        auroraState = result.aurora
    }

    // MARK: - Moon

    private func moonRow(_ moon: SkyTonight.MoonInfo) -> some View {
        let quarter = Self.moonQuarter(illuminatedPercent: moon.illuminatedPercent, phaseFraction: moon.phaseFraction)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 12) {
                Image(systemName: Self.moonSymbolName(phaseFraction: moon.phaseFraction))
                    .font(.title2)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(Color.clearSkyAccent)
                    .frame(width: 28)

                VStack(alignment: .leading, spacing: 2) {
                    Text(Self.moonPhaseName(phaseFraction: moon.phaseFraction))
                        .font(.subheadline.weight(.semibold))
                    Text(Self.moonRiseSetText(moon))
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Text("\(Int(moon.illuminatedPercent.rounded()))%")
                    .font(.subheadline)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }

            Text(PhraseBank.skyMoon(quarter: quarter, date: date, locationId: location.id))
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 8)
    }

    /// 8 equal-width (45°/0.125) phase bins, offset by half a bin so New/Full land centered on
    /// `phaseFraction` 0 and 0.5 rather than at a bin edge.
    private static func moonPhaseName(phaseFraction: Double) -> String {
        switch phaseFraction {
        case 0..<0.0625, 0.9375...1.0: return "New Moon"
        case 0.0625..<0.1875: return "Waxing Crescent"
        case 0.1875..<0.3125: return "First Quarter"
        case 0.3125..<0.4375: return "Waxing Gibbous"
        case 0.4375..<0.5625: return "Full Moon"
        case 0.5625..<0.6875: return "Waning Gibbous"
        case 0.6875..<0.8125: return "Last Quarter"
        default: return "Waning Crescent"
        }
    }

    private static func moonSymbolName(phaseFraction: Double) -> String {
        switch phaseFraction {
        case 0..<0.0625, 0.9375...1.0: return "moonphase.new.moon"
        case 0.0625..<0.1875: return "moonphase.waxing.crescent"
        case 0.1875..<0.3125: return "moonphase.first.quarter"
        case 0.3125..<0.4375: return "moonphase.waxing.gibbous"
        case 0.4375..<0.5625: return "moonphase.full.moon"
        case 0.5625..<0.6875: return "moonphase.waning.gibbous"
        case 0.6875..<0.8125: return "moonphase.last.quarter"
        default: return "moonphase.waning.crescent"
        }
    }

    /// The coarser 4-quarter bucketing `PhraseBank.skyMoon` queries on (see that function's doc
    /// comment) — driven off `illuminatedPercent` for new/full (a direct, unambiguous read) and
    /// `phaseFraction`'s waxing/waning half otherwise.
    private static func moonQuarter(illuminatedPercent: Double, phaseFraction: Double) -> PhraseBank.MoonQuarter {
        if illuminatedPercent < 5 { return .new }
        if illuminatedPercent > 95 { return .full }
        return phaseFraction < 0.5 ? .waxing : .waning
    }

    private static func moonRiseSetText(_ moon: SkyTonight.MoonInfo) -> String {
        let rise = moon.rise.map { timeFormatter.string(from: $0) } ?? "—"
        let set = moon.set.map { timeFormatter.string(from: $0) } ?? "—"
        return "Rises \(rise) · Sets \(set)"
    }

    // MARK: - Planets

    private func planetsSection(_ planets: [SkyTonight.PlanetVisibility]) -> some View {
        let visible = planets.filter(\.isVisibleTonight)
        return Group {
            if visible.isEmpty {
                Text(PhraseBank.skyNoPlanets(date: date, locationId: location.id))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(visible.enumerated()), id: \.element.body) { index, planet in
                        planetRow(planet)
                        if index < visible.count - 1 {
                            Divider()
                        }
                    }
                }
            }
        }
    }

    private func planetRow(_ planet: SkyTonight.PlanetVisibility) -> some View {
        let isExpanded = expandedPlanet == planet.body
        return VStack(spacing: 0) {
            Button {
                // Same spring + inline-fade mechanism as `DailyForecastRow.onTap`.
                withAnimation(.spring(duration: 0.35)) {
                    expandedPlanet = (expandedPlanet == planet.body) ? nil : planet.body
                }
            } label: {
                HStack(spacing: 10) {
                    Text(planet.body.displayName)
                        .font(.subheadline.weight(.semibold))
                        .frame(width: 62, alignment: .leading)

                    Text(planet.directionDescription ?? "")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)

                    Spacer(minLength: 8)

                    if let start = planet.bestViewingStart, let end = planet.bestViewingEnd {
                        Text(Self.windowText(start: start, end: end))
                            .font(.footnote)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }

                    Image(systemName: "chevron.down")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isExpanded ? 180 : 0))
                }
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(PressableRowStyle())

            if isExpanded {
                planetExpandedDetail(planet)
            }
        }
        // Same masking technique as `DailyForecastRow`: clips the expanding detail to this
        // row's animated bounds so the reveal unfolds in place instead of painting over the
        // rows below it mid-animation.
        .clipped()
    }

    /// Fade-only reveal (no `.move`) — identical rationale to `DailyExpandedDetail`'s own
    /// comment: a `.move(edge: .top)` transition here would visibly slide the detail over the
    /// row above during the expand animation; the clean unfold comes entirely from the row's
    /// animated height + `.clipped()` above, with this view just fading in beneath it.
    private func planetExpandedDetail(_ planet: SkyTonight.PlanetVisibility) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(SkyFindItGuide.blurb(for: planet.body))
                .font(.footnote)

            if let magnitude = planet.apparentMagnitude {
                Text(Self.magnitudeDescription(magnitude))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Text(PhraseBank.skyPlanet(planet.body, date: date, locationId: location.id))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .italic()
        }
        .padding(.leading, 8)
        .padding(.top, 2)
        .padding(.bottom, 6)
        .transition(.opacity)
    }

    /// Plain-English brightness helper text (PRD ask: "'bright as the brightest stars' style
    /// helper text, not raw numbers alone"). Lower (more negative) apparent magnitude = brighter.
    private static func magnitudeDescription(_ magnitude: Double) -> String {
        switch magnitude {
        case ..<(-3): return "Brighter than every star in the sky — only the Moon can outshine it tonight."
        case -3..<(-1): return "Brighter than any star in the night sky."
        case -1..<0.5: return "As bright as the brightest stars up there."
        case 0.5..<1.5: return "As bright as a prominent, easy-to-spot star."
        case 1.5..<3: return "A modest, steady point of light."
        default: return "Faint — best from a dark sky, away from city lights."
        }
    }

    private static func windowText(start: Date, end: Date) -> String {
        "\(timeFormatter.string(from: start))–\(timeFormatter.string(from: end))"
    }

    // MARK: - Aurora

    @ViewBuilder
    private var auroraRow: some View {
        switch auroraState {
        case .loading:
            skeletonLine
        case .unavailable:
            unavailableRow(label: "Aurora", note: "Aurora data unavailable right now.")
        case .available(let outlook):
            if outlook.band == .none {
                Text(PhraseBank.skyAurora(band: .none, date: date, locationId: location.id))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    Text(Self.auroraHeadline(outlook))
                        .font(.subheadline)
                        .monospacedDigit()
                    Text(PhraseBank.skyAurora(band: outlook.band, date: date, locationId: location.id))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 8)
            }
        }
    }

    /// "Aurora: fair chance · best 11 PM–1 AM" (+ "· 22% now" only when `chanceNow` clears 5%,
    /// per the PRD's "avoid fake precision" note).
    private static func auroraHeadline(_ outlook: AuroraOutlook) -> String {
        var parts = ["Aurora: \(outlook.band.description) chance"]
        parts.append("best \(timeFormatter.string(from: outlook.bestViewingWindow.start))–\(timeFormatter.string(from: outlook.bestViewingWindow.end))")
        if outlook.chanceNow >= 5 {
            parts.append("\(outlook.chanceNow)% now")
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - ISS

    @ViewBuilder
    private var issRow: some View {
        switch issState {
        case .loading:
            skeletonLine
        case .unavailable:
            unavailableRow(label: "ISS", note: "ISS pass data unavailable right now.")
        case .available(let passes):
            if passes.isEmpty {
                Text(PhraseBank.skyNoISS(date: date, locationId: location.id))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(passes.prefix(2).enumerated()), id: \.offset) { _, pass in
                        Text(Self.issPassText(pass))
                            .font(.subheadline)
                            .monospacedDigit()
                    }
                    Text(PhraseBank.skyISSPass(date: date, locationId: location.id))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 8)
            }
        }
    }

    /// "9:42 PM · WNW→ESE · 4 min · bright" — PRD-specified row format.
    private static func issPassText(_ pass: ISSPass) -> String {
        let durationMinutes = max(1, Int((pass.endTime.timeIntervalSince(pass.startTime) / 60.0).rounded()))
        return "\(timeFormatter.string(from: pass.startTime)) · \(pass.startAzimuthCompass)→\(pass.endAzimuthCompass) · \(durationMinutes) min · \(pass.brightness.rawValue)"
    }

    // MARK: - Sky note

    private var factRow: some View {
        Text(SkyFacts.tonight(date: date, locationId: location.id))
            .font(.footnote)
            .foregroundStyle(.secondary)
            .padding(.vertical, 8)
    }

    // MARK: - Shared row chrome

    private func unavailableRow(label: String, note: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text("—")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Text(note)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 8)
    }

    /// A single redacted-placeholder line for an async row still resolving (`.loading`).
    private var skeletonLine: some View {
        RoundedRectangle(cornerRadius: 6)
            .fill(Color(.tertiarySystemFill))
            .frame(height: 16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 8)
    }

    /// Full-card skeleton — only shown in the (normally near-instantaneous, since astronomy is
    /// synchronous) moment before `astronomy` has been set at all.
    private var skeletonRows: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(0..<4, id: \.self) { _ in
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(.tertiarySystemFill))
                    .frame(height: 16)
            }
        }
        .padding(.vertical, 8)
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        return formatter
    }()
}
