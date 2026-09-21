// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Metal
import simd

/// Mirrors `TileRasterZone` in TileRaster.metal.
struct TileRasterZoneUniform {
    /// xyz the camera in the render world, w the zone's start distance.
    var eyeAndStart: SIMD4<Float>
    /// x the zone's end distance, y the fragment's rank depth.
    var endAndRankDepth: SIMD4<Float>
}

/// Draws the rasterized sources of the flat world pass: one textured quad
/// over each tile's extent (TileRaster.metal), its alpha the picture's
/// share of the pixel in the raster zone (`RasterZone`). Finest first,
/// like the vector sources.
///
/// A picture that is its tile's whole ground (`RasterZone.TileDraw.picture`)
/// draws under the ground owner state just under the fills' first rank, so it
/// writes the band like the vector ground would and what draws over it
/// passes the depth test. A picture blended over its tile's own geometry
/// draws under the tile test state, writing nothing, one half step nearer
/// than the last fill rank and farther than the first ribbon: over every
/// fill under it, under every building, and what draws after it still
/// tests against the fills' depth.
enum TileRasterDrawer {
    struct Source {
        let tile: Tile
        let worldWrap: Int8
        let texture: MTLTexture
        /// The picture is blended over the tile's geometry, which drew
        /// under it.
        var isBlended: Bool = false
    }

    /// Half a step under the fills' first rank (Tile.metal,
    /// kFlatTileLayerDepthStep): painted ground, and farther than any fill
    /// that draws over the picture.
    static let groundRankDepth: Float = 1 - 0.5 * GlobeSurfaceDepthRank.layerDepthStep
    /// Between the last fill rank (256 steps) and the ribbons' class band.
    static let overFillsRankDepth: Float = 1 - 256.5 * GlobeSurfaceDepthRank.layerDepthStep

    static func draw(renderEncoder: MTLRenderCommandEncoder,
                     cameraUniform: CameraUniform,
                     sources: [Source],
                     flatRenderState: FlatRenderState,
                     groundShadowMask: GroundShadowMaskBinding,
                     pipeline: TileRasterPipeline,
                     zoneSpan: RasterZone.Span,
                     groundOwnerState: MTLDepthStencilState,
                     tileStencilTestState: MTLDepthStencilState) {
        guard sources.isEmpty == false else { return }
        renderEncoder.pushDebugGroup("ground.raster")
        pipeline.selectPipeline(renderEncoder: renderEncoder)
        renderEncoder.setCullMode(.none)
        var cameraUniformValue = cameraUniform
        renderEncoder.setVertexBytes(&cameraUniformValue, length: MemoryLayout<CameraUniform>.stride, index: 1)
        var shadowUniformValue = groundShadowMask.uniform
        renderEncoder.setFragmentBytes(&shadowUniformValue, length: MemoryLayout<ShadowUniform>.stride, index: 3)
        renderEncoder.setFragmentTexture(groundShadowMask.texture, index: 1)
        for source in sources.sorted(by: { $0.tile.z > $1.tile.z }) {
            let originAndSize = ImmersiveMapProjection.flatTileOriginAndSize(x: source.tile.x,
                                                                             y: source.tile.y,
                                                                             z: source.tile.z,
                                                                             worldWrap: source.worldWrap,
                                                                             flatRenderPan: flatRenderState.pan,
                                                                             renderMapSize: flatRenderState.renderMapSize)
            let scale = originAndSize.z / 4096.0
            var modelMatrix = Matrix.translationMatrix(x: originAndSize.x, y: originAndSize.y, z: 0)
                * Matrix.scaleMatrix(sx: scale, sy: scale, sz: 1)
            renderEncoder.setVertexBytes(&modelMatrix, length: MemoryLayout<matrix_float4x4>.stride, index: 3)
            renderEncoder.setDepthStencilState(source.isBlended ? tileStencilTestState : groundOwnerState)
            var zone = TileRasterZoneUniform(
                eyeAndStart: SIMD4<Float>(cameraUniform.eye, zoneSpan.start),
                endAndRankDepth: SIMD4<Float>(zoneSpan.end,
                                              source.isBlended ? overFillsRankDepth : groundRankDepth,
                                              0, 0))
            renderEncoder.setFragmentBytes(&zone, length: MemoryLayout<TileRasterZoneUniform>.stride, index: 4)
            renderEncoder.setStencilReferenceValue(TileSourceStencilPriority.reference(sourceZoom: source.tile.z))
            renderEncoder.setFragmentTexture(source.texture, index: 0)
            renderEncoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }
        renderEncoder.popDebugGroup()
    }
}
