import SwiftUI

/// PRD Screen C: City Power Rankings. Ranks all saved locations (including the current-location
/// entry, if any) by `PleasantnessScore`, highest first, each row showing rank, city, score,
/// current temp/condition, and a phrase-bank verdict line. See the PRD's Screen C row + Section
/// 6 states table, and `RankingsViewModel`'s doc comments for the exact ranking/failed-row/tie
/// rules implemented here.
struct RankingsView: View {
    @Environment(UnitsSettings.self) private var unitsSettings
    @Bindable var viewModel: RankingsViewModel

    /// Tapping a ranked city switches the Forecast tab to it and dismisses to Forecast (PRD
    /// Section 6 nice-to-have: "Tapping a ranked city could switch the Forecast to it +
    /// dismiss to Forecast — implement if cheap"). `nil` disables the tap (not expected in
    /// practice; kept optional so this view stays previewable without a shell).
    var onSelectCity: ((SavedLocation) -> Void)?

    /// Which row (if any) has its component-score breakdown expanded — the "why this rank"
    /// inspector PRD Section 12's scoring brief asked for the breakdown to be structured for,
    /// wired up here since a simple tap-to-expand is cheap.
    @State private var expandedRowId: UUID?

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Rankings")
                .navigationBarTitleDisplayMode(.inline)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.screenState {
        case .noCities:
            emptyState(text: PhraseBank.emptyState(.rankingsNoCities, date: viewModel.rankingDate))
        case .needOneMore(let cityName):
            needOneMoreState(cityName: cityName)
        case .loading:
            skeletonList
        case .ranked:
            rankedList
        }
    }

    // MARK: - Empty / needs-one-more states

    private func emptyState(text: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "list.number")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func needOneMoreState(cityName: String) -> some View {
        let location = viewModel.locations.first
        let rowState = location.map { viewModel.rowFetchStates[$0.id] ?? .loading }

        return VStack(spacing: 20) {
            VStack(spacing: 8) {
                Image(systemName: "person.2.slash")
                    .font(.system(size: 34))
                    .foregroundStyle(.secondary)
                Text(
                    PhraseBank.emptyState(
                        .rankingsNeedOneMore,
                        date: viewModel.rankingDate,
                        locationId: location?.id ?? PhraseBank.universalLocationId,
                        tokens: ["city": cityName]
                    )
                )
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            }

            if let location, let rowState {
                soloCityCard(location: location, state: rowState)
                    .padding(.horizontal)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func soloCityCard(location: SavedLocation, state: RankingsViewModel.RowFetchState) -> some View {
        HStack(spacing: 12) {
            Text(location.name)
                .font(.headline)
            Spacer()
            switch state {
            case .loading:
                ProgressView()
            case .loaded(let payload):
                HStack(spacing: 6) {
                    Image(systemName: payload.currentConditions.symbolName)
                        .symbolRenderingMode(.multicolor)
                    Text(TemperatureFormatting.string(payload.currentConditions.temperature, unit: unitsSettings.unit))
                        .font(.subheadline.weight(.medium))
                        .monospacedDigit()
                }
            case .failed:
                Text("--").foregroundStyle(.secondary)
            }
        }
        .padding()
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    // MARK: - Loading skeleton

    private var skeletonList: some View {
        List {
            ForEach(0..<max(viewModel.locations.count, 2), id: \.self) { _ in
                SkeletonRow()
                    .listRowSeparator(.hidden)
            }
        }
        .listStyle(.plain)
        .redacted(reason: .placeholder)
    }

    private struct SkeletonRow: View {
        var body: some View {
            HStack(spacing: 12) {
                Circle().frame(width: 28, height: 28)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Springfield").font(.body.weight(.semibold))
                    Text("Loading today's verdict, one moment.").font(.footnote)
                }
                Spacer()
                Text("74").font(.title3.weight(.semibold))
            }
            .padding(.vertical, 6)
        }
    }

    // MARK: - Ranked list

    /// UX polish package ("Cross-screen consistency"): the ranked rows now live inside one
    /// grouped `SheetCard` on a `.systemGroupedBackground` scroll surface — the same chrome as
    /// the Forecast screen's hourly/daily cards — rather than a bare `List`.
    private var rankedList: some View {
        ScrollView {
            let rows = viewModel.rows(unit: unitsSettings.unit)
            SheetCard(title: "RANKINGS") {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                        RankedRowView(
                            row: row,
                            unit: unitsSettings.unit,
                            isExpanded: expandedRowId == row.id,
                            onTapVerdictArea: {
                                guard row.breakdown != nil else { return }
                                withAnimation(.easeInOut(duration: 0.15)) {
                                    expandedRowId = expandedRowId == row.id ? nil : row.id
                                }
                            },
                            onSelect: {
                                onSelectCity?(row.location)
                            }
                        )
                        if index < rows.count - 1 {
                            Divider()
                        }
                    }
                }
            }
            .padding(16)
        }
        .background(Color(.systemGroupedBackground))
    }
}

