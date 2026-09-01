// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Metal
import simd

/// The globe counterpart of `FlatMapSurfaceDrawer`: every placement's ground
/// layer (below tile z8 the whole drawable content of a tile lives there)
/// through the sphere tile pipeline. Bindings mirror TileSphere.metal.
///
/// On the resting sphere the ground draws as layers, not as one call. The
/// opaque layers (a style whose palette alphas are 1 and whose zoom fade is
/// 1 this frame) draw first, top layer first, with blending off and a depth
/// write: each layer's z is its rank in a narrow band at the far plane, so
/// the depth test rejects every fragment a higher opaque layer already
/// painted and a pixel is shaded exactly once by its topmost opaque layer.
/// The translucent layers follow bottom-to-top with the same rank z, tested
/// without writing: an opaque layer above them still hides them, everything
/// else blends as before. Placements never contend for a pixel (each is
/// clipped to its slot), so the rank only has to be consistent within one
/// tile. The morph keeps the single blended draw.
enum GlobeVectorSurfaceDrawer {
    /// Rank z band at the far plane: layer `rank` draws at
    /// `1 - (rank + 1) * step` in NDC, the top layer nearest. Far enough
    /// from everything real (routes, models) and wide enough for 256 styles.
    private static let layerDepthStep: Float = 2e-6

