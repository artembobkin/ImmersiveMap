// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Metal
import simd

/// The globe counterpart of `FlatMapSurfaceDrawer`: every placement's ground
/// layer (below tile z8 the whole drawable content of a tile lives there)
/// through the sphere tile pipeline. Bindings mirror TileSphere.metal.
///
/// On the resting sphere the ground draws as class layers, not as one call.
/// The opaque fill layers (a style whose palette alphas are 1 and whose zoom
/// fade is 1 this frame) draw first with blending off and a depth write:
/// each layer's z is its style rank in a narrow band at the far plane
/// (computed in the vertex stage from the style index, see
/// kTileSphereLayerDepthStep in TileSphere.metal), and on a TBDR GPU hidden
/// surface removal resolves the opaque layers by that depth before shading,
/// so a pixel is shaded exactly once by its topmost opaque layer regardless
/// of submission order. The translucent fill layers follow in buffer order
/// (which is bottom-to-top), tested without writing: an opaque layer above
/// them still hides them, everything else blends as before. The line
/// ribbons draw last through the line-field pipeline, in their own depth
/// band above every fill; the classes are separate index segments baked by
/// the parser, so no class pass reads the other's vertices. With the rank
/// in the vertex stage, adjacent runs headed for the same pass merge into
/// one draw call. Placements never contend for a pixel (each is clipped to
/// its slot), so the rank only has to be consistent within one tile. The
/// morph keeps the single blended draw.
enum GlobeVectorSurfaceDrawer {

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
        // The ribbons class resolves its style in the fragment stage
        // (tileLineFragmentColor), so the palette blend is bound there too.
        renderEncoder.setFragmentBytes(&streetPaletteUniform, length: MemoryLayout<StreetPaletteUniform>.stride, index: 8)
        renderEncoder.setVertexBytes(&globeValue, length: MemoryLayout<GlobeUniform>.stride, index: 8)
        var globeFrameValue = globeFrame
        renderEncoder.setVertexBytes(&globeFrameValue,
                                     length: MemoryLayout<GlobeFrameConstantsUniform>.stride,
                                     index: 10)
        renderEncoder.setFragmentBytes(&overviewFadeValue, length: MemoryLayout<TileOverviewFadeUniform>.stride, index: 0)
        // The vertex stages fold the zoom fade into the colour's alpha, so
        // they read the same uniform (TileSphere.metal, buffer 11).
        renderEncoder.setVertexBytes(&overviewFadeValue, length: MemoryLayout<TileOverviewFadeUniform>.stride, index: 11)
        renderEncoder.setFragmentBytes(&horizonFogValue, length: MemoryLayout<HorizonFogUniform>.stride, index: 2)

