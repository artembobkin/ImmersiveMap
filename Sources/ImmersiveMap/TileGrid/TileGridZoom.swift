// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

import Foundation

/// Which zoom's tiles the grid shows at a camera zoom, and whether it
/// shows at all. Pure: no frame, no Metal.
enum TileGridZoom {
    struct Resolution: Equatable {
        /// The zoom whose tiles the grid shows.
        let zoom: Int
        /// How wide one of those tiles is on screen under the camera, in
        /// points.
        let tileScreenPoints: Double
        /// Whether the tiles are wide enough for their texts.
        let drawsLabels: Bool
    }

    /// The grid at `cameraZoom`: the tiles of the camera's own zoom,
    /// clamped into the settings' range, nil while such a tile is narrower
    /// on screen than the settings allow. `baseTileScreenPoints` is what a
    /// tile spans at the camera zoom equal to its own
    /// (`baseTileScreenPoints(viewportHeightPoints:tileWorldSize:)`), and a
    /// tile of another zoom spans twice that for every zoom the camera is
    /// deeper.
    static func resolve(cameraZoom: Double,
                        baseTileScreenPoints: Double,
                        settings: ImmersiveMapSettings.TileGridSettings) -> Resolution? {
        guard cameraZoom.isFinite, baseTileScreenPoints > 0 else { return nil }
        let range = settings.zoomRange
        let zoom = min(max(Int(cameraZoom.rounded(.down)), range.lowerBound), range.upperBound)
        let points = baseTileScreenPoints * pow(2, cameraZoom - Double(zoom))
        guard points.isFinite, points >= Double(settings.minimumTileScreenPoints) else { return nil }
        return Resolution(zoom: zoom,
                          tileScreenPoints: points,
                          drawsLabels: points >= Double(settings.labelMinimumTileScreenPoints))
    }

    /// Screen points a tile spans at the camera zoom equal to its own: the
    /// render camera (vertical field of view pi/4, at distance 1,
    /// `RenderCamera`) shows the tile's world size over the viewport's
    /// height, so the share is the same in any window.
    static func baseTileScreenPoints(viewportHeightPoints: Double, tileWorldSize: Double) -> Double {
        viewportHeightPoints * tileWorldSize / (2 * tan(Double.pi / 8))
    }
}
