// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

//
//  BaseLabelPrepareSubsystem.swift
//  ImmersiveMap
//

import Foundation
import Metal
import simd

/// The frame's label decisions on the CPU: which base and road labels show,
/// and how far each has faded.
///
/// The working set (the labels of the frame's tiles) changes only when the
/// tiles do; everything sized by it is allocated then and reused since. A
/// frame with a moving camera projects the base labels' anchors, solves the
/// collisions of base labels and road instances together in one pass
/// (`LabelCollisionSolver`), advances the fades in place and writes the
/// runtime meta and the screen positions the label shaders read. A frame
/// with a still camera and no fade in flight does none of that. There is no
/// GPU projection of the base labels any more and no visibility cycle spread
/// over frames: the decision for a pose is made in the frame that renders
/// the pose.
final class BaseLabelPrepareSubsystem: RenderSubsystem {
    let name: String = "BaseLabels"
    private static let traceLocale = Locale(identifier: "en_US_POSIX")

    private let baseLabelCache: BaseLabelCache
    private let roadLabelCache: RoadLabelCache?
    private let baseLabelTraceRecorder: BaseLabelTraceRecorder
    private let tilePointScreenProjector = TilePointScreenProjector()
    private let screenComputePipelines: TilePointScreenPipelines
    private let roadPathScreenCompute: TilePointScreenCompute
    private let roadPlacementCalculator: RoadLabelPlacementCalculator
    private let collisionSolver = LabelCollisionSolver()
    private let baseFade = BaseLabelFadeState()
    private let roadFade = BaseLabelFadeState()
    private let screenPositionsBufferStore: FrameSlottedDynamicMetalBuffer<ScreenPointOutput>
    private let roadRuntimeMetaBufferStore: FrameSlottedDynamicMetalBuffer<LabelRuntimeMeta>
    private let fallbackTileOriginDataBufferStore: FrameSlottedDynamicMetalBuffer<FlatTileOriginData>
    private let fadeInSeconds: TimeInterval
    private let fadeOutSeconds: TimeInterval
    private let maxGlyphTurnRadians: Float
    private let collisionGridCellSizePoints: Float

    private var sourceEntriesVersionTracker = StagedHashChangeTracker()
    private var projectionVersionTracker = StagedHashChangeTracker()
    private var roadDrawLabels: [DrawRoadLabels] = []
    private var visibilityTopologyGeneration: UInt64 = 0
    private var latestCameraFingerprint: Int = 0
    /// The camera the base projection and the last collision solve were
    /// made for; a frame with the same camera and nothing else changed
    /// reuses both.
    private var projectedCameraFingerprint: Int?
    private var solvedCameraFingerprint: Int?
    private var solvedPixelsPerPoint: Float = 0

    // Index-aligned with the base label set; sized at a topology change,
    // written in place every frame that needs them.
    private var baseScreenPoints: [ScreenPointOutput] = []
    private var baseHorizonVisible: [Bool] = []
    private var baseCenters: [SIMD2<Float>] = []
    private var baseHalfSizesPx: [SIMD2<Float>] = []
    private var baseGroupIds: [UInt64] = []
    private var baseReservesSpace: [Bool] = []
    private var baseCollisionVisible: [Bool] = []
    private var baseTargetVisible: [Bool] = []
    private var baseFadeAlphaScratch: [Float] = []

    // Index-aligned with the road instance set.
    private var roadCollisionVisible: [Bool] = []
    private var roadTargetVisible: [Bool] = []
    private var roadRecordActive: [Bool] = []
    /// The road instances offered to the solver this frame and their glyph
    /// boxes, flat, reused between frames.
    private var roadItems: [LabelCollisionRoadItem] = []
    private var roadBoxCenters: [SIMD2<Float>] = []
    private var roadBoxHalfSizes: [SIMD2<Float>] = []
    private var roadRuntimeMetaScratch: [LabelRuntimeMeta] = []
    private var roadRecordMetaScratch: [LabelRuntimeMeta] = []

    private var latestRoadLabelNearCameraCullCounts = (path: 0, anchor: 0)
    // Some active records have no GPU placement data yet (fresh tile, return
    // from culling): the flag keeps frames coming until the data arrives,
    // otherwise with a stationary camera labels of such tiles would never
    // appear.
    private var roadPlacementDataPending = false
    // (record, slot) pairs whose placement compute is encoded into the current
    // frame's command buffer; committed to stamps only after commit().
    private var pendingPlacementStamps: [(record: RoadLabelTileRecord, slot: Int)] = []

    private let roadPriorityBase: Int = 1_000_000_000
    private let debugOverlayControls: DebugOverlayControlState?

    init(baseLabelCache: BaseLabelCache,
         roadLabelCache: RoadLabelCache? = nil,
         baseLabelTraceRecorder: BaseLabelTraceRecorder = BaseLabelTraceRecorder(),
         metalDevice: MTLDevice,
         screenComputePipelines: TilePointScreenPipelines,
         roadPlacementPipeline: RoadLabelPlacementPipeline,
         settings: ImmersiveMapSettings.LabelSettings = ImmersiveMapSettings.default.labels,
         debugOverlayControls: DebugOverlayControlState? = nil) {
        self.baseLabelCache = baseLabelCache
        self.roadLabelCache = roadLabelCache
        self.baseLabelTraceRecorder = baseLabelTraceRecorder
        self.debugOverlayControls = debugOverlayControls
        self.screenComputePipelines = screenComputePipelines
        self.roadPathScreenCompute = TilePointScreenCompute(metalDevice: metalDevice, pipelines: screenComputePipelines)
        self.roadPlacementCalculator = RoadLabelPlacementCalculator(pipeline: roadPlacementPipeline)
        self.screenPositionsBufferStore = FrameSlottedDynamicMetalBuffer(metalDevice: metalDevice,
                                                                         slotsCount: InFlightFramePool.inFlightFramesCount,
                                                                         options: [.storageModeShared])
        self.roadRuntimeMetaBufferStore = FrameSlottedDynamicMetalBuffer(metalDevice: metalDevice,
                                                                         slotsCount: InFlightFramePool.inFlightFramesCount,
                                                                         options: [.storageModeShared])
        self.fallbackTileOriginDataBufferStore = FrameSlottedDynamicMetalBuffer(metalDevice: metalDevice,
                                                                                slotsCount: InFlightFramePool.inFlightFramesCount,
                                                                                options: [.storageModeShared])
        self.fadeInSeconds = settings.base.fadeInSeconds
        self.fadeOutSeconds = settings.base.fadeOutSeconds
        self.maxGlyphTurnRadians = settings.road.maxGlyphTurnRadians
        self.collisionGridCellSizePoints = max(4.0, settings.base.gridCellSizePoints)
    }

