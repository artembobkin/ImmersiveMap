// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation

enum BaseLabelDetailTier: UInt8, CaseIterable, Equatable {
    case full
    case reduced
    case minimal

    static func tier(forRelativeDistance distance: Int) -> BaseLabelDetailTier {
        if distance <= 2 { return .full }
        if distance <= 7 { return .reduced }
        return .minimal
    }

    /// Absolute budget of anchor labels (places, water, peaks) per tile in the tier.
    /// Absolute numbers equalize on-screen density: a dense tile yields exactly
    /// the budget, a sparse one yields everything it has, and tile borders show
    /// no seams. Spending order is collision priority, so the budget goes to
    /// the most important features. `nil` - no limit.
    static func anchorLabelBudget(tier: BaseLabelDetailTier) -> Int? {
        switch tier {
        case .full:
            return nil
        case .reduced:
            return 12
        case .minimal:
            return 4
        }
    }

    /// Absolute POI budget per tile in the tier: in the middle tier a tile yields
    /// only a handful of the best-ranked venues (large ones in full, small ones
    /// as icons), in the far tier POI do not live at all. Within POI the collision
    /// priority matches the local OpenMapTiles rank, so the budget spreads evenly
    /// across the tile instead of from one corner.
    static func poiLabelBudget(tier: BaseLabelDetailTier) -> Int? {
        switch tier {
        case .full:
            return nil
        case .reduced:
            return 12
        case .minimal:
            return 0
        }
    }

    static func relativeDistance(tile: VisibleTile, center: Center, renderSurfaceMode: ViewMode) -> Int {
        VisibleTileRelativeDistance.compute(tile: tile,
                                            center: center,
                                            renderSurfaceMode: renderSurfaceMode)
    }

    /// Distance from the view center to the nearest point of the owning tile,
    /// in tiles of the VIEW ZOOM. Measuring in view-zoom units is essential: a
    /// coarse parent of the far band would be "near" the center in its own units
    /// and would get the near tier with its full label set and no budget.
    static func relativeDistance(tile: VisibleTile,
                                 center: Center,
                                 centerZoom: Int,
                                 renderSurfaceMode: ViewMode) -> Int {
        let tileSpan = Double(sign: .plus, exponent: centerZoom - tile.z, significand: 1)
        let worldSize = Double(sign: .plus, exponent: centerZoom, significand: 1)
        let baseX = (Double(tile.x) + Double(tile.loop) * Double(1 << tile.z)) * tileSpan
        let minY = Double(tile.y) * tileSpan
        let dy = max(0.0, max(minY - center.tileY, center.tileY - (minY + tileSpan)))

        func xDistance(offset: Double) -> Double {
            let minX = baseX + offset
            return max(0.0, max(minX - center.tileX, center.tileX - (minX + tileSpan)))
        }

        let dx: Double
        switch renderSurfaceMode {
        case .flat:
            dx = xDistance(offset: 0)
        case .spherical:
            dx = min(xDistance(offset: 0),
                     min(xDistance(offset: worldSize), xDistance(offset: -worldSize)))
        }
        return Int(max(dx, dy))
    }

}
