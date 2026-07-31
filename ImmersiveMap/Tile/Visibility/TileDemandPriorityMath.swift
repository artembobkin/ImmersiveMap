// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import simd

/// Network demand order for tiles: from those closest to the camera center to the far ones.
/// The loader and the parse queue preserve the given order, so this sort alone
/// determines which tiles hit the network first and which one gets a parse slot
/// first. The metric is the Chebyshev distance in normalized world
/// coordinates: comparable across targets of different zooms
/// (distance LOD yields mixed z).
enum TileDemandPriorityMath {
    static func sortedByCameraProximity(_ targets: [VisibleTile],
                                        centerWorldMercator: SIMD2<Double>,
                                        renderSurfaceMode: ViewMode) -> [VisibleTile] {
        let wrappedCenterX = ImmersiveMapProjection.wrapNormalizedWorldX(centerWorldMercator.x)
        let clampedCenterY = ImmersiveMapProjection.clampNormalizedWorldY(centerWorldMercator.y)

        func normalizedDistance(_ target: VisibleTile) -> Double {
            let tilesCount = Double(1 << target.z)
            let tileCenterX = (Double(target.x) + 0.5) / tilesCount
            let tileCenterY = (Double(target.y) + 0.5) / tilesCount

            let dx: Double
            switch renderSurfaceMode {
            case .spherical:
                let direct = abs(wrappedCenterX - tileCenterX)
                dx = min(direct, 1.0 - direct)
            case .flat:
                dx = abs(wrappedCenterX - (tileCenterX + Double(target.loop)))
            }
            let dy = abs(clampedCenterY - tileCenterY)
            return max(dx, dy)
        }

        return targets
            .map { (target: $0, distance: normalizedDistance($0)) }
            .sorted { lhs, rhs in
                if lhs.distance != rhs.distance {
                    return lhs.distance < rhs.distance
                }
                let left = lhs.target
                let right = rhs.target
                if left.z != right.z {
                    return left.z > right.z
                }
                if left.loop != right.loop {
                    return left.loop < right.loop
                }
                if left.x != right.x {
                    return left.x < right.x
                }
                return left.y < right.y
            }
            .map(\.target)
    }
}
