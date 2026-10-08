// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Metal
import simd

/// A source of the flat ground draw: a tile at one of the world's wrap
/// copies, which place the same tile at different origins across the seam.
struct FlatGroundSourceKey: Hashable {
    let tile: Tile
    let worldWrap: Int8
}

enum FlatMapSurfaceDrawer {
    /// The share of a road's alpha its edge lines draw with: a line is one
    /// pixel wide and lands on the pixels the body's edge passes through
    /// without covering, so half the road's colour there softens the
    /// edge's steps.
    static let roadEdgeLineAlpha: Float = 0.5

    /// The view depth of the ground point under the centre of the screen,
    /// which is the clip-space w there: the depth the point-locked road
    /// widths are stated at, so a road is its style's points wide at the
    /// centre and follows the perspective away from it. Zero, which turns
    /// the perspective off, when the centre ray does not meet the ground.
    static func screenCentreGroundDepth(cameraMatrix: matrix_float4x4) -> Float {
        let inverse = cameraMatrix.inverse
        let nearClip = inverse * SIMD4<Float>(0, 0, 0, 1)
        let farClip = inverse * SIMD4<Float>(0, 0, 1, 1)
        guard abs(nearClip.w) > .leastNormalMagnitude, abs(farClip.w) > .leastNormalMagnitude else {
            return 0
        }
        let near = SIMD3<Float>(nearClip.x, nearClip.y, nearClip.z) / nearClip.w
        let far = SIMD3<Float>(farClip.x, farClip.y, farClip.z) / farClip.w
        let descent = near.z - far.z
        guard abs(descent) > .leastNormalMagnitude else {
            return 0
        }
        let t = near.z / descent
        guard t.isFinite, t > 0 else {
            return 0
        }
        let ground = near + (far - near) * t
        let depth = (cameraMatrix * SIMD4<Float>(ground.x, ground.y, 0, 1)).w
        return depth.isFinite && depth > 0 ? depth : 0
    }

