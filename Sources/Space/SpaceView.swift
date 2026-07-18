import SwiftUI

/// The Space tab (work package WP-K, then the all-dark Space tab redesign): a next-launch hero,
/// launch schedule, solar activity, and a 30-day sky calendar — four cards on the Space tab's own
/// always-dark surface (`SpaceDarkBackground`), regardless of the device's system light/dark
/// mode. This is the second surface in the app (after `TonightSkyCard`'s night panel) to commit
/// to an inverted identity — here the WHOLE screen does it, not just one card, since a page about
/// the night sky and rocket launches reads more like an observatory console than a grouped
/// settings list.
///
/// **Why every card here is a `SpacePanelCard`, not `SheetCard`:** `SheetCard` resolves its fill
/// to `.secondarySystemGroupedBackground`, which is white in light mode — exactly the "flash of
/// white" the redesign explicitly rules out ("Space tab still dark [in light mode], no white
/// flashes"). `SpacePanelCard` uses an explicit `white.opacity(0.06)` fill instead, so it never
/// depends on the system color scheme.
struct SpaceView: View {
    /// Sim-verify only: `-scrollSpaceTo sun|calendar` (see `NavigationShell`) scrolls straight to
    /// a card below the fold at launch -- `simctl` can't scroll, mirroring `ForecastPageView`'s
    /// `-scrollToAttribution`/`-scrollToSky`.
    enum ScrollTarget: String {
        case sun
        case calendar
    }

    @Bindable var viewModel: SpaceViewModel
    /// The location to compute the Sky Calendar's location-dependent rows (meteor peaks, close
    /// pairings) from -- resolved by `NavigationShell` as "active Forecast location, else first
    /// saved location, else `nil`" (see that file's `spaceLocation` doc comment). `nil` hides
    /// those rows entirely; the Launch Schedule and Sun cards don't use this at all.
    var location: SavedLocation?
    var scrollTarget: ScrollTarget? = nil
    /// Sim-verify only: `-showLaunchDetail` opens the detail sheet for the first available launch
    /// at launch (`simctl` can't tap a row) — pairs naturally with `-forceLaunchesSample` so a
    /// screenshot doesn't depend on a real schedule existing.
    var showLaunchDetailAtLaunch: Bool = false

    @State private var hasScrolledToTarget = false
    @State private var hasShownLaunchDetailHook = false
    @State private var presentedLaunch: UpcomingLaunch?
    @Environment(\.scenePhase) private var scenePhase

    private static let sunCardId = "spaceSunCard"
    private static let calendarCardId = "spaceCalendarCard"

