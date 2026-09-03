// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Metal
import simd

enum FlatMapSurfaceDrawer {
    static func draw(renderEncoder: MTLRenderCommandEncoder,
                     cameraUniform: CameraUniform,
                     cameraZoom: Double,
                     pixelsPerPoint: Float,
                     drawableHeightPx: Float,
                     separateRoadRenderingMinimumZoom: Int,
                     placeTilesContext: PlaceTilesContext,
                     flatRenderState: FlatRenderState,
                     horizonFog: HorizonFogUniform,
                     groundShadowMask: GroundShadowMaskBinding,
                     tilePipeline: TilePipeline,
                     groundOwnerState: MTLDepthStencilState,
                     tileStencilTestState: MTLDepthStencilState,
                     isWireframeEnabled: Bool,
                     withBuildingImageAttachment: Bool = false) {
        tilePipeline.selectPipeline(renderEncoder: renderEncoder,
                                    withBuildingImageAttachment: withBuildingImageAttachment)
        // Every tile triangle (ground, road buckets, bridge overlay) is
        // counter-clockwise in render space, the parser's contract
        // (ParsedPolygon.firstClockwiseTriangle), and the flat projection
        // does not mirror, so only front faces are drawn. Declared rather
        // than inherited: the world pass shares one encoder, and the
        // buildings drawn before this layer rely on Metal's default.
        renderEncoder.setFrontFacing(.counterClockwise)
        renderEncoder.setCullMode(.back)
        if isWireframeEnabled {
            renderEncoder.setTriangleFillMode(.lines)
        }
        var cameraUniformValue = cameraUniform
        // Continuous in camera zoom, so the ground palette never steps at a
        // tile-zoom boundary; the tiles bake both palettes per style.
        var streetPaletteUniform = StreetPaletteUniform(
            blend: LowZoomOverviewFade.streetPaletteBlend(for: cameraZoom)
        )
        renderEncoder.setFragmentBytes(&streetPaletteUniform,
                                       length: MemoryLayout<StreetPaletteUniform>.stride,
                                       index: 8)
        renderEncoder.setVertexBytes(&streetPaletteUniform,
                                     length: MemoryLayout<StreetPaletteUniform>.stride,
                                     index: 6)
        // The taper thins point-locked widths toward planet zooms; continuous
        // in camera zoom, so it cannot reintroduce integer-zoom width jumps.
        var overviewFadeUniform = TileOverviewFadeUniform(
            overviewAlpha: LowZoomOverviewFade.alpha(for: cameraZoom, kind: .overviewFeatures),
            roadAlpha: LowZoomOverviewFade.alpha(for: cameraZoom, kind: .roads),
            landuseAlpha: LowZoomOverviewFade.alpha(for: cameraZoom, kind: .landuse),
            pixelsPerPoint: pixelsPerPoint * LineWidthZoomTaper.scale(for: cameraZoom),
            roadSurfaceBlend: LowZoomOverviewFade.roadSurfaceBlend(for: cameraZoom),
            roadMarkingAlpha: LowZoomOverviewFade.roadMarkingAlpha(for: cameraZoom),
            cameraZoom: Float(cameraZoom)
        )
        var horizonFogValue = horizonFog
        var shadowUniformValue = groundShadowMask.uniform
        renderEncoder.setVertexBytes(&cameraUniformValue, length: MemoryLayout<CameraUniform>.stride, index: 1)
        // The vertex stage folds the zoom fade into the colour's alpha, so
        // it reads the same uniform (Tile.metal, buffer 8).
        renderEncoder.setVertexBytes(&overviewFadeUniform,
                                     length: MemoryLayout<TileOverviewFadeUniform>.stride,
                                     index: 8)
        renderEncoder.setFragmentBytes(&overviewFadeUniform,
                                       length: MemoryLayout<TileOverviewFadeUniform>.stride,
                                       index: 0)
        renderEncoder.setFragmentBytes(&horizonFogValue,
                                       length: MemoryLayout<HorizonFogUniform>.stride,
                                       index: 2)
        renderEncoder.setFragmentBytes(&shadowUniformValue,
                                       length: MemoryLayout<ShadowUniform>.stride,
                                       index: 3)
        // The flat ground pipeline reads the per-pixel ground shadow mask
        // (fragment texture 1) instead of sampling the cascades per layer.
        renderEncoder.setFragmentTexture(groundShadowMask.texture, index: 1)

        let usesSeparateRoadRendering = cameraZoom >= Double(separateRoadRenderingMinimumZoom)

        // Unique SOURCES, not placements: a coarse tile standing in for
        // several missing slots draws once at full extent, and the
        // tile-priority stencil keeps it out of every slot a finer tile
        // owns (TileSourceStencilPriority). The loop is part of the key:
        // the flat world's wrap copies place the same tile at different
        // origins across the seam. Finest first, so the owner writes win.
        struct SourceKey: Hashable {
            let tile: Tile
            let loop: Int8
        }
        var seenSources = Set<SourceKey>()
        var uniqueSources: [(metalTile: MetalTile, loop: Int8)] = []
        uniqueSources.reserveCapacity(placeTilesContext.tilePlacements.count)
        for placeTile in placeTilesContext.tilePlacements {
            let key = SourceKey(tile: placeTile.metalTile.tile, loop: placeTile.placeIn.loop)
            if seenSources.insert(key).inserted {
                uniqueSources.append((placeTile.metalTile, placeTile.placeIn.loop))
            }
        }
        uniqueSources.sort { $0.metalTile.tile.z > $1.metalTile.tile.z }

        func drawLayer(_ keyPath: KeyPath<TileBuffers, TileBuffers.GeometryLayer>,
                       bandOffset: Float,
                       runFilter: ((GroundStyleRun) -> Bool)? = nil) {
            for source in uniqueSources {
                drawFlatGeometryLayer(renderEncoder: renderEncoder,
                                      buffers: source.metalTile.tileBuffers[keyPath: keyPath],
                                      tile: source.metalTile.tile,
                                      loop: source.loop,
                                      flatRenderState: flatRenderState,
                                      pixelsPerPoint: pixelsPerPoint,
                                      drawableHeightPx: drawableHeightPx,
                                      overviewFade: overviewFadeUniform,
                                      bandOffset: bandOffset,
                                      runFilter: runFilter)
            }
        }

        // The ground draws as class layers, the sphere's scheme: the opaque
        // fill layers first, unblended, writing the rank-band depth (a
        // pixel is shaded once by its topmost opaque layer) and owning the
        // tile-priority stencil; the translucent fills and the ribbons
        // follow, tested only. The band sits at the far plane, farther than
        // every real fragment, so the buildings' occlusion is untouched.
        let isOpaqueFillRun: (GroundStyleRun) -> Bool = { run in
            run.isLinesClass == false
                && run.isAlphaOpaque
                && TileStyleFadeMath.fadeIsOne(mask: run.fadeMask, overviewFade: overviewFadeUniform)
        }
        let isTranslucentFillRun: (GroundStyleRun) -> Bool = { run in
            run.isLinesClass == false && isOpaqueFillRun(run) == false
        }
        renderEncoder.pushDebugGroup("ground.opaqueFills")
        renderEncoder.setDepthStencilState(groundOwnerState)
        tilePipeline.selectFlatOpaquePipeline(renderEncoder: renderEncoder,
                                              withBuildingImageAttachment: withBuildingImageAttachment)
        drawLayer(\.ground, bandOffset: 0, runFilter: isOpaqueFillRun)
        renderEncoder.popDebugGroup()
        // Everything after only tests the priority.
        renderEncoder.pushDebugGroup("ground.translucentFills")
        renderEncoder.setDepthStencilState(tileStencilTestState)
        tilePipeline.selectFlatFillsPipeline(renderEncoder: renderEncoder,
                                             withBuildingImageAttachment: withBuildingImageAttachment)
        drawLayer(\.ground, bandOffset: 0, runFilter: isTranslucentFillRun)
        renderEncoder.popDebugGroup()
        renderEncoder.pushDebugGroup("ground.lineRibbons")
        tilePipeline.selectPipeline(renderEncoder: renderEncoder,
                                    withBuildingImageAttachment: withBuildingImageAttachment)
        drawLayer(\.ground,
                  bandOffset: GlobeSurfaceDepthRank.classDepthBand,
                  runFilter: { $0.isLinesClass })
        renderEncoder.popDebugGroup()

        if usesSeparateRoadRendering {
            func drawRoadGroup(_ structureKind: TileMvtParser.RoadStructureKind) {
                for role in [RoadPassRole.shadow, .casing, .fill, .detail] {
                    for source in uniqueSources {
                        let structureBucket = source.metalTile.tileBuffers.roads.bucket(for: structureKind)
                        drawFlatGeometryLayer(renderEncoder: renderEncoder,
                                              buffers: structureBucket.layer(for: role),
                                              tile: source.metalTile.tile,
                                              loop: source.loop,
                                              flatRenderState: flatRenderState,
                                              pixelsPerPoint: pixelsPerPoint,
                                              drawableHeightPx: drawableHeightPx,
                                              overviewFade: overviewFadeUniform,
                                              bandOffset: GlobeSurfaceDepthRank.flatRoadsDepthOffset)
                    }
                }
            }

            renderEncoder.pushDebugGroup("roads")
            drawRoadGroup(.tunnel)
            drawRoadGroup(.ground)
            drawRoadGroup(.automobileGround)
            drawLayer(\.bridgeOverlay, bandOffset: GlobeSurfaceDepthRank.flatRoadsDepthOffset)
            drawRoadGroup(.bridge)

            for structureKind in TileMvtParser.RoadStructureKind.drawOrder {
                for source in uniqueSources {
                    let structureBucket = source.metalTile.tileBuffers.roads.bucket(for: structureKind)
                    drawFlatGeometryLayer(renderEncoder: renderEncoder,
                                          buffers: structureBucket.layer(for: .overlay),
                                          tile: source.metalTile.tile,
                                          loop: source.loop,
                                          flatRenderState: flatRenderState,
                                          pixelsPerPoint: pixelsPerPoint,
                                          drawableHeightPx: drawableHeightPx,
                                          overviewFade: overviewFadeUniform,
                                          bandOffset: GlobeSurfaceDepthRank.flatRoadsDepthOffset)
                }
            }
            renderEncoder.popDebugGroup()
        } else {
            drawLayer(\.bridgeOverlay, bandOffset: GlobeSurfaceDepthRank.flatRoadsDepthOffset)
        }
        if isWireframeEnabled {
            renderEncoder.setTriangleFillMode(.fill)
        }
        renderEncoder.setCullMode(.none)
        renderEncoder.setFrontFacing(.clockwise)
    }


