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
/// The working set (the labels of the frame's tiles) is packed when the
/// tiles change and reused since: the base labels as one span in tile
/// order (`BaseLabelCache`), the road label instances as another
/// (`RoadLabelCache`), and the per-label state of a tile that stays is
/// carried by copying its run. A frame with a moving camera projects the
/// base labels' anchors, lays the road glyphs along their roads
/// (`RoadLabelPlacer`), solves the collisions of base labels and road
/// instances together in one pass (`LabelCollisionSolver`), the copies of
/// one feature that several tiles brought left out of it but one
/// (`BaseLabelCache.labelCopyOf`), advances the fades in place and writes the
/// runtime meta, the screen positions and the glyph placements the label
/// shaders read. A frame with a still camera and no fade in flight does
/// none of that. Nothing is asked of the GPU: the decision for a pose is
/// made in the frame that renders the pose, from the numbers that frame
/// draws.
final class BaseLabelPrepareSubsystem: RenderSubsystem {
    let name: String = "BaseLabels"
    private static let traceLocale = Locale(identifier: "en_US_POSIX")

    private let baseLabelCache: BaseLabelCache
    private let roadLabelCache: RoadLabelCache?
    private let baseLabelTraceRecorder: BaseLabelTraceRecorder
    private let tilePointScreenProjector = TilePointScreenProjector()
    private let collisionSolver = LabelCollisionSolver()
    private let baseFade = BaseLabelFadeState()
    private let roadFade = BaseLabelFadeState()
    /// The labels the frame works on (`LabelActiveSpans`): each tile's
    /// labels its zoom shows, and the ones still fading out.
    private var activeSpans = LabelActiveSpans()
    /// `BaseSettings.localDetailMaximumDistanceMeters`, which the debug
    /// panel overrides while it runs.
    private let localDetailMaximumDistanceMeters: Float
    /// The distance scale the labels were last projected and placed with.
    private var projectedMaximumDistanceScale: Float?
    /// The distance the local detail was last resolved for.
    private var resolvedLocalDetailDistance: Float?
    private let screenPositionsBufferStore: FrameSlottedDynamicMetalBuffer<ScreenPointOutput>
    private let roadRuntimeMetaBufferStore: FrameSlottedDynamicMetalBuffer<LabelRuntimeMeta>
    private let fadeInSeconds: TimeInterval
    private let fadeOutSeconds: TimeInterval
    private let maxGlyphTurnRadians: Float
    private let collisionGridCellSizePoints: Float
    /// Half of `collisionSpacingPoints`: what every base label's collision
    /// box grows by on each side, so two kept labels never touch.
    private let collisionMarginPoints: Float
    /// `BaseSettings.perspectiveMinimumScale`, clamped to 0...1, which the
    /// debug panel overrides while it runs.
    private let perspectiveMinimumScale: Float
    /// The floor the base labels were last projected with.
    private var projectedPerspectiveMinimumScale: Float?

    private var sourceEntriesVersionTracker = StagedHashChangeTracker()
    private var projectionVersionTracker = StagedHashChangeTracker()
    private var roadDrawLabels: [DrawRoadLabels] = []
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
    /// Local detail outside the tile the camera looks at, hidden there.
    private var baseLocalSuppressed: [Bool] = []
    /// Where each label draws in the render world, see
    /// `TilePointScreenProjector`.
    private var baseAnchorPositions: [SIMD4<Float>] = []
    /// Each label's shrink for its distance, from the projection.
    private var basePerspectiveScales: [Float] = []
    private var baseCenters: [SIMD2<Float>] = []
    private var baseHalfSizesPx: [SIMD2<Float>] = []
    /// `baseHalfSizesPx` with each label shrunk for its distance, the boxes
    /// the collisions measure.
    private var baseScaledHalfSizesPx: [SIMD2<Float>] = []
    private var baseReservesSpace: [Bool] = []
    private var baseCollisionVisible: [Bool] = []
    private var baseTargetVisible: [Bool] = []

    // Index-aligned with the road instance set.
    private var roadCollisionVisible: [Bool] = []
    private var roadTargetVisible: [Bool] = []
    /// Per road tile record: whether it is near enough for its names.
    private var roadRecordActive: [Bool] = []
    /// The road instances offered to the solver this frame and their glyph
    /// boxes, flat, reused between frames.
    private var roadItems: [LabelCollisionRoadItem] = []
    private var roadBoxCenters: [SIMD2<Float>] = []
    private var roadBoxHalfSizes: [SIMD2<Float>] = []
    private var roadRuntimeMetaScratch: [LabelRuntimeMeta] = []
    private var roadRecordMetaScratch: [LabelRuntimeMeta] = []
    private var roadPlacerScratch = RoadLabelPlacer.Scratch()

    private var latestRoadLabelNearCameraCullCounts = (path: 0, anchor: 0)

    private let roadPriorityBase: Int = 1_000_000_000
    private let debugOverlayControls: DebugOverlayControlState?

