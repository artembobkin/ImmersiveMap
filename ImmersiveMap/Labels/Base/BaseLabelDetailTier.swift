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

    static func retainedLabelCount(labelCount: Int, tier: BaseLabelDetailTier) -> Int {
        guard labelCount > 0 else { return 0 }
        switch tier {
        case .full:
            return labelCount
        case .reduced:
            let halfCount = Int(ceil(Double(labelCount) * 0.50))
            return min(labelCount, max(minimalCount(labelCount: labelCount), halfCount))
        case .minimal:
            return minimalCount(labelCount: labelCount)
        }
    }

    static func relativeDistance(tile: VisibleTile, center: Center, renderSurfaceMode: ViewMode) -> Int {
        VisibleTileRelativeDistance.compute(tile: tile,
                                            center: center,
                                            renderSurfaceMode: renderSurfaceMode)
    }

    static func relativeDistance(tile: VisibleTile,
                                 center: Center,
                                 centerZoom: Int,
                                 renderSurfaceMode: ViewMode) -> Int {
        let normalizedCenter = center.normalized(fromZoom: centerZoom, toZoom: tile.z)
        return relativeDistance(tile: tile,
                                center: normalizedCenter,
                                renderSurfaceMode: renderSurfaceMode)
    }

    private static func minimalCount(labelCount: Int) -> Int {
        min(labelCount, max(1, min(4, Int(ceil(Double(labelCount) * 0.10)))))
    }
}

private extension Center {
    func normalized(fromZoom sourceZoom: Int, toZoom targetZoom: Int) -> Center {
        guard sourceZoom != targetZoom else {
            return self
        }

        if sourceZoom > targetZoom {
            let divisor = Double(1 << (sourceZoom - targetZoom))
            return Center(tileX: tileX / divisor,
                          tileY: tileY / divisor)
        }

        let multiplier = Double(1 << (targetZoom - sourceZoom))
        return Center(tileX: tileX * multiplier,
                      tileY: tileY * multiplier)
    }
}