/// One ranked row: rank badge, city name, score, current temp/condition icon, alert indicator,
/// and the phrase-bank verdict line — or, for a failed row, the dry inline failure note in
/// place of rank/score/verdict (PRD Section 6: "A location whose data failed to load shows as
/// unavailable with a dry-wit inline note; other rows still rank normally").
private struct RankedRowView: View {
    let row: RankingsViewModel.RankedRow
    let unit: TemperatureUnit
    let isExpanded: Bool
    let onTapVerdictArea: () -> Void
    let onSelect: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(action: onSelect) {
                HStack(spacing: 12) {
                    rankBadge
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(row.location.name)
                                .font(.body.weight(.semibold))
                            if row.hasAlert {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                            }
                        }
                        if let payload = row.payload {
                            HStack(spacing: 6) {
                                Image(systemName: payload.currentConditions.symbolName)
                                    .symbolRenderingMode(.multicolor)
                                    .font(.caption)
                                Text(TemperatureFormatting.string(payload.currentConditions.temperature, unit: unit))
                                    .font(.caption)
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    Spacer()
                    if let score = row.score {
                        scoreBadge(score)
                    }
                }
            }
            .buttonStyle(PressableRowStyle())

            if let score = row.score {
                scoreBar(score)
            }

            Text(row.verdict ?? row.failureNote ?? "")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
                .onTapGesture(perform: onTapVerdictArea)

            if isExpanded, let breakdown = row.breakdown {
                BreakdownView(breakdown: breakdown)
            }
        }
        .padding(.vertical, 6)
    }

    private var rankBadge: some View {
        Group {
            if let rank = row.rank {
                Text("\(rank)")
                    .font(.subheadline.weight(.bold))
                    .monospacedDigit()
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(Color.clearSkyAccent.opacity(0.18)))
            } else {
                Image(systemName: "questionmark")
                    .font(.subheadline.weight(.bold))
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(Color(.secondarySystemFill)))
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// One decimal place, always — not just when two scores would otherwise collide at the
    /// integer level. Two distinct scores (e.g. 84.6 and 85.3) can both round to a shared
    /// integer while still sitting in different, correctly-ordered ranks; showing the integer
    /// only sometimes would itself look inconsistent row to row. A fixed one-decimal format is
    /// the simplest fix that removes the "looks like a broken tie-break" ambiguity everywhere,
    /// not just in the specific cases that happen to collide today.
    private func scoreBadge(_ score: Double) -> some View {
        Text(score, format: .number.precision(.fractionLength(1)))
            .font(.title3.weight(.semibold))
            .monospacedDigit()
    }

    /// UX polish package ("Data-mark discipline"): unlike the daily range bar, a ranking score
    /// isn't a temperature — hue must NOT vary with score (that would silently duplicate the
    /// same red/green "good/bad" encoding the design spec explicitly avoids elsewhere). Instead
    /// this is a single-hue sequential encoding: the app accent at an opacity that scales with
    /// the score, so a higher score reads as a bolder fill of the same color, never a different
    /// color. The score number itself stays `.primary` (never tinted by the bar's color).
    private func scoreBar(_ score: Double) -> some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color(.secondarySystemFill))
                Capsule()
                    .fill(Color.clearSkyAccent.opacity(0.35 + 0.65 * (score / 100).clamped(to: 0...1)))
                    .frame(width: proxy.size.width * CGFloat(score / 100))
            }
        }
        .frame(height: 6)
    }
}

private extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}

/// The per-component score breakdown, shown when a row is tapped-to-expand — the "why this
/// rank" inspector (PRD Section 12: "structure it so the component breakdown is inspectable").
private struct BreakdownView: View {
    let breakdown: PleasantnessScore.Breakdown

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(breakdown.components, id: \.name) { component in
                HStack {
                    Text(component.name)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(Int(component.value.rounded()))/100")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Text("(\u{00D7}\(Int(component.weight * 100))%)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.top, 2)
        .padding(.leading, 38)
    }
}
