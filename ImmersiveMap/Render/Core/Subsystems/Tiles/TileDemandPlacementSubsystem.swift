// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

//
//  TileDemandPlacementSubsystem.swift
//  ImmersiveMap
//

import Foundation
import Metal
import simd

final class TileDemandPlacementSubsystem: RenderSubsystem {
    let name: String = "TileDemandPlacement"
    
    private let tileRenderStore: TileRenderStore
    private let tileTraceRecorder: TileTraceRecorder
    private let visibleTilesPreprocessor: VisibleTilesPreprocessor

    private var preprocessedVisibleTilesHashTracker = StagedHashChangeTracker()
    private var placeTilesContext: PlaceTilesContext = .empty
    private var tileAtlasPlaceTilesContext: TileAtlasPlaceTilesContext = .empty
    private var placementVersion: UInt64 = 0
    private var demandGateFingerprint: Int?
    private var latestRequestedTilesCount: Int = 0
    private var latestCounts = (visible: 0, preprocessed: 0, demanded: 0, ready: 0)

    init(tileRenderStore: TileRenderStore,
         tileTraceRecorder: TileTraceRecorder,
         visibleTilesPreprocessor: VisibleTilesPreprocessor = VisibleTilesPreprocessor()) {
        self.tileRenderStore = tileRenderStore
        self.tileTraceRecorder = tileTraceRecorder
        self.visibleTilesPreprocessor = visibleTilesPreprocessor
    }

    func update(frameContext: FrameContext) {
        // Tile culling stage: resolves current map-space center and
        // computes which tiles are visible for the active view mode.
        let visibleContent = frameContext.visibleContent
        let center = visibleContent.center
        let visibleTiles = visibleContent.visibleTiles
        let tileZoomLevel = visibleContent.tileZoomLevel

        // Dirty-gate: preprocess/demand/request зависят только от покрытия
        // (coverageVersion меняется при смене камеры/режима) и содержимого кэша
        // тайлов (contentVersion меняется при материализации/вытеснении).
        // Пропуск допустим только когда нет запрошенных-но-не-готовых тайлов:
        // retry-логика загрузчика опирается на пер-кадровый request().
        var gateHasher = Hasher()
        gateHasher.combine(visibleContent.coverageVersion)
        gateHasher.combine(tileRenderStore.cacheContentVersion)
        let gateFingerprint = gateHasher.finalize()
        if gateFingerprint == demandGateFingerprint,
           latestRequestedTilesCount == 0 {
            publishState(frameContext: frameContext,
                         visibleTilesCount: latestCounts.visible,
                         readyTilesCount: latestCounts.ready,
                         requestedTilesCount: 0)
            return
        }

        // Visible-tiles post-processing:
        // shortens the raw visible list and substitutes distant tiles
        // with coarser parents to reduce load/placement pressure.
        let preprocessedVisibleTiles = visibleTilesPreprocessor.preprocess(visibleTiles: visibleTiles,
                                                                           center: center,
                                                                           renderSurfaceMode: frameContext.renderSurfaceMode,
                                                                           transition: frameContext.transition)
        // `VisibleTile` includes `loop`, so flat-mode wrapped copies can produce
        // multiple placement targets that share the same content tile (`Tile`).
        // Deduplicate before storage request to avoid repeated cache lookup/request
        // for identical source bytes.
        let demandedSourceTiles = TileDemandSourcePlanner.makeDemandedSourceTiles(targets: preprocessedVisibleTiles,
                                                                                  parentFallbackDepth: 2)
        // Returns source-tile availability map for GPU rendering:
        // value contains Metal-ready tile buffers, or `nil` while still loading.
        let tileRequestResult = tileRenderStore.requestTiles(demandedSourceTiles,
                                                             frameIndex: frameContext.frameIndex)
        let readyTilesBySource = tileRequestResult.readyTilesBySource

        var hashBuilder = Hasher()
        hashBuilder.combine(PreprocessedVisibleTilesHasher.computePreprocessedVisibleTilesHash(
            preprocessedVisibleTiles: preprocessedVisibleTiles,
            demandedSourceTiles: demandedSourceTiles,
            readyTilesBySource: readyTilesBySource
        ))
        let preprocessedVisibleTilesHash = hashBuilder.finalize()

        let placementChanged = preprocessedVisibleTilesHashTracker.stage(preprocessedVisibleTilesHash)
        if placementChanged {
            placeTilesContext = TilePlacementPlanner.buildPlacements(targets: preprocessedVisibleTiles,
                                                                     readyTilesBySource: readyTilesBySource,
                                                                     zoom: tileZoomLevel,
                                                                     previousContext: placeTilesContext)
            tileAtlasPlaceTilesContext = TileAtlasPlaceTilesPlanner.buildPlacements(baseTargets: preprocessedVisibleTiles,
                                                                                         readyTilesBySource: readyTilesBySource,
                                                                                         baseZoom: tileZoomLevel,
                                                                                         previousContext: tileAtlasPlaceTilesContext)
            placementVersion &+= 1
            preprocessedVisibleTilesHashTracker.commitPending()
        }

        let visibleTilesCount = visibleTiles.count
        let readyTilesCount = tileRequestResult.readyTilesCount
        let requestedTilesCount = tileRequestResult.requestedTilesCount
        let renderedTilesCount = placeTilesContext.tilePlacements.count
        let lodSummary = summarizeLOD(placeTilesContext.tilePlacements)
        tileTraceRecorder.record(.tileDemandUpdate(frameIndex: frameContext.frameIndex,
                                                   visible: visibleTilesCount,
                                                   preprocessed: preprocessedVisibleTiles.count,
                                                   demanded: demandedSourceTiles.count,
                                                   ready: readyTilesCount,
                                                   requested: requestedTilesCount,
                                                   rendered: renderedTilesCount,
                                                   placementChanged: placementChanged,
                                                   placementVersion: placementVersion,
                                                   surface: frameContext.renderSurfaceMode == .spherical ? "globe" : "flat",
                                                   lodExact: lodSummary.exact,
                                                   lodCoarse: lodSummary.coarse,
                                                   lodRetained: lodSummary.retained))

        demandGateFingerprint = gateFingerprint
        latestRequestedTilesCount = requestedTilesCount
        latestCounts = (visible: visibleTilesCount,
                        preprocessed: preprocessedVisibleTiles.count,
                        demanded: demandedSourceTiles.count,
                        ready: readyTilesCount)

        publishState(frameContext: frameContext,
                     visibleTilesCount: visibleTilesCount,
                     readyTilesCount: readyTilesCount,
                     requestedTilesCount: requestedTilesCount)
    }

