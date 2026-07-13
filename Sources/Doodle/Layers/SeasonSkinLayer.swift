import SwiftUI

/// Doodle layer 2, "Season skin" (PRD Section 7): "palette and ground/foliage treatment for
/// the current season." Renders the **front** hill ridge (see `HillsShape.Profile.front` in
/// `BaseSceneLayer.swift`) filled with a season-driven color, plus a fixed row of trees along
/// that ridge whose canopy/accent treatment changes with the season: bare branches + snow caps
/// in winter, blossom-dotted canopies in spring, full dark-green canopies in summer, and
/// amber/rust canopies in fall.
///
/// Tree positions are a **fixed** array (not randomized), so the scene composition is
/// identical every time for a given size — only the coloring changes with season, keeping the
/// output deterministic per PRD Section 5.
struct SeasonSkinLayer: View {
    let season: DoodleComposer.Season

    private struct TreeSpec {
        let xFraction: CGFloat
        let ridgeYFraction: CGFloat
        let scale: CGFloat
    }

    private static let trees: [TreeSpec] = [
        TreeSpec(xFraction: 0.10, ridgeYFraction: 0.80, scale: 0.85),
        TreeSpec(xFraction: 0.23, ridgeYFraction: 0.74, scale: 1.05),
        TreeSpec(xFraction: 0.50, ridgeYFraction: 0.79, scale: 0.70),
        TreeSpec(xFraction: 0.71, ridgeYFraction: 0.75, scale: 1.0),
        TreeSpec(xFraction: 0.90, ridgeYFraction: 0.71, scale: 0.80),
    ]

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            ZStack(alignment: .topLeading) {
                HillsShape(profile: .front)
                    .fill(
                        LinearGradient(
                            colors: [groundColor.opacity(0.92), groundColor],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )

                if season == .winter {
                    HillsShape(profile: .front)
                        .stroke(Color.white.opacity(0.55), lineWidth: 3)
                        .blur(radius: 1.5)
                }

                ForEach(Array(Self.trees.enumerated()), id: \.offset) { _, spec in
                    tree(for: spec, in: size)
                }
            }
            .frame(width: size.width, height: size.height)
        }
        .allowsHitTesting(false)
    }

    // MARK: - Palette

    private var groundColor: Color {
        switch season {
        case .winter: return Color(red: 0.74, green: 0.81, blue: 0.87)
        case .spring: return Color(red: 0.45, green: 0.68, blue: 0.43)
        case .summer: return Color(red: 0.18, green: 0.47, blue: 0.27)
        case .fall: return Color(red: 0.72, green: 0.45, blue: 0.20)
        }
    }

    private var canopyColor: Color {
        switch season {
        case .winter: return .clear // no canopy — bare branches
        case .spring: return Color(red: 0.38, green: 0.63, blue: 0.36)
        case .summer: return Color(red: 0.11, green: 0.36, blue: 0.19)
        case .fall: return Color(red: 0.68, green: 0.35, blue: 0.13)
        }
    }

    private var trunkColor: Color {
        season == .winter
            ? Color(red: 0.30, green: 0.24, blue: 0.20)
            : Color(red: 0.33, green: 0.24, blue: 0.17)
    }

    private var accentColor: Color {
        switch season {
        case .winter: return .white
        case .spring: return Color(red: 0.97, green: 0.78, blue: 0.85)
        case .summer: return Color.clear
        case .fall: return Color(red: 0.87, green: 0.62, blue: 0.20)
        }
    }

    // MARK: - Tree drawing

    @ViewBuilder
    private func tree(for spec: TreeSpec, in size: CGSize) -> some View {
        let treeWidth = size.width * 0.11 * spec.scale
        let treeHeight = size.height * 0.42 * spec.scale
        let ridgeY = size.height * spec.ridgeYFraction
        let treeRect = CGRect(x: 0, y: 0, width: treeWidth, height: treeHeight)

        ZStack(alignment: .top) {
            TreeShape.trunkPath(in: treeRect)
                .fill(trunkColor)

            if season == .winter {
                TreeShape.branchPath(in: treeRect)
                    .stroke(trunkColor, lineWidth: max(1, treeWidth * 0.05))
                // Snow dusting caught on the bare branches.
                Circle()
                    .fill(Color.white.opacity(0.9))
                    .frame(width: treeWidth * 0.32, height: treeWidth * 0.32)
                    .offset(x: treeWidth * 0.18, y: treeHeight * 0.02)
            } else {
                TreeShape.canopyPath(in: treeRect)
                    .fill(canopyColor)

                if season != .summer {
                    // Blossom (spring) / leaf (fall) accent dots scattered on the canopy.
                    ForEach(0..<4, id: \.self) { i in
                        let offsets: [(CGFloat, CGFloat)] = [(0.18, 0.16), (0.55, 0.05), (0.70, 0.28), (0.30, 0.32)]
                        Circle()
                            .fill(accentColor)
                            .frame(width: treeWidth * 0.14, height: treeWidth * 0.14)
                            .offset(x: treeWidth * offsets[i].0, y: treeHeight * offsets[i].1)
                    }
                }
            }
        }
        .frame(width: treeWidth, height: treeHeight)
        .position(x: size.width * spec.xFraction, y: ridgeY - treeHeight * 0.30)
    }
}
