// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation
import simd

/// Picks the one tile the debug grid draws on: the tile under the camera centre,
/// which is the map point at the middle of the view.
enum DebugTileGridCenterTile {
    /// Placed tiles whose slot contains the camera centre. `placeIn` slots are a
    /// non-overlapping cover of the visible area, so this is a single tile per
    /// wrapped world copy: in flat mode the same tile can be on screen more than
    /// once, and every copy contains the centre equally.
    static func candidates(placeTiles: [PlaceTile],
                           centerWorldMercator: SIMD2<Double>) -> [PlaceTile] {
        let worldX = ImmersiveMapProjection.wrapNormalizedWorldX(centerWorldMercator.x)
        // The southern edge belongs to the last row rather than to a row that does
        // not exist, so a centre clamped exactly to 1.0 still lands on a tile.
        let worldY = min(ImmersiveMapProjection.clampNormalizedWorldY(centerWorldMercator.y),
                         1.0 - .ulpOfOne)

        return placeTiles.filter { placeTile in
            let zoom = placeTile.placeIn.z
            guard zoom >= 0, zoom < 30 else {
                return false
            }

            let tilesCount = Double(1 << zoom)
            let rawX = worldX * tilesCount - Double(placeTile.placeIn.x)
            let wrappedX = rawX - tilesCount * (rawX / tilesCount).rounded(.down)
            let localY = worldY * tilesCount - Double(placeTile.placeIn.y)
            return wrappedX >= 0.0 && wrappedX < 1.0 && localY >= 0.0 && localY < 1.0
        }
    }

    /// Tie-break between wrapped copies: the copy drawn closest to the middle of
    /// the viewport is the one the camera is actually looking at. `projectedCenters`
    /// holds the screen position of each candidate's UV centre, in the same order.
    static func nearestToViewportCenter(candidates: [PlaceTile],
                                        projectedCenters: [ScreenPointOutput],
                                        viewportSize: SIMD2<Float>) -> PlaceTile? {
        guard candidates.isEmpty == false else {
            return nil
        }
        guard candidates.count > 1, projectedCenters.count == candidates.count else {
            return candidates.first
        }

        let viewportCenter = viewportSize * 0.5
        var best: PlaceTile?
        var bestDistance = Float.greatestFiniteMagnitude
        for index in candidates.indices {
            let point = projectedCenters[index]
            guard point.visible != 0 else {
                continue
            }

            let distance = simd_length(point.position - viewportCenter)
            guard distance.isFinite, distance < bestDistance else {
                continue
            }

            bestDistance = distance
            best = candidates[index]
        }
        return best ?? candidates.first
    }
}
