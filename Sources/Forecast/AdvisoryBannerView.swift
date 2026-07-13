import SwiftUI

extension AlertSummary {
    /// Deterministic severity ordering so the banner always shows the most severe active
    /// alert first (PRD Section 6: "If multiple alerts are active simultaneously, the banner
    /// shows the most severe one").
    var severityRank: Int {
        switch severityCode.lowercased() {
        case "extreme": return 4
        case "severe": return 3
        case "moderate": return 2
        case "minor": return 1
        default: return 0
        }
    }
}

/// PRD Section 6, item 3: rendered only when `activeAlerts` is non-empty; tappable to a detail
/// sheet with the full agency text and the required Apple `detailsURL` link.
struct AdvisoryBanner: View {
    let alerts: [AlertSummary]
    @Binding var isPresentingDetail: Bool

    private var mostSevere: AlertSummary? {
        alerts.max { $0.severityRank < $1.severityRank }
    }

    var body: some View {
        if let alert = mostSevere {
            Button {
                isPresentingDetail = true
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                    Text(alert.title)
                        .fontWeight(.semibold)
                        .lineLimit(1)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption)
                }
                .foregroundStyle(Color.red)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Color.red.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
            }
            .buttonStyle(.plain)
        }
    }
}

/// Alert detail sheet: full agency text plus the Apple-required `detailsURL` link. Lists any
/// additional simultaneously-active alerts below the most severe one.
struct AlertDetailSheet: View {
    let alerts: [AlertSummary]

    private var sortedAlerts: [AlertSummary] {
        alerts.sorted { $0.severityRank > $1.severityRank }
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(sortedAlerts) { alert in
                    Section {
                        Text(alert.severityDescription)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.red)
                        Text(alert.agencyText)
                            .font(.body)
                        if let region = alert.region {
                            LabeledContent("Region", value: region)
                                .font(.footnote)
                        }
                        Link(destination: alert.detailsURL) {
                            Label("Full advisory details", systemImage: "link")
                        }
                    } header: {
                        Text(alert.title)
                    }
                }
            }
            .navigationTitle("Weather Alerts")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
