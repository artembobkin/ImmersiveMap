// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Metal
import simd

/// Mirrors `TileSphereRasterGrid` in TileSphereRaster.metal.
struct TileSphereRasterGridUniform {
    var cells: UInt32
    var rankDepth: Float
}

/// Draws the rasterized sources of the spherical world pass: the tile's
/// picture over a grid that follows the sphere (TileSphereRaster.metal),
/// its alpha the picture's share of the pixel in the raster zone
/// (`RasterZone`). Finest first, like the vector sources.
///
/// Every picture sits at one rank, between the last fill rank and the
/// first ribbon (`TileRasterDrawer.overFillsRankDepth`): over any fill a
/// coarser source overflowed under it, under every ribbon. The sphere has
/// no ownership prepass and the horizon reads ground off written depth, so
/// a picture that is its tile's whole ground draws under the sphere's
/// owner state, writing the depth and the tile-priority stencil like the
/// opaque fills would. A picture blended over its tile's own fills, which
/// wrote both already, draws under the tile test state and writes nothing.
enum TileSphereRasterDrawer {
    struct Source {
        let tile: Tile
        let texture: MTLTexture
        /// The picture is blended over the tile's geometry, which drew
        /// under it.
        let isBlended: Bool
    }

    /// Cells a side of a tile's grid: the parser's own split of a tile of
    /// that zoom (`GroundGeometrySubdivider`), so a picture's chords sag
    /// no more than the vector ground's, and never under four.
    static func gridCells(tileZoom: Int) -> Int {
        guard let step = GroundGeometrySubdivider.step(forTileZoom: tileZoom), step > 0 else { return 4 }
        return max(4096 / step, 4)
    }

    static func draw(renderEncoder: MTLRenderCommandEncoder,
                     cameraUniform: CameraUniform,
                     globe: GlobeUniform,
                     globeFrame: GlobeFrameConstantsUniform,
                     sources: [Source],
                     pipeline: TileSphereRasterPipeline,
                     zoneSpan: RasterZone.Span,
                     morph: Bool,
                     ownerState: MTLDepthStencilState,
                     tileStencilTestState: MTLDepthStencilState,
                     depthDisabledState: MTLDepthStencilState) {
        guard sources.isEmpty == false else { return }
        renderEncoder.pushDebugGroup("ground.raster")
        pipeline.selectPipeline(renderEncoder: renderEncoder, morph: morph)
        renderEncoder.setFrontFacing(.counterClockwise)
        renderEncoder.setCullMode(.back)
        var cameraUniformValue = cameraUniform
        var globeValue = globe
        var globeFrameValue = globeFrame
        renderEncoder.setVertexBytes(&cameraUniformValue, length: MemoryLayout<CameraUniform>.stride, index: 1)
        renderEncoder.setVertexBytes(&globeValue, length: MemoryLayout<GlobeUniform>.stride, index: 8)
        renderEncoder.setVertexBytes(&globeFrameValue, length: MemoryLayout<GlobeFrameConstantsUniform>.stride, index: 10)
        var zone = TileRasterZoneUniform(eyeAndStart: SIMD4<Float>(cameraUniform.eye, zoneSpan.start),
                                         endAndRankDepth: SIMD4<Float>(zoneSpan.end, 0, 0, 0))
        renderEncoder.setFragmentBytes(&zone, length: MemoryLayout<TileRasterZoneUniform>.stride, index: 4)
        for source in sources.sorted(by: { $0.tile.z > $1.tile.z }) {
            renderEncoder.setDepthStencilState(source.isBlended ? tileStencilTestState : ownerState)
            renderEncoder.setStencilReferenceValue(TileSourceStencilPriority.reference(sourceZoom: source.tile.z))
            var surfaceTile = GlobeSurfaceTileUniform(tile: source.tile)
            renderEncoder.setVertexBytes(&surfaceTile, length: MemoryLayout<GlobeSurfaceTileUniform>.stride, index: 9)
            let cells = gridCells(tileZoom: source.tile.z)
            var grid = TileSphereRasterGridUniform(cells: UInt32(cells), rankDepth: TileRasterDrawer.overFillsRankDepth)
            renderEncoder.setVertexBytes(&grid, length: MemoryLayout<TileSphereRasterGridUniform>.stride, index: 12)
            renderEncoder.setFragmentTexture(source.texture, index: 0)
            renderEncoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: cells * cells * 6)
        }
        renderEncoder.setCullMode(.none)
        renderEncoder.setFrontFacing(.clockwise)
        renderEncoder.setDepthStencilState(depthDisabledState)
        renderEncoder.popDebugGroup()
    }
}
