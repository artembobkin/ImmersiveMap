// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

//
//  BaseLabelPrepareSubsystem.swift
//  ImmersiveMap
//

import Foundation
import Metal
import simd

final class BaseLabelPrepareSubsystem: RenderSubsystem {
    let name: String = "BaseLabels"
    private static let traceLocale = Locale(identifier: "en_US_POSIX")

    private let baseLabelCache: BaseLabelCache
    private let roadLabelCache: RoadLabelCache?
    private let baseLabelTraceRecorder: BaseLabelTraceRecorder
    private let tilePointScreenProjector = TilePointScreenProjector()
    private let baseScreenCompute: TilePointScreenCompute
    private let roadPathScreenCompute: TilePointScreenCompute
    private let roadPlacementCalculator: RoadLabelPlacementCalculator
    private let presentationStateStore = BaseLabelPresentationStateStore()
    private let roadPresentationStateStore = BaseLabelPresentationStateStore()
    private let roadRuntimeMetaBufferStore: FrameSlottedDynamicMetalBuffer<LabelRuntimeMeta>
    private let fallbackTileOriginDataBufferStore: FrameSlottedDynamicMetalBuffer<FlatTileOriginData>
    private let fadeInSeconds: TimeInterval
    private let fadeOutSeconds: TimeInterval
    private let maxGlyphTurnRadians: Float
    private let collisionGridCellSizePx: Float
    private let collisionsEnabled: Bool = true
    private let visibilityRefreshInterval: TimeInterval = 0.2
    private let collisionGroupBudgetPerFrame: Int = 256

    private var baseSourceEntriesVersionTracker = StagedHashChangeTracker()
    private var roadSourceEntriesVersionTracker = StagedHashChangeTracker()
    private var projectionVersionTracker = StagedHashChangeTracker()
    private var roadDrawLabels: [DrawRoadLabels] = []
    private var visibilityTopologyGeneration: UInt64 = 0
    private var latestCameraFingerprint: Int = 0
    private var publishedVisibilityCameraFingerprint: Int = 0
    private var lastVisibilityCycleEndTime: TimeInterval = -.greatestFiniteMagnitude
    private var publishedHorizonReservationSignature: [Int] = []
    private var publishedBaseCollisionVisibility: [BaseLabelCollisionVisibility] = []
    private var publishedRoadInstanceVisibility: [Bool] = []
    private var visibilityCycle: VisibilityCycle?
    private var latestRoadLabelNearCameraCullCounts = (path: 0, anchor: 0)
    private var latestActiveRoadRecordIndices: Set<Int>?
    // У части активных рекордов ещё нет GPU placement-данных (свежий тайл,
    // возврат из кулла): флаг держит кадры и рестарты цикла живыми, пока данные
    // не появятся - иначе при неподвижной камере подписи таких тайлов не
    // появились бы никогда.
    private var roadPlacementDataPending = false
    // Пары (рекорд, слот), чей placement-компьют закодирован в command buffer
    // текущего кадра; фиксируются в стампы только после commit().
    private var pendingPlacementStamps: [(record: RoadLabelTileRecord, slot: Int)] = []
    private var cachedBaseProjection: TilePointScreenProjectionResult = .empty
    private var cachedBaseProjectionFingerprint: Int?
    private var cachedBaseProjectionTopologyGeneration: UInt64 = 0
    // presentationInputs дорог - чистая функция instanceKeys/instanceRetainedFlags,
    // которые меняются только вместе с топологией: пересборка 3610 структур
    // каждый кадр не нужна.
    private var cachedRoadPresentationInputs: [BaseLabelPresentationInput] = []
    private var cachedRoadPresentationInputsGeneration: UInt64?
    private var roadTargetVisibilityScratch: [Bool] = []

    private let roadPriorityBase: Int = 1_000_000_000
    private let debugOverlayControls: DebugOverlayControlState?
    // Последняя подготовка дорожных инстансов цикла видимости: экранные AABB
    // глифов для debug-рамок. Обновляется со стартом цикла, при неподвижной
    // камере позиции остаются актуальными.
    private var latestRoadPreparedInstances: [RoadPreparedInstance] = []

    init(baseLabelCache: BaseLabelCache,
         roadLabelCache: RoadLabelCache? = nil,
         baseLabelTraceRecorder: BaseLabelTraceRecorder = BaseLabelTraceRecorder(),
         metalDevice: MTLDevice,
         library: MTLLibrary,
         settings: ImmersiveMapSettings.LabelSettings = ImmersiveMapSettings.default.labels,
         debugOverlayControls: DebugOverlayControlState? = nil) {
        self.baseLabelCache = baseLabelCache
        self.roadLabelCache = roadLabelCache
        self.baseLabelTraceRecorder = baseLabelTraceRecorder
        self.debugOverlayControls = debugOverlayControls
        self.baseScreenCompute = TilePointScreenCompute(metalDevice: metalDevice, library: library)
        self.roadPathScreenCompute = TilePointScreenCompute(metalDevice: metalDevice, library: library)
        self.roadPlacementCalculator = RoadLabelPlacementCalculator(pipeline: RoadLabelPlacementPipeline(metalDevice: metalDevice,
                                                                                                         library: library))
        self.roadRuntimeMetaBufferStore = FrameSlottedDynamicMetalBuffer(metalDevice: metalDevice,
                                                                         slotsCount: InFlightFramePool.inFlightFramesCount,
                                                                         options: [.storageModeShared])
        self.fallbackTileOriginDataBufferStore = FrameSlottedDynamicMetalBuffer(metalDevice: metalDevice,
                                                                                slotsCount: InFlightFramePool.inFlightFramesCount,
                                                                                options: [.storageModeShared])
        self.fadeInSeconds = settings.base.fadeInSeconds
        self.fadeOutSeconds = settings.base.fadeOutSeconds
        self.maxGlyphTurnRadians = settings.road.maxGlyphTurnRadians
        self.collisionGridCellSizePx = max(8.0, settings.base.gridCellSizePx)
    }

    convenience init(baseLabelCache: BaseLabelCache,
                     roadLabelCache: RoadLabelCache? = nil,
                     metalDevice: MTLDevice,
                     settings: ImmersiveMapSettings.LabelSettings = ImmersiveMapSettings.default.labels) {
        let bundle = Bundle.module
        let library = RendererSetup.makeLibrary(metalDevice: metalDevice, bundle: bundle)
        self.init(baseLabelCache: baseLabelCache,
                  roadLabelCache: roadLabelCache,
                  metalDevice: metalDevice,
                  library: library,
                  settings: settings)
    }

    convenience init(baseLabelCache: BaseLabelCache,
                     roadLabelCache: RoadLabelCache? = nil,
                     metalDevice: MTLDevice,
                     library: MTLLibrary,
                     gridCellSizePx: Float,
                     fadeInSeconds: TimeInterval = ImmersiveMapSettings.default.labels.base.fadeInSeconds,
                     fadeOutSeconds: TimeInterval = ImmersiveMapSettings.default.labels.base.fadeOutSeconds,
                     roadGridCellSizePx: Float = ImmersiveMapSettings.default.labels.road.gridCellSizePx,
                     maxGlyphTurnRadians: Float = ImmersiveMapSettings.default.labels.road.maxGlyphTurnRadians) {
        var settings = ImmersiveMapSettings.default.labels
        settings.base.gridCellSizePx = gridCellSizePx
        settings.base.fadeInSeconds = fadeInSeconds
        settings.base.fadeOutSeconds = fadeOutSeconds
        settings.road.gridCellSizePx = roadGridCellSizePx
        settings.road.maxGlyphTurnRadians = maxGlyphTurnRadians
        self.init(baseLabelCache: baseLabelCache,
                  roadLabelCache: roadLabelCache,
                  metalDevice: metalDevice,
                  library: library,
                  settings: settings)
    }

    convenience init(baseLabelCache: BaseLabelCache,
                     roadLabelCache: RoadLabelCache? = nil,
                     metalDevice: MTLDevice,
                     gridCellSizePx: Float,
                     fadeInSeconds: TimeInterval = ImmersiveMapSettings.default.labels.base.fadeInSeconds,
                     fadeOutSeconds: TimeInterval = ImmersiveMapSettings.default.labels.base.fadeOutSeconds,
                     roadGridCellSizePx: Float = ImmersiveMapSettings.default.labels.road.gridCellSizePx,
                     maxGlyphTurnRadians: Float = ImmersiveMapSettings.default.labels.road.maxGlyphTurnRadians) {
        let bundle = Bundle.module
        let library = RendererSetup.makeLibrary(metalDevice: metalDevice, bundle: bundle)
        self.init(baseLabelCache: baseLabelCache,
                  roadLabelCache: roadLabelCache,
                  metalDevice: metalDevice,
                  library: library,
                  gridCellSizePx: gridCellSizePx,
                  fadeInSeconds: fadeInSeconds,
                  fadeOutSeconds: fadeOutSeconds,
                  roadGridCellSizePx: roadGridCellSizePx,
                  maxGlyphTurnRadians: maxGlyphTurnRadians)
    }