    func update(frameContext: FrameContext) {
        let placeTileTrackingState = frameContext.sharedState.placeTileTrackingState
        let projectionIndexState = frameContext.sharedState.tileProjectionIndexState
        let sourceEntries = BaseLabelSourceEntry.build(from: placeTileTrackingState.placeTiles)
        latestCameraFingerprint = makeVisibilityCameraFingerprint(frameContext: frameContext)

        // One source set serves the base and the road label caches alike.
        let sourceTilesChanged = sourceEntriesVersionTracker.stage(BaseLabelSourceEntry.makeHash(sourceEntries))
        let projectionChanged = projectionVersionTracker.stage(Int(truncatingIfNeeded: projectionIndexState.sourceIndexVersion))
        let topologyChanged = sourceTilesChanged || projectionChanged
        if topologyChanged {
            baseLabelCache.synchronize(sourceEntries: sourceEntries,
                                       tileIndexAllocator: projectionIndexState.tileIndexAllocator,
                                       trackedTilesChanged: sourceTilesChanged,
                                       projectionChanged: projectionChanged)
            roadLabelCache?.synchronize(sourceEntries: sourceEntries,
                                        tileIndexAllocator: projectionIndexState.tileIndexAllocator,
                                        trackedTilesChanged: sourceTilesChanged,
                                        projectionChanged: projectionChanged)
            visibilityTopologyGeneration &+= 1
            rebindWorkingSet(time: frameContext.time)
            if sourceTilesChanged {
                sourceEntriesVersionTracker.commitPending()
            }
            if projectionChanged {
                projectionVersionTracker.commitPending()
            }
        }

        let cameraChanged = projectedCameraFingerprint != latestCameraFingerprint
        if cameraChanged || topologyChanged {
            projectBaseLabels(frameContext: frameContext)
            projectedCameraFingerprint = latestCameraFingerprint
        }

        let pixelsPerPoint = frameContext.screenScale.pixelsPerPoint
        if pixelsPerPoint != solvedPixelsPerPoint {
            rescaleBaseHalfSizes(pixelsPerPoint: pixelsPerPoint)
        }
        // The solve depends on the pose, the set, the road data the GPU
        // hands back, and the fades (a label fading out keeps its space): a
        // frame with none of them changing keeps the previous decision.
        let fadesActive = frameContext.sharedState.baseLabelState.hasActiveFadeAnimations
            || frameContext.sharedState.roadLabelState.hasActiveFadeAnimations
        let needsSolve = cameraChanged || topologyChanged || roadPlacementDataPending || fadesActive
            || solvedCameraFingerprint == nil
        if needsSolve {
            solveCollisions(frameContext: frameContext)
            solvedCameraFingerprint = latestCameraFingerprint
            solvedPixelsPerPoint = pixelsPerPoint
        }

        let cameraZoom = Float(frameContext.zoom)
        BaseLabelVisibilityResolver.targetVisibility(inputs: baseLabelCache.presentationInputs,
                                                     collisionVisible: baseCollisionVisible,
                                                     horizonVisibility: baseHorizonVisible,
                                                     cameraZoom: cameraZoom,
                                                     into: &baseTargetVisible)
        let baseFadesActive = baseFade.advance(targetVisibility: baseTargetVisible,
                                               time: frameContext.time,
                                               fadeInSeconds: fadeInSeconds,
                                               fadeOutSeconds: fadeOutSeconds)
        let overviewFadeAlpha = LowZoomOverviewFade.alpha(for: frameContext.zoom)
        baseLabelCache.updateFadeAlphas(baseFade.currentAlphas, multiplier: overviewFadeAlpha)

        if baseLabelTraceRecorder.isRecordingActive {
            recordBaseLabelTraceFrame(frameContext: frameContext,
                                      sourceTileCount: sourceEntries.count,
                                      trackedTilesChanged: sourceTilesChanged,
                                      projectionChanged: projectionChanged,
                                      overviewFadeAlpha: overviewFadeAlpha)
        }
        frameContext.sharedState.baseLabelDebugBoxesState = makeDebugBoxesState(cameraZoom: cameraZoom,
                                                                                screenScale: frameContext.screenScale)
        publishBaseLabelState(frameContext: frameContext,
                              hasActiveFadeAnimations: baseFadesActive,
                              needsFollowUpFrame: roadPlacementDataPending)

        let roadState = buildRoadLabelState(frameContext: frameContext)
        frameContext.sharedState.roadLabelState = roadState

        frameContext.services.diagnostics.setCounter(.baseLabelCount, value: baseLabelCache.labelInputsCount)
        frameContext.services.diagnostics.setCounter(.roadLabelGlyphCount, value: roadState.glyphCount)
        frameContext.services.diagnostics.setCounter(.roadLabelInstanceCount, value: roadState.instanceCount)
        frameContext.services.diagnostics.setCounter(.roadLabelNearCameraCulledPathCount,
                                                     value: latestRoadLabelNearCameraCullCounts.path)
        frameContext.services.diagnostics.setCounter(.roadLabelNearCameraCulledAnchorCount,
                                                     value: latestRoadLabelNearCameraCullCounts.anchor)
    }

