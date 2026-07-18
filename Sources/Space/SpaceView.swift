import SwiftUI

/// The Space tab (work package WP-K): launches, solar activity, and a 30-day sky calendar, three
/// `SheetCard`s on a `.systemGroupedBackground` scroll surface -- the same grouped-card chrome as
/// `RankingsView`, with a standard system nav bar (not Forecast's custom full-bleed chrome), per
/// work order.
///
/// **Editor's-Choice sky-surfaces elevation:** these three cards stay ordinary `SheetCard`s (the
/// inverted "night panel" treatment is `TonightSkyCard`'s alone, per that work package's spec) --
/// this pass is about row-level polish: fixing the Launch Schedule's double-TBD bug, adding a
/// T-minus countdown and "Unknown Payload" handling, restructuring THE SUN into a stat+gauge
/// layout, and giving SKY CALENDAR rows a leading glyph column with same-day moon/meteor dedup.
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

    @State private var hasScrolledToTarget = false

    private static let sunCardId = "spaceSunCard"
    private static let calendarCardId = "spaceCalendarCard"

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 16) {
                        launchScheduleCard
                        sunCard.id(Self.sunCardId)
                        skyCalendarCard.id(Self.calendarCardId)
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 16)
                    // Extra clearance so the last card's content isn't flush against the floating
                    // bottom bar (`NavigationShell.floatingBar`), which overlays this screen --
                    // same treatment `ForecastPageView.sheetSurface` gives its own scroll content.
                    .padding(.bottom, 70)
                }
                .onAppear {
                    scrollToTargetIfNeeded(proxy: proxy)
                }
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Space")
            .navigationBarTitleDisplayMode(.inline)
        }
        .task {
            await viewModel.refresh()
        }
        .task(id: location?.id) {
            await viewModel.updateLocationAndRecomputeCalendar(location)
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

    // MARK: - Card 1: Launch Schedule

    private var launchScheduleCard: some View {
        SheetCard(title: "LAUNCH SCHEDULE") {
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
                        Divider()
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
                    .foregroundStyle(.secondary)
                    .padding(.top, groupIndex == 0 ? 0 : 10)
                    .padding(.bottom, 4)
                ForEach(Array(group.launches.enumerated()), id: \.element.id) { rowIndex, launch in
                    LaunchRowView(launch: launch, referenceDate: viewModel.referenceDateForDisplay)
                    if rowIndex < group.launches.count - 1 {
                        Divider()
                    }
                }
                if groupIndex < grouped.count - 1 {
                    Divider().padding(.top, 6)
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
        SheetCard(title: "THE SUN") {
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
                    Divider()
                    witLine(PhraseBank.skySolar(
                        level: state.outlook.activityLevel,
                        date: viewModel.referenceDateForDisplay,
                        locationId: launchWitLocationId
                    ))
                }
            }
        }
    }

    /// Stat row + gauge (Editor's-Choice restructure): a small activity gauge on the left (see
    /// `SolarActivityGauge`) with the level word beneath it, a sunspot-count stat plus flare/
    /// aurora-tie-in lines on the right. Status colors (green/orange/red) live ONLY on the gauge
    /// arc -- every text label here stays plain secondary/primary ink, per the app's "text never
    /// wears decoration colors" dataviz discipline.
    private func sunRows(_ state: SpaceViewModel.SolarCardState) -> some View {
        let outlook = state.outlook
        return HStack(alignment: .top, spacing: 18) {
            VStack(spacing: 6) {
                SolarActivityGauge(level: outlook.activityLevel)
                Text(outlook.activityLevel.description.capitalized)
                    .font(.subheadline.weight(.semibold))
            }

            VStack(alignment: .leading, spacing: 6) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("SUNSPOTS")
                        .font(.caption2.weight(.semibold))
                        .tracking(0.5)
                        .foregroundStyle(.secondary)
                    Text(outlook.sunspotNumber.map(String.init) ?? "\u{2014}")
                        .font(.title3.weight(.semibold))
                        .monospacedDigit()
                }

                if let flare = outlook.latestNotableFlare {
                    Text("\(flare.classString) flare peaked \(Self.timeFormatter.string(from: flare.peakTime))")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }

                if outlook.gScaleForecastMax >= 1, let dayName = state.forecastDayName {
                    Text("G\(outlook.gScaleForecastMax) storm forecast \(dayName) \u{2014} aurora odds improve")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 8)
    }

    // MARK: - Card 3: Sky Calendar

    private var skyCalendarCard: some View {
        SheetCard(title: "SKY CALENDAR") {
            VStack(alignment: .leading, spacing: 0) {
                let rows = Array(Self.dedupedCalendarEvents(viewModel.calendarEvents).prefix(12))
                if rows.isEmpty {
                    quietLine("Nothing notable in the sky the next 30 days.")
                } else {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, event in
                        calendarRow(event)
                        if index < rows.count - 1 {
                            Divider()
                        }
                    }
                }
            }
        }
    }

    /// Same-day dedup (Editor's-Choice spec): when a meteor-peak row already exists for a
    /// calendar day, that day's standalone "Full moon"/"New moon" row is dropped -- the peak
    /// row's own conditions note (`SkyCalendar.conditionsNote`) already names the Moon phase, so
    /// keeping both reads as a duplicate rather than two distinct events. Runs on the FULL event
    /// list before `prefix(12)` truncates it, so a dedup never silently costs the calendar a row
    /// it would otherwise have shown.
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
                .foregroundStyle(.secondary)
                .frame(width: 46, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(event.title)
                    .font(.subheadline.weight(.semibold))
                if !event.note.isEmpty {
                    Text(event.note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
            MoonPhaseDisc(illumination: 1, waxing: true, diameter: 18, style: .light)
        case .newMoon:
            MoonPhaseDisc(illumination: 0, waxing: true, diameter: 18, style: .light, showsRim: true)
        case .pairing:
            PairingGlyph()
        case .solstice:
            Image(systemName: "sun.max")
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
        case .equinox:
            Image(systemName: "sun.min")
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
        case .other:
            Color.clear
        }
    }

    // MARK: - Shared row chrome

    private func quietLine(_ text: String) -> some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .padding(.vertical, 8)
    }

    private func staleCaption(_ text: String) -> some View {
        Text(text)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .padding(.bottom, 6)
    }

    private func witLine(_ text: String) -> some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(.secondary)
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
                    .fill(Color(.tertiarySystemFill))
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
/// per-second refresh).
private struct LaunchRowView: View {
    let launch: UpcomingLaunch
    /// "Now" for the countdown math -- `SpaceViewModel.referenceDateForDisplay` (real `Date()`,
    /// or a `-forceDate` override for sim-verify), NOT re-read live, so a forced/sample launch
    /// schedule gets a deterministic, screenshot-stable countdown.
    let referenceDate: Date