    func update(frameContext: FrameContext) {
        let placeTileTrackingState = frameContext.sharedState.placeTileTrackingState
        let projectionIndexState = frameContext.sharedState.tileProjectionIndexState
        let sourceEntries = BaseLabelSourceEntry.build(from: placeTileTrackingState.placeTiles,
                                                       center: frameContext.visibleContent.center,
                                                       centerZoom: frameContext.visibleContent.tileZoomLevel,
                                                       renderSurfaceMode: frameContext.renderSurfaceMode)
        let baseLabelTierCounts = Self.countLabelDetailTiers(sourceEntries)
        frameContext.services.diagnostics.setCounter(.baseLabelFullTileCount, value: baseLabelTierCounts.full)
        frameContext.services.diagnostics.setCounter(.baseLabelReducedTileCount, value: baseLabelTierCounts.reduced)
        frameContext.services.diagnostics.setCounter(.baseLabelMinimalTileCount, value: baseLabelTierCounts.minimal)
        latestCameraFingerprint = makeVisibilityCameraFingerprint(frameContext: frameContext)

        let baseTrackedTilesChanged = baseSourceEntriesVersionTracker.stage(BaseLabelSourceEntry.makeBaseLabelHash(sourceEntries))
        let roadTrackedTilesChanged = roadSourceEntriesVersionTracker.stage(BaseLabelSourceEntry.makeRoadLabelHash(sourceEntries))
        let projectionChanged = projectionVersionTracker.stage(Int(truncatingIfNeeded: projectionIndexState.sourceIndexVersion))
        let sourceTilesChanged = baseTrackedTilesChanged || roadTrackedTilesChanged
        if sourceTilesChanged || projectionChanged {
            let previousBaseVisibilityByKey = makePublishedBaseVisibilityByKey()
            let previousRoadVisibilityByKey = makePublishedRoadVisibilityByKey()
            baseLabelCache.synchronize(sourceEntries: sourceEntries,
                                       tileIndexAllocator: projectionIndexState.tileIndexAllocator,
                                       trackedTilesChanged: baseTrackedTilesChanged,
                                       projectionChanged: projectionChanged)
            roadLabelCache?.synchronize(sourceEntries: sourceEntries,
                                        tileIndexAllocator: projectionIndexState.tileIndexAllocator,
                                        trackedTilesChanged: roadTrackedTilesChanged,
                                        projectionChanged: projectionChanged)
            refreshGpuTopology(trackedTilesChanged: baseTrackedTilesChanged,
                               projectionChanged: projectionChanged)
            visibilityTopologyGeneration &+= 1
            reseedPublishedVisibilityState(baseVisibilityByKey: previousBaseVisibilityByKey,
                                          roadVisibilityByKey: previousRoadVisibilityByKey)
            visibilityCycle = nil
            if baseTrackedTilesChanged {
                baseSourceEntriesVersionTracker.commitPending()
            }
            if roadTrackedTilesChanged {
                roadSourceEntriesVersionTracker.commitPending()
            }
            if projectionChanged {
                projectionVersionTracker.commitPending()
            }
        }

        let baseProjection = makeCpuBaseProjection(frameContext: frameContext,
                                                   tilePointSnapshot: baseLabelCache.tilePointSnapshot)
        let currentBaseAlphas = presentationStateStore.currentAlphas(inputs: baseLabelCache.presentationInputs,
                                                                     time: frameContext.time,
                                                                     fadeInSeconds: fadeInSeconds,
                                                                     fadeOutSeconds: fadeOutSeconds)
        let horizonReservationSignature = BaseLabelVisibilityResolver.horizonReservationSignature(
            horizonVisibility: baseProjection.horizonVisibility,
            currentAlphas: currentBaseAlphas
        )

        if collisionsEnabled {
            maybeStartVisibilityCycle(frameContext: frameContext,
                                      baseProjection: baseProjection,
                                      currentBaseAlphas: currentBaseAlphas,
                                      horizonReservationSignature: horizonReservationSignature,
                                      forceRestart: sourceTilesChanged || projectionChanged)
            advanceVisibilityCycleIfNeeded(frameContext: frameContext)
        } else {
            visibilityCycle = nil
            publishedBaseCollisionVisibility = baseLabelCache.presentationInputs.map { input in
                input.isValid ? .visible : .hidden
            }
            if let roadLabelCache {
                publishedRoadInstanceVisibility = Array(repeating: true, count: roadLabelCache.instanceKeys.count)
            } else {
                publishedRoadInstanceVisibility = []
            }
            publishedVisibilityCameraFingerprint = latestCameraFingerprint
            publishedHorizonReservationSignature = horizonReservationSignature
        }

        let overviewFadeAlpha = LowZoomOverviewFade.alpha(for: frameContext.zoom)
        let targetVisibility = BaseLabelVisibilityResolver.targetVisibility(
            inputs: baseLabelCache.presentationInputs,
            collisionVisibility: publishedBaseCollisionVisibility,
            horizonVisibility: baseProjection.horizonVisibility,
            cameraZoom: Float(frameContext.zoom)
        )
        let fadeResolution = presentationStateStore.resolveAlphas(inputs: baseLabelCache.presentationInputs,
                                                                  targetVisibility: targetVisibility,
                                                                  time: frameContext.time,
                                                                  frameIndex: frameContext.frameIndex,
                                                                  fadeInSeconds: fadeInSeconds,
                                                                  fadeOutSeconds: fadeOutSeconds)
        if baseLabelTraceRecorder.isRecordingActive {
            recordBaseLabelTraceFrame(frameContext: frameContext,
                                      sourceTileCount: sourceEntries.count,
                                      baseLabelTierCounts: baseLabelTierCounts,
                                      baseTrackedTilesChanged: baseTrackedTilesChanged,
                                      roadTrackedTilesChanged: roadTrackedTilesChanged,
                                      projectionChanged: projectionChanged,
                                      baseProjection: baseProjection,
                                      targetVisibility: targetVisibility,
                                      fadeResolution: fadeResolution,
                                      overviewFadeAlpha: overviewFadeAlpha)
        }
        baseLabelCache.updateFadeAlphas(fadeResolution.fadeAlphas,
                                        multiplier: overviewFadeAlpha)
        frameContext.sharedState.baseLabelDebugBoxesState = makeDebugBoxesState(
            baseProjection: baseProjection,
            fadeAlphas: fadeResolution.fadeAlphas,
            cameraZoom: Float(frameContext.zoom)
        )
        // visibilityCycle != nil: незавершённый цикл обязан удерживать кадры,
        // иначе при статичной камере (fingerprint публикуется первым же
        // advance) display link заснёт на середине цикла, не дойдя до
        // road-групп.
        let hasPendingVisibilityRefresh = collisionsEnabled &&
            (latestCameraFingerprint != publishedVisibilityCameraFingerprint ||
                horizonReservationSignature != publishedHorizonReservationSignature ||
                roadPlacementDataPending ||
                visibilityCycle != nil)
        publishBaseLabelState(frameContext: frameContext,
                              hasActiveFadeAnimations: fadeResolution.hasActiveAnimations,
                              hasActiveVisibilityCycle: hasPendingVisibilityRefresh)
        frameContext.sharedState.baseLabelState.screenPositionsBuffer = nil

        let roadState = buildRoadLabelState(frameContext: frameContext,
                                            roadVisibility: publishedRoadInstanceVisibility)
        frameContext.sharedState.roadLabelState = roadState

        frameContext.services.diagnostics.setCounter(.baseLabelCount, value: baseLabelCache.labelInputsCount)
        frameContext.services.diagnostics.setCounter(.roadLabelGlyphCount, value: roadState.glyphCount)
        frameContext.services.diagnostics.setCounter(.roadLabelInstanceCount, value: roadState.instanceCount)
        frameContext.services.diagnostics.setCounter(.roadLabelNearCameraCulledPathCount,
                                                     value: latestRoadLabelNearCameraCullCounts.path)
        frameContext.services.diagnostics.setCounter(.roadLabelNearCameraCulledAnchorCount,
                                                     value: latestRoadLabelNearCameraCullCounts.anchor)
    }

    private static func countLabelDetailTiers(_ sourceEntries: [BaseLabelSourceEntry]) -> (full: Int, reduced: Int, minimal: Int) {
        var fullCount = 0
        var reducedCount = 0
        var minimalCount = 0

        for sourceEntry in sourceEntries {
            switch sourceEntry.labelDetailTier {
            case .full:
                fullCount += 1
            case .reduced:
                reducedCount += 1
            case .minimal:
                minimalCount += 1
            }
        }

        return (full: fullCount, reduced: reducedCount, minimal: minimalCount)
    }