    func prepareGPU(frameContext: FrameContext, resourceRegistry _: RenderResourceRegistry) {
        // Stamps from the previous frame that never reached frameCommitted (the
        // frame was dropped without commit) - the compute never ran, so they
        // must not be committed.
        pendingPlacementStamps.removeAll(keepingCapacity: true)
        guard let commandBuffer = frameContext.commandBuffer else {
            return
        }
        let tileOriginDataBuffer = resolveTileOriginDataBuffer(frameContext: frameContext)

        // Road records are gathered up front: all point-to-screen dispatches of
        // the frame (base labels + road paths) go into one compute encoder, all
        // placement dispatches into a second, instead of a pair of encoders per record.
        struct RoadPathDispatch {
            let pointCount: Int
            let inputBuffer: MTLBuffer
            let tileSlotVisibleTileIndicesBuffer: MTLBuffer
            let outputBuffer: MTLBuffer
        }
        var roadPathDispatches: [RoadPathDispatch] = []
        var placementDispatches: [RoadLabelPlacementCalculator.RecordDispatch] = []
        var drawBatches: [DrawRoadLabels] = []
        var hasRoadRecords = false

        if let roadLabelCache, roadLabelCache.orderedTileRecords.isEmpty == false {
            hasRoadRecords = true
            let staticBatches = frameContext.sharedState.roadLabelState.drawLabels
            let records = roadLabelCache.orderedTileRecords
            drawBatches.reserveCapacity(records.count)

            for (index, record) in records.enumerated() {
                if index < roadRecordActive.count, roadRecordActive[index] == false {
                    continue
                }

                guard record.pathPointCount > 0,
                      record.glyphCount > 0,
                      let pathInputsBuffer = record.pathInputsBuffer,
                      let pathRangesBuffer = record.pathRangesBuffer,
                      let anchorsBuffer = record.anchorsBuffer,
                      let glyphInputsBuffer = record.glyphInputsBuffer,
                      let collisionInputsBuffer = record.collisionInputsBuffer else {
                    continue
                }

                let pathPointsBuffer = record.pathPointScreenBuffer(slot: frameContext.frameSlotIndex)
                roadPathDispatches.append(RoadPathDispatch(
                    pointCount: record.pathPointCount,
                    inputBuffer: pathInputsBuffer,
                    tileSlotVisibleTileIndicesBuffer: record.visibleTileIndexBuffer,
                    outputBuffer: pathPointsBuffer
                ))

                let placementBuffer = record.placementBuffer(slot: frameContext.frameSlotIndex)
                let glyphScreenPointsBuffer = record.glyphScreenPointBuffer(slot: frameContext.frameSlotIndex)
                let collisionAabbBuffer = record.collisionAabbBuffer(slot: frameContext.frameSlotIndex)
                placementDispatches.append(RoadLabelPlacementCalculator.RecordDispatch(
                    pathPointsBuffer: pathPointsBuffer,
                    pathRangesBuffer: pathRangesBuffer,
                    anchorsBuffer: anchorsBuffer,
                    glyphInputsBuffer: glyphInputsBuffer,
                    placementsBuffer: placementBuffer,
                    screenPointsBuffer: glyphScreenPointsBuffer,
                    collisionInputsBuffer: collisionInputsBuffer,
                    collisionAabbBuffer: collisionAabbBuffer,
                    glyphCount: record.glyphCount
                ))
                // The stamp is committed only in frameCommitted(): the frame may
                // be dropped after prepareGPU (no drawable), and the encoded
                // compute would never execute.
                pendingPlacementStamps.append((record: record, slot: frameContext.frameSlotIndex))

                if index < staticBatches.count {
                    let existingBatch = staticBatches[index]
                    drawBatches.append(DrawRoadLabels(placementBuffer: placementBuffer,
                                                      glyphInputBuffer: glyphInputsBuffer,
                                                      runtimeMetaBuffer: existingBatch.runtimeMetaBuffer,
                                                      localGlyphVertices: record.localGlyphVertices,
                                                      glyphCount: record.glyphCount,
                                                      labelStyle: record.labelStyle))
                }
            }
        }

        // Encoder 1: the road paths' point-to-screen computations (the base
        // labels are projected on the CPU in update, see projectBaseLabels).
        // Pass constants (PSO, camera, screenParams, origin buffer) are
        // bound once; dispatches attach only their own buffers.
        if roadPathDispatches.isEmpty == false,
           let encoder = MetalDebugComputePass.begin(commandBuffer: commandBuffer,
                                                     label: TilePointScreenCompute.passLabel(for: frameContext)) {
            if TilePointScreenCompute.beginPass(encoder: encoder,
                                                frameContext: frameContext,
                                                pipelines: screenComputePipelines,
                                                tileOriginDataBuffer: tileOriginDataBuffer) {
                for pathDispatch in roadPathDispatches {
                    roadPathScreenCompute.encodeDispatch(encoder: encoder,
                                                         frameContext: frameContext,
                                                         pointCount: pathDispatch.pointCount,
                                                         inputBuffer: pathDispatch.inputBuffer,
                                                         tileSlotVisibleTileIndicesBuffer: pathDispatch.tileSlotVisibleTileIndicesBuffer,
                                                         outputBuffer: pathDispatch.outputBuffer)
                }
            }
            MetalDebugComputePass.end(commandBuffer: commandBuffer, encoder: encoder)
        }

        guard hasRoadRecords else {
            return
        }

        // Encoder 2: glyph placement for all records of the frame.
        roadPlacementCalculator.run(commandBuffer: commandBuffer,
                                    screenScale: frameContext.screenScale,
                                    dispatches: placementDispatches)

        frameContext.sharedState.roadLabelState.drawLabels = drawBatches
        frameContext.sharedState.roadLabelState.placementBuffer = drawBatches.first?.placementBuffer
        frameContext.sharedState.roadLabelState.glyphInputBuffer = drawBatches.first?.glyphInputBuffer
        frameContext.sharedState.roadLabelState.runtimeMetaBuffer = drawBatches.first?.runtimeMetaBuffer
    }

    func encode(layer _: RenderLayer, encoder _: MTLRenderCommandEncoder, frameContext _: FrameContext) {}

    // The frame's command buffer is committed - the encoded placement compute
    // is guaranteed to execute, so the data stamps can be committed.
    func frameCommitted() {
        for pending in pendingPlacementStamps {
            pending.record.markPlacementEncoded(slot: pending.slot)
        }
        pendingPlacementStamps.removeAll(keepingCapacity: true)
    }

    func handleMemoryWarning() {
        reset()
    }

    func evict() {
        reset()
    }

    private func reset() {
        baseLabelCache.reset()
        roadLabelCache?.evict()
        baseFade.reset()
        roadFade.reset()
        roadDrawLabels.removeAll(keepingCapacity: false)
        latestRoadLabelNearCameraCullCounts = (path: 0, anchor: 0)
        roadPlacementDataPending = false
        pendingPlacementStamps.removeAll(keepingCapacity: false)
        sourceEntriesVersionTracker.invalidate()
        projectionVersionTracker.invalidate()
        projectedCameraFingerprint = nil
        solvedCameraFingerprint = nil
        solvedPixelsPerPoint = 0
        baseScreenPoints.removeAll(keepingCapacity: false)
        baseHorizonVisible.removeAll(keepingCapacity: false)
        baseCenters.removeAll(keepingCapacity: false)
        baseHalfSizesPx.removeAll(keepingCapacity: false)
        baseGroupIds.removeAll(keepingCapacity: false)
        baseReservesSpace.removeAll(keepingCapacity: false)
        baseCollisionVisible.removeAll(keepingCapacity: false)
        baseTargetVisible.removeAll(keepingCapacity: false)
        roadCollisionVisible.removeAll(keepingCapacity: false)
        roadTargetVisible.removeAll(keepingCapacity: false)
        roadRecordActive.removeAll(keepingCapacity: false)
        roadItems.removeAll(keepingCapacity: false)
        roadBoxCenters.removeAll(keepingCapacity: false)
        roadBoxHalfSizes.removeAll(keepingCapacity: false)
        collisionSolver.rebindBase(ranks: [])
    }

    // MARK: - The working set

    /// Sizes everything index-aligned with the new base and road sets: the
    /// one place the frame path allocates, and it runs only when the tiles
    /// change.
    private func rebindWorkingSet(time: TimeInterval) {
        let inputs = baseLabelCache.presentationInputs
        let candidates = baseLabelCache.labelCollisionAABBInputs
        let count = inputs.count
        baseFade.rebind(keys: inputs.map { $0.isValid ? $0.labelKey : 0 }, time: time)
        collisionSolver.rebindBase(ranks: candidates.map(LabelCollisionRank.init(candidate:)))
        baseGroupIds = candidates.map(\.groupId)
        baseHalfSizesPx = candidates.map(\.halfSize)
        solvedPixelsPerPoint = 0
        baseScreenPoints = Array(repeating: ScreenPointOutput(position: .zero, depth: 0, visible: 0), count: count)
        baseHorizonVisible = Array(repeating: false, count: count)
        baseCenters = Array(repeating: .zero, count: count)
        baseReservesSpace = Array(repeating: false, count: count)
        baseCollisionVisible = Array(repeating: false, count: count)
        baseTargetVisible = Array(repeating: false, count: count)

        let roadCount = roadLabelCache?.instanceKeys.count ?? 0
        roadFade.rebind(keys: roadLabelCache?.instanceKeys ?? [], time: time)
        roadCollisionVisible = Array(repeating: false, count: roadCount)
        roadTargetVisible = Array(repeating: false, count: roadCount)
        roadRecordActive = Array(repeating: true, count: roadLabelCache?.orderedTileRecords.count ?? 0)
        projectedCameraFingerprint = nil
        solvedCameraFingerprint = nil
    }

