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

    private var targetsHashTracker = StagedHashChangeTracker()
    private var placeTilesContext: PlaceTilesContext = .empty
    private var backdropPlaceTilesContext: PlaceTilesContext = .empty
    private var buildingPlaceTilesContext: PlaceTilesContext = .empty
    private var placementVersion: UInt64 = 0
    private var demandGateFingerprint: Int?
    private var latestRequestedTilesCount: Int = 0
    private var latestCounts = (visible: 0, demanded: 0, ready: 0)

    init(tileRenderStore: TileRenderStore,
         tileTraceRecorder: TileTraceRecorder) {
        self.tileRenderStore = tileRenderStore
        self.tileTraceRecorder = tileTraceRecorder
    }

    func update(frameContext: FrameContext) {
        // The coverage: the frame's targets, every tile at the zoom its
        // distance from the eye wants (`TileCulling`), and the horizon
        // backdrop under them on the plane.
        let visibleContent = frameContext.visibleContent
        let center = visibleContent.center
        let targets = visibleContent.visibleTiles
        let tileZoomLevel = visibleContent.tileZoomLevel

        // Dirty-gate: demand/request/placement depend only on the coverage
        // (coverageVersion changes when the camera, the mode or the reach
        // changes) and the working set's contents (contentVersion changes on
        // insert/release). Skipping is allowed only when there are no
        // requested-but-not-ready tiles: the loader's retry logic relies on
        // the per-frame request().
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

        // The backdrop's demand and placements are shared with the coverage.
        let backdropTiles = visibleContent.backdropTiles
        // A backdrop exists - beneath the main coverage the whole frame is painted
        // at its zoom, so the planner's substitutes never go to that zoom or
        // coarser (it is already drawn by the layer below).
        let backdropZoomLevel = backdropTiles.isEmpty ? nil : TileCulling.flatBackdropZoomLevel
        // The demand is the targets and the backdrop, nothing else: no
        // stand-in is asked for. What covers a loading target is what is
        // resident already (the working set keeps the tiles that stand in
        // for one, see `TileWorkingSetStore`), and beneath it the backdrop
        // or the pinned world cover. `VisibleTile` includes `loop`, so
        // flat-mode wrapped copies share one content tile (`Tile`); the
        // list is deduplicated.
        let demandedSourceTiles = Self.uniqueSourceTiles(of: targets + backdropTiles)
        // Demand order = network and parsing priority: tiles closest to the camera
        // start first. The placement hash uses the stable
        // `demandedSourceTiles` (center-based sorting would change on every
        // camera shift and cause needless rebuilds) - both lists have the same contents.
        let prioritizedTargets = TileDemandPriorityMath.sortedByCameraProximity(targets,
                                                                                centerWorldMercator: visibleContent.centerWorldMercator,
                                                                                renderSurfaceMode: frameContext.renderSurfaceMode)
        let prioritizedDemand = Self.uniqueSourceTiles(of: prioritizedTargets + backdropTiles)
        // Returns source-tile availability map for GPU rendering:
        // value contains Metal-ready tile buffers, or `nil` while still loading.
        let tileRequestResult = tileRenderStore.requestTiles(prioritizedDemand,
                                                             frameIndex: frameContext.frameIndex)
        let readyTilesBySource = tileRequestResult.readyTilesBySource

        var hashBuilder = Hasher()
        hashBuilder.combine(CoverageTargetsHasher.computeTargetsHash(
            targets: targets + backdropTiles,
            demandedSourceTiles: demandedSourceTiles,
            readyTilesBySource: readyTilesBySource
        ))
        // The placement also reads the stand-ins (descendants standing in
        // are never demanded), so a tile landing outside the demand, which
        // bumps the content version, rebuilds it too.
        hashBuilder.combine(tileRenderStore.cacheContentVersion)
        let targetsHash = hashBuilder.finalize()

        let placementChanged = targetsHashTracker.stage(targetsHash)
        if placementChanged {
            // The placement is a function of the targets and of what is
            // resident now (the stand-ins included): nothing is carried
            // over from the previous frame's placement.
            let resident = tileRenderStore.residentTiles()
            placeTilesContext = TilePlacementPlanner.buildPlacements(targets: targets,
                                                                     resident: resident,
                                                                     zoom: tileZoomLevel,
                                                                     backdropZoomLevel: backdropZoomLevel)
            backdropPlaceTilesContext = TilePlacementPlanner.buildPlacements(targets: backdropTiles,
                                                                             resident: resident,
                                                                             zoom: tileZoomLevel,
                                                                             descendantSearchDepth: 0)
            // The buildings: a partition of the near field over the resident
            // tiles, never a substitute (see the planner).
            let eyeGroundCell: SIMD2<Double>? = frameContext.renderSurfaceMode == .flat
                ? FlatCoverageCamera.eyeGround(eye: frameContext.cameraEye,
                                               flatRenderState: frameContext.resolvedPresentation.flatRenderState,
                                               lookAt: SIMD2<Double>(center.tileX, center.tileY),
                                               targetZoom: tileZoomLevel)
                    * pow(2.0, Double(BuildingCoveragePlanner.minimumSourceZoom - tileZoomLevel))
                : nil
            buildingPlaceTilesContext = BuildingCoveragePlanner.plan(resident: resident,
                                                                     visibleTiles: targets,
                                                                     eyeGroundCell: eyeGroundCell,
                                                                     targetZoom: tileZoomLevel)
            placementVersion &+= 1
            targetsHashTracker.commitPending()
        }

        let visibleTilesCount = targets.count
        let readyTilesCount = tileRequestResult.readyTilesCount
        let requestedTilesCount = tileRequestResult.requestedTilesCount
        let renderedTilesCount = placeTilesContext.tilePlacements.count
        let lodSummary = summarizeLOD(placeTilesContext.tilePlacements)
        tileTraceRecorder.record(.tileDemandUpdate(frameIndex: frameContext.frameIndex,
                                                   visible: visibleTilesCount,
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
                        demanded: demandedSourceTiles.count,
                        ready: readyTilesCount)

        publishState(frameContext: frameContext,
                     visibleTilesCount: visibleTilesCount,
                     readyTilesCount: readyTilesCount,
                     requestedTilesCount: requestedTilesCount)
    }


    /// The content tiles of the targets, first occurrence first.
    private static func uniqueSourceTiles(of targets: [VisibleTile]) -> [Tile] {
        var seen = Set<Tile>()
        seen.reserveCapacity(targets.count)
        var tiles: [Tile] = []
        tiles.reserveCapacity(targets.count)
        for target in targets where seen.insert(target.tile).inserted {
            tiles.append(target.tile)
        }
        return tiles
    }

    private func publishState(frameContext: FrameContext,
                              visibleTilesCount: Int,
                              readyTilesCount: Int,
                              requestedTilesCount: Int) {
        let renderedTilesCount = placeTilesContext.tilePlacements.count
        frameContext.sharedState.tilePlacementState = TilePlacementState(
            placeTilesContext: placeTilesContext,
            backdropPlaceTilesContext: backdropPlaceTilesContext,
            buildingPlaceTilesContext: buildingPlaceTilesContext,
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
        // Placement contexts are kept and hold their tiles strongly; the store
        // keeps the demanded set, so the map doesn't go blank; the next frame
        // rebuilds placements from scratch.
        targetsHashTracker.invalidate()
        demandGateFingerprint = nil
        placementVersion &+= 1
    }

    func evict() {
        tileRenderStore.evict()
        placeTilesContext = .empty
        backdropPlaceTilesContext = .empty
        buildingPlaceTilesContext = .empty
        targetsHashTracker.invalidate()
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