    func prepareGPU(frameContext: FrameContext, resourceRegistry _: RenderResourceRegistry) {
        // Стампы прошлого кадра, не дошедшие до frameCommitted (кадр отброшен
        // без commit) - компьют не исполнился, фиксировать их нельзя.
        pendingPlacementStamps.removeAll(keepingCapacity: true)
        let tileOriginDataBuffer = resolveTileOriginDataBuffer(frameContext: frameContext)
        let basePointCount = baseLabelCache.activeLabelSpanCount
        if basePointCount > 0 {
            baseScreenCompute.run(frameContext: frameContext,
                                  pointCount: basePointCount,
                                  tileOriginDataBuffer: tileOriginDataBuffer)
            frameContext.sharedState.baseLabelState.screenPositionsBuffer = baseScreenCompute.outputBuffer(slot: frameContext.frameSlotIndex,
                                                                                                           count: basePointCount)
        }

        guard let roadLabelCache,
              roadLabelCache.orderedTileRecords.isEmpty == false else {
            return
        }

        guard let commandBuffer = frameContext.commandBuffer else {
            return
        }

        var drawBatches: [DrawRoadLabels] = []
        let staticBatches = frameContext.sharedState.roadLabelState.drawLabels
        let records = roadLabelCache.orderedTileRecords
        let activeRecordIndices = latestActiveRoadRecordIndices
        drawBatches.reserveCapacity(records.count)

        for (index, record) in records.enumerated() {
            if let activeRecordIndices,
               activeRecordIndices.contains(index) == false {
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
            roadPathScreenCompute.run(frameContext: frameContext,
                                      pointCount: record.pathPointCount,
                                      inputBuffer: pathInputsBuffer,
                                      tileSlotVisibleTileIndicesBuffer: record.visibleTileIndexBuffer,
                                      tileOriginDataBuffer: tileOriginDataBuffer,
                                      outputBuffer: pathPointsBuffer)

            let placementBuffer = record.placementBuffer(slot: frameContext.frameSlotIndex)
            let glyphScreenPointsBuffer = record.glyphScreenPointBuffer(slot: frameContext.frameSlotIndex)
            let collisionAabbBuffer = record.collisionAabbBuffer(slot: frameContext.frameSlotIndex)
            roadPlacementCalculator.run(commandBuffer: commandBuffer,
                                        pathPointsBuffer: pathPointsBuffer,
                                        pathRangesBuffer: pathRangesBuffer,
                                        anchorsBuffer: anchorsBuffer,
                                        glyphInputsBuffer: glyphInputsBuffer,
                                        placementsBuffer: placementBuffer,
                                        screenPointsBuffer: glyphScreenPointsBuffer,
                                        collisionInputsBuffer: collisionInputsBuffer,
                                        collisionAabbBuffer: collisionAabbBuffer,
                                        glyphCount: record.glyphCount)
            // Стамп фиксируется только в frameCommitted(): кадр может быть
            // отброшен после prepareGPU (нет drawable), и закодированный
            // компьют никогда не исполнится.
            pendingPlacementStamps.append((record: record, slot: frameContext.frameSlotIndex))

            if index < staticBatches.count {
                let existingBatch = staticBatches[index]
                drawBatches.append(DrawRoadLabels(placementBuffer: placementBuffer,
                                                  glyphInputBuffer: glyphInputsBuffer,
                                                  runtimeMetaBuffer: existingBatch.runtimeMetaBuffer,
                                                  localGlyphVerticesBuffer: record.localGlyphVerticesBuffer,
                                                  glyphCount: record.glyphCount,
                                                  localGlyphVertexCount: record.localGlyphVertexCount,
                                                  labelStyle: record.labelStyle))
            }
        }

        frameContext.sharedState.roadLabelState.drawLabels = drawBatches
        frameContext.sharedState.roadLabelState.placementBuffer = drawBatches.first?.placementBuffer
        frameContext.sharedState.roadLabelState.glyphInputBuffer = drawBatches.first?.glyphInputBuffer
        frameContext.sharedState.roadLabelState.runtimeMetaBuffer = drawBatches.first?.runtimeMetaBuffer
        frameContext.sharedState.roadLabelState.glyphVerticesBuffer = drawBatches.first?.localGlyphVerticesBuffer
        frameContext.sharedState.roadLabelState.glyphVertexCount = drawBatches.first?.localGlyphVertexCount ?? 0
    }

    func encode(layer _: RenderLayer, encoder _: MTLRenderCommandEncoder, frameContext _: FrameContext) {}

    // Command buffer кадра закоммичен - закодированный placement-компьют
    // гарантированно исполнится, стампы данных можно фиксировать.
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
        presentationStateStore.reset()
        roadPresentationStateStore.reset()
        roadDrawLabels.removeAll(keepingCapacity: false)
        latestRoadLabelNearCameraCullCounts = (path: 0, anchor: 0)
        latestActiveRoadRecordIndices = nil
        roadPlacementDataPending = false
        pendingPlacementStamps.removeAll(keepingCapacity: false)
        baseSourceEntriesVersionTracker.invalidate()
        roadSourceEntriesVersionTracker.invalidate()
        projectionVersionTracker.invalidate()
        cachedBaseProjection = .empty
        cachedBaseProjectionFingerprint = nil
        cachedBaseProjectionTopologyGeneration = 0
        cachedRoadPresentationInputs.removeAll(keepingCapacity: false)
        cachedRoadPresentationInputsGeneration = nil
        roadTargetVisibilityScratch.removeAll(keepingCapacity: false)
        lastVisibilityCycleEndTime = -.greatestFiniteMagnitude
    }

    private func publishBaseLabelState(frameContext: FrameContext,
                                       hasActiveFadeAnimations: Bool,
                                       hasActiveVisibilityCycle: Bool) {
        frameContext.sharedState.baseLabelState.labelInputsCount = baseLabelCache.labelInputsCount
        frameContext.sharedState.baseLabelState.activeLabelSpanCount = baseLabelCache.activeLabelSpanCount
        frameContext.sharedState.baseLabelState.labelRuntimeMetaBuffer = baseLabelCache.labelRuntimeMetaBuffer(frameSlotIndex: frameContext.frameSlotIndex)
        frameContext.sharedState.baseLabelState.baseLabelsDrawBatches = baseLabelCache.baseLabelsDrawBatches
        frameContext.sharedState.baseLabelState.hasActiveFadeAnimations = hasActiveFadeAnimations
        frameContext.sharedState.baseLabelState.hasActiveVisibilityCycle = hasActiveVisibilityCycle
    }

    /// Рамки лейблов для debug-оверлея: коллизионные AABB со свежими экранными
    /// позициями кадра. Спрятанные (коллизией, горизонтом лейбла, фейдом)
    /// включаются наравне с видимыми: смысл оверлея - показать всё, что
    /// участвует в кадре. За горизонтом проекции точка невалидна и рамки нет.
    /// Лейблы ниже своего minCameraZoom пропускаются: коллизия их не считает,
    /// и красный цвет должен означать «проиграл коллизию», а не «ещё не дорос
    /// до зума». Базовые и дорожные рамки включаются раздельными тумблерами.
    private func makeDebugBoxesState(baseProjection: TilePointScreenProjectionResult,
                                     fadeAlphas: [Float],
                                     cameraZoom: Float) -> BaseLabelDebugBoxesState {
        guard let controls = debugOverlayControls?.snapshot(),
              controls.baseLabelBoundsEnabled || controls.roadLabelBoundsEnabled else {
            return .empty
        }

        var boxes: [BaseLabelDebugBox] = []
        if controls.baseLabelBoundsEnabled {
            let candidates = baseLabelCache.labelCollisionAABBInputs
            let presentationInputs = baseLabelCache.presentationInputs
            let screenPoints = baseProjection.screenPoints
            let count = min(candidates.count, screenPoints.count)
            boxes.reserveCapacity(count)

            for index in 0..<count {
                let candidate = candidates[index]
                let screenPoint = screenPoints[index]
                guard candidate.isEnabled, screenPoint.visible != 0 else {
                    continue
                }
                if index < presentationInputs.count,
                   presentationInputs[index].minCameraZoom > cameraZoom {
                    continue
                }
                let alpha = index < fadeAlphas.count ? fadeAlphas[index] : 0.0
                boxes.append(BaseLabelDebugBox(center: screenPoint.position,
                                               halfSize: candidate.halfSize,
                                               isVisible: alpha > 0.01))
            }
        }

        // Дорожные рамки: per-glyph AABB из последней подготовки цикла
        // видимости, видимость по опубликованному решению коллизий инстанса.
        var roadBoxes: [BaseLabelDebugBox] = []
        if controls.roadLabelBoundsEnabled {
            for instance in latestRoadPreparedInstances {
                let isVisible = instance.targetIndex < publishedRoadInstanceVisibility.count
                    && publishedRoadInstanceVisibility[instance.targetIndex]
                for candidate in instance.collisionCandidates {
                    roadBoxes.append(BaseLabelDebugBox(center: candidate.position,
                                                       halfSize: candidate.halfSize,
                                                       isVisible: isVisible))
                }
            }
        }
        return BaseLabelDebugBoxesState(boxes: boxes, roadBoxes: roadBoxes)
    }

    private func makeCpuBaseProjection(frameContext: FrameContext,
                                       tilePointSnapshot: TilePointToScreenPointSnapshot) -> TilePointScreenProjectionResult {
        guard baseLabelCache.activeLabelSpanCount > 0 else {
            return .empty
        }
        // Проекция - чистая функция от камеры и топологии тайлов: fingerprint камеры
        // покрывает все проекционные входы (центр, зум, углы, drawSize, режимы
        // поверхности), а generation топологии меняется при любой смене
        // snapshot/tileOriginData. При неподвижной камере пересчёт не нужен.
        if cachedBaseProjectionFingerprint == latestCameraFingerprint,
           cachedBaseProjectionTopologyGeneration == visibilityTopologyGeneration {
            return cachedBaseProjection
        }
        let projectionIndexState = frameContext.sharedState.tileProjectionIndexState
        let projection = tilePointScreenProjector.projectWithHorizonVisibility(snapshot: tilePointSnapshot,
                                                                               frameContext: frameContext,
                                                                               tileOriginData: projectionIndexState.tileOriginData)
        cachedBaseProjection = projection
        cachedBaseProjectionFingerprint = latestCameraFingerprint
        cachedBaseProjectionTopologyGeneration = visibilityTopologyGeneration
        return projection
    }