    static func draw(renderEncoder: MTLRenderCommandEncoder,
                     cameraUniform: CameraUniform,
                     globe: GlobeUniform,
                     horizonFog: HorizonFogUniform,
                     cameraZoom: Double,
                     pixelsPerPoint: Float,
                     drawableHeightPx: Float,
                     renderMapSize: Double,
                     placeTilesContext: PlaceTilesContext,
                     pipeline: TilePipeline,
                     opaqueDepthState: MTLDepthStencilState,
                     translucentDepthState: MTLDepthStencilState,
                     depthDisabledState: MTLDepthStencilState,
                     isWireframeEnabled: Bool,
                     pureSphere: Bool,
                     globeFrame: GlobeFrameConstantsUniform) {
        guard placeTilesContext.tilePlacements.isEmpty == false else {
            return
        }
        // Off while the globe performance work concentrates on the polygon
        // fills: the ribbons class (boundaries and overview strokes) is not
        // drawn on the resting sphere at all. The morph keeps the combined
        // pass, ribbons included.
        let drawsLineRibbons = false

        // Every tile triangle is counter-clockwise in render space (the
        // parser's contract, ParsedPolygon.firstClockwiseTriangle) and the
        // sphere projection does not mirror, so the near side of the planet
        // is counter-clockwise on screen and the far side clockwise: culling
        // back faces removes the far side by orientation alone. Both calls
        // are explicit because the world pass shares one encoder and the
        // buildings rely on Metal's default front face.
        renderEncoder.setFrontFacing(.counterClockwise)
        renderEncoder.setCullMode(.back)
        if isWireframeEnabled {
            renderEncoder.setTriangleFillMode(.lines)
        }

        var cameraUniformValue = cameraUniform
        var globeValue = globe
        var horizonFogValue = horizonFog
        var streetPaletteUniform = StreetPaletteUniform(
            blend: LowZoomOverviewFade.streetPaletteBlend(for: cameraZoom)
        )
        // Point-locked widths resolve against the real screen gradient of the
        // line field (fwidth in the coverage), so the taper is all the sphere
        // needs. Every road is a symbol at these zooms and no road is painted
        // yet: the surface blend and the marking alpha stay zero.
        let overviewFadeUniform = TileOverviewFadeUniform(
            overviewAlpha: LowZoomOverviewFade.alpha(for: cameraZoom, kind: .overviewFeatures),
            roadAlpha: LowZoomOverviewFade.alpha(for: cameraZoom, kind: .roads),
            landuseAlpha: LowZoomOverviewFade.alpha(for: cameraZoom, kind: .landuse),
            pixelsPerPoint: pixelsPerPoint * LineWidthZoomTaper.scale(for: cameraZoom),
            cameraZoom: Float(cameraZoom)
        )
        var overviewFadeValue = overviewFadeUniform
        renderEncoder.setVertexBytes(&cameraUniformValue, length: MemoryLayout<CameraUniform>.stride, index: 1)
        renderEncoder.setVertexBytes(&streetPaletteUniform, length: MemoryLayout<StreetPaletteUniform>.stride, index: 6)
        renderEncoder.setVertexBytes(&globeValue, length: MemoryLayout<GlobeUniform>.stride, index: 8)
        var globeFrameValue = globeFrame
        renderEncoder.setVertexBytes(&globeFrameValue,
                                     length: MemoryLayout<GlobeFrameConstantsUniform>.stride,
                                     index: 10)
        renderEncoder.setFragmentBytes(&overviewFadeValue, length: MemoryLayout<TileOverviewFadeUniform>.stride, index: 0)
        renderEncoder.setFragmentBytes(&horizonFogValue, length: MemoryLayout<HorizonFogUniform>.stride, index: 2)

        if pureSphere {
            // The opaque layers, top first, depth-written and unblended.
            renderEncoder.setDepthStencilState(opaqueDepthState)
            pipeline.selectSphereOpaqueFillsPipeline(renderEncoder: renderEncoder)
            forEachPlacement(renderEncoder: renderEncoder,
                             placeTilesContext: placeTilesContext,
                             renderMapSize: renderMapSize,
                             pixelsPerPoint: pixelsPerPoint,
                             drawableHeightPx: drawableHeightPx) { buffers, indices in
                drawRuns(renderEncoder: renderEncoder,
                         buffers: buffers,
                         indices: indices,
                         reversed: true) { run in
                    isOpaque(run, overviewFade: overviewFadeUniform)
                }
            }
            // The translucent layers, bottom to top, blended, tested but
            // never written: an opaque layer above still hides them.
            renderEncoder.setDepthStencilState(translucentDepthState)
            pipeline.selectSphereSplitPipeline(renderEncoder: renderEncoder, linesClass: false)
            forEachPlacement(renderEncoder: renderEncoder,
                             placeTilesContext: placeTilesContext,
                             renderMapSize: renderMapSize,
                             pixelsPerPoint: pixelsPerPoint,
                             drawableHeightPx: drawableHeightPx) { buffers, indices in
                drawRuns(renderEncoder: renderEncoder,
                         buffers: buffers,
                         indices: indices,
                         reversed: false) { run in
                    isOpaque(run, overviewFade: overviewFadeUniform) == false
                }
            }
            if drawsLineRibbons {
                pipeline.selectSphereSplitPipeline(renderEncoder: renderEncoder, linesClass: true)
                forEachPlacement(renderEncoder: renderEncoder,
                                 placeTilesContext: placeTilesContext,
                                 renderMapSize: renderMapSize,
                                 pixelsPerPoint: pixelsPerPoint,
                                 drawableHeightPx: drawableHeightPx) { buffers, indices in
                    drawRuns(renderEncoder: renderEncoder,
                             buffers: buffers,
                             indices: indices,
                             reversed: false) { _ in true }
                }
            }
            renderEncoder.setDepthStencilState(depthDisabledState)
        } else {
            // The morph: one combined blended draw per placement, no depth.
            pipeline.selectSpherePipeline(renderEncoder: renderEncoder, pureSphere: false)
            forEachPlacement(renderEncoder: renderEncoder,
                             placeTilesContext: placeTilesContext,
                             renderMapSize: renderMapSize,
                             pixelsPerPoint: pixelsPerPoint,
                             drawableHeightPx: drawableHeightPx) { buffers, indices in
                renderEncoder.drawIndexedPrimitives(type: .triangle,
                                                    indexCount: indices.count,
                                                    indexType: buffers.indexType,
                                                    indexBuffer: indices.buffer,
                                                    indexBufferOffset: indices.offset)
            }
        }

        if isWireframeEnabled {
            renderEncoder.setTriangleFillMode(.fill)
        }
        renderEncoder.setCullMode(.none)
        renderEncoder.setFrontFacing(.clockwise)
    }

    /// Whether a run draws opaque this frame: both palette alphas are 1 and
    /// the style's zoom fade is exactly 1 (TileStyleFadeMath mirrors the
    /// shader's tileStyleFade).
    private static func isOpaque(_ run: GroundStyleRun,
                                 overviewFade: TileOverviewFadeUniform) -> Bool {
        run.isAlphaOpaque && TileStyleFadeMath.fadeIsOne(mask: run.fadeMask, overviewFade: overviewFade)
    }