    /// - Parameter roadRankState: the road buckets' state, the rank depth
    ///   tested and written (`RoadRankDepth`).
    static func draw(renderEncoder: MTLRenderCommandEncoder,
                     cameraUniform: CameraUniform,
                     cpuCameraMatrix: matrix_float4x4,
                     cameraZoom: Double,
                     pixelsPerPoint: Float,
                     drawableSizePx: SIMD2<Float>,
                     placeTilesContext: PlaceTilesContext,
                     flatRenderState: FlatRenderState,
                     groundShadowMask: GroundShadowMaskBinding,
                     tilePipeline: TilePipeline,
                     groundOwnerState: MTLDepthStencilState,
                     tileStencilTestState: MTLDepthStencilState,
                     roadRankState: MTLDepthStencilState,
                     isWireframeEnabled: Bool,
                     linelessTiles: Set<VisibleTile> = [],
                     rasterTiles: [VisibleTile: RasterTileSpec] = [:]) {
        tilePipeline.selectPipeline(renderEncoder: renderEncoder)
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
        var overviewFadeUniform = TileOverviewFadeUniform(
            pixelsPerPoint: pixelsPerPoint,
            cameraZoom: Float(cameraZoom),
            viewportSizePx: drawableSizePx,
            // The CPU's matrix, not the uniform's: the depth of the screen
            // centre's ground point is found by unprojecting, and the
            // uniform's z is remapped for the GPU (RenderCamera.gpuClipDepthAdjustment),
            // so an NDC depth of 1 through it lies past the far plane.
            pointWidthReferenceDepth: screenCentreGroundDepth(cameraMatrix: cpuCameraMatrix),
            cameraMatrix: cpuCameraMatrix
        )
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
        renderEncoder.setFragmentBytes(&shadowUniformValue,
                                       length: MemoryLayout<ShadowUniform>.stride,
                                       index: 3)
        // The flat ground pipeline reads the per-pixel ground shadow mask
        // (fragment texture 1) instead of sampling the cascades per layer.
        renderEncoder.setFragmentTexture(groundShadowMask.texture, index: 1)

        // Unique SOURCES, not placements: a coarse tile standing in for
        // several missing slots draws once at full extent, and the
        // tile-priority stencil keeps it out of every slot a finer tile
        // owns (TileSourceStencilPriority). The world wrap is part of the key:
        // the flat world's wrap copies place the same tile at different
        // origins across the seam. Finest first, so the owner writes win.
        typealias SourceKey = FlatGroundSourceKey
        var seenSources = Set<SourceKey>()
        var uniqueSources: [(metalTile: MetalTile, worldWrap: Int8)] = []
        uniqueSources.reserveCapacity(placeTilesContext.tilePlacements.count)
        for placeTile in placeTilesContext.tilePlacements {
            let key = SourceKey(tile: placeTile.metalTile.tile, worldWrap: placeTile.placeIn.worldWrap)
            if seenSources.insert(key).inserted {
                uniqueSources.append((placeTile.metalTile, placeTile.placeIn.worldWrap))
            }
        }
        uniqueSources.sort { $0.metalTile.tile.z > $1.metalTile.tile.z }
        // The sources that draw their lines (`FlatRingRule.drawsLines`): a
        // source does while any slot it is placed in belongs to a rule that
        // draws them, so a stand-in for a lined slot keeps its roads.
        var linedSourceKeys = Set<SourceKey>()
        for placeTile in placeTilesContext.tilePlacements where linelessTiles.contains(placeTile.placeIn) == false {
            linedSourceKeys.insert(SourceKey(tile: placeTile.metalTile.tile, worldWrap: placeTile.placeIn.worldWrap))
        }
        let linedSources = uniqueSources.filter {
            linedSourceKeys.contains(SourceKey(tile: $0.metalTile.tile, worldWrap: $0.worldWrap))
        }
        // The sources that draw their fills: a source does while any slot
        // it is placed in draws its ground as geometry. A raster target's
        // ground is its texture (`RasterTileRenderSubsystem`) or nothing,
        // so its own tile and its stand-ins draw only their lines there.
        var groundSourceKeys = Set<SourceKey>()
        for placeTile in placeTilesContext.tilePlacements where rasterTiles[placeTile.placeIn] == nil {
            groundSourceKeys.insert(SourceKey(tile: placeTile.metalTile.tile, worldWrap: placeTile.placeIn.worldWrap))
        }
        let groundSources = rasterTiles.isEmpty
            ? uniqueSources
            : uniqueSources.filter { groundSourceKeys.contains(SourceKey(tile: $0.metalTile.tile, worldWrap: $0.worldWrap)) }

        // Each group selects its pipeline once.
        enum GroundPipeline {
            case lines
            case fills
            case opaqueFills
            case roadOpaque
            case roadBlended
        }
        var selectedPipeline: GroundPipeline?
        func selectPipeline(_ pipeline: GroundPipeline) {
            if selectedPipeline == pipeline { return }
            selectedPipeline = pipeline
            switch pipeline {
            case .lines:
                tilePipeline.selectFlatLinesPipeline(renderEncoder: renderEncoder)
            case .fills:
                tilePipeline.selectFlatFillsPipeline(renderEncoder: renderEncoder)
            case .opaqueFills:
                tilePipeline.selectFlatOpaquePipeline(renderEncoder: renderEncoder)
            case .roadOpaque, .roadBlended:
                // A pipeline without the road variants draws the roads as
                // plain ribbons.
                if tilePipeline.selectFlatRoadPipeline(renderEncoder: renderEncoder,
                                                       blended: pipeline == .roadBlended) == false {
                    tilePipeline.selectFlatLinesPipeline(renderEncoder: renderEncoder)
                }
            }
        }

        func drawLayer(_ keyPath: KeyPath<TileBuffers, TileBuffers.GeometryLayer>,
                       pipeline: GroundPipeline,
                       bandOffset: Float,
                       sources: [(metalTile: MetalTile, worldWrap: Int8)],
                       runFilter: ((GroundStyleRun) -> Bool)? = nil) {
            selectPipeline(pipeline)
            for source in sources {
                let layer = source.metalTile.tileBuffers[keyPath: keyPath]
                // The fills of a flattened ground take one depth: no rank
                // step between their styles (Tile.metal, FlatDepthBand).
                let rankStep: Float = pipeline == .opaqueFills && layer.isFlattened
                    ? 0 : GlobeSurfaceDepthRank.layerDepthStep
                drawFlatGeometryLayer(renderEncoder: renderEncoder,
                                      buffers: layer,
                                      tile: source.metalTile.tile,
                                      worldWrap: source.worldWrap,
                                      flatRenderState: flatRenderState,
                                      pixelsPerPoint: pixelsPerPoint,
                                      drawableHeightPx: drawableSizePx.y,
                                      overviewFade: overviewFadeUniform,
                                      bandOffset: bandOffset,
                                      rankStep: rankStep,
                                      runFilter: runFilter)
            }
        }

        // The ground draws as class layers, the sphere's scheme: the opaque
        // fill layers first, unblended, writing the rank-band depth (a
        // pixel is shaded once by its topmost opaque layer) and owning the
        // tile-priority stencil; the translucent fills and the ribbons
        // follow, tested only. The band sits at the far plane, farther than
        // every real fragment, so the buildings' occlusion is untouched.
        // A flattened ground's fills overlap nowhere: every run of them draws
        // in the opaque pass, at one depth, whatever its fade.
        let isOpaqueFillRun: (GroundStyleRun) -> Bool = { run in
            run.isFillsClass
                && (run.isFlattened
                    || (run.isAlphaOpaque
                        && TileStyleFadeMath.fadeIsOne(zoomFade: run.zoomFade, overviewFade: overviewFadeUniform)))
        }
        let isTranslucentFillRun: (GroundStyleRun) -> Bool = { run in
            run.isFillsClass && isOpaqueFillRun(run) == false
        }
        renderEncoder.pushDebugGroup("ground.opaqueFills")
        renderEncoder.setDepthStencilState(groundOwnerState)
        drawLayer(\.ground, pipeline: .opaqueFills, bandOffset: 0, sources: groundSources, runFilter: isOpaqueFillRun)
        renderEncoder.popDebugGroup()
        // Everything after only tests the priority.
        renderEncoder.pushDebugGroup("ground.translucentFills")
        renderEncoder.setDepthStencilState(tileStencilTestState)
        drawLayer(\.ground, pipeline: .fills, bandOffset: 0, sources: groundSources, runFilter: isTranslucentFillRun)
        renderEncoder.popDebugGroup()
        renderEncoder.pushDebugGroup("ground.lineRibbons")
        drawLayer(\.ground,
                  pipeline: .lines,
                  bandOffset: GlobeSurfaceDepthRank.classDepthBand,
                  sources: linedSources,
                  runFilter: { $0.isLinesClass })
        renderEncoder.popDebugGroup()

        // The road buckets: whatever the tiles carry. A tile whose roads the
        // style drew as ground lines carries none. The roads are ordered by
        // depth, not by the order of the draws: every layer of every
        // structure has its band of ranks (`RoadRankDepth`), and the state
        // tests and writes them.
        // - A layer whose styles are all opaque this frame draws unblended.
        //   The GPU shades a pixel once, by the highest road that covers
        //   it.
        // - A layer with a translucent, a fading or a dashed style blends.
        //   These draw after every opaque road, so what lies under them is
        //   already there, and nearest first, so a pixel takes one of them,
        //   the highest, and a translucent road never darkens where two
        //   pieces of it overlap.
        // - A sphere-era tile's road ribbons are baked with their feather,
        //   not deferred (`LineFeatureReader`), and draw with the blended
        //   layers through the plain line coverage.
        // - The edge lines of every deferred road, its rim as one-pixel
        //   line primitives, draw after all of them, blended at half the
        //   road's alpha, tested against the ranks and writing none: a line
        //   shows over the ground and over a lower road, and never across a
        //   body of its own rank. That softens the steps of the hard edge.
        enum RoadLayerPass {
            case opaque
            case blended
            case baked
        }
        var roadDraws: [(source: Int, layer: TileBuffers.GeometryLayer, band: Int, pass: RoadLayerPass)] = []
        for entry in RoadRankDepth.layersNearestFirst {
            for (sourceIndex, source) in linedSources.enumerated() {
                let layer = source.metalTile.tileBuffers.roads.bucket(for: entry.structureKind).layer(for: entry.role)
                guard layer.indicesCount > 0 else { continue }
                let pass: RoadLayerPass
                if GroundGeometrySubdivider.step(forTileZoom: source.metalTile.tile.z) != nil {
                    pass = .baked
                } else {
                    switch layer.roadStyles.pass(overviewFade: overviewFadeUniform) {
                    case .hidden: continue
                    case .opaque: pass = .opaque
                    case .blended: pass = .blended
                    }
                }
                roadDraws.append((sourceIndex, layer, entry.band, pass))
            }
        }
        func drawRoad(_ roadDraw: (source: Int, layer: TileBuffers.GeometryLayer, band: Int, pass: RoadLayerPass),
                      pipeline: GroundPipeline,
                      indexRange: Range<Int>,
                      primitiveType: MTLPrimitiveType = .triangle) {
            let source = linedSources[roadDraw.source]
            selectPipeline(pipeline)
            if pipeline == .roadBlended {
                // The blended road variant's alpha scale (Tile.metal,
                // buffer 11): one for a body, the edge lines' share for
                // them.
                var alphaScale: Float = primitiveType == .line ? roadEdgeLineAlpha : 1
                renderEncoder.setFragmentBytes(&alphaScale, length: MemoryLayout<Float>.stride, index: 11)
            }
            drawFlatGeometryLayer(renderEncoder: renderEncoder,
                                  buffers: roadDraw.layer,
                                  tile: source.metalTile.tile,
                                  worldWrap: source.worldWrap,
                                  flatRenderState: flatRenderState,
                                  pixelsPerPoint: pixelsPerPoint,
                                  drawableHeightPx: drawableSizePx.y,
                                  overviewFade: overviewFadeUniform,
                                  bandOffset: RoadRankDepth.depthOffset(band: roadDraw.band),
                                  indexRange: indexRange,
                                  primitiveType: primitiveType)
        }
        // A deferred layer's indices are its bodies, as triangles, then its
        // edge lines, as line segments.
        func edgeLineIndexStart(_ layer: TileBuffers.GeometryLayer) -> Int {
            min(max(layer.roadEdgeLineIndexStart ?? layer.indicesCount, 0), layer.indicesCount)
        }
        func drawRoads(opaque: Bool) {
            for roadDraw in roadDraws where (roadDraw.pass == .opaque) == opaque {
                switch roadDraw.pass {
                case .opaque:
                    drawRoad(roadDraw, pipeline: .roadOpaque, indexRange: 0 ..< edgeLineIndexStart(roadDraw.layer))
                case .blended:
                    drawRoad(roadDraw, pipeline: .roadBlended, indexRange: 0 ..< edgeLineIndexStart(roadDraw.layer))
                case .baked:
                    drawRoad(roadDraw, pipeline: .lines, indexRange: 0 ..< roadDraw.layer.indicesCount)
                }
            }
        }
        func drawRoadEdgeLines() {
            for roadDraw in roadDraws where roadDraw.pass != .baked {
                drawRoad(roadDraw,
                         pipeline: .roadBlended,
                         indexRange: edgeLineIndexStart(roadDraw.layer) ..< roadDraw.layer.indicesCount,
                         primitiveType: .line)
            }
        }

        renderEncoder.pushDebugGroup("roads")
        renderEncoder.setDepthStencilState(roadRankState)
        renderEncoder.pushDebugGroup("roads.opaque")
        drawRoads(opaque: true)
        renderEncoder.popDebugGroup()
        renderEncoder.pushDebugGroup("roads.blended")
        drawRoads(opaque: false)
        renderEncoder.popDebugGroup()
        renderEncoder.pushDebugGroup("roads.edgeLines")
        renderEncoder.setDepthStencilState(tileStencilTestState)
        drawRoadEdgeLines()
        renderEncoder.popDebugGroup()
        // The bridge overlay is plain ground geometry laid over the roads:
        // tested against the ranks the roads wrote, in its own band, and
        // writing none.
        renderEncoder.pushDebugGroup("roads.bridgeOverlay")
        drawLayer(\.bridgeOverlay,
                  pipeline: .lines,
                  bandOffset: RoadRankDepth.depthOffset(band: RoadRankDepth.bridgeOverlayBand),
                  sources: linedSources)
        renderEncoder.popDebugGroup()
        renderEncoder.popDebugGroup()
        if isWireframeEnabled {
            renderEncoder.setTriangleFillMode(.fill)
        }
        renderEncoder.setCullMode(.none)
        renderEncoder.setFrontFacing(.clockwise)
    }