    private func refreshGpuTopology(trackedTilesChanged: Bool,
                                    projectionChanged: Bool) {
        if trackedTilesChanged {
            baseScreenCompute.uploadInputs(baseLabelCache.tilePointInputs)
        }
        if trackedTilesChanged || projectionChanged {
            baseScreenCompute.uploadTileSlotVisibleTileIndices(baseLabelCache.tilePointSnapshot.tileSlotVisibleTileIndices)
        }
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

    private func recordBaseLabelTraceFrame(frameContext: FrameContext,
                                           sourceTileCount: Int,
                                           baseLabelTierCounts: (full: Int, reduced: Int, minimal: Int),
                                           baseTrackedTilesChanged: Bool,
                                           roadTrackedTilesChanged: Bool,
                                           projectionChanged: Bool,
                                           baseProjection: TilePointScreenProjectionResult,
                                           targetVisibility: [Bool],
                                           fadeResolution: BaseLabelPresentationResolution,
                                           overviewFadeAlpha: Float) {
        let inputs = baseLabelCache.presentationInputs
        var validLabelCount = 0
        var duplicateLabelCount = 0
        var retainedLabelCount = 0
        var collisionVisibleCount = 0
        var collisionHiddenCount = 0
        var collisionUnknownCount = 0
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

            switch baseLabelCollisionVisibility(at: index) {
            case .visible:
                collisionVisibleCount += 1
            case .hidden:
                collisionHiddenCount += 1
            case .unknown:
                collisionUnknownCount += 1
            }

            if index < targetVisibility.count, targetVisibility[index] {
                targetVisibleCount += 1
            }
            if index < baseProjection.horizonVisibility.count, baseProjection.horizonVisibility[index] {
                horizonVisibleCount += 1
            }

            let fadeAlpha = Self.traceFadeAlpha(index: index,
                                                fadeAlphas: fadeResolution.fadeAlphas,
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
                                                           screenPoints: baseProjection.screenPoints,
                                                           collisionVisibility: publishedBaseCollisionVisibility,
                                                           targetVisibility: targetVisibility,
                                                           maxBucketCount: baseLabelTraceRecorder.options.maxHotBuckets)
        let includeFullLabels = baseLabelTraceRecorder.options.shouldIncludeFullLabels(
            frameIndex: frameContext.frameIndex,
            baseTrackedTilesChanged: baseTrackedTilesChanged,
            projectionChanged: projectionChanged,
            maxHotBucketCount: hotBuckets.maxBucketCount
        )
        let labels = includeFullLabels ? Self.makeBaseLabelTraceLabels(inputs: inputs,
                                                                       screenPoints: baseProjection.screenPoints,
                                                                       collisionVisibility: publishedBaseCollisionVisibility,
                                                                       targetVisibility: targetVisibility,
                                                                       horizonVisibility: baseProjection.horizonVisibility,
                                                                       fadeAlphas: fadeResolution.fadeAlphas,
                                                                       overviewFadeAlpha: overviewFadeAlpha,
                                                                       collisionCandidates: baseLabelCache.labelCollisionAABBInputs) : nil
        let cycle = visibilityCycle
        baseLabelTraceRecorder.record(.baseLabelFrame(frameIndex: frameContext.frameIndex,
                                                      zoom: frameContext.zoom,
                                                      pitchDegrees: Double(frameContext.mapCameraState.pitch) * 180.0 / .pi,
                                                      bearingDegrees: Double(frameContext.mapCameraState.bearing) * 180.0 / .pi,
                                                      sourceTileCount: sourceTileCount,
                                                      baseTrackedTilesChanged: baseTrackedTilesChanged,
                                                      roadTrackedTilesChanged: roadTrackedTilesChanged,
                                                      projectionChanged: projectionChanged,
                                                      fullTileCount: baseLabelTierCounts.full,
                                                      reducedTileCount: baseLabelTierCounts.reduced,
                                                      minimalTileCount: baseLabelTierCounts.minimal,
                                                      activeLabelSpanCount: baseLabelCache.activeLabelSpanCount,
                                                      labelInputsCount: baseLabelCache.labelInputsCount,
                                                      validLabelCount: validLabelCount,
                                                      duplicateLabelCount: duplicateLabelCount,
                                                      retainedLabelCount: retainedLabelCount,
                                                      collisionVisibleCount: collisionVisibleCount,
                                                      collisionHiddenCount: collisionHiddenCount,
                                                      collisionUnknownCount: collisionUnknownCount,
                                                      targetVisibleCount: targetVisibleCount,
                                                      horizonVisibleCount: horizonVisibleCount,
                                                      fadeVisibleCount: fadeVisibleCount,
                                                      fadeAnimatingCount: fadeAnimatingCount,
                                                      cycleActive: cycle != nil,
                                                      cycleCursor: cycle?.cursor ?? 0,
                                                      cycleGroupCount: cycle?.groupCount ?? 0,
                                                      cycleComplete: cycle?.isComplete ?? true,
                                                      labels: labels,
                                                      hotBuckets: hotBuckets.description,
                                                      maxHotBucketCount: hotBuckets.maxBucketCount,
                                                      droppedEventCount: baseLabelTraceRecorder.currentDroppedEventCount))
    }

    private func baseLabelCollisionVisibility(at index: Int) -> BaseLabelCollisionVisibility {
        index < publishedBaseCollisionVisibility.count ? publishedBaseCollisionVisibility[index] : .unknown
    }

    private static func makeBaseLabelTraceLabels(inputs: [BaseLabelPresentationInput],
                                                 screenPoints: [ScreenPointOutput],
                                                 collisionVisibility: [BaseLabelCollisionVisibility],
                                                 targetVisibility: [Bool],
                                                 horizonVisibility: [Bool],
                                                 fadeAlphas: [Float],
                                                 overviewFadeAlpha: Float,
                                                 collisionCandidates: [ScreenCollisionCandidate]) -> String {
        guard inputs.isEmpty == false else {
            return ""
        }

        var labels: [String] = []
        labels.reserveCapacity(inputs.count)
        for index in inputs.indices {
            let input = inputs[index]
            let point = index < screenPoints.count ? screenPoints[index] : nil
            let candidate = index < collisionCandidates.count ? collisionCandidates[index] : nil
            let visibility = index < collisionVisibility.count ? collisionVisibility[index] : .unknown
            let targetVisible = index < targetVisibility.count && targetVisibility[index]
            let horizonVisible = index < horizonVisibility.count && horizonVisibility[index]
            let fadeAlpha = traceFadeAlpha(index: index,
                                           fadeAlphas: fadeAlphas,
                                           overviewFadeAlpha: overviewFadeAlpha)
            let position = point?.position ?? .zero
            let halfSize = candidate?.halfSize ?? .zero
            let screenVisible = point?.visible != 0
            let priority = candidate?.priority ?? Int.max
            let secondaryPriority = candidate?.secondaryPriority ?? Int.max

            labels.append("\(index)|\(input.labelKey)|v=\(input.isValid ? 1 : 0)|d=\(input.duplicate)|r=\(input.isRetained)|cv=\(traceString(for: visibility))|t=\(targetVisible ? 1 : 0)|hz=\(horizonVisible ? 1 : 0)|a=\(formatTraceFloat(fadeAlpha))|x=\(formatTraceFloat(position.x))|y=\(formatTraceFloat(position.y))|sv=\(screenVisible ? 1 : 0)|p=\(priority)|sp=\(secondaryPriority)|hw=\(formatTraceFloat(halfSize.x))|hh=\(formatTraceFloat(halfSize.y))")
        }
        return labels.joined(separator: ";")
    }

    private static func makeBaseLabelTraceHotBuckets(inputs: [BaseLabelPresentationInput],
                                                     screenPoints: [ScreenPointOutput],
                                                     collisionVisibility: [BaseLabelCollisionVisibility],
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
            if index < collisionVisibility.count, collisionVisibility[index] == .visible {
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

    private static func traceString(for visibility: BaseLabelCollisionVisibility) -> String {
        switch visibility {
        case .unknown:
            return "unknown"
        case .visible:
            return "visible"
        case .hidden:
            return "hidden"
        }
    }

    private static func formatTraceFloat(_ value: Float) -> String {
        String(format: "%.2f", locale: traceLocale, Double(value))
    }

    private func reseedPublishedVisibilityState(baseVisibilityByKey: [UInt64: BaseLabelCollisionVisibility],
                                                roadVisibilityByKey: [UInt64: Bool]) {
        publishedBaseCollisionVisibility = baseLabelCache.presentationInputs.map { input in
            guard input.isValid else {
                return .hidden
            }
            return baseVisibilityByKey[input.labelKey] ?? .hidden
        }

        if let roadLabelCache {
            publishedRoadInstanceVisibility = roadLabelCache.instanceKeys.map { key in
                roadVisibilityByKey[key] ?? false
            }
        } else {
            publishedRoadInstanceVisibility = []
        }
    }

    private func makePublishedBaseVisibilityByKey() -> [UInt64: BaseLabelCollisionVisibility] {
        var visibilityByKey: [UInt64: BaseLabelCollisionVisibility] = [:]
        let inputs = baseLabelCache.presentationInputs
        let count = min(inputs.count, publishedBaseCollisionVisibility.count)
        guard count > 0 else {
            return visibilityByKey
        }

        for index in 0..<count {
            let input = inputs[index]
            guard input.isValid else {
                continue
            }
            let visibility = publishedBaseCollisionVisibility[index]
            if let existing = visibilityByKey[input.labelKey] {
                visibilityByKey[input.labelKey] = Self.mergedCollisionVisibility(existing, visibility)
            } else {
                visibilityByKey[input.labelKey] = visibility
            }
        }
        return visibilityByKey
    }

    private func makePublishedRoadVisibilityByKey() -> [UInt64: Bool] {
        guard let roadLabelCache else {
            return [:]
        }

        var visibilityByKey: [UInt64: Bool] = [:]
        let count = min(roadLabelCache.instanceKeys.count, publishedRoadInstanceVisibility.count)
        guard count > 0 else {
            return visibilityByKey
        }

        for index in 0..<count {
            let key = roadLabelCache.instanceKeys[index]
            let isVisible = publishedRoadInstanceVisibility[index]
            visibilityByKey[key] = (visibilityByKey[key] ?? false) || isVisible
        }
        return visibilityByKey
    }

    private static func mergedCollisionVisibility(_ lhs: BaseLabelCollisionVisibility,
                                                  _ rhs: BaseLabelCollisionVisibility) -> BaseLabelCollisionVisibility {
        if lhs == .visible || rhs == .visible {
            return .visible
        }
        if lhs == .unknown || rhs == .unknown {
            return .unknown
        }
        return .hidden
    }

    static func shouldReplaceActiveVisibilityCycle(_ cycle: VisibilityCycle,
                                                    latestCameraFingerprint: Int,
                                                    forceRestart: Bool) -> Bool {
        forceRestart
    }

    static func shouldPublishVisibilityCycle(_ cycle: VisibilityCycle,
                                             topologyGeneration: UInt64) -> Bool {
        cycle.topologyGeneration == topologyGeneration
    }

    private func maybeStartVisibilityCycle(frameContext: FrameContext,
                                           baseProjection: TilePointScreenProjectionResult,
                                           currentBaseAlphas: [Float],
                                           horizonReservationSignature: [Int],
                                           forceRestart: Bool) {
        if forceRestart {
            visibilityCycle = makeVisibilityCycle(frameContext: frameContext,
                                                  baseProjection: baseProjection,
                                                  currentBaseAlphas: currentBaseAlphas,
                                                  horizonReservationSignature: horizonReservationSignature)
            return
        }

        if let visibilityCycle {
            guard Self.shouldReplaceActiveVisibilityCycle(visibilityCycle,
                                                          latestCameraFingerprint: latestCameraFingerprint,
                                                          forceRestart: forceRestart) else {
                return
            }
            self.visibilityCycle = makeVisibilityCycle(frameContext: frameContext,
                                                       baseProjection: baseProjection,
                                                       currentBaseAlphas: currentBaseAlphas,
                                                       horizonReservationSignature: horizonReservationSignature)
            return
        }

        // Каденс отсчитывается от ЗАВЕРШЕНИЯ прошлого цикла и гейтит в том числе
        // камерные рестарты: во время непрерывного жеста fingerprint (точные
        // bitPattern) расходится с published каждый кадр, и без паузы циклы шли
        // back-to-back - полная пересборка road-инстансов каждые ~15 кадров.
        // Экранные позиции лейблов считает GPU покадрово; каденс задерживает
        // только решения показать/скрыть. forceRestart (смена тайлов/проекции)
        // остаётся немедленным - на нём держится reseed видимости.
        let cameraChanged = latestCameraFingerprint != publishedVisibilityCameraFingerprint
        let horizonReservationChanged = horizonReservationSignature != publishedHorizonReservationSignature
        let cadenceElapsed = frameContext.time - lastVisibilityCycleEndTime >= visibilityRefreshInterval
        guard (cameraChanged || horizonReservationChanged || roadPlacementDataPending) && cadenceElapsed else {
            return
        }

        visibilityCycle = makeVisibilityCycle(frameContext: frameContext,
                                              baseProjection: baseProjection,
                                              currentBaseAlphas: currentBaseAlphas,
                                              horizonReservationSignature: horizonReservationSignature)
    }

    private func advanceVisibilityCycleIfNeeded(frameContext: FrameContext) {
        guard let cycle = visibilityCycle else {
            return
        }

        cycle.processNextGroups(maxGroupCount: collisionGroupBudgetPerFrame)
        if Self.shouldPublishVisibilityCycle(cycle,
                                             topologyGeneration: visibilityTopologyGeneration) {
            // Инкрементальная публикация: за кадр решения получают максимум
            // budget групп - переносим только их, вместо аллокации и слияния
            // полных массивов (published реseed-ится на топологию цикла ДО его
            // создания, поэтому индексы совместимы; bounds-guard на случай
            // рассинхронизации сохраняется).
            cycle.drainPendingPublications(
                base: { index, visibility in
                    guard index < publishedBaseCollisionVisibility.count else { return }
                    publishedBaseCollisionVisibility[index] = visibility
                },
                road: { index, isVisible in
                    guard index < publishedRoadInstanceVisibility.count else { return }
                    publishedRoadInstanceVisibility[index] = isVisible
                }
            )
            publishedVisibilityCameraFingerprint = cycle.cameraFingerprint
            publishedHorizonReservationSignature = cycle.horizonReservationSignature
        }

        if cycle.isComplete {
            visibilityCycle = nil
            lastVisibilityCycleEndTime = frameContext.time
        }
    }

    private func makeVisibilityCycle(frameContext: FrameContext,
                                     baseProjection: TilePointScreenProjectionResult,
                                     currentBaseAlphas: [Float],
                                     horizonReservationSignature: [Int]) -> VisibilityCycle {
        let baseCollisionCandidates = BaseLabelVisibilityResolver.collisionCandidates(
            baseCandidates: baseLabelCache.labelCollisionAABBInputs,
            screenPoints: baseProjection.screenPoints,
            horizonVisibility: baseProjection.horizonVisibility,
            currentAlphas: currentBaseAlphas,
            minCameraZooms: baseLabelCache.presentationInputs.map(\.minCameraZoom),
            cameraZoom: Float(frameContext.zoom)
        )

        let roadPreparation = prepareRoadInstances(frameContext: frameContext,
                                                   projectionIndexState: frameContext.sharedState.tileProjectionIndexState)
        latestRoadPreparedInstances = roadPreparation.instances
        let seededBaseGroups = Self.makeSeededBaseCollisionGroups(candidates: baseCollisionCandidates,
                                                                  visibility: publishedBaseCollisionVisibility)
        let seededRoadGroups = makeSeededRoadCollisionGroups(roadInstances: roadPreparation.instances,
                                                             visibility: publishedRoadInstanceVisibility)
        let collisionGroups = makeCollisionGroups(baseCandidates: baseCollisionCandidates,
                                                  roadInstances: roadPreparation.instances)
        return VisibilityCycle(topologyGeneration: visibilityTopologyGeneration,
                               cameraFingerprint: latestCameraFingerprint,
                               horizonReservationSignature: horizonReservationSignature,
                               viewportSize: SIMD2<Float>(Float(frameContext.drawSize.width),
                                                          Float(frameContext.drawSize.height)),
                               baseCount: baseLabelCache.activeLabelSpanCount,
                               roadCount: roadLabelCache?.instanceKeys.count ?? 0,
                               groups: collisionGroups.groups,
                               seededGroups: seededBaseGroups + seededRoadGroups,
                               resolvedHiddenBaseIndices: collisionGroups.disabledBaseIndices,
                               resolvedHiddenRoadIndices: roadPreparation.hiddenInstanceIndices,
                               cellSizePx: collisionGridCellSizePx)
    }

    static func makeSeededBaseCollisionGroups(candidates: [ScreenCollisionCandidate],
                                              visibility: [BaseLabelCollisionVisibility]) -> [VisibilityCollisionGroup] {
        let count = min(candidates.count, visibility.count)
        guard count > 0 else {
            return []
        }

        var groups: [VisibilityCollisionGroup] = []
        groups.reserveCapacity(count)
        for index in 0..<count {
            let candidate = candidates[index]
            guard visibility[index] == .visible,
                  candidate.isEnabled else {
                continue
            }
            groups.append(VisibilityCollisionGroup(target: .base(index),
                                                  members: [candidate],
                                                  priority: candidate.priority,
                                                  secondaryPriority: candidate.secondaryPriority,
                                                  sortPriority: candidate.sortPriority,
                                                  stableOrderKey: candidate.stableOrderKey))
        }
        return groups
    }

    private func makeSeededRoadCollisionGroups(roadInstances: [RoadPreparedInstance],
                                               visibility: [Bool]) -> [VisibilityCollisionGroup] {
        guard roadInstances.isEmpty == false,
              visibility.isEmpty == false else {
            return []
        }

        var groups: [VisibilityCollisionGroup] = []
        groups.reserveCapacity(roadInstances.count)
        for instance in roadInstances {
            guard instance.targetIndex < visibility.count,
                  visibility[instance.targetIndex],
                  let firstCandidate = instance.collisionCandidates.first else {
                continue
            }
            groups.append(VisibilityCollisionGroup(target: .road(instance.targetIndex),
                                                  members: instance.collisionCandidates,
                                                  priority: firstCandidate.priority,
                                                  secondaryPriority: firstCandidate.secondaryPriority,
                                                  sortPriority: firstCandidate.sortPriority,
                                                  stableOrderKey: firstCandidate.stableOrderKey))
        }
        return groups
    }

    // Выключенные кандидаты не получают групп (не занимают бюджет цикла и не
    // аллоцируют members) - они сразу помечаются .hidden при инициализации цикла.
    private func makeCollisionGroups(baseCandidates: [ScreenCollisionCandidate],
                                     roadInstances: [RoadPreparedInstance]) -> (groups: [VisibilityCollisionGroup],
                                                                                disabledBaseIndices: [Int]) {
        var groups: [VisibilityCollisionGroup] = []
        groups.reserveCapacity(baseCandidates.count + roadInstances.count)
        var disabledBaseIndices: [Int] = []

        for index in baseCandidates.indices {
            let candidate = baseCandidates[index]
            guard candidate.isEnabled else {
                disabledBaseIndices.append(index)
                continue
            }
            groups.append(VisibilityCollisionGroup(target: .base(index),
                                                  members: [candidate],
                                                  priority: candidate.priority,
                                                  secondaryPriority: candidate.secondaryPriority,
                                                  sortPriority: candidate.sortPriority,
                                                  stableOrderKey: candidate.stableOrderKey))
        }

        for instance in roadInstances {
            guard let firstCandidate = instance.collisionCandidates.first else {
                continue
            }
            groups.append(VisibilityCollisionGroup(target: .road(instance.targetIndex),
                                                  members: instance.collisionCandidates,
                                                  priority: firstCandidate.priority,
                                                  secondaryPriority: firstCandidate.secondaryPriority,
                                                  sortPriority: firstCandidate.sortPriority,
                                                  stableOrderKey: firstCandidate.stableOrderKey))
        }

        return (groups.sorted(by: VisibilityCollisionGroup.sortForCollisionOrder), disabledBaseIndices)
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
        // Проекция зависит и от globe-униформы (transition/radius/pan), которая может
        // меняться при неизменной камере: forced-переключение режима поверхности и
        // live-обновление presentationSettings (radius задаёт и flatRenderMapSize).
        let globeUniform = frameContext.globeRenderUniform
        hasher.combine(globeUniform.transition.bitPattern)
        hasher.combine(globeUniform.radius.bitPattern)
        hasher.combine(globeUniform.panX.bitPattern)
        hasher.combine(globeUniform.panY.bitPattern)
        return hasher.finalize()
    }

    // Коллизионные кандидаты дорог читаются из GPU-буферов placement-компьюта:
    // GPU уже проецирует пути, выбирает ориентацию и пишет повёрнутые AABB
    // глифов для отрисовки - CPU-репроекция дублировала бы ту же работу и
    // могла расходиться с реально нарисованными глифами. Слот текущего кадра
    // читается ДО prepareGPU и содержит данные завершённого кадра N-slots:
    // решения видимости и так принимаются по позе старта цикла (0.2-0.45 с),
    // лаг readback на их фоне пренебрежим.
    private func prepareRoadInstances(frameContext: FrameContext,
                                      projectionIndexState: TileProjectionIndexState) -> RoadPreparation {
        guard let roadLabelCache,
              frameContext.renderSurfaceMode == .flat,
              roadLabelCache.orderedTileRecords.isEmpty == false else {
            latestRoadLabelNearCameraCullCounts = (path: 0, anchor: 0)
            latestActiveRoadRecordIndices = nil
            roadPlacementDataPending = false
            return RoadPreparation(instances: [],
                                   hiddenInstanceIndices: [])
        }

        var nearCameraCulledPathCount = 0
        var instances: [RoadPreparedInstance] = []
        var hiddenInstanceIndices: [Int] = []
        var activeRecordIndices: Set<Int> = []
        var hasRecordsAwaitingPlacementData = false
        instances.reserveCapacity(roadLabelCache.instanceKeys.count)
        hiddenInstanceIndices.reserveCapacity(roadLabelCache.instanceKeys.count)

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
                                                           underzoomLevels: max(0, frameContext.visibleContent.tileZoomLevel - record.ownerKey.z)) else {
                nearCameraCulledPathCount += record.entries.count
                appendRoadRecordInstanceIndices(record: record,
                                                into: &hiddenInstanceIndices)
                // prepareGPU перестанет кодировать компьют рекорда, буферы
                // заморозятся - сбрасываем стампы, чтобы после возврата не
                // читать позиции произвольной давности.
                record.invalidatePlacementData()
                continue
            }

            // Активность рекорда управляет GPU-компьютом в prepareGPU и не
            // зависит от readback - иначе новый рекорд никогда не получил бы
            // данных.
            activeRecordIndices.insert(recordIndex)

            guard record.canEncodePlacements else {
                continue
            }

            // Нет данных завершённого кадра (свежий рекорд, возврат из кулла) -
            // решения по инстансам не принимаются, published-видимость
            // сохраняется, а pending-флаг держит кадры и рестарты цикла живыми,
            // пока данные не появятся.
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
                guard let collisionCandidates = Self.makeRoadInstanceCandidates(
                    instanceKey: instanceKey,
                    secondaryPriority: secondaryPriority,
                    anchorOrdinal: record.instanceAnchorOrdinals[localIndex],
                    glyphRange: record.instanceGlyphRanges[localIndex],
                    placements: placements,
                    collisionAabbs: collisionAabbs,
                    roadPriorityBase: roadPriorityBase,
                    maxGlyphTurnRadians: maxGlyphTurnRadians
                ) else {
                    continue
                }
                instances.append(RoadPreparedInstance(instanceKey: instanceKey,
                                                      targetIndex: record.instanceStart + localIndex,
                                                      collisionCandidates: collisionCandidates))
            }
        }

        latestRoadLabelNearCameraCullCounts = (path: nearCameraCulledPathCount,
                                               anchor: 0)
        latestActiveRoadRecordIndices = activeRecordIndices
        roadPlacementDataPending = hasRecordsAwaitingPlacementData
        return RoadPreparation(instances: instances,
                               hiddenInstanceIndices: hiddenInstanceIndices)
    }