    private static func drawFlatGeometryLayer(renderEncoder: MTLRenderCommandEncoder,
                                              buffers: TileBuffers.GeometryLayer,
                                              tile: Tile,
                                              loop: Int8,
                                              flatRenderState: FlatRenderState,
                                              pixelsPerPoint: Float,
                                              drawableHeightPx: Float,
                                              overviewFade: TileOverviewFadeUniform,
                                              bandOffset: Float,
                                              runFilter: ((GroundStyleRun) -> Bool)? = nil) {
        // A run whose zoom fade is exactly 0 this frame would rasterize
        // with alpha 0: the ground bucket carries a run table (the road
        // buckets do not and draw whole, as before), so its invisible runs
        // are skipped, the class filter picks the pass's runs, and the
        // visible spans coalesce, before any binding.
        let visibleSpans = visibleRunSpans(buffers: buffers,
                                           overviewFade: overviewFade,
                                           runFilter: runFilter)
        guard buffers.indicesCount > 0,
              visibleSpans.isEmpty == false,
              let indices = buffers.indices,
              let vertices = buffers.vertices,
              let styles = buffers.styles,
              let overviewStyleMask = buffers.overviewStyleMask,
              let lineStyles = buffers.lineStyles else { return }

        let originAndSize = ImmersiveMapProjection.flatTileOriginAndSize(x: tile.x,
                                                                         y: tile.y,
                                                                         z: tile.z,
                                                                         loop: loop,
                                                                         flatRenderPan: flatRenderState.pan,
                                                                         renderMapSize: flatRenderState.renderMapSize)
        let scale = originAndSize.z / 4096.0

        renderEncoder.setVertexBuffer(vertices.buffer, offset: vertices.offset, index: 0)
        renderEncoder.setVertexBuffer(styles.buffer, offset: styles.offset, index: 2)
        renderEncoder.setVertexBuffer(overviewStyleMask.buffer, offset: overviewStyleMask.offset, index: 4)
        renderEncoder.setVertexBuffer(lineStyles.buffer, offset: lineStyles.offset, index: 5)
        // The lines-class fragment resolves the style by index (the fills
        // fragment never reads these slots).
        renderEncoder.setFragmentBuffer(styles.buffer, offset: styles.offset, index: 5)
        renderEncoder.setFragmentBuffer(overviewStyleMask.buffer, offset: overviewStyleMask.offset, index: 6)
        renderEncoder.setFragmentBuffer(lineStyles.buffer, offset: lineStyles.offset, index: 7)
        // The tile-priority stencil reference: the ground pass replaces the
        // stencil with it, every pass tests greaterEqual against the finest
        // painter (TileSourceStencilPriority). No slot clip: a substitute
        // draws at full extent and the stencil keeps it out of covered slots.
        renderEncoder.setStencilReferenceValue(TileSourceStencilPriority.reference(sourceZoom: tile.z))
        // The group's place in the rank-depth band (Tile.metal, buffer 7).
        var bandOffsetValue = bandOffset
        renderEncoder.setVertexBytes(&bandOffsetValue, length: MemoryLayout<Float>.stride, index: 7)

        // Anchors point-dashed patterns to the geometry: the scale depends on
        // the source tile's world size and the viewport, never on the live
        // camera, so dashes hold still under camera motion (untapered on
        // purpose: a pattern must not stretch with the zoom taper either).
        var lineDashUniform = LineDashUniform(
            unitsPerPoint: pixelsPerPoint * LineDashNominalScale.unitsPerPixel(
                sourceTileWorldSize: originAndSize.z,
                drawableHeightPx: drawableHeightPx
            )
        )
        renderEncoder.setFragmentBytes(&lineDashUniform,
                                       length: MemoryLayout<LineDashUniform>.stride,
                                       index: 4)

        var modelMatrix = Matrix.translationMatrix(
            x: originAndSize.x,
            y: originAndSize.y,
            z: 0
        ) * Matrix.scaleMatrix(sx: scale, sy: scale, sz: 1)
        renderEncoder.setVertexBytes(&modelMatrix, length: MemoryLayout<matrix_float4x4>.stride, index: 3)

        let indexByteWidth = buffers.indexType == .uint16 ? 2 : 4
        for span in visibleSpans {
            renderEncoder.drawIndexedPrimitives(type: .triangle,
                                                indexCount: span.count,
                                                indexType: buffers.indexType,
                                                indexBuffer: indices.buffer,
                                                indexBufferOffset: indices.offset + span.start * indexByteWidth)
        }
    }