    var body: some View {
        NavigationStack {
            ZStack {
                SpaceDarkBackground()
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 16) {
                            nextLaunchHeroCard
                            launchScheduleCard
                            sunCard.id(Self.sunCardId)
                            skyCalendarCard.id(Self.calendarCardId)
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 16)
                        // Extra clearance so the last card's content isn't flush against the
                        // floating bottom bar (`NavigationShell.floatingBar`), which overlays this
                        // screen -- same treatment `ForecastPageView.sheetSurface` gives its own
                        // scroll content.
                        .padding(.bottom, 70)
                    }
                    .scrollContentBackground(.hidden)
                    .onAppear {
                        scrollToTargetIfNeeded(proxy: proxy)
                    }
                }
            }
            .navigationTitle("Space")
            .navigationBarTitleDisplayMode(.inline)
            // Dark-styled title/back-button ink regardless of the device's system appearance --
            // this screen's own identity is always dark (work order: "Space tab still dark [in
            // light mode], no white flashes").
            .toolbarColorScheme(.dark, for: .navigationBar)
        }
        .task {
            await viewModel.refresh()
        }
        .task(id: location?.id) {
            await viewModel.updateLocationAndRecomputeCalendar(location)
        }
        .sheet(item: $presentedLaunch) { launch in
            LaunchDetailSheet(launch: launch)
        }
        .onAppear {
            showLaunchDetailHookIfNeeded()
        }
        .onChange(of: viewModel.launchesState) {
            showLaunchDetailHookIfNeeded()
        }
    }

    private func scrollToTargetIfNeeded(proxy: ScrollViewProxy) {
        guard !hasScrolledToTarget, let scrollTarget else { return }
        hasScrolledToTarget = true
        let id = scrollTarget == .sun ? Self.sunCardId : Self.calendarCardId
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            proxy.scrollTo(id, anchor: .top)
        }
    }

    /// `-showLaunchDetail` sim-verify hook: presents the soonest launch's detail sheet as soon as
    /// the schedule has actually loaded (`simctl` can't tap a row to open it). Guarded so it only
    /// ever fires once, whenever `launchesState` first resolves to `.loaded` with a launch to
    /// show.
    private func showLaunchDetailHookIfNeeded() {
        guard showLaunchDetailAtLaunch, !hasShownLaunchDetailHook else { return }
        guard case .loaded(let launches, _) = viewModel.launchesState, let first = launches.first else { return }
        hasShownLaunchDetailHook = true
        presentedLaunch = first
    }

    // MARK: - Card 0: Next Launch hero

    /// The soonest `.go` launch, large -- mission name, provider/vehicle, pad location, a T-minus
    /// countdown, and the class silhouette with a soft glow. Only ever considers a `.go` launch
    /// (a Hold or TBD launch has no confident T-0 worth headlining); falls back to a quiet line
    /// when none is cached, per work order ("no .go launch cached: quiet fallback").
    private var nextGoLaunch: UpcomingLaunch? {
        guard case .loaded(let launches, _) = viewModel.launchesState else { return nil }
        return launches.first { $0.status == .go }
    }

    @ViewBuilder
    private var nextLaunchHeroCard: some View {
        SpacePanelCard(title: "NEXT LAUNCH") {
            switch viewModel.launchesState {
            case .loading:
                cardSkeleton
            case .unavailable:
                quietLine("Launch schedule unavailable right now.")
            case .loaded:
                if let launch = nextGoLaunch {
                    heroContent(launch)
                } else {
                    quietLine("Next launch times firm up closer to the day.")
                }
            }
        }
    }

    @State private var heroCountdownText: String?

    private func heroContent(_ launch: UpcomingLaunch) -> some View {
        let vehicleClass = LaunchVehicleClass.classify(vehicle: launch.vehicle, provider: launch.provider)
        return Button {
            presentedLaunch = launch
        } label: {
            HStack(alignment: .top, spacing: 16) {
                RocketSilhouette(vehicleClass: vehicleClass, size: 56, tint: .white.opacity(0.92))
                    .shadow(color: .white.opacity(0.55), radius: 16)

                VStack(alignment: .leading, spacing: 6) {
                    Text(launch.missionName)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                    Text("\(launch.providerAbbrev) \u{00B7} \(launch.vehicle)")
                        .font(.subheadline)
                        .foregroundStyle(Color.white.opacity(0.65))
                    Text(launch.locationDisplay)
                        .font(.footnote)
                        .foregroundStyle(Color.white.opacity(0.5))
                    if let heroCountdownText {
                        Text(heroCountdownText)
                            .font(.system(.title2, design: .rounded).weight(.semibold))
                            .monospacedDigit()
                            .foregroundStyle(Color.clearSkyAccentOnDark)
                            .padding(.top, 4)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onAppear {
            recomputeHeroCountdown(launch)
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                recomputeHeroCountdown(launch)
            }
        }
    }

    /// Recomputed on appear/foreground only -- spec: "no per-second live timer; minute precision
    /// is fine." `viewModel.referenceDateForDisplay` is real `Date()` unless `-forceDate`
    /// overrides it, matching every other "now" in this screen.
    private func recomputeHeroCountdown(_ launch: UpcomingLaunch) {
        heroCountdownText = Self.tMinusText(net: launch.net, now: viewModel.referenceDateForDisplay)
    }

    /// "T\u{2212}2d 4h" / "T\u{2212}3h 12m" -- largest two units, rounded to the minute. `nil`
    /// once the countdown has reached (or passed) zero -- the hero simply stops showing a stale
    /// countdown rather than displaying a negative one.
    private static func tMinusText(net: Date, now: Date) -> String? {
        let seconds = net.timeIntervalSince(now)
        guard seconds > 0 else { return nil }
        let totalMinutes = Int((seconds / 60).rounded())
        let days = totalMinutes / (24 * 60)
        let hours = (totalMinutes % (24 * 60)) / 60
        let minutes = totalMinutes % 60
        if days > 0 {
            return hours > 0 ? "T\u{2212}\(days)d \(hours)h" : "T\u{2212}\(days)d"
        } else if hours > 0 {
            return minutes > 0 ? "T\u{2212}\(hours)h \(minutes)m" : "T\u{2212}\(hours)h"
        } else if minutes > 0 {
            return "T\u{2212}\(minutes)m"
        }
        return "T\u{2212}0m"
    }

    // MARK: - Card 1: Launch Schedule

    private var launchScheduleCard: some View {
        SpacePanelCard(title: "LAUNCH SCHEDULE") {
            VStack(alignment: .leading, spacing: 0) {
                switch viewModel.launchesState {
                case .loading:
                    cardSkeleton
                case .unavailable:
                    quietLine("Launch schedule unavailable right now.")
                case .loaded(let launches, let isStale):
                    if launches.isEmpty {
                        quietLine("Nothing on the schedule in the next stretch.")
                    } else {
                        if isStale {
                            staleCaption("Showing the last cached schedule -- network unavailable.")
                        }
                        launchRows(launches)
                        SpaceHairlineDivider().padding(.vertical, 8)
                        witLine(PhraseBank.skyLaunch(date: viewModel.referenceDateForDisplay, locationId: launchWitLocationId))
                    }
                }
            }
        }
    }

    private func launchRows(_ launches: [UpcomingLaunch]) -> some View {
        let grouped = LaunchSchedule.launchesByDay(launches)
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(grouped.enumerated()), id: \.element.day) { groupIndex, group in
                Text(Self.dayHeaderText(for: group.day).uppercased())
                    .font(.caption2.weight(.semibold))
                    .tracking(0.6)
                    .foregroundStyle(Color.white.opacity(0.5))
                    .padding(.top, groupIndex == 0 ? 0 : 10)
                    .padding(.bottom, 4)
                ForEach(Array(group.launches.enumerated()), id: \.element.id) { rowIndex, launch in
                    LaunchRowView(launch: launch, referenceDate: viewModel.referenceDateForDisplay) {
                        presentedLaunch = launch
                    }
                    if rowIndex < group.launches.count - 1 {
                        SpaceHairlineDivider()
                    }
                }
                if groupIndex < grouped.count - 1 {
                    SpaceHairlineDivider().padding(.top, 6)
                }
            }
        }
    }

    private static func dayHeaderText(for day: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return "Today" }
        if calendar.isDateInTomorrow(day) { return "Tomorrow" }
        return day.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
    }

    // MARK: - Card 2: The Sun

    private var sunCard: some View {
        SpacePanelCard(title: "THE SUN") {
            VStack(alignment: .leading, spacing: 0) {
                switch viewModel.solarState {
                case .loading:
                    cardSkeleton
                case .unavailable:
                    quietLine("Solar activity data unavailable right now.")
                case .loaded(let state):
                    if state.isStale {
                        staleCaption("Showing the last cached solar data -- network unavailable.")
                    }
                    sunRows(state)
                    SpaceHairlineDivider().padding(.vertical, 8)
                    witLine(PhraseBank.skySolar(
                        level: state.outlook.activityLevel,
                        date: viewModel.referenceDateForDisplay,
                        locationId: launchWitLocationId
                    ))
                }
            }
        }
    }

    /// Stat row + gauge: a small activity gauge on the left with the level word beneath it, a
    /// sunspot-count stat plus flare/aurora-tie-in lines on the right. Status colors (green/
    /// orange/red) live ONLY on the gauge arc -- every text label here stays plain white/white-
    /// opacity ink, per the app's "text never wears decoration colors" dataviz discipline.
    private func sunRows(_ state: SpaceViewModel.SolarCardState) -> some View {
        let outlook = state.outlook
        return HStack(alignment: .top, spacing: 18) {
            VStack(spacing: 6) {
                SolarActivityGauge(level: outlook.activityLevel)
                Text(outlook.activityLevel.description.capitalized)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
            }

            VStack(alignment: .leading, spacing: 6) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("SUNSPOTS")
                        .font(.caption2.weight(.semibold))
                        .tracking(0.5)
                        .foregroundStyle(Color.white.opacity(0.5))
                    Text(outlook.sunspotNumber.map(String.init) ?? "\u{2014}")
                        .font(.title3.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                }

                if let flare = outlook.latestNotableFlare {
                    Text("\(flare.classString) flare peaked \(Self.timeFormatter.string(from: flare.peakTime))")
                        .font(.footnote)
                        .foregroundStyle(Color.white.opacity(0.65))
                        .monospacedDigit()
                }

                if outlook.gScaleForecastMax >= 1, let dayName = state.forecastDayName {
                    Text("G\(outlook.gScaleForecastMax) storm forecast \(dayName) \u{2014} aurora odds improve")
                        .font(.footnote)
                        .foregroundStyle(Color.white.opacity(0.65))
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 8)
    }

    // MARK: - Card 3: Sky Calendar

    private var skyCalendarCard: some View {
        SpacePanelCard(title: "SKY CALENDAR") {
            VStack(alignment: .leading, spacing: 0) {
                let rows = Array(Self.dedupedCalendarEvents(viewModel.calendarEvents).prefix(12))
                if rows.isEmpty {
                    quietLine("Nothing notable in the sky the next 30 days.")
                } else {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, event in
                        calendarRow(event)
                        if index < rows.count - 1 {
                            SpaceHairlineDivider()
                        }
                    }
                }
            }
        }
    }

    /// Same-day dedup: when a meteor-peak row already exists for a calendar day, that day's
    /// standalone "Full moon"/"New moon" row is dropped -- the peak row's own conditions note
    /// (`SkyCalendar.conditionsNote`) already names the Moon phase, so keeping both reads as a
    /// duplicate rather than two distinct events. Runs on the FULL event list before `prefix(12)`
    /// truncates it, so a dedup never silently costs the calendar a row it would otherwise show.
    private static func dedupedCalendarEvents(_ events: [SkyCalendar.Event]) -> [SkyCalendar.Event] {
        let calendar = Calendar(identifier: .gregorian)
        let meteorPeakDays = Set(
            events.filter { kind(for: $0) == .meteorPeak }.map { calendar.startOfDay(for: $0.date) }
        )
        return events.filter { event in
            let eventKind = kind(for: event)
            guard eventKind == .fullMoon || eventKind == .newMoon else { return true }
            return !meteorPeakDays.contains(calendar.startOfDay(for: event.date))
        }
    }

    /// Additive display-only classification of a `SkyCalendar.Event` (that engine has no `kind`
    /// field of its own -- see its doc comment: title/note are plain strings) so the leading
    /// glyph column and the dedup rule above can both key off the same inference rather than
    /// duplicating string-matching logic.
    private enum CalendarEventKind {
        case meteorPeak
        case fullMoon
        case newMoon
        case pairing
        case solstice
        case equinox
        case other
    }

    private static func kind(for event: SkyCalendar.Event) -> CalendarEventKind {
        if event.title == "Full moon" { return .fullMoon }
        if event.title == "New moon" { return .newMoon }
        if event.title.hasSuffix(" peak") { return .meteorPeak }
        if event.note.hasSuffix("\u{00B0} apart") { return .pairing }
        if event.title.contains("Solstice") { return .solstice }
        if event.title.contains("Equinox") { return .equinox }
        return .other
    }

    private func calendarRow(_ event: SkyCalendar.Event) -> some View {
        HStack(alignment: .top, spacing: 10) {
            calendarGlyph(for: event)
                .frame(width: 22, height: 22)
            Text(event.date.formatted(.dateTime.month(.abbreviated).day()))
                .font(.subheadline)
                .monospacedDigit()
                .foregroundStyle(Color.white.opacity(0.65))
                .frame(width: 46, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(event.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                if !event.note.isEmpty {
                    Text(event.note)
                        .font(.caption)
                        .foregroundStyle(Color.white.opacity(0.65))
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private func calendarGlyph(for event: SkyCalendar.Event) -> some View {
        switch Self.kind(for: event) {
        case .meteorPeak:
            MeteorStreakGlyph()
        case .fullMoon:
            MoonPhaseDisc(illumination: 1, waxing: true, diameter: 18, style: .dark)
        case .newMoon:
            MoonPhaseDisc(illumination: 0, waxing: true, diameter: 18, style: .dark, showsRim: true)
        case .pairing:
            PairingGlyph()
        case .solstice:
            Image(systemName: "sun.max")
                .font(.system(size: 15))
                .foregroundStyle(Color.white.opacity(0.65))
        case .equinox:
            Image(systemName: "sun.min")
                .font(.system(size: 15))
                .foregroundStyle(Color.white.opacity(0.65))
        case .other:
            Color.clear
        }
    }

    // MARK: - Shared row chrome

    private func quietLine(_ text: String) -> some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(Color.white.opacity(0.65))
            .padding(.vertical, 8)
    }

    private func staleCaption(_ text: String) -> some View {
        Text(text)
            .font(.caption2)
            .foregroundStyle(Color.white.opacity(0.5))
            .padding(.bottom, 6)
    }

    private func witLine(_ text: String) -> some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(Color.white.opacity(0.65))
            .padding(.top, 8)
    }

    /// Space's Launch Schedule/Sun cards aren't inherently location-specific data, but seeding the
    /// phrase-bank rotation on the active location (falling back to the universal id when there
    /// is none) still gives different saved cities variety on the same day, same rationale as
    /// every other non-location-specific slot in this codebase (`emptyState`/`errorState`).
    private var launchWitLocationId: UUID {
        location?.id ?? PhraseBank.universalLocationId
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

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        return formatter
    }()
}

// MARK: - Launch row

/// One Launch Schedule row -- a `View` struct (not a free function like the rest of this file's
/// row builders) so it can own the small piece of `@State` its T-minus countdown needs (spec:
/// "recompute on appear, no live timer" -- computed once in `onAppear`, not a `TimelineView`/
/// per-second refresh). Wrapped in a `Button` (work item 4) so tapping the row opens the launch
/// detail sheet.
private struct LaunchRowView: View {
    let launch: UpcomingLaunch
    /// "Now" for the countdown math -- `SpaceViewModel.referenceDateForDisplay` (real `Date()`,
    /// or a `-forceDate` override for sim-verify), NOT re-read live, so a forced/sample launch
    /// schedule gets a deterministic, screenshot-stable countdown.
    let referenceDate: Date
    let onSelect: () -> Void

    @State private var countdownText: String?

    private var vehicleClass: LaunchVehicleClass {
        LaunchVehicleClass.classify(vehicle: launch.vehicle, provider: launch.provider)
    }

    var body: some View {
        Button(action: onSelect) {
            HStack(alignment: .top, spacing: 10) {
                // Rocket-class silhouette (~30pt, white 0.85) replaces the old plain SF-Symbol
                // status glyph -- work item 3's "Launch rows get the class glyph."
                RocketSilhouette(vehicleClass: vehicleClass, size: 30, tint: .white.opacity(0.85))
                    .frame(width: 30, height: 30)

                VStack(alignment: .leading, spacing: 2) {
                    if isPlaceholderMissionName {
                        // "Unknown Payload" rows: promote provider + vehicle to the primary line
                        // and drop the placeholder name entirely, per spec -- a bare "Unknown
                        // Payload" heading tells the reader nothing; "CASC · Long March" does.
                        Text(providerVehicleLine)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white)
                    } else {
                        Text(launch.missionName)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white)
                        Text(providerVehicleLine)
                            .font(.caption)
                            .foregroundStyle(Color.white.opacity(0.65))
                            .lineLimit(1)
                    }
                    Text(launch.locationDisplay)
                        .font(.caption2)
                        .foregroundStyle(Color.white.opacity(0.5))
                }

                Spacer(minLength: 8)

                VStack(alignment: .trailing, spacing: 4) {
                    if let timeText = Self.timeText(for: launch) {
                        Text(timeText)
                            .font(.subheadline)
                            .monospacedDigit()
                            .foregroundStyle(.white)
                    }
                    if let countdownText {
                        Text(countdownText)
                            .font(.caption2)
                            .foregroundStyle(Color.white.opacity(0.65))
                            .monospacedDigit()
                    }
                    LaunchStatusChip(status: launch.status)
                }
            }
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onAppear {
            countdownText = Self.countdownText(
                net: launch.net, now: referenceDate, status: launch.status, precision: launch.netPrecision
            )
        }
    }

    private var isPlaceholderMissionName: Bool {
        let normalized = launch.missionName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.isEmpty || normalized.contains("unknown payload")
    }

    private var providerVehicleLine: String {
        "\(Self.displayProviderAbbrev(launch)) \u{00B7} \(launch.vehicle)"
    }

    /// The trailing time slot. `nil` (an empty slot, chip-only) exactly when it would otherwise
    /// read "TBD" AND the status chip *also* reads TBD -- spec: never show a TBD time stacked on
    /// a TBD chip. A TBD time next to a GO/HOLD chip is fine and unchanged (a launch can be
    /// confidently Go/Hold with only a rough, non-`.exact` NET).
    private static func timeText(for launch: UpcomingLaunch) -> String? {
        guard launch.netPrecision == .approximate else {
            return timeFormatter.string(from: launch.net)
        }
        return launch.status == .tbd ? nil : "TBD"
    }

    /// "in 2d 4h" -- largest two units, rounded to the minute before splitting. Only shown for a
    /// confidently-scheduled launch (spec: "only when status == .go and precision is exact") --
    /// a countdown to a Hold or a TBD-precision NET would be presenting false confidence.
    private static func countdownText(
        net: Date, now: Date, status: LaunchStatus, precision: LaunchTimePrecision
    ) -> String? {
        guard status == .go, precision == .exact else { return nil }
        let seconds = net.timeIntervalSince(now)
        guard seconds > 0 else { return nil }
        let totalMinutes = Int((seconds / 60).rounded())
        let days = totalMinutes / (24 * 60)
        let hours = (totalMinutes % (24 * 60)) / 60
        let minutes = totalMinutes % 60
        if days > 0 {
            return hours > 0 ? "in \(days)d \(hours)h" : "in \(days)d"
        } else if hours > 0 {
            return minutes > 0 ? "in \(hours)h \(minutes)m" : "in \(hours)h"
        } else if minutes > 0 {
            return "in \(minutes)m"
        }
        return "in <1m"
    }

    /// Additive display-layer abbreviations for a handful of long agency names the work package
    /// calls out by name, layered on top of (never replacing) `LaunchSchedule.providerAbbrev`'s
    /// own engine-side table -- deliberately NOT added there (don't-modify-engine-logic rule that
    /// table's own doc comment documents: "everything not in this table is shown as-is"); this is
    /// a display-only formatting concern, so it lives here instead.
    private static let extraProviderAbbreviations: [String: String] = [
        "China Aerospace Science and Technology Corporation": "CASC",
        "China Aerospace Science and Industry Corporation": "CASIC",
        "Indian Space Research Organization": "ISRO",
        "Indian Space Research Organisation": "ISRO",
        "Russian Federal Space Agency": "Roscosmos",
    ]

    private static func displayProviderAbbrev(_ launch: UpcomingLaunch) -> String {
        extraProviderAbbreviations[launch.provider] ?? launch.providerAbbrev
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        return formatter
    }()
}

// MARK: - Sun gauge

/// A 270°-sweep activity gauge -- dark-surface pass: track uses an explicit `white.opacity(0.15)`
/// (the old `.quaternaryLabel` resolves against the SYSTEM color scheme, which is wrong on a
/// screen that forces a dark identity regardless of device appearance); the three status hues are
/// brightened versions of the originals so they read clearly against the dark indigo fill (spec:
/// "gauge colors re-tuned for dark: keep status hues but raise brightness").
private struct SolarActivityGauge: View {
    let level: SolarActivityLevel

    private static let sweepDegrees: Double = 270

    private var fraction: Double {
        switch level {
        case .quiet: return 0.15
        case .active: return 0.55
        case .stormy: return 0.95
        }
    }

    private var color: Color {
        switch level {
        case .quiet: return Color(red: 0.40, green: 0.88, blue: 0.55)
        case .active: return Color(red: 1.0, green: 0.66, blue: 0.26)
        case .stormy: return Color(red: 1.0, green: 0.38, blue: 0.38)
        }
    }

    var body: some View {
        ZStack {
            Circle()
                .trim(from: 0, to: Self.sweepDegrees / 360)
                .stroke(Color.white.opacity(0.15), style: StrokeStyle(lineWidth: 4, lineCap: .round))
                .rotationEffect(Self.startRotation)
            Circle()
                .trim(from: 0, to: (Self.sweepDegrees / 360) * fraction)
                .stroke(color, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                .rotationEffect(Self.startRotation)
        }
        .frame(width: 60, height: 60)
    }

    /// Rotates the trim's 0%-start (normally 3 o'clock) to the top of the bottom gap, so the
    /// 270° arc runs clockwise from lower-left to lower-right with the 90° gap centered at 6
    /// o'clock.
    private static var startRotation: Angle { .degrees(90 + (360 - sweepDegrees) / 2) }
}

// MARK: - Sky calendar glyphs

/// Meteor-shower peak glyph: a diagonal streak with 3 trailing dots fading toward the tail --
/// dark-surface pass: white-tinted (was `Color.secondary`, which resolves against the system
/// color scheme) so it reads correctly on this screen's always-dark surface.
private struct MeteorStreakGlyph: View {
    var body: some View {
        ZStack {
            Path { path in
                path.move(to: CGPoint(x: 5, y: 5))
                path.addLine(to: CGPoint(x: 17, y: 17))
            }
            .stroke(Color.white.opacity(0.85), style: StrokeStyle(lineWidth: 2, lineCap: .round))
            Circle().fill(Color.white.opacity(0.55)).frame(width: 3, height: 3).position(x: 10, y: 10)
            Circle().fill(Color.white.opacity(0.35)).frame(width: 2.4, height: 2.4).position(x: 7.5, y: 7.5)
            Circle().fill(Color.white.opacity(0.2)).frame(width: 2, height: 2).position(x: 5.5, y: 5.5)
        }
        .frame(width: 22, height: 22)
    }
}

/// Close-pairing glyph: two overlapping 6pt outline circles -- dark-surface pass, same white-tint
/// rationale as `MeteorStreakGlyph`.
private struct PairingGlyph: View {
    var body: some View {
        ZStack {
            Circle().stroke(Color.white.opacity(0.75), lineWidth: 1.2).frame(width: 6, height: 6).offset(x: -2.2)
            Circle().stroke(Color.white.opacity(0.75), lineWidth: 1.2).frame(width: 6, height: 6).offset(x: 2.2)
        }
        .frame(width: 22, height: 22)
    }
}