    // Кандидаты инстанса из per-glyph выходов GPU. nil - решение по инстансу не
    // принимается: невидимый глиф (путь за камерой/короче лейбла), глиф,
    // экстраполированный за концы пути, или превышение поворота между соседними
    // глифами (maxGlyphTurnRadians) - те же правила, что у прежнего CPU-пути,
    // но по углам реально нарисованных глифов.
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

    private func buildRoadLabelState(frameContext: FrameContext,
                                     roadVisibility: [Bool]) -> RoadLabelState {
        guard let roadLabelCache,
              frameContext.renderSurfaceMode == .flat,
              roadLabelCache.instanceKeys.isEmpty == false else {
            return .empty
        }

        if cachedRoadPresentationInputsGeneration != visibilityTopologyGeneration {
            cachedRoadPresentationInputs.removeAll(keepingCapacity: true)
            cachedRoadPresentationInputs.reserveCapacity(roadLabelCache.instanceKeys.count)
            for index in roadLabelCache.instanceKeys.indices {
                cachedRoadPresentationInputs.append(BaseLabelPresentationInput(labelKey: roadLabelCache.instanceKeys[index],
                                                                               duplicate: 0,
                                                                               isRetained: roadLabelCache.instanceRetainedFlags[index],
                                                                               isValid: true,
                                                                               minCameraZoom: 0))
            }
            cachedRoadPresentationInputsGeneration = visibilityTopologyGeneration
        }
        let presentationInputs = cachedRoadPresentationInputs

        roadTargetVisibilityScratch.removeAll(keepingCapacity: true)
        roadTargetVisibilityScratch.reserveCapacity(roadLabelCache.instanceKeys.count)
        for index in roadLabelCache.instanceKeys.indices {
            roadTargetVisibilityScratch.append(index < roadVisibility.count ? roadVisibility[index] : false)
        }
        let targetVisibility = roadTargetVisibilityScratch

        let fadeResolution = roadPresentationStateStore.resolveAlphas(inputs: presentationInputs,
                                                                      targetVisibility: targetVisibility,
                                                                      time: frameContext.time,
                                                                      frameIndex: frameContext.frameIndex,
                                                                      fadeInSeconds: fadeInSeconds,
                                                                      fadeOutSeconds: fadeOutSeconds)

        let frameSlotIndex = frameContext.frameSlotIndex
        let activeRoadLabelTiles = makeActiveRoadLabelTiles(records: roadLabelCache.orderedTileRecords)
        var aggregatedRuntimeMeta: [LabelRuntimeMeta] = []
        aggregatedRuntimeMeta.reserveCapacity(roadLabelCache.instanceKeys.count)
        var drawBatches: [DrawRoadLabels] = []
        drawBatches.reserveCapacity(roadLabelCache.orderedTileRecords.count)
        var totalGlyphCount = 0

        for record in roadLabelCache.orderedTileRecords {
            let start = record.instanceStart
            let end = start + record.instanceKeys.count
            var runtimeMeta: [LabelRuntimeMeta] = []
            runtimeMeta.reserveCapacity(record.instanceKeys.count)
            for index in start..<end {
                let alpha = index < fadeResolution.fadeAlphas.count ? fadeResolution.fadeAlphas[index] : 0
                let meta = LabelRuntimeMeta(duplicate: 0,
                                            isRetained: roadLabelCache.instanceRetainedFlags[index],
                                            visibleTileIndex: 0,
                                            fadeAlpha: alpha,
                                            labelSizePx: roadLabelCache.instanceLabelSizes[index])
                runtimeMeta.append(meta)
                aggregatedRuntimeMeta.append(meta)
            }
            let runtimeMetaBuffer = record.runtimeMetaBuffer(slot: frameSlotIndex, meta: runtimeMeta)
            drawBatches.append(DrawRoadLabels(placementBuffer: nil,
                                              glyphInputBuffer: record.glyphInputsBuffer,
                                              runtimeMetaBuffer: runtimeMetaBuffer,
                                              localGlyphVerticesBuffer: record.localGlyphVerticesBuffer,
                                              glyphCount: record.glyphCount,
                                              localGlyphVertexCount: record.localGlyphVertexCount,
                                              labelStyle: record.labelStyle))
            totalGlyphCount += record.glyphCount
        }

        let hasVisibleOrAnimatingRoadLabels = fadeResolution.hasActiveAnimations ||
            aggregatedRuntimeMeta.contains(where: { $0.fadeAlpha > 0.0001 })
        guard hasVisibleOrAnimatingRoadLabels else {
            roadDrawLabels = []
            return .empty
        }

        let runtimeMetaBuffer = roadRuntimeMetaBufferStore.ensureCapacity(slot: frameSlotIndex,
                                                                          count: max(1, aggregatedRuntimeMeta.count))
        upload(values: aggregatedRuntimeMeta, into: runtimeMetaBuffer)
        roadDrawLabels = drawBatches
        return RoadLabelState(instanceCount: roadLabelCache.instanceKeys.count,
                              glyphCount: totalGlyphCount,
                              activeRoadLabelTiles: activeRoadLabelTiles,
                              runtimeMetaBuffer: runtimeMetaBuffer,
                              placementBuffer: nil,
                              glyphInputBuffer: drawBatches.first?.glyphInputBuffer,
                              glyphVerticesBuffer: drawBatches.first?.localGlyphVerticesBuffer,
                              glyphVertexCount: drawBatches.first?.localGlyphVertexCount ?? 0,
                              drawLabels: drawBatches,
                              hasActiveFadeAnimations: fadeResolution.hasActiveAnimations)
    }

