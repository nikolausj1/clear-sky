import CoreLocation
import SwiftUI
import WidgetKit

/// Widget work package's honest sim-verify substitute (per work order): `simctl` can add a
/// widget to the Home Screen gallery, but reliably long-press-and-tap through the gallery picker
/// via computer-use automation proved too unreliable to budget for in this pass, so this screen
/// instead renders the SAME widget views (`MoonPhaseCircularView`/`TonightRectangularView`/
/// `TonightSmallView`/`TonightMediumView` from `Widgets/Views/ZenithWidgetViews.swift`) at their
/// real accessory/small/medium frame sizes, fed by a REAL `WidgetSnapshot` — this screen doesn't
/// fabricate one. On appear it runs `WidgetSnapshotWriter.refresh(location:)` for a demo location
/// (the same Tomah, WI coordinate `SmokeTestView`/`ForecastViewModel.defaultCoordinate` use),
/// exactly the call `NavigationShell.handleSkyStateResolved` makes for real, then reads back
/// whatever landed in the app-group container via `WidgetSnapshot.read()` — proving the full
/// app-write -> app-group -> widget-read pipeline, not just the view code in isolation.
///
/// Shown instead of the normal root view when the app launches with `-widgetPreview` (see
/// `ClearSkyApp.swift`), mirroring `-smoketest`'s existing pattern.
struct WidgetPreviewView: View {
    /// Tomah, WI — same demo coordinate `SmokeTestView` and `ForecastViewModel.defaultCoordinate`
    /// already use, so this screen doesn't need its own hardcoded location story.
    private static let coordinate = CLLocationCoordinate2D(latitude: 43.9814, longitude: -90.5040)
    private static let demoLocation = SavedLocation(
        id: UUID(uuidString: "00000000-0000-0000-0000-00000000005D")!,
        name: "Tomah",
        latitude: coordinate.latitude,
        longitude: coordinate.longitude,
        sortOrder: 0
    )

    @State private var snapshot: WidgetSnapshot?
    @State private var isRefreshing = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if let snapshot {
                        widgetGallery(snapshot)
                        proofSection(snapshot)
                    } else {
                        ProgressView("Resolving tonight's sky…")
                            .padding(.top, 40)
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationTitle("Widget Preview")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Refresh") { Task { await refresh() } }
                        .disabled(isRefreshing)
                }
            }
        }
        .task { await refresh() }
    }

    private func refresh() async {
        isRefreshing = true
        await WidgetSnapshotWriter.refresh(location: Self.demoLocation)
        snapshot = WidgetSnapshot.read()
        isRefreshing = false
    }

    // MARK: - Gallery

    @ViewBuilder
    private func widgetGallery(_ snapshot: WidgetSnapshot) -> some View {
        Group {
            labeled("Lock Screen — accessoryCircular (76x76)") {
                MoonPhaseCircularView(snapshot: snapshot)
                    .frame(width: 76, height: 76)
                    .background(Color.black)
                    .clipShape(Circle())
            }
            labeled("Lock Screen — accessoryRectangular (172x76)") {
                TonightRectangularView(snapshot: snapshot)
                    .frame(width: 172, height: 76)
                    .background(Color.black)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            labeled("Home Screen — systemSmall (155x155)") {
                // `.containerBackground(for: .widget)` (inside `TonightSmallView` itself) only
                // composites correctly when a real `Widget` hosts the view — outside that
                // context (this plain app screen) it silently doesn't render, so this preview
                // duplicates the same background behind it purely for visual fidelity here. The
                // production view/modifier is untouched; this is a preview-harness-only fix.
                TonightSmallView(snapshot: snapshot)
                    .frame(width: 155, height: 155)
                    .background(NightSceneBackground(terrainClass: snapshot.terrainClass))
                    .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            }
            labeled("Home Screen — systemMedium (329x155)") {
                TonightMediumView(snapshot: snapshot)
                    .frame(width: 329, height: 155)
                    .background(NightSceneBackground(terrainClass: snapshot.terrainClass))
                    .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            }
        }
    }

    private func labeled(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
            content()
        }
    }

    // MARK: - Snapshot JSON proof

    private func proofSection(_ snapshot: WidgetSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Written app-group snapshot (group.com.levelup.clearsky)")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(Self.prettyJSON(snapshot))
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
        }
    }

    private static func prettyJSON(_ snapshot: WidgetSnapshot) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(snapshot), let string = String(data: data, encoding: .utf8) else {
            return "<failed to encode>"
        }
        return string
    }
}