    private func rescaleBaseHalfSizes(pixelsPerPoint: Float) {
        let candidates = baseLabelCache.labelCollisionAABBInputs
        let count = min(candidates.count, baseHalfSizesPx.count)
        for index in 0..<count {
            baseHalfSizesPx[index] = candidates[index].halfSize * pixelsPerPoint
        }
    }

    /// The base anchors on screen for this camera, written in place; the
    /// same array is what the label shaders read, uploaded per frame slot.
    private func projectBaseLabels(frameContext: FrameContext) {
        guard baseLabelCache.activeLabelSpanCount > 0 else {
            return
        }
        let projectionIndexState = frameContext.sharedState.tileProjectionIndexState
        tilePointScreenProjector.projectWithHorizonVisibility(snapshot: baseLabelCache.tilePointSnapshot,
                                                              frameContext: frameContext,
                                                              tileOriginData: projectionIndexState.tileOriginData,
                                                              screenPoints: &baseScreenPoints,
                                                              horizonVisibility: &baseHorizonVisible)
        for index in baseScreenPoints.indices {
            baseCenters[index] = baseScreenPoints[index].position
        }
    }

    // MARK: - Collisions

    private func solveCollisions(frameContext: FrameContext) {
        let cameraZoom = Float(frameContext.zoom)
        let candidates = baseLabelCache.labelCollisionAABBInputs
        let inputs = baseLabelCache.presentationInputs
        let alphas = baseFade.currentAlphas
        let count = min(candidates.count, min(baseScreenPoints.count, baseReservesSpace.count))
        for index in 0..<count {
            baseReservesSpace[index] = BaseLabelVisibilityResolver.reservesSpace(
                candidateEnabled: candidates[index].isEnabled,
                screenVisible: baseScreenPoints[index].visible != 0,
                horizonVisible: index < baseHorizonVisible.count && baseHorizonVisible[index],
                currentAlpha: index < alphas.count ? alphas[index] : 0,
                minCameraZoom: index < inputs.count ? inputs[index].minCameraZoom : 0,
                cameraZoom: cameraZoom)
        }

        prepareRoadInstances(frameContext: frameContext,
                             projectionIndexState: frameContext.sharedState.tileProjectionIndexState)
        for index in roadCollisionVisible.indices {
            roadCollisionVisible[index] = false
        }

        collisionSolver.solve(viewportSize: SIMD2<Float>(Float(frameContext.drawSize.width),
                                                         Float(frameContext.drawSize.height)),
                              cellSizePx: frameContext.screenScale.pixels(collisionGridCellSizePoints),
                              baseCenters: baseCenters,
                              baseHalfSizes: baseHalfSizesPx,
                              baseEnabled: baseReservesSpace,
                              baseGroupIds: baseGroupIds,
                              roadItems: roadItems,
                              roadCenters: roadBoxCenters,
                              roadHalfSizes: roadBoxHalfSizes,
                              baseVisible: &baseCollisionVisible,
                              roadVisible: &roadCollisionVisible)
    }

    private func makeVisibilityCameraFingerprint(frameContext: FrameContext) -> Int {
        var hasher = Hasher()
        let cameraState = frameContext.mapCameraState
        hasher.combine(cameraState.centerWorldMercator.x.bitPattern)
        hasher.combine(cameraState.centerWorldMercator.y.bitPattern)
        hasher.combine(cameraState.zoom.bitPattern)
        hasher.combine(cameraState.bearing.bitPattern)
        hasher.combine(cameraState.pitch.bitPattern)
        hasher.combine(Int(frameContext.drawSize.width.rounded()))
        hasher.combine(Int(frameContext.drawSize.height.rounded()))
        hasher.combine(frameContext.renderSurfaceMode == .flat)
        hasher.combine(frameContext.screenSpaceProjectionMode == .flat)
        // The projection also depends on the globe uniform (transition/radius/pan),
        // which can change with an unchanged camera: forced surface-mode switching
        // and live presentationSettings updates (radius also sets flatRenderMapSize).
        let globeUniform = frameContext.globeRenderUniform
        hasher.combine(globeUniform.transition.bitPattern)
        hasher.combine(globeUniform.radius.bitPattern)
        hasher.combine(globeUniform.panX.bitPattern)
        hasher.combine(globeUniform.panY.bitPattern)
        return hasher.finalize()
    }

