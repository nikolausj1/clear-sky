import SwiftUI
import WidgetKit

// MARK: - Lock-screen circular: moon phase disc

/// Reuses `MoonPhaseDisc` (`Sources/Shared/MoonPhaseDisc.swift`) directly — the same drawing
/// logic `TonightSkyCard`'s moon row and the Space tab's Sky Calendar already share. Lock-screen
/// accessory widgets render in the system's own vibrant/tinted mode regardless of the colors a
/// view actually draws (WidgetKit's documented accessory-family behavior), so `MoonPhaseDisc`'s
/// bone-white/near-black pair still reads correctly as "lit vs. shadowed" — the system maps
/// each pixel's luminance/alpha to the lock screen's own tint, it doesn't need a special
/// widget-only color variant.
struct MoonPhaseCircularView: View {
    let snapshot: WidgetSnapshot

    var body: some View {
        MoonPhaseDisc(illumination: snapshot.moonIlluminatedFraction, waxing: snapshot.moonWaxing, diameter: 42, style: .dark)
            .containerBackground(.clear, for: .widget)
    }
}

// MARK: - Lock-screen rectangular: "Tonight" + headline

struct TonightRectangularView: View {
    let snapshot: WidgetSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("TONIGHT")
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(.secondary)
            Text(snapshot.headline)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(2)
                .minimumScaleFactor(0.85)
                .foregroundStyle(.primary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .containerBackground(.clear, for: .widget)
    }
}

// MARK: - Home-screen small: mini night scene + headline one-liner

struct TonightSmallView: View {
    let snapshot: WidgetSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                MoonPhaseDisc(illumination: snapshot.moonIlluminatedFraction, waxing: snapshot.moonWaxing, diameter: 26, style: .dark)
                Spacer()
            }
            Spacer(minLength: 0)
            Text(snapshot.headline)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(2)
                .minimumScaleFactor(0.85)
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .containerBackground(for: .widget) {
            NightSceneBackground(terrainClass: snapshot.terrainClass)
        }
    }
}

// MARK: - Home-screen medium: small's scene + top 3 object rows

struct TonightMediumView: View {
    let snapshot: WidgetSnapshot

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                MoonPhaseDisc(illumination: snapshot.moonIlluminatedFraction, waxing: snapshot.moonWaxing, diameter: 26, style: .dark)
                Spacer(minLength: 0)
                Text(snapshot.headline)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(3)
                    .minimumScaleFactor(0.85)
            }
            .frame(width: 118, alignment: .leading)

            if !snapshot.topObjects.isEmpty {
                Divider().overlay(Color.white.opacity(0.15))
                GanttRows(objects: snapshot.topObjects)
                    .padding(.leading, 12)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .containerBackground(for: .widget) {
            NightSceneBackground(terrainClass: snapshot.terrainClass)
        }
    }
}

/// Static Gantt-style rows: object name + a bar showing its viewing window, all scaled against
/// one shared time span (the earliest window start through the latest window end across every
/// row) so the three bars are visually comparable at a glance — no ticks/labels/axis, no
/// interactivity, per the work order's "static" instruction.
private struct GanttRows: View {
    let objects: [WidgetSnapshot.ObjectWindow]

    private var span: (start: Date, end: Date) {
        let starts = objects.map(\.windowStart)
        let ends = objects.map(\.windowEnd)
        let start = starts.min() ?? Date()
        let end = ends.max() ?? start.addingTimeInterval(3600)
        return (start, end > start ? end : start.addingTimeInterval(3600))
    }

    var body: some View {
        let (spanStart, spanEnd) = span
        let totalSeconds = max(spanEnd.timeIntervalSince(spanStart), 60)

        VStack(alignment: .leading, spacing: 6) {
            ForEach(objects) { object in
                HStack(spacing: 6) {
                    Text(object.name)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.white.opacity(0.85))
                        .frame(width: 46, alignment: .leading)
                        .lineLimit(1)

                    GeometryReader { proxy in
                        let leading = max(0, object.windowStart.timeIntervalSince(spanStart) / totalSeconds)
                        let width = max(0.06, object.windowEnd.timeIntervalSince(object.windowStart) / totalSeconds)
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.white.opacity(0.12))
                            Capsule()
                                .fill(Self.barColor(for: object.kind))
                                .frame(width: proxy.size.width * min(width, 1))
                                .offset(x: proxy.size.width * min(leading, 1))
                        }
                    }
                    .frame(height: 6)
                }
            }
        }
    }

    private static func barColor(for kind: WidgetSnapshot.ObjectWindow.Kind) -> Color {
        switch kind {
        case .iss: return Color(red: 0.55, green: 0.85, blue: 1.0)
        case .planet: return Color(red: 1.0, green: 0.82, blue: 0.4)
        case .moon: return Color(red: 0.96, green: 0.97, blue: 0.99)
        }
    }
}