    private func publishState(frameContext: FrameContext,
                              visibleTilesCount: Int,
                              readyTilesCount: Int,
                              requestedTilesCount: Int) {
        let renderedTilesCount = placeTilesContext.tilePlacements.count
        frameContext.sharedState.tilePlacementState = TilePlacementState(
            placeTilesContext: placeTilesContext,
            tileAtlasPlaceTilesContext: tileAtlasPlaceTilesContext,
            placementVersion: placementVersion,
            visibleTilesCount: visibleTilesCount,
            readyTilesCount: readyTilesCount,
            requestedTilesCount: requestedTilesCount,
            renderedTilesCount: renderedTilesCount
        )
        frameContext.sharedState.placeTileTrackingState = PlaceTileTrackingState(placeTiles: placeTilesContext.tilePlacements)

        frameContext.services.diagnostics.setCounter(.visibleTiles, value: visibleTilesCount)
        frameContext.services.diagnostics.setCounter(.readyTiles, value: readyTilesCount)
        frameContext.services.diagnostics.setCounter(.requestedTiles, value: requestedTilesCount)
        frameContext.services.diagnostics.setCounter(.renderedTiles, value: renderedTilesCount)
    }

    func prepareGPU(frameContext _: FrameContext, resourceRegistry _: RenderResourceRegistry) {}

    func encode(layer _: RenderLayer, encoder _: MTLRenderCommandEncoder, frameContext _: FrameContext) {}

    func handleMemoryWarning() {
        tileRenderStore.handleMemoryWarning()
        // Контексты размещения сохраняются: trim в store защищает видимые тайлы,
        // поэтому карта не пустеет; следующий кадр пересоберёт размещения заново.
        preprocessedVisibleTilesHashTracker.invalidate()
        demandGateFingerprint = nil
        placementVersion &+= 1
    }

    func evict() {
        tileRenderStore.evict()
        placeTilesContext = .empty
        tileAtlasPlaceTilesContext = .empty
        preprocessedVisibleTilesHashTracker.invalidate()
        demandGateFingerprint = nil
        placementVersion &+= 1
    }

    private func summarizeLOD(_ placements: [PlaceTile]) -> (exact: Int, coarse: Int, retained: Int) {
        var exact = 0
        var coarse = 0
        var retained = 0
        for placement in placements {
            switch placement.lodKind {
            case .exact:
                exact += 1
            case .coarseSubstitute:
                coarse += 1
            case .retainedReplacement:
                retained += 1
            }
        }
        return (exact: exact, coarse: coarse, retained: retained)
    }
}