    // Road collision boxes are read from the placement compute's GPU
    // buffers: the GPU already projects the paths, picks the orientation, and
    // writes the rotated glyph AABBs for drawing - a CPU reprojection would
    // duplicate the same work and could diverge from the actually drawn glyphs.
    // The current frame's slot is read BEFORE prepareGPU and holds data from
    // the completed frame N-slots back, a few frames of lag on the road
    // decisions. Fills `roadItems` and the road box arrays in place; an
    // instance without data this frame is not offered and stays hidden
    // until its data arrives (`roadPlacementDataPending` keeps frames
    // coming).
    private func prepareRoadInstances(frameContext: FrameContext,
                                      projectionIndexState: TileProjectionIndexState) {
        roadItems.removeAll(keepingCapacity: true)
        roadBoxCenters.removeAll(keepingCapacity: true)
        roadBoxHalfSizes.removeAll(keepingCapacity: true)
        guard let roadLabelCache,
              frameContext.renderSurfaceMode == .flat,
              roadLabelCache.orderedTileRecords.isEmpty == false else {
            latestRoadLabelNearCameraCullCounts = (path: 0, anchor: 0)
            roadPlacementDataPending = false
            for index in roadRecordActive.indices {
                roadRecordActive[index] = true
            }
            return
        }

        var nearCameraCulledPathCount = 0
        var hasRecordsAwaitingPlacementData = false
        if roadRecordActive.count != roadLabelCache.orderedTileRecords.count {
            roadRecordActive = Array(repeating: true, count: roadLabelCache.orderedTileRecords.count)
        }

        let viewportWidth = Float(frameContext.drawSize.width)
        let viewportHeight = Float(frameContext.drawSize.height)
        let slot = frameContext.frameSlotIndex

        for (recordIndex, record) in roadLabelCache.orderedTileRecords.enumerated() {
            let tileClipCorners = projectRoadRecordTileCorners(record: record,
                                                               frameContext: frameContext,
                                                               projectionIndexState: projectionIndexState)
            guard RoadLabelNearCameraFilter.shouldKeepTile(clipCorners: tileClipCorners,
                                                           viewportWidth: viewportWidth,
                                                           viewportHeight: viewportHeight,
                                                           screenScale: frameContext.screenScale,
                                                           underzoomLevels: max(0, frameContext.visibleContent.tileZoomLevel - record.ownerKey.z)) else {
                nearCameraCulledPathCount += record.entries.count
                roadRecordActive[recordIndex] = false
                // prepareGPU will stop encoding this record's compute and the
                // buffers will freeze - reset the stamps so that after the
                // record returns we don't read arbitrarily stale positions.
                record.invalidatePlacementData()
                continue
            }

            // Record activity drives the GPU compute in prepareGPU and does not
            // depend on readback - otherwise a new record would never receive
            // any data.
            roadRecordActive[recordIndex] = true

            guard record.canEncodePlacements else {
                continue
            }
            guard record.hasPlacementData(slot: slot) else {
                hasRecordsAwaitingPlacementData = true
                continue
            }

            let placementsBuffer = record.placementBuffer(slot: slot)
            let collisionAabbBuffer = record.collisionAabbBuffer(slot: slot)
            let placements = UnsafeBufferPointer(start: placementsBuffer.contents()
                                                     .assumingMemoryBound(to: RoadGlyphPlacementOutput.self),
                                                 count: record.glyphCount)
            let collisionAabbs = UnsafeBufferPointer(start: collisionAabbBuffer.contents()
                                                         .assumingMemoryBound(to: RoadGlyphCollisionOutput.self),
                                                     count: record.glyphCount)

            for localIndex in record.instanceKeys.indices {
                let instanceKey = record.instanceKeys[localIndex]
                let secondaryPriority = record.instanceSourcePriorities[localIndex] * 1024
                    + Int(record.instanceAnchorOrdinals[localIndex])
                let boxStart = roadBoxCenters.count
                guard Self.appendRoadInstanceBoxes(glyphRange: record.instanceGlyphRanges[localIndex],
                                                   placements: placements,
                                                   collisionAabbs: collisionAabbs,
                                                   maxGlyphTurnRadians: maxGlyphTurnRadians,
                                                   centers: &roadBoxCenters,
                                                   halfSizes: &roadBoxHalfSizes) else {
                    roadBoxCenters.removeSubrange(boxStart...)
                    roadBoxHalfSizes.removeSubrange(boxStart...)
                    continue
                }
                roadItems.append(LabelCollisionRoadItem(
                    rank: LabelCollisionRank(priority: roadPriorityBase,
                                             secondaryPriority: secondaryPriority,
                                             sortPriority: Int(record.instanceAnchorOrdinals[localIndex]),
                                             stableOrderKey: instanceKey),
                    groupId: instanceKey,
                    boxRange: boxStart..<roadBoxCenters.count,
                    targetIndex: record.instanceStart + localIndex))
            }
        }

        latestRoadLabelNearCameraCullCounts = (path: nearCameraCulledPathCount, anchor: 0)
        roadPlacementDataPending = hasRecordsAwaitingPlacementData
    }

    /// Appends the glyph boxes of one road instance from the GPU's per-glyph
    /// outputs. Returns false when the instance gets no decision: an
    /// invisible glyph (path behind the camera / shorter than the label), a
    /// glyph extrapolated beyond the path ends, or exceeding the turn between
    /// adjacent glyphs (maxGlyphTurnRadians).
    static func appendRoadInstanceBoxes(glyphRange: Range<Int>,
                                        placements: UnsafeBufferPointer<RoadGlyphPlacementOutput>,
                                        collisionAabbs: UnsafeBufferPointer<RoadGlyphCollisionOutput>,
                                        maxGlyphTurnRadians: Float,
                                        centers: inout [SIMD2<Float>],
                                        halfSizes: inout [SIMD2<Float>]) -> Bool {
        guard glyphRange.isEmpty == false,
              glyphRange.lowerBound >= 0,
              glyphRange.upperBound <= placements.count,
              glyphRange.upperBound <= collisionAabbs.count else {
            return false
        }
        var previousAngle: Float?
        for glyphIndex in glyphRange {
            let placement = placements[glyphIndex]
            guard placement.visible != 0,
                  placement.extrapolated == 0 else {
                return false
            }
            if let previousAngle,
               abs(Self.normalizedAngleDelta(lhs: previousAngle, rhs: placement.angle)) > maxGlyphTurnRadians {
                return false
            }
            previousAngle = placement.angle
            centers.append(placement.position)
            halfSizes.append(collisionAabbs[glyphIndex].halfSizeAABB)
        }
        return true
    }

    // Instance candidates from the GPU's per-glyph outputs. nil - no decision
    // is made for the instance: an invisible glyph (path behind the camera /
    // shorter than the label), a glyph extrapolated beyond the path ends, or
    // exceeding the turn between adjacent glyphs (maxGlyphTurnRadians) - the
    // same rules as the old CPU path, but using the angles of the actually
    // drawn glyphs.
    static func makeRoadInstanceCandidates(instanceKey: UInt64,
                                           secondaryPriority: Int,
                                           anchorOrdinal: UInt32,
                                           glyphRange: Range<Int>,
                                           placements: UnsafeBufferPointer<RoadGlyphPlacementOutput>,
                                           collisionAabbs: UnsafeBufferPointer<RoadGlyphCollisionOutput>,
                                           roadPriorityBase: Int,
                                           maxGlyphTurnRadians: Float) -> [ScreenCollisionCandidate]? {
        guard glyphRange.isEmpty == false,
              glyphRange.lowerBound >= 0,
              glyphRange.upperBound <= placements.count,
              glyphRange.upperBound <= collisionAabbs.count else {
            return nil
        }

        var collisionCandidates: [ScreenCollisionCandidate] = []
        collisionCandidates.reserveCapacity(glyphRange.count)
        var previousAngle: Float?
        for glyphIndex in glyphRange {
            let placement = placements[glyphIndex]
            guard placement.visible != 0,
                  placement.extrapolated == 0 else {
                return nil
            }
            if let previousAngle,
               abs(Self.normalizedAngleDelta(lhs: previousAngle, rhs: placement.angle)) > maxGlyphTurnRadians {
                return nil
            }
            previousAngle = placement.angle
            collisionCandidates.append(ScreenCollisionCandidate(position: placement.position,
                                                                halfSize: collisionAabbs[glyphIndex].halfSizeAABB,
                                                                priority: roadPriorityBase,
                                                                secondaryPriority: secondaryPriority,
                                                                sortPriority: Int(anchorOrdinal),
                                                                stableOrderKey: instanceKey,
                                                                groupId: instanceKey,
                                                                isEnabled: true))
        }
        return collisionCandidates
    }

    private static func normalizedAngleDelta(lhs: Float, rhs: Float) -> Float {
        var delta = rhs - lhs
        while delta > .pi {
            delta -= 2 * .pi
        }
        while delta < -.pi {
            delta += 2 * .pi
        }
        return delta
    }

    private func appendRoadRecordInstanceIndices(record: RoadLabelTileRecord,
                                                 into indices: inout [Int]) {
        guard record.instanceKeys.isEmpty == false else {
            return
        }

        indices.append(contentsOf: record.instanceStart..<(record.instanceStart + record.instanceKeys.count))
    }

