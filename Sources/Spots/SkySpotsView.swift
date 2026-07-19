import SwiftUI

/// The Sky Spots tab (replaces the old City Power Rankings screen): "your saved cities, ranked
/// by tonight's stargazing score" up top, then the curated `SkySpot` atlas's three world-spanning
/// sections underneath -- launch sites, aurora capitals, dark-sky legends. Built on the same
/// always-dark surface the Space tab redesign introduced (`SpaceDarkBackground`/`SpacePanelCard`/
/// `SpaceHairlineDivider` from `Sources/Space/SpaceDarkTheme.swift`) -- per work order, "this is a
/// space surface," same rationale `SpaceView`'s own doc comment gives for going all-dark rather
/// than reusing the light `SheetCard`.
struct SkySpotsView: View {
    /// Sim-verify only: `-scrollSpotsTo launchSites|aurora|darkSky` (see `NavigationShell`)
    /// scrolls straight to a card below the fold at launch -- `simctl` can't scroll, mirroring
    /// `SpaceView.ScrollTarget`.
    enum ScrollTarget: String {
        case launchSites
        case aurora
        case darkSky
    }

    @Environment(UnitsSettings.self) private var unitsSettings
    @Bindable var viewModel: SkySpotsViewModel

    /// Tapping a ranked city switches the Forecast tab to it -- same mechanism the old
    /// `RankingsView.onSelectCity` gave `NavigationShell`.
    var onSelectCity: ((SavedLocation) -> Void)?
    var scrollTarget: ScrollTarget? = nil
    /// Sim-verify only: `-expandSpotId <id>` (an `id` from `skyspots.json`, e.g.
    /// "cape-canaveral") pre-expands that row's inline blurb/coordinates/distance detail at
    /// launch -- `simctl` can't tap a row to expand it.
    var initialExpandedSpotId: String? = nil

    /// Which non-city row (keyed by `SkySpot.id`) has its blurb/coordinates/distance expanded --
    /// the same fade + `.clipped()` inline-expand pattern `TonightSkyCard.planetRow` uses (see
    /// that file's doc comments), reproduced here since this view has no access to that file's
    /// `private` detail view.
    @State private var expandedSpotId: String?
    @State private var hasScrolledToTarget = false

    private static let launchSitesCardId = "spotsLaunchSitesCard"
    private static let auroraCardId = "spotsAuroraCard"
    private static let darkSkyCardId = "spotsDarkSkyCard"