    private static func drawFlatGeometryLayer(renderEncoder: MTLRenderCommandEncoder,
                                              buffers: TileBuffers.GeometryLayer,
                                              tile: Tile,
                                              worldWrap: Int8,
                                              flatRenderState: FlatRenderState,
                                              pixelsPerPoint: Float,
                                              drawableHeightPx: Float,
                                              overviewFade: TileOverviewFadeUniform,
                                              bandOffset: Float,
                                              rankStep: Float = GlobeSurfaceDepthRank.layerDepthStep,
                                              runFilter: ((GroundStyleRun) -> Bool)? = nil,
                                              indexRange: Range<Int>? = nil,
                                              primitiveType: MTLPrimitiveType = .triangle) {
        let originAndSize = ImmersiveMapProjection.flatTileOriginAndSize(x: tile.x,
                                                                         y: tile.y,
                                                                         z: tile.z,
                                                                         worldWrap: worldWrap,
                                                                         flatRenderPan: flatRenderState.pan,
                                                                         renderMapSize: flatRenderState.renderMapSize)
        let scale = originAndSize.z / 4096.0

        // A run whose zoom fade is exactly 0 this frame would rasterize
        // with alpha 0: the ground bucket carries a run table (the road
        // buckets do not and draw whole), so its invisible runs
        // are skipped, the class filter picks the pass's runs, and the
        // visible spans coalesce, before any binding.
        // A road layer draws a part of its indices at a time instead: its
        // bodies, or its edge lines.
        let visibleSpans: [(start: Int, count: Int)]
        if let indexRange {
            visibleSpans = indexRange.isEmpty ? [] : [(indexRange.lowerBound, indexRange.count)]
        } else {
            visibleSpans = visibleRunSpans(buffers: buffers,
                                           overviewFade: overviewFade,
                                           runFilter: runFilter)
        }
        guard buffers.indicesCount > 0,
              visibleSpans.isEmpty == false,
              let indices = buffers.indices,
              let vertices = buffers.vertices,
              let styles = buffers.styles,
              let styleZoomFade = buffers.styleZoomFade,
              let lineStyles = buffers.lineStyles else { return }

        renderEncoder.setVertexBuffer(vertices.buffer, offset: vertices.offset, index: 0)
        renderEncoder.setVertexBuffer(styles.buffer, offset: styles.offset, index: 2)
        renderEncoder.setVertexBuffer(styleZoomFade.buffer, offset: styleZoomFade.offset, index: 4)
        renderEncoder.setVertexBuffer(lineStyles.buffer, offset: lineStyles.offset, index: 5)
        // The lines-class fragment resolves the style by index (the fills
        // fragment never reads these slots).
        renderEncoder.setFragmentBuffer(styles.buffer, offset: styles.offset, index: 5)
        renderEncoder.setFragmentBuffer(styleZoomFade.buffer, offset: styleZoomFade.offset, index: 6)
        renderEncoder.setFragmentBuffer(lineStyles.buffer, offset: lineStyles.offset, index: 7)
        // The tile-priority stencil reference: the ground pass replaces the
        // stencil with it, every pass tests greaterEqual against the finest
        // painter (TileSourceStencilPriority). No slot clip: a substitute
        // draws at full extent and the stencil keeps it out of covered slots.
        renderEncoder.setStencilReferenceValue(TileSourceStencilPriority.reference(sourceZoom: tile.z))
        // The group's place in the rank-depth band (Tile.metal, buffer 7).
        var depthBand = FlatDepthBand(offset: bandOffset, rankStep: rankStep)
        renderEncoder.setVertexBytes(&depthBand, length: MemoryLayout<FlatDepthBand>.stride, index: 7)

        // Anchors point-dashed patterns to the geometry: the scale depends on
        // the source tile's world size and the viewport, never on the live
        // camera, so dashes hold still under camera motion.
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
            renderEncoder.drawIndexedPrimitives(type: primitiveType,
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
        // Without a run table the layer keeps its historical behavior: whole
        // without a class filter, nothing with one.
        guard runs.isEmpty == false else { return runFilter == nil ? [(0, buffers.indicesCount)] : [] }
        var spans: [(start: Int, count: Int)] = []
        var spanStart = 0
        var spanCount = 0
        for run in runs {
            guard run.indexCount > 0,
                  runFilter?(run) != false,
                  TileStyleFadeMath.fadeIsZero(zoomFade: run.zoomFade, overviewFade: overviewFade) == false else {
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

/// Mirror of `FlatDepthBand` in Tile.metal (buffer 7): a draw's offset in
/// the rank-depth band and its step from one style rank to the next.
struct FlatDepthBand {
    var offset: Float
    var rankStep: Float
}