    /// The index spans of a layer worth drawing this frame: without a run
    /// table the whole layer is one span (the road buckets), with one the
    /// zero-fade runs drop out and the contiguous survivors merge. The
    /// paint order is the buffer order either way.
    private static func visibleRunSpans(buffers: TileBuffers.GeometryLayer,
                                        overviewFade: TileOverviewFadeUniform,
                                        runFilter: ((GroundStyleRun) -> Bool)? = nil) -> [(start: Int, count: Int)] {
        guard buffers.indicesCount > 0 else { return [] }
        let runs = buffers.styleRuns
        guard runs.isEmpty == false else { return runFilter == nil ? [(0, buffers.indicesCount)] : [] }
        var spans: [(start: Int, count: Int)] = []
        var spanStart = 0
        var spanCount = 0
        for run in runs {
            guard run.indexCount > 0,
                  runFilter?(run) != false,
                  TileStyleFadeMath.fadeIsZero(mask: run.fadeMask, overviewFade: overviewFade) == false else {
                if spanCount > 0 { spans.append((spanStart, spanCount)) }
                spanCount = 0
                continue
            }
            if spanCount > 0, spanStart + spanCount == Int(run.indexStart) {
                spanCount += Int(run.indexCount)
            } else {
                if spanCount > 0 { spans.append((spanStart, spanCount)) }
                spanStart = Int(run.indexStart)
                spanCount = Int(run.indexCount)
            }
        }
        if spanCount > 0 { spans.append((spanStart, spanCount)) }
        return spans
    }
}