    private func projectRoadRecordTileCorners(record: RoadLabelTileRecord,
                                              frameContext: FrameContext,
                                              projectionIndexState: TileProjectionIndexState) -> [SIMD4<Float>] {
        let snapshot = TilePointToScreenPointSnapshot(pointInputs: RoadLabelNearCameraFilter.makeTileCornerInputs(tile: record.ownerKey),
                                                      tileSlotVisibleTileIndices: [record.visibleTileIndex])
        return tilePointScreenProjector.projectFlatClipSpacePoints(snapshot: snapshot,
                                                                   frameContext: frameContext,
                                                                   tileOriginData: projectionIndexState.tileOriginData)
    }

    // MARK: - Road label state

    private func buildRoadLabelState(frameContext: FrameContext) -> RoadLabelState {
        guard let roadLabelCache,
              frameContext.renderSurfaceMode == .flat,
              roadLabelCache.instanceKeys.isEmpty == false else {
            return .empty
        }

        let instanceCount = roadLabelCache.instanceKeys.count
        if roadTargetVisible.count != instanceCount {
            roadTargetVisible = Array(repeating: false, count: instanceCount)
        }
        for index in 0..<instanceCount {
            roadTargetVisible[index] = index < roadCollisionVisible.count && roadCollisionVisible[index]
        }
        let hasActiveAnimations = roadFade.advance(targetVisibility: roadTargetVisible,
                                                   time: frameContext.time,
                                                   fadeInSeconds: fadeInSeconds,
                                                   fadeOutSeconds: fadeOutSeconds)
        let fadeAlphas = roadFade.currentAlphas

        let frameSlotIndex = frameContext.frameSlotIndex
        let activeRoadLabelTiles = makeActiveRoadLabelTiles(records: roadLabelCache.orderedTileRecords)
        roadRuntimeMetaScratch.removeAll(keepingCapacity: true)
        roadRuntimeMetaScratch.reserveCapacity(instanceCount)
        var drawBatches: [DrawRoadLabels] = []
        drawBatches.reserveCapacity(roadLabelCache.orderedTileRecords.count)
        var totalGlyphCount = 0
        var hasVisibleRoadLabels = false

        for record in roadLabelCache.orderedTileRecords {
            let start = record.instanceStart
            let end = start + record.instanceKeys.count
            roadRecordMetaScratch.removeAll(keepingCapacity: true)
            for index in start..<end {
                let alpha = index < fadeAlphas.count ? fadeAlphas[index] : 0
                if alpha > 0.0001 {
                    hasVisibleRoadLabels = true
                }
                let meta = LabelRuntimeMeta(duplicate: 0,
                                            isRetained: roadLabelCache.instanceRetainedFlags[index],
                                            visibleTileIndex: 0,
                                            fadeAlpha: alpha,
                                            labelSizePoints: roadLabelCache.instanceLabelSizes[index])
                roadRecordMetaScratch.append(meta)
                roadRuntimeMetaScratch.append(meta)
            }
            let runtimeMetaBuffer = record.runtimeMetaBuffer(slot: frameSlotIndex, meta: roadRecordMetaScratch)
            drawBatches.append(DrawRoadLabels(placementBuffer: nil,
                                              glyphInputBuffer: record.glyphInputsBuffer,
                                              runtimeMetaBuffer: runtimeMetaBuffer,
                                              localGlyphVertices: record.localGlyphVertices,
                                              glyphCount: record.glyphCount,
                                              labelStyle: record.labelStyle))
            totalGlyphCount += record.glyphCount
        }

        guard hasActiveAnimations || hasVisibleRoadLabels else {
            roadDrawLabels = []
            return .empty
        }

        let runtimeMetaBuffer = roadRuntimeMetaBufferStore.ensureCapacity(slot: frameSlotIndex,
                                                                          count: max(1, roadRuntimeMetaScratch.count))
        upload(values: roadRuntimeMetaScratch, into: runtimeMetaBuffer)
        roadDrawLabels = drawBatches
        return RoadLabelState(instanceCount: instanceCount,
                              glyphCount: totalGlyphCount,
                              activeRoadLabelTiles: activeRoadLabelTiles,
                              runtimeMetaBuffer: runtimeMetaBuffer,
                              placementBuffer: nil,
                              glyphInputBuffer: drawBatches.first?.glyphInputBuffer,
                              drawLabels: drawBatches,
                              hasActiveFadeAnimations: hasActiveAnimations)
    }

    private func makeActiveRoadLabelTiles(records: [RoadLabelTileRecord]) -> [VisibleTile] {
        guard records.isEmpty == false else {
            return []
        }
        guard roadRecordActive.count == records.count else {
            return records.map(\.ownerKey)
        }
        return records.enumerated().compactMap { index, record in
            roadRecordActive[index] ? record.ownerKey : nil
        }
    }

    private func upload<T>(values: [T], into buffer: MTLBuffer) {
        guard values.isEmpty == false else {
            return
        }
        values.withUnsafeBytes { bytes in
            buffer.contents().copyMemory(from: bytes.baseAddress!,
                                         byteCount: values.count * MemoryLayout<T>.stride)
        }
    }

    private func copy<T>(values: [T], into buffer: MTLBuffer) {
        guard values.isEmpty == false else {
            return
        }
        values.withUnsafeBytes { bytes in
            buffer.contents().copyMemory(from: bytes.baseAddress!,
                                         byteCount: values.count * MemoryLayout<T>.stride)
        }
    }

    private func upload(screenPoints: [ScreenPointOutput],
                        into buffer: MTLBuffer,
                        expectedCount: Int) {
        if screenPoints.isEmpty {
            writeDefaultScreenPoint(into: buffer)
            return
        }

        screenPoints.withUnsafeBytes { bytes in
            buffer.contents().copyMemory(from: bytes.baseAddress!,
                                         byteCount: screenPoints.count * MemoryLayout<ScreenPointOutput>.stride)
        }

        let missingCount = max(0, expectedCount - screenPoints.count)
        if missingCount > 0 {
            let byteOffset = screenPoints.count * MemoryLayout<ScreenPointOutput>.stride
            buffer.contents().advanced(by: byteOffset).initializeMemory(as: UInt8.self,
                                                                        repeating: 0,
                                                                        count: missingCount * MemoryLayout<ScreenPointOutput>.stride)
        }
    }

    private func writeDefaultScreenPoint(into buffer: MTLBuffer) {
        var point = ScreenPointOutput(position: .zero, depth: 0, visible: 0, visibilityAlpha: 0.0)
        withUnsafeBytes(of: &point) { bytes in
            buffer.contents().copyMemory(from: bytes.baseAddress!,
                                         byteCount: MemoryLayout<ScreenPointOutput>.stride)
        }
    }

    // MARK: - Publication

