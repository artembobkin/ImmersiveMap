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
    /// - Parameter groundRelief: the terrain the flattened ground rises by,
    ///   nil for a flat ground. Everything of a flattened tile whose terrain
    ///   is in rises by it: its fills, its lines, its roads and its bridges.
    /// - Parameter pointWidthReferenceDepth: the view depth the point-locked
    ///   road widths are stated at, the ground under the centre of the
    ///   screen: on a relief the terrain there
    ///   (`GroundReliefCameraLift.centreGroundDepth`), else the plane.
    /// - Parameter slotClips: the frame's rings: every placement draws its
    ///   slot's ground only (`GroundSlotClip`), once per rectangle of it,
    ///   and the depth alone orders the sources.
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
                     groundSlotOwnerState: MTLDepthStencilState,
                     groundSlotTestState: MTLDepthStencilState,
                     roadRankState: MTLDepthStencilState,
                     isWireframeEnabled: Bool,
                     linelessTiles: Set<VisibleTile> = [],
                     rasterGroundSlots: Set<VisibleTile> = [],
                     groundRelief: GroundReliefStore? = nil,
                     pointWidthReferenceDepth: Float? = nil,
                     slotClips: GroundSlotClip.Rings) {
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
            pointWidthReferenceDepth: pointWidthReferenceDepth ?? screenCentreGroundDepth(cameraMatrix: cpuCameraMatrix),
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

        // PLACEMENTS, each drawing its slot's ground only (`GroundSlotClip`):
        // the sources do not overlap, and the depth orders them. A stand-in
        // placed in several slots draws once per slot. The slot is the
        // target's, a descendant standing in included, whose own tile is
        // where it is drawn but not what it is drawn for: the target's ring
        // names the band that bounds it, and its lines and fills are the
        // target's rule's (`FlatRingRule.drawsLines`, and a raster target's
        // ground is its texture, `RasterTileRenderSubsystem`, so its own
        // tile and its stand-ins draw only their lines there). An ancestor
        // standing in draws around the descendants placed in the same
        // slot.
        // The relief of a flattened source whose terrain is in, the ring's
        // of its slot: such a source draws every class through the relief
        // variant of the class's pipeline, raised by its terrain.
        let reliefStore = tilePipeline.flatReliefPipelineStates.isEmpty ? nil : groundRelief
        let sources = GroundSlotClip.placements(placeTilesContext.tilePlacements, rings: slotClips).map { placement in
            let tile = placement.placeTile.metalTile.tile
            let relief = placement.placeTile.metalTile.tileBuffers.ground.isFlattened
                ? reliefStore?.relief(for: tile, terrainZoom: GroundReliefStore.terrainZoom(forTargetZoom: placement.placeTile.slot.z))
                : nil
            return Source(metalTile: placement.placeTile.metalTile,
                          worldWrap: placement.placeTile.placeIn.worldWrap,
                          clips: placement.clips,
                          relief: relief,
                          drawsLines: linelessTiles.contains(placement.placeTile.slot) == false,
                          drawsGround: rasterGroundSlots.contains(placement.placeTile.slot) == false)
        }
        let linedSources = sources.filter(\.drawsLines)
        let groundSources = sources.filter(\.drawsGround)
        func relief(of source: Source) -> GroundRelief? { source.relief }

        // Each group selects its pipeline once, and again only where a
        // source's relief wants the class's relief variant, or the next
        // source the plain one.
        typealias GroundPipeline = TilePipeline.FlatClass
        var selectedPipeline: (pipeline: GroundPipeline, relief: Bool)?
        func selectPipeline(_ pipeline: GroundPipeline, relief: Bool = false) {
            if let selectedPipeline, selectedPipeline.pipeline == pipeline, selectedPipeline.relief == relief { return }
            selectedPipeline = (pipeline, relief)
            if relief, tilePipeline.selectFlatReliefPipeline(pipeline, renderEncoder: renderEncoder) {
                return
            }
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
        /// The pipeline for one source's draw of a class: the relief
        /// variant with the source's terrain bound where it has one. Over
        /// a relief the ground writes its real depth (Tile.metal,
        /// kReliefBandScale), and what lies on it (the lines, the roads,
        /// the bridges) draws with a depth bias that scales with the
        /// slope, so it stays over the ground where its triangles sample
        /// the terrain apart from the ground's.
        var depthBiased = false
        func selectPipeline(_ pipeline: GroundPipeline, for source: Source) {
            let relief = relief(of: source)
            let biased = relief != nil && pipeline != .opaqueFills
            if biased != depthBiased {
                depthBiased = biased
                renderEncoder.setDepthBias(biased ? -1 : 0, slopeScale: biased ? -1 : 0, clamp: 0)
            }
            guard let relief, let groundRelief else {
                selectPipeline(pipeline)
                return
            }
            selectPipeline(pipeline, relief: true)
            bindGroundRelief(relief,
                             tile: source.metalTile.tile,
                             datumMetres: groundRelief.datumMetres,
                             renderMapSize: flatRenderState.renderMapSize,
                             renderEncoder: renderEncoder)
        }

        func drawLayer(_ keyPath: KeyPath<TileBuffers, TileBuffers.GeometryLayer>,
                       pipeline: GroundPipeline,
                       bandOffset: Float,
                       sources: [Source],
                       runFilter: ((GroundStyleRun) -> Bool)? = nil) {
            for source in sources {
                let layer = source.metalTile.tileBuffers[keyPath: keyPath]
                // The fills of a flattened ground take one depth: no rank
                // step between their styles (Tile.metal, FlatDepthBand).
                let rankStep: Float = pipeline == .opaqueFills && layer.isFlattened
                    ? 0 : GlobeSurfaceDepthRank.layerDepthStep
                selectPipeline(pipeline, for: source)
                drawFlatGeometryLayer(renderEncoder: renderEncoder,
                                      buffers: layer,
                                      tile: source.metalTile.tile,
                                      worldWrap: source.worldWrap,
                                      clips: source.clips,
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
        // pixel is shaded once by its topmost opaque layer); the
        // translucent fills and the ribbons follow, tested only. The band
        // sits at the far plane, farther than every real fragment, so the
        // buildings' occlusion is untouched.
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
        renderEncoder.setDepthStencilState(groundSlotOwnerState)
        drawLayer(\.ground, pipeline: .opaqueFills, bandOffset: 0, sources: groundSources, runFilter: isOpaqueFillRun)
        renderEncoder.popDebugGroup()
        // Everything after only tests the depth.
        renderEncoder.pushDebugGroup("ground.translucentFills")
        renderEncoder.setDepthStencilState(groundSlotTestState)
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
            selectPipeline(pipeline, for: source)
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
                                  clips: source.clips,
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
        renderEncoder.setDepthStencilState(groundSlotTestState)
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
        if depthBiased {
            renderEncoder.setDepthBias(0, slopeScale: 0, clamp: 0)
        }
        renderEncoder.setCullMode(.none)
        renderEncoder.setFrontFacing(.clockwise)
    }


    /// The relief of one flattened tile (Tile.metal, kTileGroundRelief):
    /// its terrain texture at vertex texture 0, its roughness texture at
    /// vertex texture 1, and at vertex buffer 9 where the tile lies in
    /// them, the world units a metre of terrain rises by at the tile's
    /// latitude, worked out here once for the tile, the frame's datum
    /// (`GroundReliefStore.datumMetres`) and the frame's fades.
    private static func bindGroundRelief(_ relief: GroundRelief,
                                         tile: Tile,
                                         datumMetres: Float,
                                         renderMapSize: Double,
                                         renderEncoder: MTLRenderCommandEncoder) {
        let latitude = ImmersiveMapProjection.latitude(fromNormalizedWorldY: (Double(tile.y) + 0.5) / Double(1 << tile.z))
        let unitsPerMetre = ImmersiveMapProjection.worldUnitsPerMeter(latitudeRadians: latitude,
                                                                      renderMapSize: renderMapSize)
        var uniform = GroundReliefUniform(relief: relief, worldUnitsPerMetre: Float(unitsPerMetre), datumMetres: datumMetres)
        renderEncoder.setVertexTexture(relief.texture, index: 0)
        renderEncoder.setVertexTexture(relief.roughnessTexture, index: 1)
        renderEncoder.setVertexBytes(&uniform, length: MemoryLayout<GroundReliefUniform>.stride, index: 9)
    }

    private static func drawFlatGeometryLayer(renderEncoder: MTLRenderCommandEncoder,
                                              buffers: TileBuffers.GeometryLayer,
                                              tile: Tile,
                                              worldWrap: Int8,
                                              clips: [SIMD4<Float>],
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
        // The slot's rectangles the draw is clipped to (Tile.metal, buffer
        // 12, GroundSlotClip).
        for clip in clips {
            var clipRect = clip
            renderEncoder.setVertexBytes(&clipRect, length: MemoryLayout<SIMD4<Float>>.stride, index: 12)
            for span in visibleSpans {
                renderEncoder.drawIndexedPrimitives(type: primitiveType,
                                                    indexCount: span.count,
                                                    indexType: buffers.indexType,
                                                    indexBuffer: indices.buffer,
                                                    indexBufferOffset: indices.offset + span.start * indexByteWidth)
            }
        }
    }

    /// One draw of the ground: a source, where it lies, the rectangles of
    /// its slot it draws (`GroundSlotClip`), the terrain it rises by, and
    /// which of its classes it draws.
    struct Source {
        let metalTile: MetalTile
        let worldWrap: Int8
        let clips: [SIMD4<Float>]
        let relief: GroundRelief?
        let drawsLines: Bool
        let drawsGround: Bool
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

/// Mirror of `GroundReliefUniform` in GroundRelief.h (vertex buffer 9):
/// the tile's corner and side in its terrain texture and the world units
/// a metre of terrain rises by, its corner and side in its roughness
/// texture and the datum, the terrain's metres the ground is drawn from
/// (`GroundReliefStore.datumMetres`), the frame's fades and the frame's
/// zoom and strength scale (`GroundReliefFrame`).
struct GroundReliefUniform {
    var placement: SIMD4<Float>
    var roughness: SIMD4<Float>
    var fades: SIMD4<Float>
    var frame: SIMD4<Float>

    init(relief: GroundRelief, worldUnitsPerMetre: Float, datumMetres: Float) {
        placement = SIMD4<Float>(relief.origin.x, relief.origin.y, relief.scale, worldUnitsPerMetre)
        roughness = SIMD4<Float>(relief.roughnessOrigin.x, relief.roughnessOrigin.y, relief.roughnessScale, datumMetres)
        fades = SIMD4<Float>(relief.frame.flat.x, relief.frame.flat.y, relief.frame.mountain.x, relief.frame.mountain.y)
        frame = SIMD4<Float>(relief.frame.cameraZoom, relief.frame.strengthScale, 0, 0)
    }
}

/// Mirror of `FlatDepthBand` in Tile.metal (buffer 7): a draw's offset in
/// the rank-depth band and its step from one style rank to the next.
struct FlatDepthBand {
    var offset: Float
    var rankStep: Float
}