    init(baseLabelCache: BaseLabelCache,
         roadLabelCache: RoadLabelCache? = nil,
         baseLabelTraceRecorder: BaseLabelTraceRecorder = BaseLabelTraceRecorder(),
         metalDevice: MTLDevice,
         settings: ImmersiveMapSettings.LabelSettings = ImmersiveMapSettings.default.labels,
         debugOverlayControls: DebugOverlayControlState? = nil) {
        self.baseLabelCache = baseLabelCache
        self.roadLabelCache = roadLabelCache
        self.baseLabelTraceRecorder = baseLabelTraceRecorder
        self.debugOverlayControls = debugOverlayControls
        self.localDetailMaximumDistanceMeters = settings.base.localDetailMaximumDistanceMeters
        self.screenPositionsBufferStore = FrameSlottedDynamicMetalBuffer(metalDevice: metalDevice,
                                                                         slotsCount: InFlightFramePool.inFlightFramesCount,
                                                                         options: [.storageModeShared])
        self.roadRuntimeMetaBufferStore = FrameSlottedDynamicMetalBuffer(metalDevice: metalDevice,
                                                                         slotsCount: InFlightFramePool.inFlightFramesCount,
                                                                         options: [.storageModeShared])
        self.fadeInSeconds = settings.base.fadeInSeconds
        self.fadeOutSeconds = settings.base.fadeOutSeconds
        self.maxGlyphTurnRadians = settings.road.maxGlyphTurnRadians
        self.collisionGridCellSizePoints = max(4.0, settings.base.gridCellSizePoints)
        self.collisionMarginPoints = max(0, settings.base.collisionSpacingPoints) * 0.5
        self.perspectiveMinimumScale = min(max(settings.base.perspectiveMinimumScale, 0), 1)
    }

    func update(frameContext: FrameContext) {
        // A slot whose ring rule draws no labels (`FlatRingRule.drawsLabels`)
        // offers none: a tile keeps its labels while any slot it fills is
        // labelled, as a tile keeps its lines.
        let unlabelledTiles = frameContext.visibleContent.unlabelledTiles
        let allPlaceTiles = frameContext.sharedState.tilePlacementState.placeTilesContext.tilePlacements
        let placeTiles = unlabelledTiles.isEmpty
            ? allPlaceTiles
            : allPlaceTiles.filter { unlabelledTiles.contains($0.placeIn) == false }
        let projectionIndexState = frameContext.sharedState.tileProjectionIndexState
        let sourceEntries = BaseLabelSourceEntry.build(from: placeTiles)
        latestCameraFingerprint = makeVisibilityCameraFingerprint(frameContext: frameContext)

        // One source set serves the base and the road label caches alike.
        let sourceTilesChanged = sourceEntriesVersionTracker.stage(BaseLabelSourceEntry.makeHash(sourceEntries))
        let projectionChanged = projectionVersionTracker.stage(Int(truncatingIfNeeded: projectionIndexState.sourceIndexVersion))
        let topologyChanged = sourceTilesChanged || projectionChanged
        if topologyChanged {
            let baseChange = baseLabelCache.synchronize(sourceEntries: sourceEntries,
                                                        tileIndexAllocator: projectionIndexState.tileIndexAllocator,
                                                        trackedTilesChanged: sourceTilesChanged,
                                                        projectionChanged: projectionChanged)
            let roadChange = roadLabelCache?.synchronize(sourceEntries: sourceEntries,
                                                         tileIndexAllocator: projectionIndexState.tileIndexAllocator,
                                                         trackedTilesChanged: sourceTilesChanged,
                                                         projectionChanged: projectionChanged)
            if let baseChange {
                rebindWorkingSet(base: baseChange, road: roadChange ?? .empty, time: frameContext.time)
            }
            projectedCameraFingerprint = nil
            solvedCameraFingerprint = nil
            if sourceTilesChanged {
                sourceEntriesVersionTracker.commitPending()
            }
            if projectionChanged {
                projectionVersionTracker.commitPending()
            }
        }

        // The labels the camera's zoom shows, and those still fading out:
        // every pass below works on them alone.
        let cameraZoom = Float(frameContext.zoom)
        baseLabelCache.presentationInputs.withUnsafeBufferPointer { inputs in
            baseFade.currentAlphas.withUnsafeBufferPointer { alphas in
                activeSpans.resolve(inputs: inputs, alphas: alphas, cameraZoom: cameraZoom)
            }
        }
        let spans = activeSpans.spans

        let minimumScale = debugOverlayControls?.labelPerspectiveMinimum() ?? perspectiveMinimumScale
        // The labels' reach is the rule's of the camera zoom
        // (`LabelDistanceRules`), the panel's or the default.
        let distanceScale = debugOverlayControls?.labelDistanceScale(forCameraZoom: frameContext.zoom)
            ?? LabelDistanceRules.default.scale(forCameraZoom: frameContext.zoom)
        let cameraChanged = projectedCameraFingerprint != latestCameraFingerprint
            || projectedPerspectiveMinimumScale != minimumScale
            || projectedMaximumDistanceScale != distanceScale
        if cameraChanged || topologyChanged {
            projectBaseLabels(frameContext: frameContext,
                              minimumScale: minimumScale,
                              distanceScale: distanceScale,
                              spans: spans)
            placeRoadLabels(frameContext: frameContext,
                            projectionIndexState: projectionIndexState,
                            distanceScale: distanceScale)
            projectedPerspectiveMinimumScale = minimumScale
            projectedMaximumDistanceScale = distanceScale
            projectedCameraFingerprint = latestCameraFingerprint
        }

        // The local detail keeps to the tiles around the look-at point and
        // to the distance from the camera, which the debug panel can move
        // with the camera still: resolved on either change.
        let localDetailDistance = debugOverlayControls?.localLabelMaximumDistance() ?? localDetailMaximumDistanceMeters
        var localDetailChanged = false
        if cameraChanged || topologyChanged || localDetailDistance != resolvedLocalDetailDistance {
            localDetailChanged = resolveLocalDetail(frameContext: frameContext,
                                                    maximumDistanceMeters: localDetailDistance,
                                                    spans: spans)
            resolvedLocalDetailDistance = localDetailDistance
        }

        let pixelsPerPoint = frameContext.screenScale.pixelsPerPoint
        if pixelsPerPoint != solvedPixelsPerPoint {
            rescaleBaseHalfSizes(pixelsPerPoint: pixelsPerPoint)
        }
        // The solve depends on the pose, the set and the fades (a label fading out keeps its space): a frame with
        // none of them changing keeps the previous decision.
        let fadesActive = frameContext.sharedState.baseLabelState.hasActiveFadeAnimations
            || frameContext.sharedState.roadLabelState.hasActiveFadeAnimations
        let needsSolve = cameraChanged || topologyChanged || fadesActive || localDetailChanged
            || solvedCameraFingerprint == nil
        if needsSolve {
            solveCollisions(frameContext: frameContext, spans: spans)
            solvedCameraFingerprint = latestCameraFingerprint
            solvedPixelsPerPoint = pixelsPerPoint
        }

        BaseLabelVisibilityResolver.targetVisibility(inputs: baseLabelCache.presentationInputs,
                                                     collisionVisible: baseCollisionVisible,
                                                     horizonVisibility: baseHorizonVisible,
                                                     localSuppressed: baseLocalSuppressed,
                                                     cameraZoom: cameraZoom,
                                                     spans: spans,
                                                     into: &baseTargetVisible)
        let baseFadesActive = baseFade.advance(targetVisibility: baseTargetVisible,
                                               time: frameContext.time,
                                               fadeInSeconds: fadeInSeconds,
                                               fadeOutSeconds: fadeOutSeconds,
                                               spans: spans)
        let overviewFadeAlpha = ImmersiveMapZoomFade.overview.alpha(atZoom: frameContext.zoom)
        baseLabelCache.updateFadeAlphas(baseFade.currentAlphas, multiplier: overviewFadeAlpha, spans: spans)
        baseFade.currentAlphas.withUnsafeBufferPointer { alphas in
            baseTargetVisible.withUnsafeBufferPointer { targets in
                activeSpans.updateLitEnds(alphas: alphas, targets: targets)
            }
        }

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
                              hasActiveFadeAnimations: baseFadesActive)