    private func makeActiveRoadLabelTiles(records: [RoadLabelTileRecord]) -> [VisibleTile] {
        guard records.isEmpty == false else {
            return []
        }
        guard let latestActiveRoadRecordIndices else {
            return records.map(\.ownerKey)
        }
        return records.enumerated().compactMap { index, record in
            latestActiveRoadRecordIndices.contains(index) ? record.ownerKey : nil
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

}

private struct RoadPreparation {
    let instances: [RoadPreparedInstance]
    let hiddenInstanceIndices: [Int]
}

enum VisibilityCollisionTarget: Hashable {
    case base(Int)
    case road(Int)
}

struct VisibilityCollisionRank: Equatable {
    let priority: Int
    let secondaryPriority: Int
    let sortPriority: Int

    func strictlyOutranks(_ other: VisibilityCollisionRank) -> Bool {
        if priority != other.priority {
            return priority < other.priority
        }
        if secondaryPriority != other.secondaryPriority {
            return secondaryPriority < other.secondaryPriority
        }
        if sortPriority != other.sortPriority {
            return sortPriority < other.sortPriority
        }
        return false
    }
}

struct VisibilityCollisionGroup {
    let target: VisibilityCollisionTarget
    let members: [ScreenCollisionCandidate]
    let rank: VisibilityCollisionRank
    let stableOrderKey: UInt64

    init(target: VisibilityCollisionTarget,
         members: [ScreenCollisionCandidate],
         priority: Int,
         secondaryPriority: Int,
         sortPriority: Int = .max,
         stableOrderKey: UInt64? = nil) {
        self.target = target
        self.members = members
        self.rank = VisibilityCollisionRank(priority: priority,
                                            secondaryPriority: secondaryPriority,
                                            sortPriority: sortPriority)
        self.stableOrderKey = stableOrderKey ?? Self.stableOrderKey(for: target)
    }

    var priority: Int { rank.priority }
    var secondaryPriority: Int { rank.secondaryPriority }
    var sortPriority: Int { rank.sortPriority }

    static func sortForCollisionOrder(lhs: VisibilityCollisionGroup,
                                      rhs: VisibilityCollisionGroup) -> Bool {
        if lhs.rank.strictlyOutranks(rhs.rank) {
            return true
        }
        if rhs.rank.strictlyOutranks(lhs.rank) {
            return false
        }
        return lhs.stableOrderKey < rhs.stableOrderKey
    }

    private static func stableOrderKey(for target: VisibilityCollisionTarget) -> UInt64 {
        switch target {
        case let .base(index):
            return UInt64(index)
        case let .road(index):
            return UInt64(index) | (1 << 63)
        }
    }
}

final class VisibilityCycle {
    let topologyGeneration: UInt64
    let cameraFingerprint: Int
    let horizonReservationSignature: [Int]
    private let groups: [VisibilityCollisionGroup]
    private let gridWidth: Int
    private let gridHeight: Int
    private let cellSizePx: Float

    private(set) var cursor: Int = 0
    private(set) var baseCollisionVisibility: [BaseLabelCollisionVisibility]
    private(set) var roadInstanceVisibility: [Bool]
    private(set) var roadInstanceVisibilityResolved: [Bool]
    private var gridBuckets: [[VisibilityPlacedCandidate]]
    // Ячейки, занятые каждым размещённым target - чтобы эвикция чистила только их,
    // а не сканировала всю сетку.
    private var coveredCellsByTarget: [VisibilityCollisionTarget: [CoveredCellRange]] = [:]
    // Выключенные кандидаты публикуются .hidden только при завершении цикла:
    // прерванный цикл (forceRestart) сохраняет им прежнюю published-видимость,
    // как это делал бюджетный обход по группам.
    private let resolvedHiddenBaseIndices: [Int]
    private var didApplyResolvedHiddenBaseIndices = false
    // Индексы, чьи решения ещё не перенесены в published-состояние: за кадр
    // решается максимум budget групп, полное слияние массивов не нужно.
    private var pendingPublishedBaseIndices: [Int] = []
    private var pendingPublishedRoadIndices: [Int] = []
    // Переиспользуемые буферы processGroup/seedGroupIfUnblocked: аллокация на
    // каждую из ~3.7k групп цикла - заметная доля malloc/free в профиле.
    private var scratchCovered: [(candidate: VisibilityPlacedCandidate, cells: CoveredCellRange)] = []
    private var scratchTargetsToEvict: [VisibilityCollisionTarget] = []

    init(topologyGeneration: UInt64,
         cameraFingerprint: Int,
         horizonReservationSignature: [Int],
         viewportSize: SIMD2<Float>,
         baseCount: Int,
         roadCount: Int,
         groups: [VisibilityCollisionGroup],
         seededGroups: [VisibilityCollisionGroup] = [],
         resolvedHiddenBaseIndices: [Int] = [],
         resolvedHiddenRoadIndices: [Int] = [],
         cellSizePx: Float) {
        self.topologyGeneration = topologyGeneration
        self.cameraFingerprint = cameraFingerprint
        self.horizonReservationSignature = horizonReservationSignature
        self.groups = groups
        self.cellSizePx = cellSizePx
        self.gridWidth = max(1, Int(ceil(max(1.0, viewportSize.x) / cellSizePx)))
        self.gridHeight = max(1, Int(ceil(max(1.0, viewportSize.y) / cellSizePx)))
        self.baseCollisionVisibility = Array(repeating: .unknown, count: baseCount)
        self.roadInstanceVisibility = Array(repeating: false, count: roadCount)
        self.roadInstanceVisibilityResolved = Array(repeating: false, count: roadCount)
        self.gridBuckets = Array(repeating: [], count: max(1, self.gridWidth * self.gridHeight))
        self.resolvedHiddenBaseIndices = resolvedHiddenBaseIndices
        for index in resolvedHiddenRoadIndices where index >= 0 && index < roadInstanceVisibilityResolved.count {
            self.roadInstanceVisibilityResolved[index] = true
            self.pendingPublishedRoadIndices.append(index)
        }
        seedGroups(seededGroups)
        applyResolvedHiddenBaseIndicesIfComplete()
    }

    /// Переносит накопленные решения цикла в published-состояние подписчика
    /// и очищает очередь. Порядок применения повторяет порядок решений -
    /// последняя запись по индексу побеждает, как и при полном слиянии.
    func drainPendingPublications(base: (Int, BaseLabelCollisionVisibility) -> Void,
                                  road: (Int, Bool) -> Void) {
        for index in pendingPublishedBaseIndices {
            base(index, baseCollisionVisibility[index])
        }
        for index in pendingPublishedRoadIndices {
            road(index, roadInstanceVisibility[index])
        }
        pendingPublishedBaseIndices.removeAll(keepingCapacity: true)
        pendingPublishedRoadIndices.removeAll(keepingCapacity: true)
    }

    var isComplete: Bool {
        cursor >= groups.count
    }

    var groupCount: Int {
        groups.count
    }

    func processNextGroups(maxGroupCount: Int) {
        guard maxGroupCount > 0, isComplete == false else {
            return
        }

        let end = min(groups.count, cursor + maxGroupCount)
        while cursor < end {
            processGroup(groups[cursor])
            cursor += 1
        }
        applyResolvedHiddenBaseIndicesIfComplete()
    }

    private func applyResolvedHiddenBaseIndicesIfComplete() {
        guard isComplete, didApplyResolvedHiddenBaseIndices == false else {
            return
        }
        didApplyResolvedHiddenBaseIndices = true
        for index in resolvedHiddenBaseIndices where index >= 0 && index < baseCollisionVisibility.count {
            if baseCollisionVisibility[index] == .unknown {
                baseCollisionVisibility[index] = .hidden
                pendingPublishedBaseIndices.append(index)
            }
        }
    }

    private func processGroup(_ group: VisibilityCollisionGroup) {
        scratchCovered.removeAll(keepingCapacity: true)
        scratchTargetsToEvict.removeAll(keepingCapacity: true)

        for member in group.members {
            guard member.isEnabled,
                  let cells = makeCoveredCellRange(for: member) else {
                continue
            }
            let placed = VisibilityPlacedCandidate(position: member.position,
                                                   halfSize: member.halfSize,
                                                   groupId: member.groupId,
                                                   target: group.target,
                                                   rank: group.rank)
            guard collectEvictableCollisions(for: placed,
                                             cells: cells,
                                             rank: group.rank,
                                             targetsToEvict: &scratchTargetsToEvict) else {
                applyRejected(group.target)
                return
            }
            scratchCovered.append((placed, cells))
        }

        guard scratchCovered.isEmpty == false else {
            applyRejected(group.target)
            return
        }
        for target in scratchTargetsToEvict {
            removePlacement(of: target)
            applyRejected(target)
        }
        // Посеянная в init цель при повторном accept уже размещена в сетке -
        // без удаления прежнего размещения её члены дублировались бы в бакетах,
        // удлиняя все последующие AABB-сканы (решения не меняются: дубликаты
        // геометрически идентичны и скрыты от само-коллизий groupId).
        if coveredCellsByTarget[group.target] != nil {
            removePlacement(of: group.target)
        }
        for item in scratchCovered {
            insert(item.candidate, cells: item.cells)
        }
        applyAccepted(group.target)
    }

    private func seedGroups(_ groups: [VisibilityCollisionGroup]) {
        for group in groups.sorted(by: VisibilityCollisionGroup.sortForCollisionOrder) {
            seedGroupIfUnblocked(group)
        }
    }

    private func seedGroupIfUnblocked(_ group: VisibilityCollisionGroup) {
        scratchCovered.removeAll(keepingCapacity: true)

        for member in group.members {
            guard member.isEnabled,
                  let cells = makeCoveredCellRange(for: member) else {
                continue
            }
            let placed = VisibilityPlacedCandidate(position: member.position,
                                                   halfSize: member.halfSize,
                                                   groupId: member.groupId,
                                                   target: group.target,
                                                   rank: group.rank)
            if hasAnyCollision(candidate: placed, cells: cells) {
                applyRejected(group.target)
                return
            }
            scratchCovered.append((placed, cells))
        }

        guard scratchCovered.isEmpty == false else {
            applyRejected(group.target)
            return
        }
        for item in scratchCovered {
            insert(item.candidate, cells: item.cells)
        }
    }

    private func applyAccepted(_ target: VisibilityCollisionTarget) {
        switch target {
        case let .base(index):
            guard index < baseCollisionVisibility.count else { return }
            baseCollisionVisibility[index] = .visible
            pendingPublishedBaseIndices.append(index)
        case let .road(index):
            guard index < roadInstanceVisibility.count else { return }
            roadInstanceVisibility[index] = true
            roadInstanceVisibilityResolved[index] = true
            pendingPublishedRoadIndices.append(index)
        }
    }

    private func applyRejected(_ target: VisibilityCollisionTarget) {
        switch target {
        case let .base(index):
            guard index < baseCollisionVisibility.count else { return }
            baseCollisionVisibility[index] = .hidden
            pendingPublishedBaseIndices.append(index)
        case let .road(index):
            guard index < roadInstanceVisibility.count else { return }
            roadInstanceVisibility[index] = false
            roadInstanceVisibilityResolved[index] = true
            pendingPublishedRoadIndices.append(index)
        }
    }

    // Возвращает false, если найдена коллизия, которую rank не перевешивает
    // (группа должна быть отклонена); иначе накапливает цели на эвикцию.
    // targetsToEvict - массив с линейной дедупликацией: эвиктится обычно 0-2
    // цели, Set на каждую группу дороже (hash + аллокация).
    private func collectEvictableCollisions(for candidate: VisibilityPlacedCandidate,
                                            cells: CoveredCellRange,
                                            rank: VisibilityCollisionRank,
                                            targetsToEvict: inout [VisibilityCollisionTarget]) -> Bool {
        for cellY in cells.minY...cells.maxY {
            for cellX in cells.minX...cells.maxX {
                let bucketIndex = cellY * gridWidth + cellX
                for other in gridBuckets[bucketIndex] {
                    if candidate.groupId != 0,
                       candidate.groupId == other.groupId {
                        continue
                    }
                    let delta = simd_abs(candidate.position - other.position)
                    let overlap = candidate.halfSize + other.halfSize
                    if delta.x < overlap.x && delta.y < overlap.y {
                        guard rank.strictlyOutranks(other.rank) else {
                            return false
                        }
                        if targetsToEvict.contains(other.target) == false {
                            targetsToEvict.append(other.target)
                        }
                    }
                }
            }
        }
        return true
    }

    private func hasAnyCollision(candidate: VisibilityPlacedCandidate,
                                 cells: CoveredCellRange) -> Bool {
        for cellY in cells.minY...cells.maxY {
            for cellX in cells.minX...cells.maxX {
                let bucketIndex = cellY * gridWidth + cellX
                for other in gridBuckets[bucketIndex] {
                    if candidate.groupId != 0,
                       candidate.groupId == other.groupId {
                        continue
                    }
                    let delta = simd_abs(candidate.position - other.position)
                    let overlap = candidate.halfSize + other.halfSize
                    if delta.x < overlap.x && delta.y < overlap.y {
                        return true
                    }
                }
            }
        }
        return false
    }

    private func removePlacement(of target: VisibilityCollisionTarget) {
        guard let cellRanges = coveredCellsByTarget.removeValue(forKey: target) else {
            return
        }
        for cells in cellRanges {
            for cellY in cells.minY...cells.maxY {
                for cellX in cells.minX...cells.maxX {
                    let bucketIndex = cellY * gridWidth + cellX
                    gridBuckets[bucketIndex].removeAll { $0.target == target }
                }
            }
        }
    }

    private func insert(_ candidate: VisibilityPlacedCandidate,
                        cells: CoveredCellRange) {
        coveredCellsByTarget[candidate.target, default: []].append(cells)
        for cellY in cells.minY...cells.maxY {
            for cellX in cells.minX...cells.maxX {
                let bucketIndex = cellY * gridWidth + cellX
                gridBuckets[bucketIndex].append(candidate)
            }
        }
    }

    private func makeCoveredCellRange(for candidate: ScreenCollisionCandidate) -> CoveredCellRange? {
        let viewportSize = SIMD2<Float>(Float(gridWidth) * cellSizePx, Float(gridHeight) * cellSizePx)
        let minX = candidate.position.x - candidate.halfSize.x
        let maxX = candidate.position.x + candidate.halfSize.x
        let minY = candidate.position.y - candidate.halfSize.y
        let maxY = candidate.position.y + candidate.halfSize.y

        if maxX < 0 || maxY < 0 || minX > viewportSize.x || minY > viewportSize.y {
            return nil
        }

        let clampedMinX = max(0.0, minX)
        let clampedMaxX = min(viewportSize.x, maxX)
        let clampedMinY = max(0.0, minY)
        let clampedMaxY = min(viewportSize.y, maxY)

        let startCellX = min(max(Int(floor(clampedMinX / cellSizePx)), 0), gridWidth - 1)
        let endCellX = min(max(Int(floor(clampedMaxX / cellSizePx)), 0), gridWidth - 1)
        let startCellY = min(max(Int(floor(clampedMinY / cellSizePx)), 0), gridHeight - 1)
        let endCellY = min(max(Int(floor(clampedMaxY / cellSizePx)), 0), gridHeight - 1)

        return CoveredCellRange(minX: startCellX,
                                maxX: endCellX,
                                minY: startCellY,
                                maxY: endCellY)
    }
}

private struct VisibilityPlacedCandidate {
    let position: SIMD2<Float>
    let halfSize: SIMD2<Float>
    let groupId: UInt64
    let target: VisibilityCollisionTarget
    let rank: VisibilityCollisionRank
}

private struct CoveredCellRange {
    let minX: Int
    let maxX: Int
    let minY: Int
    let maxY: Int
}

private struct RoadPreparedInstance {
    let instanceKey: UInt64
    let targetIndex: Int
    let collisionCandidates: [ScreenCollisionCandidate]
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