    /// Binds one placement's buffers and per-draw uniforms, then hands the
    /// draw to `body`.
    private static func forEachPlacement(renderEncoder: MTLRenderCommandEncoder,
                                         placeTilesContext: PlaceTilesContext,
                                         renderMapSize: Double,
                                         pixelsPerPoint: Float,
                                         drawableHeightPx: Float,
                                         body: (TileBuffers.GeometryLayer, TileBufferView) -> Void) {
        for placeTile in placeTilesContext.tilePlacements {
            let metalTile = placeTile.metalTile
            let buffers = metalTile.tileBuffers.ground
            guard buffers.indicesCount > 0,
                  let indices = buffers.indices,
                  let vertices = buffers.vertices,
                  let styles = buffers.styles,
                  let overviewStyleMask = buffers.overviewStyleMask,
                  let lineStyles = buffers.lineStyles else { continue }

            let tile = metalTile.tile
            renderEncoder.setVertexBuffer(vertices.buffer, offset: vertices.offset, index: 0)
            renderEncoder.setVertexBuffer(styles.buffer, offset: styles.offset, index: 2)
            renderEncoder.setVertexBuffer(overviewStyleMask.buffer, offset: overviewStyleMask.offset, index: 4)
            renderEncoder.setVertexBuffer(lineStyles.buffer, offset: lineStyles.offset, index: 5)

            // The vertices are in the source tile's space; a retained
            // substitute is clipped to its placeIn slot by the rasterizer.
            var localClipBounds = TileLocalClipMath.clipBounds(source: tile, placeIn: placeTile.placeIn.tile)
            renderEncoder.setVertexBytes(&localClipBounds, length: MemoryLayout<SIMD4<Float>>.stride, index: 7)
            var surfaceTile = GlobeSurfaceTileUniform(tile: tile)
            renderEncoder.setVertexBytes(&surfaceTile, length: MemoryLayout<GlobeSurfaceTileUniform>.stride, index: 9)

            // The dash anchor of the flat path, with the source tile's world
            // size on the equator: the pattern holds still under camera
            // motion and matches the plane at the surface swap.
            let sourceTileWorldSize = Float(renderMapSize / Double(1 << tile.z))
            var lineDashUniform = LineDashUniform(
                unitsPerPoint: GlobeLineDashScale.coarseTileDashScale(sourceTileZoom: tile.z)
                    * pixelsPerPoint
                    * LineDashNominalScale.unitsPerPixel(sourceTileWorldSize: sourceTileWorldSize,
                                                         drawableHeightPx: drawableHeightPx)
            )
            renderEncoder.setFragmentBytes(&lineDashUniform, length: MemoryLayout<LineDashUniform>.stride, index: 4)

            body(buffers, indices)
        }
    }

    /// Draws the placement's style runs that pass `predicate`, each at its
    /// rank z. Falls back to one full translucent-style draw when the run
    /// table is absent, which paints exactly like the unsplit path.
    private static func drawRuns(renderEncoder: MTLRenderCommandEncoder,
                                 buffers: TileBuffers.GeometryLayer,
                                 indices: TileBufferView,
                                 reversed: Bool,
                                 predicate: (GroundStyleRun) -> Bool) {
        let runs = buffers.styleRuns
        guard runs.isEmpty == false else {
            var layerNdcZ: Float = 1.0 - layerDepthStep
            renderEncoder.setVertexBytes(&layerNdcZ, length: MemoryLayout<Float>.stride, index: 3)
            renderEncoder.drawIndexedPrimitives(type: .triangle,
                                                indexCount: indices.count,
                                                indexType: buffers.indexType,
                                                indexBuffer: indices.buffer,
                                                indexBufferOffset: indices.offset)
            return
        }
        let indexByteWidth = buffers.indexType == .uint16 ? 2 : 4
        let order = reversed ? Array(runs.indices.reversed()) : Array(runs.indices)
        for rank in order {
            let run = runs[rank]
            guard run.indexCount > 0, predicate(run) else { continue }
            var layerNdcZ: Float = 1.0 - Float(rank + 1) * layerDepthStep
            renderEncoder.setVertexBytes(&layerNdcZ, length: MemoryLayout<Float>.stride, index: 3)
            renderEncoder.drawIndexedPrimitives(type: .triangle,
                                                indexCount: Int(run.indexCount),
                                                indexType: buffers.indexType,
                                                indexBuffer: indices.buffer,
                                                indexBufferOffset: indices.offset + Int(run.indexStart) * indexByteWidth)
        }
    }
}
