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
    private var backdropPlaceTilesContext: PlaceTilesContext = .empty
    private var shadowCasterPlaceTilesContext: PlaceTilesContext = .empty
    private var globeSurfaceSlots: [Tile] = []
    private var placementVersion: UInt64 = 0
    private var demandGateFingerprint: Int?
    private var latestRequestedTilesCount: Int = 0
    private var latestCounts = (visible: 0, preprocessed: 0, demanded: 0, ready: 0)
    /// Union of the tiles the three placement contexts reference, rebuilt on
    /// every placement change and reported to the cache on every rendered
    /// frame for the purgeable bookkeeping.
    private var activePlacementTiles: Set<Tile> = []

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

        // Dirty-gate: preprocess/demand/request depend only on the coverage
        // (coverageVersion changes when the camera/mode changes) and the tile
        // cache contents (contentVersion changes on materialization/eviction).
        // Skipping is allowed only when there are no requested-but-not-ready tiles:
        // the loader's retry logic relies on the per-frame request().
        var gateHasher = Hasher()
        gateHasher.combine(visibleContent.coverageVersion)
        gateHasher.combine(tileRenderStore.cacheContentVersion)
        let gateFingerprint = gateHasher.finalize()
        if gateFingerprint == demandGateFingerprint,
           latestRequestedTilesCount == 0 {
            // The gated frame still renders the existing placements, so their
            // tiles must keep fresh activity stamps: otherwise the first
            // placement rebuild after a long gated stretch would compare
            // against stamps hundreds of frames old and could park a tile
            // volatile while in-flight GPU frames still read it.
            tileRenderStore.recordActiveTiles(activePlacementTiles,
                                              frameIndex: frameContext.frameIndex)
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
        // The horizon backdrop bypasses the preprocessor: its distance filter
        // measures distances in target-zoom tiles and would discard the coarse
        // backdrop tiles. Its demand and placements are shared with the coverage.
        let backdropTiles = visibleContent.backdropTiles
        // The sun-ward caster strip also bypasses the preprocessor: it is a
        // thin band of exact-zoom tiles just past the frustum edge, and its
        // demand rides at the tail of the priority order (shadows fill in
        // after the visible map).
        let shadowCasterTiles = visibleContent.shadowCasterTiles
        // `VisibleTile` includes `loop`, so flat-mode wrapped copies can produce
        // multiple placement targets that share the same content tile (`Tile`).
        // Deduplicate before storage request to avoid repeated cache lookup/request
        // for identical source bytes.
        let demandedSourceTiles = TileDemandSourcePlanner.makeDemandedSourceTiles(targets: preprocessedVisibleTiles + backdropTiles + shadowCasterTiles,
                                                                                  parentFallbackDepth: 2)
        // Demand order = network and parsing priority: tiles closest to the camera
        // start first. The placement hash uses the stable
        // `demandedSourceTiles` (center-based sorting would change on every
        // camera shift and cause needless rebuilds) - both lists have the same contents.
        let prioritizedTargets = TileDemandPriorityMath.sortedByCameraProximity(preprocessedVisibleTiles,
                                                                                centerWorldMercator: visibleContent.centerWorldMercator,
                                                                                renderSurfaceMode: frameContext.renderSurfaceMode)
        let prioritizedDemand = TileDemandSourcePlanner.makeDemandedSourceTiles(targets: prioritizedTargets + backdropTiles + shadowCasterTiles,
                                                                                parentFallbackDepth: 2)
        // Returns source-tile availability map for GPU rendering:
        // value contains Metal-ready tile buffers, or `nil` while still loading.
        let tileRequestResult = tileRenderStore.requestTiles(prioritizedDemand,
                                                             frameIndex: frameContext.frameIndex)
        let readyTilesBySource = tileRequestResult.readyTilesBySource

        var hashBuilder = Hasher()
        hashBuilder.combine(PreprocessedVisibleTilesHasher.computePreprocessedVisibleTilesHash(
            preprocessedVisibleTiles: preprocessedVisibleTiles + backdropTiles + shadowCasterTiles,
            demandedSourceTiles: demandedSourceTiles,
            readyTilesBySource: readyTilesBySource
        ))
        let preprocessedVisibleTilesHash = hashBuilder.finalize()

        let placementChanged = preprocessedVisibleTilesHashTracker.stage(preprocessedVisibleTilesHash)
        if placementChanged {
            // A backdrop exists - beneath the main coverage the whole frame is painted
            // at its zoom, and the planner must not fill holes with content
            // of that zoom (it is already drawn by the layer below).
            let backdropZoomLevel = backdropTiles.isEmpty ? nil : TileCulling.flatBackdropZoomLevel
            placeTilesContext = TilePlacementPlanner.buildPlacements(targets: preprocessedVisibleTiles,
                                                                     readyTilesBySource: readyTilesBySource,
                                                                     zoom: tileZoomLevel,
                                                                     previousContext: placeTilesContext,
                                                                     backdropZoomLevel: backdropZoomLevel)
            backdropPlaceTilesContext = TilePlacementPlanner.buildPlacements(targets: backdropTiles,
                                                                             readyTilesBySource: readyTilesBySource,
                                                                             zoom: tileZoomLevel,
                                                                             previousContext: backdropPlaceTilesContext)
            shadowCasterPlaceTilesContext = TilePlacementPlanner.buildPlacements(targets: shadowCasterTiles,
                                                                                 readyTilesBySource: readyTilesBySource,
                                                                                 zoom: tileZoomLevel,
                                                                                 previousContext: shadowCasterPlaceTilesContext)
            globeSurfaceSlots = preprocessedVisibleTiles.map(\.tile)
            placementVersion &+= 1
            preprocessedVisibleTilesHashTracker.commitPending()
            rebuildActivePlacementTiles()
        }

        // Purgeable bookkeeping: the cache may only park tiles that nothing
        // references, and the demanded set alone is not that (retained
        // substitutes in the placements keep drawing after leaving demand).
        // Report the union of everything the placement contexts hold, on
        // every rendered frame (the gated branch above reports too), so
        // stamps stay fresh and the in-flight window is measured from the
        // frame a tile actually stopped being drawn.
        tileRenderStore.recordActiveTiles(activePlacementTiles, frameIndex: frameContext.frameIndex)

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

    private func rebuildActivePlacementTiles() {
        var activeTiles = Set<Tile>()
        for placement in placeTilesContext.tilePlacements {
            activeTiles.insert(placement.metalTile.tile)
        }
        for placement in backdropPlaceTilesContext.tilePlacements {
            activeTiles.insert(placement.metalTile.tile)
        }
        // The sun-ward caster strip renders into the cascade maps every flat
        // frame: its tiles are as live as the visible ones and must never be
        // parked volatile under the shadow pass.
        for placement in shadowCasterPlaceTilesContext.tilePlacements {
            activeTiles.insert(placement.metalTile.tile)
        }
        activePlacementTiles = activeTiles
    }

    private func publishState(frameContext: FrameContext,
                              visibleTilesCount: Int,
                              readyTilesCount: Int,
                              requestedTilesCount: Int) {
        let renderedTilesCount = placeTilesContext.tilePlacements.count
        frameContext.sharedState.tilePlacementState = TilePlacementState(
            placeTilesContext: placeTilesContext,
            backdropPlaceTilesContext: backdropPlaceTilesContext,
            shadowCasterPlaceTilesContext: shadowCasterPlaceTilesContext,
            globeSurfaceSlots: globeSurfaceSlots,
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
        // Placement contexts are kept: the store's trim protects visible tiles,
        // so the map doesn't go blank; the next frame rebuilds placements from scratch.
        preprocessedVisibleTilesHashTracker.invalidate()
        demandGateFingerprint = nil
        placementVersion &+= 1
    }

    func evict() {
        tileRenderStore.evict()
        placeTilesContext = .empty
        backdropPlaceTilesContext = .empty
        shadowCasterPlaceTilesContext = .empty
        globeSurfaceSlots = []
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
