import SwiftUI

/// The Space tab (work package WP-K): launches, solar activity, and a 30-day sky calendar, three
/// `SheetCard`s on a `.systemGroupedBackground` scroll surface -- the same grouped-card chrome as
/// `RankingsView`, with a standard system nav bar (not Forecast's custom full-bleed chrome), per
/// work order.
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
                    launchRow(launch)
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

    private func launchRow(_ launch: UpcomingLaunch) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(launch.missionName)
                    .font(.subheadline.weight(.semibold))
                Text("\(launch.providerAbbrev) \u{00B7} \(launch.vehicle)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(launch.locationDisplay)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 6) {
                Text(Self.t0Text(for: launch))
                    .font(.subheadline)
                    .monospacedDigit()
                statusChip(launch.status)
            }
        }
        .padding(.vertical, 8)
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

    private static func t0Text(for launch: UpcomingLaunch) -> String {
        launch.netPrecision == .approximate ? "TBD" : timeFormatter.string(from: launch.net)
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

    private func sunRows(_ state: SpaceViewModel.SolarCardState) -> some View {
        let outlook = state.outlook
        return VStack(alignment: .leading, spacing: 6) {
            Text("Solar activity: \(outlook.activityLevel.description)")
                .font(.subheadline.weight(.semibold))

            if let sunspotNumber = outlook.sunspotNumber {
                Text("Sunspot number: \(sunspotNumber)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
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
        .padding(.vertical, 8)
    }

    // MARK: - Card 3: Sky Calendar

    private var skyCalendarCard: some View {
        SheetCard(title: "SKY CALENDAR") {
            VStack(alignment: .leading, spacing: 0) {
                let rows = Array(viewModel.calendarEvents.prefix(12))
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

    private func calendarRow(_ event: SkyCalendar.Event) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(event.date.formatted(.dateTime.month(.abbreviated).day()))
                .font(.subheadline)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 56, alignment: .leading)
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
