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
    /// Whether a source draws with the exact rank depth (Tile.metal,
    /// kTileExactRankDepth): every source below `exactRankDepthBelowZoom`.
    /// The rank depth in the vertex z survives the near cut only while a
    /// source's triangles are small against the near distance, which the
    /// target zoom's tiles are and a coarser band's are not (each level
    /// down doubles the error), so the target zoom keeps the early depth
    /// test and everything coarser takes the exact path.
    static func usesExactRankDepth(sourceZoom: Int, exactRankDepthBelowZoom: Int) -> Bool {
        sourceZoom < exactRankDepthBelowZoom
    }

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

    /// - Parameter exactRankDepthBelowZoom: the sources below this zoom
    ///   write their rank depth from the fragment stage
    ///   (`usesExactRankDepth`). The main coverage passes the target zoom.
    /// - Parameter roadSheetStates: the road sheet's states. With them each
    ///   road group draws as one sheet, every pixel blended once (the road
    ///   sheet in Tile.metal); without them the groups draw the plain way,
    ///   in painter's order.
    static func draw(renderEncoder: MTLRenderCommandEncoder,
                     cameraUniform: CameraUniform,
                     cameraZoom: Double,
                     pixelsPerPoint: Float,
                     drawableSizePx: SIMD2<Float>,
                     placeTilesContext: PlaceTilesContext,
                     flatRenderState: FlatRenderState,
                     groundShadowMask: GroundShadowMaskBinding,
                     tilePipeline: TilePipeline,
                     groundOwnerState: MTLDepthStencilState,
                     tileStencilTestState: MTLDepthStencilState,
                     roadSheetStates: RoadSheetStates? = nil,
                     isWireframeEnabled: Bool,
                     exactRankDepthBelowZoom: Int,
                     linelessTiles: Set<VisibleTile> = []) {
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
            pointWidthReferenceDepth: screenCentreGroundDepth(cameraMatrix: cameraUniform.matrix),
            cameraMatrix: cameraUniform.matrix
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
        var uniqueSources: [(metalTile: MetalTile, worldWrap: Int8, exactRankDepth: Bool)] = []
        uniqueSources.reserveCapacity(placeTilesContext.tilePlacements.count)
        for placeTile in placeTilesContext.tilePlacements {
            let key = SourceKey(tile: placeTile.metalTile.tile, worldWrap: placeTile.placeIn.worldWrap)
            if seenSources.insert(key).inserted {
                let exact = usesExactRankDepth(sourceZoom: placeTile.metalTile.tile.z,
                                               exactRankDepthBelowZoom: exactRankDepthBelowZoom)
                uniqueSources.append((placeTile.metalTile, placeTile.placeIn.worldWrap, exact))
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

        // Each group selects its pipeline per source, since a source's
        // depth path is its own (usesExactRankDepth): finest first, so the
        // exact sources come last and the state changes once per group.
        enum GroundPipeline {
            case lines
            case fills
            case opaqueFills
        }
        var selectedPipeline: (GroundPipeline, Bool)?
        // Set while a road group draws as a sheet: the stage has bound its
        // own pipeline, and the per-source selection stands aside.
        var roadSheetStage: RoadSheetDepth.Stage?
        func selectPipeline(_ pipeline: GroundPipeline, exactRankDepth: Bool) {
            if roadSheetStage != nil { return }
            if let selectedPipeline, selectedPipeline == (pipeline, exactRankDepth) { return }
            selectedPipeline = (pipeline, exactRankDepth)
            switch pipeline {
            case .lines:
                tilePipeline.selectFlatLinesPipeline(renderEncoder: renderEncoder, exactRankDepth: exactRankDepth)
            case .fills:
                tilePipeline.selectFlatFillsPipeline(renderEncoder: renderEncoder, exactRankDepth: exactRankDepth)
            case .opaqueFills:
                tilePipeline.selectFlatOpaquePipeline(renderEncoder: renderEncoder, exactRankDepth: exactRankDepth)
            }
        }

        func drawLayer(_ keyPath: KeyPath<TileBuffers, TileBuffers.GeometryLayer>,
                       pipeline: GroundPipeline,
                       bandOffset: Float,
                       linesOnly: Bool = false,
                       runFilter: ((GroundStyleRun) -> Bool)? = nil) {
            for source in linesOnly ? linedSources : uniqueSources {
                selectPipeline(pipeline, exactRankDepth: source.exactRankDepth)
                drawFlatGeometryLayer(renderEncoder: renderEncoder,
                                      buffers: source.metalTile.tileBuffers[keyPath: keyPath],
                                      tile: source.metalTile.tile,
                                      worldWrap: source.worldWrap,
                                      flatRenderState: flatRenderState,
                                      pixelsPerPoint: pixelsPerPoint,
                                      drawableHeightPx: drawableSizePx.y,
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
            run.isFillsClass
                && run.isAlphaOpaque
                && TileStyleFadeMath.fadeIsOne(zoomFade: run.zoomFade, overviewFade: overviewFadeUniform)
        }
        let isTranslucentFillRun: (GroundStyleRun) -> Bool = { run in
            run.isFillsClass && isOpaqueFillRun(run) == false
        }
        renderEncoder.pushDebugGroup("ground.opaqueFills")
        renderEncoder.setDepthStencilState(groundOwnerState)
        drawLayer(\.ground, pipeline: .opaqueFills, bandOffset: 0, runFilter: isOpaqueFillRun)
        renderEncoder.popDebugGroup()
        // Everything after only tests the priority.
        renderEncoder.pushDebugGroup("ground.translucentFills")
        renderEncoder.setDepthStencilState(tileStencilTestState)
        drawLayer(\.ground, pipeline: .fills, bandOffset: 0, runFilter: isTranslucentFillRun)
        renderEncoder.popDebugGroup()
        renderEncoder.pushDebugGroup("ground.lineRibbons")
        drawLayer(\.ground,
                  pipeline: .lines,
                  bandOffset: GlobeSurfaceDepthRank.classDepthBand,
                  linesOnly: true,
                  runFilter: { $0.isLinesClass })
        renderEncoder.popDebugGroup()

        // The road buckets: whatever the tiles carry. A tile whose roads the
        // style drew as ground lines carries none, and the casing's zoom is
        // the style's too, baked as the pass's fade band.
        func drawRoadLayer(_ structureKind: RoadStructureKind, role: RoadPassRole) {
            for source in linedSources {
                selectPipeline(.lines, exactRankDepth: source.exactRankDepth)
                let structureBucket = source.metalTile.tileBuffers.roads.bucket(for: structureKind)
                drawFlatGeometryLayer(renderEncoder: renderEncoder,
                                      buffers: structureBucket.layer(for: role),
                                      tile: source.metalTile.tile,
                                      worldWrap: source.worldWrap,
                                      flatRenderState: flatRenderState,
                                      pixelsPerPoint: pixelsPerPoint,
                                      drawableHeightPx: drawableSizePx.y,
                                      overviewFade: overviewFadeUniform,
                                      bandOffset: GlobeSurfaceDepthRank.flatRoadsDepthOffset)
            }
        }
        func roadLayerIsEmpty(_ structureKind: RoadStructureKind, role: RoadPassRole) -> Bool {
            linedSources.allSatisfy {
                $0.metalTile.tileBuffers.roads.bucket(for: structureKind).layer(for: role).indicesCount == 0
            }
        }

        // One group of roads as one sheet: the depth stage, then the colour
        // stage, over the same draws (the road sheet in Tile.metal). Each
        // group takes the next band of the sheet's depths, so it paints
        // over the groups before it, the order the groups are drawn in.
        var roadSheetGroup = 0
        func drawRoadSheet(isEmpty: Bool, _ drawGroup: () -> Void) {
            guard isEmpty == false else { return }
            guard let roadSheetStates else {
                drawGroup()
                return
            }
            for stage in [RoadSheetDepth.Stage.depth, .color] {
                guard tilePipeline.selectFlatRoadSheetPipeline(renderEncoder: renderEncoder, stage: stage) else {
                    drawGroup()
                    return
                }
                roadSheetStage = stage
                renderEncoder.setDepthStencilState(stage == .depth
                    ? roadSheetStates.depthStage
                    : roadSheetStates.colorStage)
                var sheetUniform = RoadSheetDepth.uniform(group: roadSheetGroup, stage: stage)
                renderEncoder.setFragmentBytes(&sheetUniform,
                                               length: MemoryLayout<RoadSheetUniform>.stride,
                                               index: 11)
                drawGroup()
            }
            roadSheetStage = nil
            selectedPipeline = nil
            roadSheetGroup += 1
        }
        // One sheet per role over the structures that read as one network.
        func drawRoadSheets(_ structureKinds: [RoadStructureKind]) {
            for role in [RoadPassRole.shadow, .casing, .fill, .detail] {
                drawRoadSheet(isEmpty: structureKinds.allSatisfy { roadLayerIsEmpty($0, role: role) }) {
                    for structureKind in structureKinds {
                        drawRoadLayer(structureKind, role: role)
                    }
                }
            }
        }

        renderEncoder.pushDebugGroup("roads")
        drawRoadSheets([.tunnel])
        drawRoadSheets([.ground])
        // The carriageways of the ground and of the bridges are one sheet
        // per role: a flyover over an avenue, a ramp leaving it and the
        // avenue itself are one network on screen, and a translucent road
        // must not darken where one of them passes over another. The
        // bridges follow the ground inside the sheet, so where the alphas
        // tie, the ground's pixel is the one that draws. The price is the
        // kerb of a bridge, which no longer cuts across the road under it.
        drawRoadSheets([.automobileGround, .bridge])
        drawRoadSheet(isEmpty: linedSources.allSatisfy { $0.metalTile.tileBuffers.bridgeOverlay.indicesCount == 0 }) {
            drawLayer(\.bridgeOverlay, pipeline: .lines, bandOffset: GlobeSurfaceDepthRank.flatRoadsDepthOffset,
                      linesOnly: true)
        }

        drawRoadSheet(isEmpty: RoadStructureKind.drawOrder.allSatisfy { roadLayerIsEmpty($0, role: .overlay) }) {
            for structureKind in RoadStructureKind.drawOrder {
                drawRoadLayer(structureKind, role: .overlay)
            }
        }
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
                                              runFilter: ((GroundStyleRun) -> Bool)? = nil) {
        let originAndSize = ImmersiveMapProjection.flatTileOriginAndSize(x: tile.x,
                                                                         y: tile.y,
                                                                         z: tile.z,
                                                                         worldWrap: worldWrap,
                                                                         flatRenderPan: flatRenderState.pan,
                                                                         renderMapSize: flatRenderState.renderMapSize)
        let scale = originAndSize.z / 4096.0

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
        var bandOffsetValue = bandOffset
        renderEncoder.setVertexBytes(&bandOffsetValue, length: MemoryLayout<Float>.stride, index: 7)

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
