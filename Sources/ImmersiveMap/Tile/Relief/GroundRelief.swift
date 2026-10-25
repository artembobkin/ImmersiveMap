// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Metal
import simd

/// The heights a flattened ground tile rises by (`Tile.metal`, the ground
/// relief variant): a terrain tile's heights in metres as a texture, and
/// where the ground tile lies in it, the terrain tile being the ground
/// tile's own or an ancestor's. With them the frame's strength: a point
/// of the ground rises by its height over the datum, times the strength
/// the frame's zoom leaves of the relief (`GroundReliefFrameState.setFrame`).
struct GroundRelief {
    /// The terrain tile's heights (`GroundReliefTile`), the texture the
    /// vertex stages sample and the same numbers the CPU reads.
    let terrain: GroundReliefTile
    /// The ground tile's north-west corner in the texture, in 0...1.
    let origin: SIMD2<Float>
    /// The ground tile's side in the texture, in 0...1: 1 for the tile's
    /// own terrain, a half for its parent's.
    let scale: Float
    /// How much taller than the terrain the ground is drawn this frame:
    /// the configured exaggeration times what the zoom fades leave.
    let strength: Float
    /// The terrain tile's occlusion of the sky (`GroundReliefOcclusion`),
    /// over the same square of the tile as the heights, nil while it is
    /// not computed, which draws no darkening.
    let occlusion: MTLTexture?

    var texture: MTLTexture { terrain.texture }

    init(terrain: GroundReliefTile, origin: SIMD2<Float>, scale: Float, strength: Float, occlusion: MTLTexture? = nil) {
        self.terrain = terrain
        self.origin = origin
        self.scale = scale
        self.strength = strength
        self.occlusion = occlusion
    }

    /// The terrain's height in metres under a point of the ground tile, in
    /// the tile's uv (v from the north edge), bilinear between the texels
    /// around it, as the vertex stage samples it.
    func metres(atTileUV uv: SIMD2<Float>) -> Float {
        terrain.metres(atTextureUV: origin + simd_clamp(uv, SIMD2<Float>(repeating: 0), SIMD2<Float>(repeating: 1)) * scale)
    }

    /// The metres a point of the tile is drawn at over the datum, the
    /// frame's strength in them: what to multiply by the world units per
    /// metre.
    func drawnMetres(atTileUV uv: SIMD2<Float>, datumMetres: Float) -> Float {
        (metres(atTileUV: uv) - datumMetres) * strength
    }

    /// The same heights over `part`, a square inside the ground tile
    /// `tile` this relief is over: what draws a part of the tile on its own
    /// grid and lifts it exactly as the whole tile's draw does.
    func narrowed(to part: Tile, in tile: Tile) -> GroundRelief {
        let inner = Self.placement(of: part, in: tile)
        return GroundRelief(terrain: terrain,
                            origin: origin + inner.origin * scale,
                            scale: scale * inner.scale,
                            strength: strength,
                            occlusion: occlusion)
    }

    /// Where a tile lies in the terrain tile `source` over it.
    static func placement(of tile: Tile, in source: Tile) -> (origin: SIMD2<Float>, scale: Float) {
        let depth = max(0, tile.z - source.z)
        let span = Double(1 << depth)
        let origin = SIMD2<Float>(Float((Double(tile.x) - Double(source.x) * span) / span),
                                  Float((Double(tile.y) - Double(source.y) * span) / span))
        return (origin, Float(1 / span))
    }
}
