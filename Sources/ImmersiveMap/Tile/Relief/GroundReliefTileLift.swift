// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import simd

/// How far the drawn ground of one tile rises under a point, in world
/// units, for what is placed on the ground rather than drawn as it (the
/// labels): the terrain the ground of the tile rises by
/// (`GroundReliefStore.relief(for:terrainZoom:)`), over the frame's datum,
/// times the frame's strength, so a point sits where the ground is drawn.
/// Nil where the tile's terrain is not in, and the point stays on the
/// plane as the tile does.
struct GroundReliefTileLift {
    let relief: GroundRelief
    let unitsPerMetre: Float
    let datumMetres: Float

    /// `targetZoom` is the ring the tile is drawn in, which picks the
    /// terrain (`GroundReliefStore.terrainZoom(forTargetZoom:)`). The
    /// rise is the frame's, the ground's (`GroundReliefStore.worldUnitsPerMetre`).
    init?(store: GroundReliefStore, tile: Tile, targetZoom: Int) {
        guard let relief = store.relief(for: tile, targetZoom: targetZoom) else {
            return nil
        }
        self.relief = relief
        self.unitsPerMetre = store.worldUnitsPerMetre
        self.datumMetres = store.datumMetres
    }

    /// The lift under the point at `uv`, the tile's uv with v from its
    /// north edge, in world units.
    func worldUnits(atTileUV uv: SIMD2<Float>) -> Float {
        relief.drawnMetres(atTileUV: uv, datumMetres: datumMetres) * unitsPerMetre
    }
}
