// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

/// CPU mirror of the sphere ground's rank-depth constants in
/// TileSphere.metal (kTileSphereLayerDepthStep and the band built from
/// it); the literals are pinned against the shader source by
/// TileClipDistanceContractTests. The band orders class first, style rank
/// second; WHICH tile owns a pixel is the tile-priority stencil's job
/// (TileSourceStencilPriority).
enum GlobeSurfaceDepthRank {
    /// One style rank step, in NDC at the far plane.
    static let layerDepthStep: Float = 4e-7
    /// The ribbons class sits one class band nearer than the fills: 256
    /// styles plus one step of separation.
    static let classDepthBand: Float = 257 * layerDepthStep
    /// The flat road buckets and the bridge overlay: nearer than both
    /// ground bands, so painter's order among them stays free while they
    /// still pass the depth test over the opaque ground's writes.
    static let flatRoadsDepthOffset: Float = 600 * layerDepthStep
}
