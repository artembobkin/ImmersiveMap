// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

/// CPU mirror of the sphere ground's rank-depth constants in
/// TileSphere.metal (kTileSphereLayerDepthStep and the bands built from
/// it); the literals are pinned against the shader source by
/// TileClipDistanceContractTests. The band orders source zoom first, class
/// second, style rank third, so one depth test rejects a coarse
/// substitute's overflow wherever a finer tile painted, on top of the
/// layer ordering it already carried.
enum GlobeSurfaceDepthRank {
    /// One style rank step, in NDC at the far plane.
    static let layerDepthStep: Float = 4e-7
    /// The ribbons class sits one class band nearer than the fills of the
    /// same source zoom: 256 styles plus one step of separation.
    static let classDepthBand: Float = 257 * layerDepthStep
    /// One source zoom's band: its fills band and its ribbons band.
    static let zoomDepthBand: Float = 2 * classDepthBand

    /// The per-draw depth bias of a source tile: a finer source carries a
    /// larger bias, so its whole band sits nearer and wins the depth test
    /// over every coarser source. Zooms are clamped to the sphere's range
    /// (tiles from z10 never draw on the sphere).
    static func bias(sourceZoom: Int) -> Float {
        Float(min(max(sourceZoom, 0), 9) + 1) * zoomDepthBand
    }
}
