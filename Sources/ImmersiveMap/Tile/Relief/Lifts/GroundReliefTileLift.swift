// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import simd

/// How far the drawn ground of one tile rises under a point, in world
/// units, for what is placed on the ground rather than drawn as it (the
/// labels): the terrain the ground of the tile rises by, the one its
/// placement is bound to (`PlaceTile.terrain`,
/// `GroundReliefFrame.relief(for:terrain:)`), over the frame's datum,
/// times the frame's strength, so a point sits where the ground is drawn.
/// Nil on the plane, where the point stays as the tile does.
struct GroundReliefTileLift {
    let relief: GroundRelief
    let unitsPerMetre: Float
    let datumMetres: Float

    /// `terrain` is the terrain tile the tile's grid rises by
    /// (`PlaceTilesContext.displacementBySource`). The rise is the frame's,
    /// the ground's (`GroundReliefFrame.worldUnitsPerMetre`).
    init?(relief frame: GroundReliefFrame, tile: Tile, terrain: Tile?) {
        guard let terrain, let relief = frame.relief(for: tile, terrain: terrain) else {
            return nil
        }
        self.relief = relief
        self.unitsPerMetre = frame.worldUnitsPerMetre
        self.datumMetres = frame.datumMetres
    }

    /// The lift under the point at `uv`, the tile's uv with v from its
    /// north edge, in world units.
    func worldUnits(atTileUV uv: SIMD2<Float>) -> Float {
        relief.drawnMetres(atTileUV: uv, datumMetres: datumMetres) * unitsPerMetre
    }
}