    init(
        viewModel: SkySpotsViewModel,
        onSelectCity: ((SavedLocation) -> Void)? = nil,
        scrollTarget: ScrollTarget? = nil,
        initialExpandedSpotId: String? = nil
    ) {
        self.viewModel = viewModel
        self.onSelectCity = onSelectCity
        self.scrollTarget = scrollTarget
        self.initialExpandedSpotId = initialExpandedSpotId
        self._expandedSpotId = State(initialValue: initialExpandedSpotId)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                SpaceDarkBackground()
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 16) {
                            citiesCard
                            launchSitesCard.id(Self.launchSitesCardId)
                            auroraCard.id(Self.auroraCardId)
                            darkSkyCard.id(Self.darkSkyCardId)
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 16)
                        // Same floating-bottom-bar clearance every other tab's scroll surface
                        // gives its last card (`SpaceView`/`ForecastPageView`'s own
                        // `.padding(.bottom, 70)`).
                        .padding(.bottom, 70)
                    }
                    .scrollContentBackground(.hidden)
                    .onAppear {
                        scrollToTargetIfNeeded(proxy: proxy)
                    }
                }
            }
            .navigationTitle("Sky Spots")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
        }
        .task {
            await viewModel.refresh()
        }
    }

    private func scrollToTargetIfNeeded(proxy: ScrollViewProxy) {
        guard !hasScrolledToTarget, let scrollTarget else { return }
        hasScrolledToTarget = true
        let id: String
        switch scrollTarget {
        case .launchSites: id = Self.launchSitesCardId
        case .aurora: id = Self.auroraCardId
        case .darkSky: id = Self.darkSkyCardId
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            proxy.scrollTo(id, anchor: .top)
        }
    }

    // MARK: - Section 1: Your Cities Tonight

    private var citiesCard: some View {
        SpacePanelCard(title: "YOUR CITIES TONIGHT") {
            VStack(alignment: .leading, spacing: 0) {
                if viewModel.locations.isEmpty {
                    quietLine("Save a city to see it ranked here for tonight's stargazing.")
                } else {
                    let rankings = viewModel.cityRankings
                    if rankings.isEmpty {
                        quietLine(
                            viewModel.isLoadingAnyCity
                                ? "Loading tonight's scores for your saved cities."
                                : "No cached forecast yet for your saved cities."
                        )
                    } else {
                        ForEach(Array(rankings.enumerated()), id: \.element.city) { index, ranking in
                            cityRow(ranking)
                            if index < rankings.count - 1 {
                                SpaceHairlineDivider()
                            }
                        }
                    }
                }
            }
        }
    }

    private func cityRow(_ ranking: SkySpots.CityRanking) -> some View {
        Button {
            guard let location = viewModel.locations.first(where: { $0.name == ranking.city }) else { return }
            onSelectCity?(location)
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    limitingFactorGlyph(ranking.limitingFactor)
                    Text(ranking.city)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                    Spacer(minLength: 8)
                }
                citySkyBar(score: ranking.tonightScore)
            }
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableRowStyle())
    }

    @ViewBuilder
    private func limitingFactorGlyph(_ factor: BestNight.LimitingFactor) -> some View {
        switch factor {
        case .clouds:
            Image(systemName: "cloud.fill")
                .font(.caption)
                .foregroundStyle(Color.white.opacity(0.55))
        case .moon:
            Image(systemName: "moon.fill")
                .font(.caption)
                .foregroundStyle(Color.white.opacity(0.55))
        case .none:
            Image(systemName: "sparkles")
                .font(.caption)
                .foregroundStyle(Color.clearSkyAccentOnDark.opacity(0.8))
        }
    }

    /// "7 · Good" -- same visual style as `HourlyForecastSection`'s stargazing-score chip bar
    /// (accent fill whose opacity steps by quality tier, monospaced score + quality word), reused
    /// here on tonight's per-city `BestNight` rating rather than that file's private hourly bar
    /// view, which this target can't reach directly. `StargazingScore.QualityLabel.forScore(_:)`
    /// itself IS reused directly (both scores share the same 0...10 scale).
    private func citySkyBar(score: Int) -> some View {
        let quality = StargazingScore.QualityLabel.forScore(score)
        return HStack(spacing: 10) {
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.12))
                    Capsule()
                        .fill(Color.clearSkyAccentOnDark.opacity(Self.skyBarFillOpacity(quality)))
                        .frame(width: proxy.size.width * CGFloat(score) / 10)
                }
            }
            .frame(height: 6)

            Text("\(score)").font(.subheadline.weight(.semibold)).monospacedDigit().foregroundStyle(.white)
                + Text(" \u{00B7} \(Self.qualityWord(quality))").font(.caption2).foregroundStyle(Color.white.opacity(0.65))
        }
    }

    private static func skyBarFillOpacity(_ quality: StargazingScore.QualityLabel) -> Double {
        switch quality {
        case .poor: return 0.35
        case .fair: return 0.55
        case .good: return 0.8
        case .excellent: return 1.0
        }
    }

    private static func qualityWord(_ quality: StargazingScore.QualityLabel) -> String {
        switch quality {
        case .poor: return "Poor"
        case .fair: return "Fair"
        case .good: return "Good"
        case .excellent: return "Excellent"
        }
    }

    // MARK: - Section 2: Launch Sites

    private var launchSitesCard: some View {
        SpacePanelCard(title: "LAUNCH SITES") {
            VStack(alignment: .leading, spacing: 0) {
                switch viewModel.launchesState {
                case .loading:
                    cardSkeleton
                case .unavailable, .loaded:
                    let spots = viewModel.launchSiteSpots
                    ForEach(Array(spots.enumerated()), id: \.element.id) { index, spot in
                        launchSiteRow(spot)
                        if index < spots.count - 1 {
                            SpaceHairlineDivider()
                        }
                    }
                }
            }
        }
    }

    private func launchSiteRow(_ spot: SkySpot) -> some View {
        let nextLaunch = viewModel.nextLaunch(for: spot)
        let vehicleClass = nextLaunch.map { LaunchVehicleClass.classify(vehicle: $0.vehicle, provider: $0.provider) }
        let isExpanded = expandedSpotId == spot.id

        return VStack(spacing: 0) {
            Button {
                withAnimation(.spring(duration: 0.35)) {
                    expandedSpotId = (expandedSpotId == spot.id) ? nil : spot.id
                }
            } label: {
                HStack(alignment: .top, spacing: 10) {
                    RocketSilhouette(
                        vehicleClass: vehicleClass ?? .small,
                        size: 26,
                        tint: .white.opacity(vehicleClass == nil ? 0.3 : 0.85)
                    )
                    .frame(width: 26, height: 26)
                    .padding(.top, 2)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(spot.name)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white)
                        if let nextLaunch {
                            HStack(spacing: 6) {
                                Text("Next: \(nextLaunch.missionName) \u{00B7} \(Self.launchDateText(nextLaunch))")
                                    .font(.footnote)
                                    .foregroundStyle(Color.white.opacity(0.65))
                                    .lineLimit(1)
                                LaunchStatusChip(status: nextLaunch.status)
                            }
                        } else {
                            Text("No launch currently scheduled.")
                                .font(.footnote)
                                .foregroundStyle(Color.white.opacity(0.5))
                        }
                    }
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.down")
                        .font(.caption2)
                        .foregroundStyle(Color.white.opacity(0.4))
                        .rotationEffect(.degrees(isExpanded ? 180 : 0))
                        .padding(.top, 4)
                }
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(PressableRowStyle())

            if isExpanded {
                spotExpandedDetail(spot)
            }
        }
        .clipped()
    }

    private static func launchDateText(_ launch: UpcomingLaunch) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = launch.netPrecision == .approximate ? "MMM d" : "MMM d, h:mm a"
        return formatter.string(from: launch.net)
    }

    // MARK: - Section 3: Aurora Capitals

    private var auroraCard: some View {
        SpacePanelCard(title: "AURORA CAPITALS") {
            VStack(alignment: .leading, spacing: 0) {
                switch viewModel.auroraFeedState {
                case .loading:
                    cardSkeleton
                case .unavailable:
                    quietLine("Aurora outlook unavailable right now.")
                case .loaded:
                    let rows = viewModel.auroraRows
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                        auroraRow(row)
                        if index < rows.count - 1 {
                            SpaceHairlineDivider()
                        }
                    }
                }
            }
        }
    }

    private func auroraRow(_ row: SkySpotsViewModel.AuroraSpotRow) -> some View {
        let isExpanded = expandedSpotId == row.spot.id
        return VStack(spacing: 0) {
            Button {
                withAnimation(.spring(duration: 0.35)) {
                    expandedSpotId = (expandedSpotId == row.spot.id) ? nil : row.spot.id
                }
            } label: {
                HStack(spacing: 10) {
                    Circle()
                        .fill(Color.green.opacity(Self.auroraDotOpacity(row.outlook.band)))
                        .frame(width: 10, height: 10)
                        .shadow(
                            color: .green.opacity(row.outlook.band >= .good ? 0.8 : 0),
                            radius: row.outlook.band >= .good ? 5 : 0
                        )
                    Text("\(row.spot.name) \u{2014} \(Self.auroraOutlookPhrase(row.outlook.band))")
                        .font(.subheadline)
                        .foregroundStyle(.white)
                        .lineLimit(2)
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.down")
                        .font(.caption2)
                        .foregroundStyle(Color.white.opacity(0.4))
                        .rotationEffect(.degrees(isExpanded ? 180 : 0))
                }
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(PressableRowStyle())

            if isExpanded {
                spotExpandedDetail(row.spot)
            }
        }
        .clipped()
    }

    /// Single-hue (green) sequential encoding, opacity only -- same dataviz discipline
    /// `RankingsView.scoreBar`'s doc comment documents ("hue must NOT vary," a bolder fill of the
    /// same color reads as "better," never a different color).
    private static func auroraDotOpacity(_ band: AuroraBand) -> Double {
        switch band {
        case .none: return 0.2
        case .low: return 0.4
        case .fair: return 0.6
        case .good: return 0.8
        case .strong: return 1.0
        }
    }

    private static func auroraOutlookPhrase(_ band: AuroraBand) -> String {
        switch band {
        case .none: return "no aurora expected tonight"
        case .low: return "slim chance tonight"
        case .fair: return "fair chance tonight"
        case .good: return "good chance tonight"
        case .strong: return "strong chance tonight"
        }
    }

    // MARK: - Section 4: Dark Sky Legends

    private var darkSkyCard: some View {
        SpacePanelCard(title: "DARK SKY LEGENDS") {
            VStack(alignment: .leading, spacing: 0) {
                let rows = viewModel.darkSkyRows
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                    darkSkyRow(row)
                    if index < rows.count - 1 {
                        SpaceHairlineDivider()
                    }
                }
            }
        }
    }

    private func darkSkyRow(_ row: SkySpotsViewModel.DarkSkySpotRow) -> some View {
        let isExpanded = expandedSpotId == row.spot.id
        return VStack(spacing: 0) {
            Button {
                withAnimation(.spring(duration: 0.35)) {
                    expandedSpotId = (expandedSpotId == row.spot.id) ? nil : row.spot.id
                }
            } label: {
                HStack(alignment: .top, spacing: 10) {
                    MoonPhaseDisc(
                        illumination: row.tonight.moonIlluminationPct / 100,
                        waxing: true,
                        diameter: 20,
                        style: .dark,
                        showsRim: row.tonight.moonIlluminationPct < 15
                    )
                    .padding(.top, 1)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(row.spot.name)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white)
                        Text(row.tonight.note)
                            .font(.footnote)
                            .foregroundStyle(Color.white.opacity(0.65))
                        if let bortleNote = row.spot.bortleNote {
                            Text(bortleNote)
                                .font(.caption)
                                .foregroundStyle(Color.clearSkyAccentOnDark.opacity(0.85))
                        }
                    }
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.down")
                        .font(.caption2)
                        .foregroundStyle(Color.white.opacity(0.4))
                        .rotationEffect(.degrees(isExpanded ? 180 : 0))
                        .padding(.top, 4)
                }
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(PressableRowStyle())

            if isExpanded {
                spotExpandedDetail(row.spot)
            }
        }
        .clipped()
    }

    // MARK: - Shared inline-expand detail (launch sites / aurora capitals / dark sky legends)

    /// Full blurb + coordinates + "≈{distance} away" from the user's first saved city -- work
    /// order: every non-city row expands inline for this. Fade-only reveal (no `.move`), identical
    /// rationale to `TonightSkyCard.planetExpandedDetail`'s own doc comment: the clean unfold
    /// comes entirely from the row's animated height + the row's own `.clipped()`, with this view
    /// just fading in beneath it.
    private func spotExpandedDetail(_ spot: SkySpot) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(spot.blurb)
                .font(.footnote)
                .foregroundStyle(Color.white.opacity(0.8))
            HStack(spacing: 6) {
                Text(Self.coordinateText(spot))
                    .font(.caption2)
                    .monospacedDigit()
                    .foregroundStyle(Color.white.opacity(0.5))
                if let distanceText = distanceText(to: spot) {
                    Text("\u{00B7} \u{2248}\(distanceText) away")
                        .font(.caption2)
                        .foregroundStyle(Color.white.opacity(0.5))
                }
            }
        }
        .padding(.leading, 36)
        .padding(.top, 2)
        .padding(.bottom, 8)
        .transition(.opacity)
    }

    private static func coordinateText(_ spot: SkySpot) -> String {
        let latDirection = spot.latitude >= 0 ? "N" : "S"
        let lonDirection = spot.longitude >= 0 ? "E" : "W"
        return String(format: "%.1f\u{00B0}%@, %.1f\u{00B0}%@", abs(spot.latitude), latDirection, abs(spot.longitude), lonDirection)
    }

    /// mi when the user's temperature unit is Fahrenheit, km when Celsius -- there's no separate
    /// distance-unit setting in `UnitsSettings` (PRD Section 11 only ever specified F/C), so this
    /// piggybacks on that same toggle as the app's one signal for "which measurement system," the
    /// same locale-derived convention `TemperatureUnit.systemDefault` already establishes.
    private func distanceText(to spot: SkySpot) -> String? {
        guard let km = viewModel.distanceKm(to: spot) else { return nil }
        switch unitsSettings.unit {
        case .fahrenheit:
            return "\(Int((km * 0.621371).rounded())) mi"
        case .celsius:
            return "\(Int(km.rounded())) km"
        }
    }

    // MARK: - Shared row chrome

    private func quietLine(_ text: String) -> some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(Color.white.opacity(0.65))
            .padding(.vertical, 8)
    }

    private var cardSkeleton: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(0..<3, id: \.self) { _ in
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.white.opacity(0.12))
                    .frame(height: 16)
            }
        }
        .padding(.vertical, 8)
        .redacted(reason: .placeholder)
    }
}