    @State private var countdownText: String?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: leadingGlyphName)
                .font(.system(size: 16))
                .foregroundStyle(.secondary)
                .frame(width: 16, height: 20)

            VStack(alignment: .leading, spacing: 2) {
                if isPlaceholderMissionName {
                    // "Unknown Payload" rows: promote provider + vehicle to the primary line and
                    // drop the placeholder name entirely, per spec -- a bare "Unknown Payload"
                    // heading tells the reader nothing; "CASC · Long March" does.
                    Text(providerVehicleLine)
                        .font(.subheadline.weight(.semibold))
                } else {
                    Text(launch.missionName)
                        .font(.subheadline.weight(.semibold))
                    Text(providerVehicleLine)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Text(launch.locationDisplay)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 4) {
                if let timeText = Self.timeText(for: launch) {
                    Text(timeText)
                        .font(.subheadline)
                        .monospacedDigit()
                }
                if let countdownText {
                    Text(countdownText)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                statusChip(launch.status)
            }
        }
        .padding(.vertical, 8)
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

    private var leadingGlyphName: String {
        switch launch.status {
        case .go: return "arrow.up.circle"
        case .hold: return "pause.circle"
        case .tbd: return "questionmark.circle"
        }
    }

    private func statusChip(_ status: LaunchStatus) -> some View {
        let (label, fill, foreground): (String, Color, Color) = {
            switch status {
            case .go: return ("GO", Color.clearSkyAccent, .white)
            case .tbd: return ("TBD", Color(.tertiarySystemFill), .secondary)
            case .hold: return ("HOLD", Color.orange.opacity(0.18), .orange)
            }
        }()
        return Text(label)
            .font(.caption2.weight(.bold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(fill, in: Capsule())
            .foregroundStyle(foreground)
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

/// A 270°-sweep activity gauge -- Editor's-Choice spec: "thin 4pt track (quaternary fill), filled
/// portion by level ... in the RESERVED status colors ... never the accent." The 90° gap is
/// centered at the bottom, standard speedometer orientation.
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
        case .quiet: return Color(.systemGreen).opacity(0.7)
        case .active: return .orange
        case .stormy: return .red
        }
    }

    var body: some View {
        ZStack {
            Circle()
                .trim(from: 0, to: Self.sweepDegrees / 360)
                .stroke(Color(.quaternaryLabel), style: StrokeStyle(lineWidth: 4, lineCap: .round))
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
/// spec's custom option, kept plain `.secondary` (not a decoration color) per the app's dataviz
/// discipline.
private struct MeteorStreakGlyph: View {
    var body: some View {
        ZStack {
            Path { path in
                path.move(to: CGPoint(x: 5, y: 5))
                path.addLine(to: CGPoint(x: 17, y: 17))
            }
            .stroke(Color.secondary.opacity(0.9), style: StrokeStyle(lineWidth: 2, lineCap: .round))
            Circle().fill(Color.secondary.opacity(0.55)).frame(width: 3, height: 3).position(x: 10, y: 10)
            Circle().fill(Color.secondary.opacity(0.35)).frame(width: 2.4, height: 2.4).position(x: 7.5, y: 7.5)
            Circle().fill(Color.secondary.opacity(0.2)).frame(width: 2, height: 2).position(x: 5.5, y: 5.5)
        }
        .frame(width: 22, height: 22)
    }
}

/// Close-pairing glyph: two overlapping 6pt outline circles.
private struct PairingGlyph: View {
    var body: some View {
        ZStack {
            Circle().stroke(Color.secondary.opacity(0.75), lineWidth: 1.2).frame(width: 6, height: 6).offset(x: -2.2)
            Circle().stroke(Color.secondary.opacity(0.75), lineWidth: 1.2).frame(width: 6, height: 6).offset(x: 2.2)
        }
        .frame(width: 22, height: 22)
    }
}
