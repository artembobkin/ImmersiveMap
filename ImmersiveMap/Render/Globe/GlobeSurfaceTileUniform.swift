// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import simd

/// Per-draw tile identity of the sphere tile pipeline, precomputed so the
/// vertex stage does no per-vertex pow(2, z); the layout mirrors
/// `GlobeSurfaceTile` in TileSphere.metal (pinned by
/// `GlobeVectorSurfaceUniformLayoutTests`).
struct GlobeSurfaceTileUniform {
    /// World uv of the tile's north-west corner (x east, y the Mercator row).
    var uvOrigin: SIMD2<Float>
    /// Tile-local uv to world uv: 1 / 2^z.
    var uvScale: Float
    /// The normalized world x the flat morph target unwraps around: the
    /// tile's centre.
    var referenceWorldX: Float
    /// The source zoom's rank-depth band offset (GlobeSurfaceDepthRank): a
    /// finer source sits nearer, which is what rejects a coarser
    /// substitute's overflow wherever a finer tile painted.
    var depthBias: Float
    var padding: Float = 0

    init(tile: Tile) {
        let zPow = Float(1 << tile.z)
        self.uvOrigin = SIMD2<Float>(Float(tile.x) / zPow, Float(tile.y) / zPow)
        self.uvScale = 1.0 / zPow
        self.referenceWorldX = (Float(tile.x) + 0.5) / zPow
        self.depthBias = GlobeSurfaceDepthRank.bias(sourceZoom: tile.z)
    }
}
