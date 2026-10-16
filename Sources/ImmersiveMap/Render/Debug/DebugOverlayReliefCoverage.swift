// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import CoreGraphics
import simd

/// The terrain seen from above, for the relief tab's coverage map: every
/// terrain tile the store lists (`GroundReliefStatusSnapshot`) as its
/// square, by its state, the frame's wanted ones drawn strong and the ones
/// kept from earlier frames faint, over the view's footprint, the point
/// the camera looks at and the eye of the tiles' coverage map
/// (`DebugOverlayTileCoverage`). Normalized Mercator, as that map.
struct DebugOverlayReliefCoverage: Equatable {
    struct Square: Equatable {
        let tile: Tile
        let state: GroundReliefStatusSnapshot.State
        let isWanted: Bool

        var square: CGRect {
            let count = Double(1 << tile.z)
            return CGRect(x: Double(tile.x) / count, y: Double(tile.y) / count, width: 1 / count, height: 1 / count)
        }
    }

    let squares: [Square]
    let footprint: [SIMD2<Double>]
    let center: SIMD2<Double>
    let eye: SIMD2<Double>?

    static func make(status: GroundReliefStatusSnapshot, view: DebugOverlayTileCoverage) -> DebugOverlayReliefCoverage {
        DebugOverlayReliefCoverage(squares: status.tiles.map { Square(tile: $0.tile, state: $0.state, isWanted: $0.isWanted) },
                                   footprint: view.footprint,
                                   center: view.center,
                                   eye: view.eye)
    }

    /// The square of Mercator shown: the wanted tiles and the point looked
    /// at, as the tiles' map frames its slots
    /// (`DebugOverlayTileCoverageLayout.window(for:)`). A kept tile out of
    /// it is cut at its edge.
    var window: CGRect {
        var bounds = CGRect(x: center.x, y: center.y, width: 0, height: 0)
        for square in squares where square.isWanted { bounds = bounds.union(square.square) }
        guard bounds.width > 0 || bounds.height > 0 else {
            return CGRect(x: center.x - 0.5, y: center.y - 0.5, width: 1, height: 1)
        }
        let side = max(bounds.width, bounds.height) * (1 + DebugOverlayTileCoverageLayout.margin * 2)
        return CGRect(x: bounds.midX - side / 2, y: bounds.midY - side / 2, width: side, height: side)
    }

    /// The squares in drawing order: the kept under the wanted, the
    /// coarse under the fine.
    var drawingOrder: [Square] {
        squares.sorted { a, b in
            if a.isWanted != b.isWanted { return a.isWanted == false }
            if a.tile.z != b.tile.z { return a.tile.z < b.tile.z }
            if a.tile.x != b.tile.x { return a.tile.x < b.tile.x }
            return a.tile.y < b.tile.y
        }
    }
}
