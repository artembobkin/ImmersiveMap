// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

import CoreGraphics
import simd

/// Hit-test state of one rendered frame of the tile grid: the zoom whose
/// tiles it showed, the projection it drew them with, and the rules a tap
/// is held to, as the frame's settings had them. What is on screen is what
/// can be tapped: a frame that showed no grid takes no tap.
struct TileGridSelectionSnapshot: SelectionPickData, @unchecked Sendable {
    static let empty = TileGridSelectionSnapshot(frameIndex: 0, drawSize: .zero, projection: nil, zoom: 0,
                                                 gesture: .tap, mode: .multiple,
                                                 selectionLimit: nil, selectableBounds: nil)

    var kind: ImmersiveMapSelection.Kind { .tileGrid }
    let frameIndex: UInt64
    let drawSize: CGSize
    /// The frame's projection, nil for a frame that showed no grid or one
    /// whose tiles are not for tapping.
    let projection: GeoScreenProjectionMath.FrameConstants?
    /// The zoom of the tiles the frame showed.
    let zoom: Int
    /// The gesture that selects a tile, and how many it may hold.
    let gesture: ImmersiveMapSettings.TileGridSettings.SelectionGesture
    let mode: ImmersiveMapSettings.TileGridSettings.SelectionMode
    let selectionLimit: Int?
    let selectableBounds: ImmersiveMapGeoBounds?

    /// The tile under `point` (drawable pixels, origin bottom-left) and
    /// the place on the map there.
    func hitTest(point: CGPoint) -> (tile: Tile, coordinate: GeoCoordinate)? {
        guard let projection,
              let place = GeoScreenPlaceMath.place(under: SIMD2(Double(point.x), Double(point.y)),
                                                   constants: projection) else {
            return nil
        }
        return (Tile.containing(normalizedWorld: place.world, zoom: zoom),
                GeoScreenPlaceMath.coordinate(ofWorld: place.world))
    }
}