        let roadState = buildRoadLabelState(frameContext: frameContext)
        frameContext.sharedState.roadLabelState = roadState

        frameContext.services.diagnostics.setCounter(.baseLabelCount, value: baseLabelCache.labelInputsCount)
        frameContext.services.diagnostics.setCounter(.baseLabelActiveCount, value: activeSpans.count)
        frameContext.services.diagnostics.setCounter(.roadLabelGlyphCount, value: roadState.glyphCount)
        frameContext.services.diagnostics.setCounter(.roadLabelInstanceCount, value: roadState.instanceCount)
        frameContext.services.diagnostics.setCounter(.roadLabelNearCameraCulledPathCount,
                                                     value: latestRoadLabelNearCameraCullCounts.path)
        frameContext.services.diagnostics.setCounter(.roadLabelNearCameraCulledAnchorCount,
                                                     value: latestRoadLabelNearCameraCullCounts.anchor)
    }

    func prepareGPU(frameContext _: FrameContext, resourceRegistry _: RenderResourceRegistry) {}

    /// The labels are drawn by `BaseLabelDrawSubsystem`.
    func encode(layer _: RenderLayer, encoder _: MTLRenderCommandEncoder, frameContext _: FrameContext) {}

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
        activeSpans.reset()
        roadDrawLabels.removeAll(keepingCapacity: false)
        latestRoadLabelNearCameraCullCounts = (path: 0, anchor: 0)
        sourceEntriesVersionTracker.invalidate()
        projectionVersionTracker.invalidate()
        projectedCameraFingerprint = nil
        projectedPerspectiveMinimumScale = nil
        projectedMaximumDistanceScale = nil
        resolvedLocalDetailDistance = nil
        solvedCameraFingerprint = nil
        solvedPixelsPerPoint = 0
        baseScreenPoints.removeAll(keepingCapacity: false)
        baseHorizonVisible.removeAll(keepingCapacity: false)
        baseLocalSuppressed.removeAll(keepingCapacity: false)
        baseAnchorPositions.removeAll(keepingCapacity: false)
        baseCenters.removeAll(keepingCapacity: false)
        baseHalfSizesPx.removeAll(keepingCapacity: false)
        baseScaledHalfSizesPx.removeAll(keepingCapacity: false)
        basePerspectiveScales.removeAll(keepingCapacity: false)
        baseReservesSpace.removeAll(keepingCapacity: false)
        baseCollisionVisible.removeAll(keepingCapacity: false)
        baseTargetVisible.removeAll(keepingCapacity: false)
        roadCollisionVisible.removeAll(keepingCapacity: false)
        roadTargetVisible.removeAll(keepingCapacity: false)
        roadRecordActive.removeAll(keepingCapacity: false)
        roadItems.removeAll(keepingCapacity: false)
        roadBoxCenters.removeAll(keepingCapacity: false)
        roadBoxHalfSizes.removeAll(keepingCapacity: false)
        collisionSolver.rebindBase(ranks: [], order: [])
    }

    // MARK: - The working set

    /// Sizes everything index-aligned with the new base and road sets and
    /// carries the fades to their new places, the
    /// surviving tiles' by run and the swapped tiles' lit labels by key,
    /// then hands each copy's fade to the copy the set keeps: the one place
    /// the frame path allocates, and it runs only when the tiles change.
    private func rebindWorkingSet(base: LabelWorkingSetChange, road: LabelWorkingSetChange, time: TimeInterval) {
        // A feature whose tile was swapped for another in this change (a
        // zoom step, a tile boundary in a pan) keeps its fade: the lit
        // labels of the tiles that left seed the same keys in the tiles
        // that arrived. The road instances have no such case, their keys
        // hold their tile.
        let base = base.seeded(oldAlphas: baseFade.currentAlphas,
                               threshold: BaseLabelVisibilityResolver.activeAlphaThreshold)
        let count = base.count
        baseFade.rebind(change: base, time: time)
        // One feature draws once: a copy hands its fade to the kept one and
        // goes out at once, whichever of the two was showing before.
        let copyOf = baseLabelCache.labelCopyOf
        for index in baseLabelCache.copyIndices {
            baseFade.transfer(from: index, to: Int(copyOf[index]))
        }
        activeSpans.rebind(runs: baseLabelCache.tileRuns)
        collisionSolver.rebindBase(ranks: baseLabelCache.labelRanks, order: baseLabelCache.rankOrder)
        baseHalfSizesPx = baseLabelCache.labelHalfSizes.map { $0 + collisionMarginPoints }
        baseScaledHalfSizesPx = baseHalfSizesPx
        basePerspectiveScales = Array(repeating: 1, count: count)
        solvedPixelsPerPoint = 0
        baseScreenPoints = Array(repeating: ScreenPointOutput(position: .zero, depth: 0, visible: 0), count: count)
        baseHorizonVisible = Array(repeating: false, count: count)
        baseLocalSuppressed = Array(repeating: false, count: count)
        baseAnchorPositions = Array(repeating: .zero, count: count)
        baseCenters = Array(repeating: .zero, count: count)
        baseReservesSpace = Array(repeating: false, count: count)
        baseCollisionVisible = Array(repeating: false, count: count)
        baseTargetVisible = Array(repeating: false, count: count)

        roadFade.rebind(change: road, time: time)
        roadCollisionVisible = Array(repeating: false, count: road.count)
        roadTargetVisible = Array(repeating: false, count: road.count)
        roadRecordActive = Array(repeating: true, count: roadLabelCache?.orderedTileRecords.count ?? 0)
    }

    private func rescaleBaseHalfSizes(pixelsPerPoint: Float) {
        let margin = collisionMarginPoints
        let count = min(baseLabelCache.labelHalfSizes.count, baseHalfSizesPx.count)
        baseLabelCache.labelHalfSizes.withUnsafeBufferPointer { labelHalfSizes in
            baseHalfSizesPx.withUnsafeMutableBufferPointer { halfSizes in
                var index = 0
                while index < count {
                    halfSizes[index] = (labelHalfSizes[index] + margin) * pixelsPerPoint
                    index += 1
                }
            }
        }
    }

    /// The base anchors on screen for this camera, written in place; the
    /// same array is what the label shaders read, uploaded per frame slot.
    private func projectBaseLabels(frameContext: FrameContext,
                                   minimumScale: Float,
                                   distanceScale: Float,
                                   spans: [Range<Int>]) {
        guard baseLabelCache.labelInputsCount > 0 else {
            return
        }
        let projectionIndexState = frameContext.sharedState.tileProjectionIndexState
        tilePointScreenProjector.projectWithHorizonVisibility(snapshot: baseLabelCache.tilePointSnapshot,
                                                              frameContext: frameContext,
                                                              tileOriginData: projectionIndexState.tileOriginData,
                                                              minimumPerspectiveScale: minimumScale,
                                                              maximumDistanceScale: distanceScale,
                                                              spans: spans,
                                                              screenPoints: &baseScreenPoints,
                                                              horizonVisibility: &baseHorizonVisible,
                                                              perspectiveScales: &basePerspectiveScales,
                                                              anchorPositions: &baseAnchorPositions)
        let count = min(baseScreenPoints.count, baseCenters.count)
        baseScreenPoints.withUnsafeBufferPointer { points in
            baseCenters.withUnsafeMutableBufferPointer { centers in
                for span in spans {
                    var index = span.lowerBound
                    let end = min(span.upperBound, count)
                    while index < end {
                        centers[index] = points[index].position
                        index += 1
                    }
                }
            }
        }
        baseLabelCache.updatePerspectiveScales(basePerspectiveScales, spans: spans)
    }

    /// Which local labels are out of reach this frame: outside the three
    /// by three tiles around the look-at point, or farther from the camera
    /// than `maximumDistanceMeters`, measured to where the label draws. On
    /// the flat map only is the distance measured; on the globe the tiles
    /// alone decide. Returns whether any label changed.
    private func resolveLocalDetail(frameContext: FrameContext,
                                    maximumDistanceMeters: Float,
                                    spans: [Range<Int>]) -> Bool {
        var unitsPerMeter: Float?
        if frameContext.screenSpaceProjectionMode == .flat {
            let centre = frameContext.visibleContent.centerWorldMercator
            let latitude = ImmersiveMapProjection.latitude(fromNormalizedWorldY: centre.y)
            let units = ImmersiveMapProjection.worldUnitsPerMeter(latitudeRadians: latitude,
                                                                  renderMapSize: frameContext.renderNormalizationState.flatRenderMapSize)
            if units > 0, units.isFinite {
                unitsPerMeter = Float(units)
            }
        }
        let reach = BaseLabelVisibilityResolver.LocalDetailReach(eye: frameContext.cameraEye,
                                                                 unitsPerMeter: unitsPerMeter,
                                                                 maximumDistanceMeters: maximumDistanceMeters)
        return BaseLabelVisibilityResolver.localSuppression(inputs: baseLabelCache.presentationInputs,
                                                            pointInputs: baseLabelCache.tilePointInputs,
                                                            anchors: baseAnchorPositions,
                                                            centerWorldMercator: frameContext.visibleContent.centerWorldMercator,
                                                            reach: reach,
                                                            spans: spans,
                                                            into: &baseLocalSuppressed)
    }

    // MARK: - Road placement

    /// Lays every near road tile's glyphs along their roads for this
    /// camera, on the flat map. A tile too far or too flat on screen for
    /// its names (`RoadLabelNearCameraFilter`) keeps its last placement
    /// and offers nothing to the solve, so its names fade out where they
    /// were.
    private func placeRoadLabels(frameContext: FrameContext,
                                 projectionIndexState: TileProjectionIndexState,
                                 distanceScale: Float) {
        guard let roadLabelCache,
              frameContext.renderSurfaceMode == .flat,
              roadLabelCache.orderedTileRecords.isEmpty == false else {
            latestRoadLabelNearCameraCullCounts = (path: 0, anchor: 0)
            return
        }
        let records = roadLabelCache.orderedTileRecords
        if roadRecordActive.count != records.count {
            roadRecordActive = Array(repeating: true, count: records.count)
        }
        let viewportSize = SIMD2<Float>(Float(frameContext.drawSize.width), Float(frameContext.drawSize.height))
        let cameraMatrix = frameContext.cameraMatrices.projectionView
        let pixelsPerPoint = frameContext.screenScale.pixelsPerPoint
        let tileOriginData = projectionIndexState.tileOriginData
        // The reach is measured as the base labels' is: in multiples of
        // the camera's depth of the point it looks at, the world origin.
        let maximumDepth = (cameraMatrix * SIMD4<Float>(0, 0, 0, 1)).w * max(distanceScale, 0)
        var culledPathCount = 0

        for (recordIndex, record) in records.enumerated() {
            let tileClipCorners = projectRoadRecordTileCorners(record: record,
                                                               frameContext: frameContext,
                                                               tileOriginData: tileOriginData)
            guard RoadLabelNearCameraFilter.shouldKeepTile(clipCorners: tileClipCorners,
                                                           viewportWidth: viewportSize.x,
                                                           viewportHeight: viewportSize.y,
                                                           screenScale: frameContext.screenScale,
                                                           underzoomLevels: max(0, frameContext.visibleContent.tileZoomLevel - record.ownerKey.z)) else {
                culledPathCount += record.pathCount
                roadRecordActive[recordIndex] = false
                continue
            }
            roadRecordActive[recordIndex] = true
            let originIndex = Int(record.visibleTileIndex)
            guard record.glyphCount > 0, originIndex < tileOriginData.count else {
                record.placement.hideAll()
                continue
            }
            RoadLabelPlacer.place(geometry: record.geometry,
                                  origin: tileOriginData[originIndex],
                                  cameraMatrix: cameraMatrix,
                                  viewportSize: viewportSize,
                                  pixelsPerPoint: pixelsPerPoint,
                                  maximumDepth: maximumDepth,
                                  scratch: &roadPlacerScratch,
                                  output: &record.placement)
        }
        latestRoadLabelNearCameraCullCounts = (path: culledPathCount, anchor: 0)
    }

    private func projectRoadRecordTileCorners(record: RoadLabelTileRecord,
                                              frameContext: FrameContext,
                                              tileOriginData: [FlatTileOriginData]) -> [SIMD4<Float>] {
        let snapshot = TilePointToScreenPointSnapshot(pointInputs: RoadLabelNearCameraFilter.makeTileCornerInputs(tile: record.ownerKey),
                                                      tileSlotVisibleTileIndices: [record.visibleTileIndex])
        return tilePointScreenProjector.projectFlatClipSpacePoints(snapshot: snapshot,
                                                                   frameContext: frameContext,
                                                                   tileOriginData: tileOriginData)
    }

    /// The road instances for the solve from the frame's placement: an
    /// instance whose glyphs all sit on the road, none past an end, none
    /// turning too sharply against its neighbour, offered with its glyph
    /// boxes as one; the others get no decision and stay hidden.
    private func prepareRoadInstances(frameContext: FrameContext) {
        roadItems.removeAll(keepingCapacity: true)
        roadBoxCenters.removeAll(keepingCapacity: true)
        roadBoxHalfSizes.removeAll(keepingCapacity: true)
        guard let roadLabelCache,
              frameContext.renderSurfaceMode == .flat,
              roadLabelCache.orderedTileRecords.isEmpty == false else {
            return
        }
        for (recordIndex, record) in roadLabelCache.orderedTileRecords.enumerated() {
            guard recordIndex < roadRecordActive.count, roadRecordActive[recordIndex] else {
                continue
            }
            let placement = record.placement
            let glyphRanges = record.instanceGlyphRanges
            for localIndex in record.instanceKeys.indices {
                let boxStart = roadBoxCenters.count
                guard RoadLabelPlacer.appendInstanceBoxes(glyphRange: glyphRanges[localIndex],
                                                          output: placement,
                                                          maxGlyphTurnRadians: maxGlyphTurnRadians,
                                                          centers: &roadBoxCenters,
                                                          halfSizes: &roadBoxHalfSizes) else {
                    continue
                }
                let instanceKey = record.instanceKeys[localIndex]
                let anchorOrdinal = Int(record.instanceAnchorOrdinals[localIndex])
                roadItems.append(LabelCollisionRoadItem(
                    rank: LabelCollisionRank(priority: roadPriorityBase,
                                             secondaryPriority: record.instanceSourcePriorities[localIndex] * 1024 + anchorOrdinal,
                                             sortPriority: anchorOrdinal,
                                             tileOrder: recordIndex,
                                             stableOrderKey: instanceKey),
                    groupId: instanceKey,
                    boxRange: boxStart..<roadBoxCenters.count,
                    targetIndex: record.instanceStart + localIndex))
            }
        }
    }

    // MARK: - Collisions

    private func solveCollisions(frameContext: FrameContext, spans: [Range<Int>]) {
        let cameraZoom = Float(frameContext.zoom)
        BaseLabelVisibilityResolver.reservesSpace(inputs: baseLabelCache.presentationInputs,
                                                  screenPoints: baseScreenPoints,
                                                  horizonVisibility: baseHorizonVisible,
                                                  localSuppressed: baseLocalSuppressed,
                                                  currentAlphas: baseFade.currentAlphas,
                                                  cameraZoom: cameraZoom,
                                                  spans: spans,
                                                  into: &baseReservesSpace)

        prepareRoadInstances(frameContext: frameContext)
        roadCollisionVisible.withUnsafeMutableBufferPointer { visible in
            visible.update(repeating: false)
        }

        // The box shrinks with the label, the spacing between two labels
        // does not: the margin is added after the scale.
        let marginPx = SIMD2<Float>(repeating: collisionMarginPoints * frameContext.screenScale.pixelsPerPoint)
        let scaledCount = min(baseHalfSizesPx.count, min(basePerspectiveScales.count, baseScaledHalfSizesPx.count))
        baseHalfSizesPx.withUnsafeBufferPointer { halfSizes in
        basePerspectiveScales.withUnsafeBufferPointer { scales in
        baseScaledHalfSizesPx.withUnsafeMutableBufferPointer { scaled in
            for span in spans {
                var index = span.lowerBound
                let end = min(span.upperBound, scaledCount)
                while index < end {
                    scaled[index] = (halfSizes[index] - marginPx) * scales[index] + marginPx
                    index += 1
                }
            }
        }}}
        collisionSolver.solve(viewportSize: SIMD2<Float>(Float(frameContext.drawSize.width),
                                                         Float(frameContext.drawSize.height)),
                              cellSizePx: frameContext.screenScale.pixels(collisionGridCellSizePoints),
                              baseCenters: baseCenters,
                              baseHalfSizes: baseScaledHalfSizesPx,
                              baseEnabled: baseReservesSpace,
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
        // The labels on the roofs rise with the buildings.
        hasher.combine(frameContext.sharedState.buildingRiseSignature.bitPattern)
        return hasher.finalize()
    }

    // MARK: - Road label state

    /// Advances the road fades and hands the frame's placements and fades
    /// to the road text shader: every record's glyph placement and
    /// instance meta into the frame's slot, one draw batch per record.
    private func buildRoadLabelState(frameContext: FrameContext) -> RoadLabelState {
        guard let roadLabelCache,
              frameContext.renderSurfaceMode == .flat,
              roadLabelCache.instanceKeys.isEmpty == false else {
            roadDrawLabels = []
            return .empty
        }

        let instanceCount = roadLabelCache.instanceKeys.count
        if roadTargetVisible.count != instanceCount {
            roadTargetVisible = Array(repeating: false, count: instanceCount)
        }
        let visibleCount = min(instanceCount, roadCollisionVisible.count)
        roadTargetVisible.withUnsafeMutableBufferPointer { target in
            roadCollisionVisible.withUnsafeBufferPointer { collision in
                var index = 0
                while index < visibleCount {
                    target[index] = collision[index]
                    index += 1
                }
                while index < instanceCount {
                    target[index] = false
                    index += 1
                }
            }
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
            let end = start + record.instanceCount
            roadRecordMetaScratch.removeAll(keepingCapacity: true)
            for index in start..<end {
                let alpha = index < fadeAlphas.count ? fadeAlphas[index] : 0
                if alpha > 0.0001 {
                    hasVisibleRoadLabels = true
                }
                let meta = LabelRuntimeMeta(fadeAlpha: alpha,
                                            perspectiveScale: 1,
                                            labelSizePoints: roadLabelCache.instanceLabelSizes[index])
                roadRecordMetaScratch.append(meta)
                roadRuntimeMetaScratch.append(meta)
            }
            totalGlyphCount += record.glyphCount
            guard record.hasRenderableGlyphs,
                  let localGlyphVertices = record.localGlyphVertices,
                  let glyphInputsBuffer = record.glyphInputsBuffer else {
                continue
            }
            drawBatches.append(DrawRoadLabels(placementBuffer: record.placementBuffer(slot: frameSlotIndex),
                                              glyphInputBuffer: glyphInputsBuffer,
                                              runtimeMetaBuffer: record.runtimeMetaBuffer(slot: frameSlotIndex,
                                                                                          meta: roadRecordMetaScratch),
                                              localGlyphVertices: localGlyphVertices,
                                              labelStyle: record.labelStyle))
        }

        guard hasActiveAnimations || hasVisibleRoadLabels else {
            roadDrawLabels = []
            return .empty
        }

        let runtimeMetaBuffer = roadRuntimeMetaBufferStore.ensureCapacity(slot: frameSlotIndex,
                                                                          count: max(1, roadRuntimeMetaScratch.count))
        roadRuntimeMetaScratch.withUnsafeBytes { bytes in
            if bytes.count > 0 {
                runtimeMetaBuffer.contents().copyMemory(from: bytes.baseAddress!, byteCount: bytes.count)
            }
        }
        roadDrawLabels = drawBatches
        return RoadLabelState(instanceCount: instanceCount,
                              glyphCount: totalGlyphCount,
                              activeRoadLabelTiles: activeRoadLabelTiles,
                              runtimeMetaBuffer: runtimeMetaBuffer,
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

    // MARK: - Publication

    private func publishBaseLabelState(frameContext: FrameContext,
                                       hasActiveFadeAnimations: Bool) {
        let count = baseLabelCache.labelInputsCount
        var screenPositionsBuffer: MTLBuffer?
        if count > 0 {
            let buffer = screenPositionsBufferStore.ensureCapacity(slot: frameContext.frameSlotIndex, count: count)
            let byteCount = min(baseScreenPoints.count, count) * MemoryLayout<ScreenPointOutput>.stride
            baseScreenPoints.withUnsafeBytes { bytes in
                if byteCount > 0 {
                    buffer.contents().copyMemory(from: bytes.baseAddress!, byteCount: byteCount)
                }
            }
            let missingBytes = count * MemoryLayout<ScreenPointOutput>.stride - byteCount
            if missingBytes > 0 {
                buffer.contents().advanced(by: byteCount).initializeMemory(as: UInt8.self, repeating: 0, count: missingBytes)
            }
            screenPositionsBuffer = buffer
        }
        frameContext.sharedState.baseLabelState.labelInputsCount = count
        frameContext.sharedState.baseLabelState.labelRuntimeMetaBuffer = baseLabelCache.labelRuntimeMetaBuffer(frameSlotIndex: frameContext.frameSlotIndex)
        frameContext.sharedState.baseLabelState.screenPositionsBuffer = screenPositionsBuffer
        frameContext.sharedState.baseLabelState.baseLabelsDrawBatches = baseLabelCache.baseLabelsDrawBatches
        frameContext.sharedState.baseLabelState.hasActiveFadeAnimations = hasActiveFadeAnimations
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
            let labelHalfSizes = baseLabelCache.labelHalfSizes
            let presentationInputs = baseLabelCache.presentationInputs
            let alphas = baseFade.currentAlphas
            let count = min(labelHalfSizes.count, baseScreenPoints.count)
            boxes.reserveCapacity(count)

            for index in 0..<count {
                let screenPoint = baseScreenPoints[index]
                guard screenPoint.visible != 0 else {
                    continue
                }
                if index < presentationInputs.count,
                   presentationInputs[index].minCameraZoom > cameraZoom {
                    continue
                }
                let alpha = index < alphas.count ? alphas[index] : 0.0
                boxes.append(BaseLabelDebugBox(center: screenPoint.position,
                                               halfSize: screenScale.pixels(labelHalfSizes[index]),
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

    // MARK: - Trace

    private func recordBaseLabelTraceFrame(frameContext: FrameContext,
                                           sourceTileCount: Int,
                                           trackedTilesChanged: Bool,
                                           projectionChanged: Bool,
                                           overviewFadeAlpha: Float) {
        let inputs = baseLabelCache.presentationInputs
        let fadeAlphas = baseFade.currentAlphas
        var copyLabelCount = 0
        let copyOf = baseLabelCache.labelCopyOf
        var collisionVisibleCount = 0
        var collisionHiddenCount = 0
        var targetVisibleCount = 0
        var horizonVisibleCount = 0
        var fadeVisibleCount = 0
        var fadeAnimatingCount = 0

        for index in inputs.indices {
            if index < copyOf.count, copyOf[index] >= 0 {
                copyLabelCount += 1
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
                                                                       copyOf: copyOf,
                                                                       targetVisibility: baseTargetVisible,
                                                                       horizonVisibility: baseHorizonVisible,
                                                                       fadeAlphas: fadeAlphas,
                                                                       overviewFadeAlpha: overviewFadeAlpha,
                                                                       halfSizes: baseLabelCache.labelHalfSizes,
                                                                       ranks: baseLabelCache.labelRanks,
                                                                       screenScale: frameContext.screenScale) : nil
        baseLabelTraceRecorder.record(.baseLabelFrame(frameIndex: frameContext.frameIndex,
                                                      zoom: frameContext.zoom,
                                                      pitchDegrees: Double(frameContext.mapCameraState.pitch) * 180.0 / .pi,
                                                      bearingDegrees: Double(frameContext.mapCameraState.bearing) * 180.0 / .pi,
                                                      sourceTileCount: sourceTileCount,
                                                      baseTrackedTilesChanged: trackedTilesChanged,
                                                      roadTrackedTilesChanged: trackedTilesChanged,
                                                      projectionChanged: projectionChanged,
                                                      activeLabelSpanCount: baseLabelCache.labelInputsCount,
                                                      labelInputsCount: baseLabelCache.labelInputsCount,
                                                      validLabelCount: inputs.count,
                                                      duplicateLabelCount: copyLabelCount,
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
                                                 copyOf: [Int32],
                                                 targetVisibility: [Bool],
                                                 horizonVisibility: [Bool],
                                                 fadeAlphas: [Float],
                                                 overviewFadeAlpha: Float,
                                                 halfSizes: [SIMD2<Float>],
                                                 ranks: [BaseLabelRank],
                                                 screenScale: ScreenScale) -> String {
        guard inputs.isEmpty == false else {
            return ""
        }

        var labels: [String] = []
        labels.reserveCapacity(inputs.count)
        for index in inputs.indices {
            let input = inputs[index]
            let point = index < screenPoints.count ? screenPoints[index] : nil
            let visibility = index < collisionVisibility.count && collisionVisibility[index]
            let duplicate = index < copyOf.count && copyOf[index] >= 0 ? 1 : 0
            let targetVisible = index < targetVisibility.count && targetVisibility[index]
            let horizonVisible = index < horizonVisibility.count && horizonVisibility[index]
            let fadeAlpha = traceFadeAlpha(index: index,
                                           fadeAlphas: fadeAlphas,
                                           overviewFadeAlpha: overviewFadeAlpha)
            let position = point?.position ?? .zero
            let halfSize = screenScale.pixels(index < halfSizes.count ? halfSizes[index] : .zero)
            let screenVisible = point?.visible != 0
            let priority = index < ranks.count ? ranks[index].priority : Int.max

            labels.append("\(index)|\(input.labelKey)|v=1|d=\(duplicate)|cv=\(visibility ? "visible" : "hidden")|t=\(targetVisible ? 1 : 0)|hz=\(horizonVisible ? 1 : 0)|a=\(formatTraceFloat(fadeAlpha))|x=\(formatTraceFloat(position.x))|y=\(formatTraceFloat(position.y))|sv=\(screenVisible ? 1 : 0)|p=\(priority)|hw=\(formatTraceFloat(halfSize.x))|hh=\(formatTraceFloat(halfSize.y))")
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
        for index in inputs.indices where index < screenPoints.count {
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
