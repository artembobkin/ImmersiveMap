// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

/// CPU mirror of the sphere ground's rank-depth constants in
/// TileSphere.metal (kTileSphereLayerDepthStep and the band built from
/// it); the literals are pinned against the shader source by
/// TileClipDistanceContractTests. The band orders class first, style rank
/// second; WHICH tile owns a pixel is the tile-priority stencil's job
/// (TileSourceStencilPriority).
enum GlobeSurfaceDepthRank {
    /// One style rank step, in NDC at the far plane for the sphere, and
    /// as a scale of the projection's depth for the flat ground
    /// (Tile.metal). A float depth resolves a step of 1e-7, but the flat
    /// ground's depth is interpolated across a triangle that can run from
    /// the near plane to the horizon, and two layers' triangles of one
    /// plane interpolate to values a few 1e-6 apart: a step of 4e-7 lost
    /// the order between them (HorizonOffscreenRenderTests), 8e-7 kept
    /// it, and this is four times that.
    static let layerDepthStep: Float = 3.2e-6
    /// The ribbons class sits one class band nearer than the fills: 256
    /// styles plus one step of separation.
    static let classDepthBand: Float = 257 * layerDepthStep
    /// The flat road buckets and the bridge overlay: nearer than both
    /// ground bands, so they pass the depth test over the opaque ground's
    /// writes. The roads' own ranks start here (`RoadRankDepth`).
    static let flatRoadsDepthOffset: Float = 600 * layerDepthStep
}