    private func publishBaseLabelState(frameContext: FrameContext,
                                       hasActiveFadeAnimations: Bool,
                                       needsFollowUpFrame: Bool) {
        let count = baseLabelCache.activeLabelSpanCount
        var screenPositionsBuffer: MTLBuffer?
        if count > 0 {
            let buffer = screenPositionsBufferStore.ensureCapacity(slot: frameContext.frameSlotIndex, count: count)
            upload(screenPoints: baseScreenPoints, into: buffer, expectedCount: count)
            screenPositionsBuffer = buffer
        }
        frameContext.sharedState.baseLabelState.labelInputsCount = baseLabelCache.labelInputsCount
        frameContext.sharedState.baseLabelState.activeLabelSpanCount = count
        frameContext.sharedState.baseLabelState.labelRuntimeMetaBuffer = baseLabelCache.labelRuntimeMetaBuffer(frameSlotIndex: frameContext.frameSlotIndex)
        frameContext.sharedState.baseLabelState.screenPositionsBuffer = screenPositionsBuffer
        frameContext.sharedState.baseLabelState.baseLabelsDrawBatches = baseLabelCache.baseLabelsDrawBatches
        frameContext.sharedState.baseLabelState.hasActiveFadeAnimations = hasActiveFadeAnimations
        frameContext.sharedState.baseLabelState.hasActiveVisibilityCycle = needsFollowUpFrame
    }

    /// Label frames for the debug overlay: collision AABBs with the frame's
    /// screen positions. Hidden ones (by collision, label horizon, fade)
    /// are included alongside visible ones: the overlay's point is to show
    /// everything participating in the frame. Beyond the projection horizon the
    /// point is invalid and there is no frame. Labels below their minCameraZoom
    /// are skipped: collision doesn't consider them, and red must mean "lost
    /// the collision", not "hasn't grown to the zoom yet". Base and road frames
    /// are enabled by separate toggles.
    private func makeDebugBoxesState(cameraZoom: Float,
                                     screenScale: ScreenScale) -> BaseLabelDebugBoxesState {
        guard let controls = debugOverlayControls?.snapshot(),
              controls.baseLabelBoundsEnabled || controls.roadLabelBoundsEnabled else {
            return .empty
        }

        var boxes: [BaseLabelDebugBox] = []
        if controls.baseLabelBoundsEnabled {
            let candidates = baseLabelCache.labelCollisionAABBInputs
            let presentationInputs = baseLabelCache.presentationInputs
            let alphas = baseFade.currentAlphas
            let count = min(candidates.count, baseScreenPoints.count)
            boxes.reserveCapacity(count)

            for index in 0..<count {
                let candidate = candidates[index]
                let screenPoint = baseScreenPoints[index]
                guard candidate.isEnabled, screenPoint.visible != 0 else {
                    continue
                }
                if index < presentationInputs.count,
                   presentationInputs[index].minCameraZoom > cameraZoom {
                    continue
                }
                let alpha = index < alphas.count ? alphas[index] : 0.0
                boxes.append(BaseLabelDebugBox(center: screenPoint.position,
                                               halfSize: screenScale.pixels(candidate.halfSize),
                                               isVisible: alpha > 0.01))
            }
        }

        // Road frames: per-glyph AABBs of the instances offered to the last
        // solve, visibility from that solve's decision.
        var roadBoxes: [BaseLabelDebugBox] = []
        if controls.roadLabelBoundsEnabled {
            for item in roadItems {
                let isVisible = item.targetIndex < roadCollisionVisible.count && roadCollisionVisible[item.targetIndex]
                for boxIndex in item.boxRange where boxIndex < roadBoxCenters.count {
                    roadBoxes.append(BaseLabelDebugBox(center: roadBoxCenters[boxIndex],
                                                       halfSize: roadBoxHalfSizes[boxIndex],
                                                       isVisible: isVisible))
                }
            }
        }
        return BaseLabelDebugBoxesState(boxes: boxes, roadBoxes: roadBoxes)
    }

    private func resolveTileOriginDataBuffer(frameContext: FrameContext) -> MTLBuffer? {
        if let buffer = frameContext.sharedState.tileProjectionIndexState.tileOriginDataBuffer {
            return buffer
        }

        let tileOriginData = frameContext.sharedState.tileProjectionIndexState.tileOriginData
        guard tileOriginData.isEmpty == false else {
            return nil
        }

        let buffer = fallbackTileOriginDataBufferStore.ensureCapacity(slot: frameContext.frameSlotIndex,
                                                                      count: max(1, tileOriginData.count))
        tileOriginData.withUnsafeBytes { bytes in
            buffer.contents().copyMemory(from: bytes.baseAddress!,
                                         byteCount: tileOriginData.count * MemoryLayout<FlatTileOriginData>.stride)
        }
        return buffer
    }

    // MARK: - Trace

    private func recordBaseLabelTraceFrame(frameContext: FrameContext,
                                           sourceTileCount: Int,
                                           trackedTilesChanged: Bool,
                                           projectionChanged: Bool,
                                           overviewFadeAlpha: Float) {
        let inputs = baseLabelCache.presentationInputs
        let fadeAlphas = baseFade.currentAlphas
        var validLabelCount = 0
        var duplicateLabelCount = 0
        var retainedLabelCount = 0
        var collisionVisibleCount = 0
        var collisionHiddenCount = 0
        var targetVisibleCount = 0
        var horizonVisibleCount = 0
        var fadeVisibleCount = 0
        var fadeAnimatingCount = 0

        for index in inputs.indices {
            let input = inputs[index]
            if input.isValid {
                validLabelCount += 1
            }
            if input.duplicate != 0 {
                duplicateLabelCount += 1
            }
            if input.isRetained != 0 {
                retainedLabelCount += 1
            }
            if index < baseCollisionVisible.count, baseCollisionVisible[index] {
                collisionVisibleCount += 1
            } else {
                collisionHiddenCount += 1
            }
            if index < baseTargetVisible.count, baseTargetVisible[index] {
                targetVisibleCount += 1
            }
            if index < baseHorizonVisible.count, baseHorizonVisible[index] {
                horizonVisibleCount += 1
            }

            let fadeAlpha = Self.traceFadeAlpha(index: index,
                                                fadeAlphas: fadeAlphas,
                                                overviewFadeAlpha: overviewFadeAlpha)
            if fadeAlpha > BaseLabelVisibilityResolver.activeAlphaThreshold {
                fadeVisibleCount += 1
            }
            if fadeAlpha > BaseLabelVisibilityResolver.activeAlphaThreshold,
               fadeAlpha < 0.9999 {
                fadeAnimatingCount += 1
            }
        }

        let hotBuckets = Self.makeBaseLabelTraceHotBuckets(inputs: inputs,
                                                           screenPoints: baseScreenPoints,
                                                           collisionVisibility: baseCollisionVisible,
                                                           targetVisibility: baseTargetVisible,
                                                           maxBucketCount: baseLabelTraceRecorder.options.maxHotBuckets)
        let includeFullLabels = baseLabelTraceRecorder.options.shouldIncludeFullLabels(
            frameIndex: frameContext.frameIndex,
            baseTrackedTilesChanged: trackedTilesChanged,
            projectionChanged: projectionChanged,
            maxHotBucketCount: hotBuckets.maxBucketCount
        )
        let labels = includeFullLabels ? Self.makeBaseLabelTraceLabels(inputs: inputs,
                                                                       screenPoints: baseScreenPoints,
                                                                       collisionVisibility: baseCollisionVisible,
                                                                       targetVisibility: baseTargetVisible,
                                                                       horizonVisibility: baseHorizonVisible,
                                                                       fadeAlphas: fadeAlphas,
                                                                       overviewFadeAlpha: overviewFadeAlpha,
                                                                       collisionCandidates: baseLabelCache.labelCollisionAABBInputs,
                                                                       screenScale: frameContext.screenScale) : nil
        baseLabelTraceRecorder.record(.baseLabelFrame(frameIndex: frameContext.frameIndex,
                                                      zoom: frameContext.zoom,
                                                      pitchDegrees: Double(frameContext.mapCameraState.pitch) * 180.0 / .pi,
                                                      bearingDegrees: Double(frameContext.mapCameraState.bearing) * 180.0 / .pi,
                                                      sourceTileCount: sourceTileCount,
                                                      baseTrackedTilesChanged: trackedTilesChanged,
                                                      roadTrackedTilesChanged: trackedTilesChanged,
                                                      projectionChanged: projectionChanged,
                                                      activeLabelSpanCount: baseLabelCache.activeLabelSpanCount,
                                                      labelInputsCount: baseLabelCache.labelInputsCount,
                                                      validLabelCount: validLabelCount,
                                                      duplicateLabelCount: duplicateLabelCount,
                                                      retainedLabelCount: retainedLabelCount,
                                                      collisionVisibleCount: collisionVisibleCount,
                                                      collisionHiddenCount: collisionHiddenCount,
                                                      collisionUnknownCount: 0,
                                                      targetVisibleCount: targetVisibleCount,
                                                      horizonVisibleCount: horizonVisibleCount,
                                                      fadeVisibleCount: fadeVisibleCount,
                                                      fadeAnimatingCount: fadeAnimatingCount,
                                                      labels: labels,
                                                      hotBuckets: hotBuckets.description,
                                                      maxHotBucketCount: hotBuckets.maxBucketCount,
                                                      droppedEventCount: baseLabelTraceRecorder.currentDroppedEventCount))
    }

