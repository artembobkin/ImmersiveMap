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

    // MARK: - Over the ground

    // What draws over the ground and its roads, each at one depth of its
    // own: so many rank steps nearer than the far plane. A higher rank is
    // nearer, so the list reads from what lies lowest to what stands over
    // everything. The three are stated here, in one place, because their
    // order is the contract between the features that draw by them, and
    // `RoadRankDepthContractTests` holds it: every road under the layers,
    // the layers under the labels, the labels under the real geometry.

    /// The layers of the app's data (`LayerDepth`).
    static let appLayersRank: Float = 1_210
    /// The labels painted on the map (`SurfaceLabelDepth`).
    static let surfaceLabelsRank: Float = 1_220
    /// The buildings, the models and the trees, by the scale the camera's
    /// matrix carries (`RenderCamera.realDepthScale`). The shaders that
    /// divide it back out repeat it as a literal, pinned by the tests.
    static let realGeometryRank: Float = 1_536
}