        // Both worlds draw the same layered class passes; the morph only
        // swaps in the pipeline variants that carry the unroll and the fog.
        let morph = pureSphere == false
        do {
            // The sphere draws unique SOURCES, not placements: a
            // coarse tile standing in for several missing slots is drawn
            // once at its full extent, and the slot clip is gone entirely.
            // What keeps a substitute out of a covered slot is the depth
            // band: sources draw finest first, every tile's opaque
            // background quad writes depth over its whole slot, and a
            // coarser source's overflow fails the test wherever a finer
            // tile painted (see kTileSphereLayerDepthStep in TileSphere.metal).
            var seenSources = Set<MetalTile>()
            var uniqueSources: [MetalTile] = []
            uniqueSources.reserveCapacity(placeTilesContext.tilePlacements.count)
            for placement in placeTilesContext.tilePlacements
            where seenSources.insert(placement.metalTile).inserted {
                uniqueSources.append(placement.metalTile)
            }
            uniqueSources.sort { $0.tile.z > $1.tile.z }

            // The opaque fill layers, depth-written and unblended.
            renderEncoder.pushDebugGroup("ground.opaqueFills")
            renderEncoder.setDepthStencilState(opaqueDepthState)
            pipeline.selectSphereOpaqueFillsPipeline(renderEncoder: renderEncoder, morph: morph)
            let isOpaqueFillRun: (GroundStyleRun) -> Bool = { run in
                run.isLinesClass == false && isOpaque(run, overviewFade: overviewFadeUniform)
            }
            forEachSource(renderEncoder: renderEncoder,
                          sources: uniqueSources,
                          renderMapSize: renderMapSize,
                          pixelsPerPoint: pixelsPerPoint,
                          drawableHeightPx: drawableHeightPx,
                          worthBinding: { $0.styleRuns.contains(where: isOpaqueFillRun) }) { buffers, indices in
                drawRuns(renderEncoder: renderEncoder,
                         buffers: buffers,
                         indices: indices,
                         predicate: isOpaqueFillRun)
            }
            renderEncoder.popDebugGroup()
            // The translucent fill layers, bottom to top, blended, tested
            // but never written: an opaque layer above still hides them.
            renderEncoder.pushDebugGroup("ground.translucentFills")
            renderEncoder.setDepthStencilState(translucentDepthState)
            pipeline.selectSphereClassPipeline(renderEncoder: renderEncoder, linesClass: false, morph: morph)
            // A run whose fade is exactly 0 this frame would rasterize with
            // alpha 0: skipped here, before a single buffer is bound (road
            // strokes below their start zoom are whole invisible layers).
            let isTranslucentFillRun: (GroundStyleRun) -> Bool = { run in
                run.isLinesClass == false
                    && isOpaque(run, overviewFade: overviewFadeUniform) == false
                    && TileStyleFadeMath.fadeIsZero(mask: run.fadeMask, overviewFade: overviewFadeUniform) == false
            }
            forEachSource(renderEncoder: renderEncoder,
                          sources: uniqueSources,
                          renderMapSize: renderMapSize,
                          pixelsPerPoint: pixelsPerPoint,
                          drawableHeightPx: drawableHeightPx,
                          worthBinding: { $0.styleRuns.contains(where: isTranslucentFillRun) }) { buffers, indices in
                drawRuns(renderEncoder: renderEncoder,
                         buffers: buffers,
                         indices: indices,
                         predicate: isTranslucentFillRun)
            }
            renderEncoder.popDebugGroup()
            // The line ribbons (boundaries, overview strokes) last, through
            // the line-field coverage, at their rank z above every fill;
            // fully faded ribbons (road strokes below their start zoom) are
            // skipped the same way.
            let isVisibleRibbonRun: (GroundStyleRun) -> Bool = { run in
                run.isLinesClass
                    && TileStyleFadeMath.fadeIsZero(mask: run.fadeMask, overviewFade: overviewFadeUniform) == false
            }
            renderEncoder.pushDebugGroup("ground.lineRibbons")
            pipeline.selectSphereClassPipeline(renderEncoder: renderEncoder, linesClass: true, morph: morph)
            forEachSource(renderEncoder: renderEncoder,
                          sources: uniqueSources,
                          renderMapSize: renderMapSize,
                          pixelsPerPoint: pixelsPerPoint,
                          drawableHeightPx: drawableHeightPx,
                          worthBinding: { buffers in
                              buffers.styleRuns.isEmpty || buffers.styleRuns.contains(where: isVisibleRibbonRun)
                          }) { buffers, indices in
                drawRuns(renderEncoder: renderEncoder,
                         buffers: buffers,
                         indices: indices,
                         drawsAllWithoutRuns: true,
                         predicate: isVisibleRibbonRun)
            }
            renderEncoder.popDebugGroup()
            renderEncoder.setDepthStencilState(depthDisabledState)
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
    /// Binds one unique source tile's buffers and per-draw uniforms, then
    /// hands the draw to `body`. There is no slot clip: the sphere passes
    /// draw each source once at full extent and the rank depth rejects a
    /// coarser source's overflow (see kTileSphereLayerDepthStep).
    /// `worthBinding` runs first so a source with nothing for the pass
    /// encodes no binds.
    private static func forEachSource(renderEncoder: MTLRenderCommandEncoder,
                                      sources: [MetalTile],
                                      renderMapSize: Double,
                                      pixelsPerPoint: Float,
                                      drawableHeightPx: Float,
                                      worthBinding: (TileBuffers.GeometryLayer) -> Bool = { _ in true },
                                      body: (TileBuffers.GeometryLayer, TileBufferView) -> Void) {
        for metalTile in sources {
            let buffers = metalTile.tileBuffers.ground
            guard buffers.indicesCount > 0,
                  worthBinding(buffers),
                  let indices = buffers.indices,
                  let vertices = buffers.vertices,
                  let styles = buffers.styles,
                  let overviewStyleMask = buffers.overviewStyleMask,
                  let lineStyles = buffers.lineStyles else { continue }

            let tile = metalTile.tile
            // The tile-priority stencil reference: the opaque owner pass
            // replaces the stencil with it, every pass tests greaterEqual
            // against the finest painter (TileSourceStencilPriority).
            renderEncoder.setStencilReferenceValue(TileSourceStencilPriority.reference(sourceZoom: tile.z))
            renderEncoder.setVertexBuffer(vertices.buffer, offset: vertices.offset, index: 0)
            renderEncoder.setVertexBuffer(styles.buffer, offset: styles.offset, index: 2)
            renderEncoder.setVertexBuffer(overviewStyleMask.buffer, offset: overviewStyleMask.offset, index: 4)
            renderEncoder.setVertexBuffer(lineStyles.buffer, offset: lineStyles.offset, index: 5)
            // The ribbons fragment resolves the style by index (the fills
            // fragment never reads these slots).
            renderEncoder.setFragmentBuffer(styles.buffer, offset: styles.offset, index: 5)
            renderEncoder.setFragmentBuffer(overviewStyleMask.buffer, offset: overviewStyleMask.offset, index: 6)
            renderEncoder.setFragmentBuffer(lineStyles.buffer, offset: lineStyles.offset, index: 7)
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

    private static func isOpaque(_ run: GroundStyleRun,
                                 overviewFade: TileOverviewFadeUniform) -> Bool {
        run.isAlphaOpaque && TileStyleFadeMath.fadeIsOne(mask: run.fadeMask, overviewFade: overviewFade)
    }

    /// Draws the placement's style runs that pass `predicate`, coalescing
    /// adjacent index-contiguous runs into one call: the rank depth comes
    /// from the vertex stage (per style index), so a merged span still
    /// layers correctly. When the run table is absent, only the ribbons pass
    /// (`drawsAllWithoutRuns`) falls back to one full draw, whose line-field
    /// pipeline paints exactly like the unsplit combined path.
    private static func drawRuns(renderEncoder: MTLRenderCommandEncoder,
                                 buffers: TileBuffers.GeometryLayer,
                                 indices: TileBufferView,
                                 drawsAllWithoutRuns: Bool = false,
                                 predicate: (GroundStyleRun) -> Bool) {
        let runs = buffers.styleRuns
        guard runs.isEmpty == false else {
            guard drawsAllWithoutRuns else { return }
            renderEncoder.drawIndexedPrimitives(type: .triangle,
                                                indexCount: indices.count,
                                                indexType: buffers.indexType,
                                                indexBuffer: indices.buffer,
                                                indexBufferOffset: indices.offset)
            return
        }
        let indexByteWidth = buffers.indexType == .uint16 ? 2 : 4
        var spanStart = 0
        var spanCount = 0
        func flush() {
            guard spanCount > 0 else { return }
            renderEncoder.drawIndexedPrimitives(type: .triangle,
                                                indexCount: spanCount,
                                                indexType: buffers.indexType,
                                                indexBuffer: indices.buffer,
                                                indexBufferOffset: indices.offset + spanStart * indexByteWidth)
            spanCount = 0
        }
        for run in runs {
            guard run.indexCount > 0, predicate(run) else {
                flush()
                continue
            }
            if spanCount > 0, spanStart + spanCount == Int(run.indexStart) {
                spanCount += Int(run.indexCount)
            } else {
                flush()
                spanStart = Int(run.indexStart)
                spanCount = Int(run.indexCount)
            }
        }
        flush()
    }
}