    /// The cache holds collision boxes in layout points while the positions
    /// beside them are device pixels, so the trace converts: a reader comparing
    /// a box against a position has to be looking at one space.
    private static func makeBaseLabelTraceLabels(inputs: [BaseLabelPresentationInput],
                                                 screenPoints: [ScreenPointOutput],
                                                 collisionVisibility: [Bool],
                                                 targetVisibility: [Bool],
                                                 horizonVisibility: [Bool],
                                                 fadeAlphas: [Float],
                                                 overviewFadeAlpha: Float,
                                                 collisionCandidates: [ScreenCollisionCandidate],
                                                 screenScale: ScreenScale) -> String {
        guard inputs.isEmpty == false else {
            return ""
        }

        var labels: [String] = []
        labels.reserveCapacity(inputs.count)
        for index in inputs.indices {
            let input = inputs[index]
            let point = index < screenPoints.count ? screenPoints[index] : nil
            let candidate = index < collisionCandidates.count ? collisionCandidates[index] : nil
            let visibility = index < collisionVisibility.count && collisionVisibility[index]
            let targetVisible = index < targetVisibility.count && targetVisibility[index]
            let horizonVisible = index < horizonVisibility.count && horizonVisibility[index]
            let fadeAlpha = traceFadeAlpha(index: index,
                                           fadeAlphas: fadeAlphas,
                                           overviewFadeAlpha: overviewFadeAlpha)
            let position = point?.position ?? .zero
            let halfSize = screenScale.pixels(candidate?.halfSize ?? .zero)
            let screenVisible = point?.visible != 0
            let priority = candidate?.priority ?? Int.max
            let secondaryPriority = candidate?.secondaryPriority ?? Int.max

            labels.append("\(index)|\(input.labelKey)|v=\(input.isValid ? 1 : 0)|d=\(input.duplicate)|r=\(input.isRetained)|cv=\(visibility ? "visible" : "hidden")|t=\(targetVisible ? 1 : 0)|hz=\(horizonVisible ? 1 : 0)|a=\(formatTraceFloat(fadeAlpha))|x=\(formatTraceFloat(position.x))|y=\(formatTraceFloat(position.y))|sv=\(screenVisible ? 1 : 0)|p=\(priority)|sp=\(secondaryPriority)|hw=\(formatTraceFloat(halfSize.x))|hh=\(formatTraceFloat(halfSize.y))")
        }
        return labels.joined(separator: ";")
    }

    private static func makeBaseLabelTraceHotBuckets(inputs: [BaseLabelPresentationInput],
                                                     screenPoints: [ScreenPointOutput],
                                                     collisionVisibility: [Bool],
                                                     targetVisibility: [Bool],
                                                     maxBucketCount: Int) -> BaseLabelTraceHotBucketSummary {
        let cellSize: Float = 64
        var buckets: [String: BaseLabelTraceBucket] = [:]
        for index in inputs.indices {
            guard inputs[index].isValid,
                  index < screenPoints.count else {
                continue
            }

            let point = screenPoints[index]
            guard point.visible != 0 else {
                continue
            }

            let bucketKey = "\(Int(floor(point.position.x / cellSize)))/\(Int(floor(point.position.y / cellSize)))"
            var bucket = buckets[bucketKey] ?? BaseLabelTraceBucket()
            bucket.total += 1
            if index < targetVisibility.count, targetVisibility[index] {
                bucket.targetVisible += 1
            }
            if index < collisionVisibility.count, collisionVisibility[index] {
                bucket.collisionVisible += 1
            }
            buckets[bucketKey] = bucket
        }

        var largestBucketCount = 0
        let description = buckets
            .sorted { lhs, rhs in
                if lhs.value.total != rhs.value.total {
                    return lhs.value.total > rhs.value.total
                }
                return lhs.key < rhs.key
            }
            .prefix(max(0, maxBucketCount))
            .map { key, bucket in
                largestBucketCount = max(largestBucketCount, bucket.total)
                return "\(key):\(bucket.total)/\(bucket.targetVisible)/\(bucket.collisionVisible)"
            }
            .joined(separator: ";")
        return BaseLabelTraceHotBucketSummary(description: description,
                                              maxBucketCount: largestBucketCount)
    }

    private static func traceFadeAlpha(index: Int,
                                       fadeAlphas: [Float],
                                       overviewFadeAlpha: Float) -> Float {
        guard index < fadeAlphas.count else {
            return 0
        }
        return fadeAlphas[index] * overviewFadeAlpha
    }

    private static func formatTraceFloat(_ value: Float) -> String {
        String(format: "%.2f", locale: traceLocale, Double(value))
    }

}

private struct BaseLabelTraceBucket {
    var total: Int = 0
    var targetVisible: Int = 0
    var collisionVisible: Int = 0
}

private struct BaseLabelTraceHotBucketSummary {
    let description: String
    let maxBucketCount: Int
}
