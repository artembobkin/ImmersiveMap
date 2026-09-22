// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation
import Metal
import simd

/// Keeps the tiles' working set in step with the frame's coverage. The
/// walk (`TileCulling`) says which tiles the frame wants, this subsystem
/// turns that into what the frame can have: it orders the wanted tiles
/// from the store nearest first and lets go of the rest, plans what
/// draws in a wanted tile's place while it loads (`TilePlacementPlanner`,
/// `BuildingCoveragePlanner`, over what is resident this frame), and
/// publishes the placements and the counts. One gate keeps it idle when
/// neither the coverage nor the store's contents changed.
final class TileWorkingSetSubsystem: RenderSubsystem {
    let name: String = "TileWorkingSet"

    private let tileRenderStore: TileRenderStore
    private let tileTraceRecorder: TileTraceRecorder

    private var placeTilesContext: PlaceTilesContext = .empty
    private var backdropPlaceTilesContext: PlaceTilesContext = .empty
    private var buildingPlaceTilesContext: PlaceTilesContext = .empty
    private var placementVersion: UInt64 = 0
    /// The coverage and the working set the last placements were planned
    /// over, nil until the first plan.
    private var plannedCoverageVersion: UInt64?
    private var plannedContentVersion: UInt64?
    private var latestRequestedTilesCount: Int = 0
    private var latestCounts = (visible: 0, demanded: 0, ready: 0)

    init(tileRenderStore: TileRenderStore,
         tileTraceRecorder: TileTraceRecorder) {
        self.tileRenderStore = tileRenderStore
        self.tileTraceRecorder = tileTraceRecorder
    }

    func update(frameContext: FrameContext) {
        // The coverage: the frame's targets, every tile at the zoom its
        // place on screen wants (`TileCulling`), and the horizon backdrop
        // under them on the plane.
        let visibleContent = frameContext.visibleContent
        let center = visibleContent.center
        let targets = visibleContent.visibleTiles
        let tileZoomLevel = visibleContent.tileZoomLevel

        // The gate: the demand, the loads and the placements depend on the
        // coverage (its version moves when the targets or the backdrop
        // change) and on the working set's contents (its version moves
        // when a tile lands and when memory pressure releases one; the
        // releases the demand itself causes touch only tiles it stopped
        // asking about), on nothing else. Both as they were when the
        // placements were last planned, and no tile in flight: nothing to
        // do. A tile in flight keeps the per-frame request going, which
        // the loader's retries rely on.
        let coverageVersion = visibleContent.coverageVersion
        if coverageVersion == plannedCoverageVersion,
           tileRenderStore.cacheContentVersion == plannedContentVersion,
           latestRequestedTilesCount == 0 {
            publishState(frameContext: frameContext,
                         visibleTilesCount: latestCounts.visible,
                         readyTilesCount: latestCounts.ready,
                         requestedTilesCount: 0)
            return
        }

        // The backdrop's demand and placements are shared with the coverage.
        let backdropTiles = visibleContent.backdropTiles
        // The plane draws no backdrop, but the world cover's zoom is still
        // the floor of the planner's stand-ins: a target still loading is
        // never covered by the pinned world tile, which at a street zoom
        // is a plain of one colour with nothing on it. The globe keeps its
        // cover as a stand-in.
        let backdropZoomLevel: Int? = frameContext.renderSurfaceMode == .flat ? TileCulling.flatBackdropZoomLevel : nil
        // The demand is the targets and the backdrop, nothing else: no
        // stand-in is asked for. What covers a loading target is what is
        // resident already (the working set keeps the tiles that stand in
        // for one, see `TileWorkingSetStore`), and beneath it the backdrop
        // or the pinned world cover. `VisibleTile` includes `worldWrap`, so
        // flat-mode wrapped copies share one content tile (`Tile`); the
        // list is deduplicated.
        let demandedSourceTiles = Self.uniqueSourceTiles(of: targets + backdropTiles)
        // Demand order = network and parsing priority: tiles closest to the
        // camera start first.
        let prioritizedTargets = TileDemandPriorityMath.sortedByCameraProximity(targets,
                                                                                centerWorldMercator: visibleContent.centerWorldMercator,
                                                                                renderSurfaceMode: frameContext.renderSurfaceMode)
        let prioritizedDemand = Self.uniqueSourceTiles(of: prioritizedTargets + backdropTiles)
        // The store keeps the demand and releases the rest.
        let tileRequestResult = tileRenderStore.requestTiles(prioritizedDemand,
                                                             frameIndex: frameContext.frameIndex)
        let contentVersion = tileRenderStore.cacheContentVersion

        // The placement is a function of the targets and of what is
        // resident now (the stand-ins included, which are never demanded):
        // replanned from scratch when either moved, kept otherwise.
        let placementChanged = coverageVersion != plannedCoverageVersion || contentVersion != plannedContentVersion
        if placementChanged {
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
                ? BuildingCoveragePlanner.eyeGroundCell(eye: frameContext.cameraEye,
                                                        flatRenderState: frameContext.resolvedPresentation.flatRenderState,
                                                        lookAt: SIMD2<Double>(center.tileX, center.tileY),
                                                        targetZoom: tileZoomLevel)
                : nil
            buildingPlaceTilesContext = BuildingCoveragePlanner.plan(resident: resident,
                                                                     visibleTiles: targets,
                                                                     eyeGroundCell: eyeGroundCell,
                                                                     targetZoom: tileZoomLevel)
            placementVersion &+= 1
            plannedCoverageVersion = coverageVersion
            plannedContentVersion = contentVersion
        }

        let visibleTilesCount = targets.count
        let readyTilesCount = tileRequestResult.readyTilesCount
        let requestedTilesCount = tileRequestResult.requestedTilesCount
        let renderedTilesCount = placeTilesContext.tilePlacements.count
        let inOwnSlotCount = placeTilesContext.tilePlacements.count { $0.inOwnSlot }
        tileTraceRecorder.record(.tileDemandUpdate(frameIndex: frameContext.frameIndex,
                                                   visible: visibleTilesCount,
                                                   demanded: demandedSourceTiles.count,
                                                   ready: readyTilesCount,
                                                   requested: requestedTilesCount,
                                                   rendered: renderedTilesCount,
                                                   placementChanged: placementChanged,
                                                   placementVersion: placementVersion,
                                                   surface: frameContext.renderSurfaceMode == .spherical ? "globe" : "flat",
                                                   inOwnSlot: inOwnSlotCount,
                                                   standIns: renderedTilesCount - inOwnSlotCount))

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

        frameContext.services.diagnostics.setCounter(.visibleTiles, value: visibleTilesCount)
        frameContext.services.diagnostics.setCounter(.readyTiles, value: readyTilesCount)
        frameContext.services.diagnostics.setCounter(.requestedTiles, value: requestedTilesCount)
        frameContext.services.diagnostics.setCounter(.renderedTiles, value: renderedTilesCount)
    }

    func prepareGPU(frameContext _: FrameContext, resourceRegistry _: RenderResourceRegistry) {}

    func encode(layer _: RenderLayer, encoder _: MTLRenderCommandEncoder, frameContext _: FrameContext) {}

    func handleMemoryWarning() {
        tileRenderStore.handleMemoryWarning()
        // The placement contexts are kept and hold their tiles strongly, and
        // the store keeps the demanded set, so the map does not go blank.
        // The next frame replans from scratch.
        plannedCoverageVersion = nil
        plannedContentVersion = nil
        placementVersion &+= 1
    }

    func evict() {
        tileRenderStore.evict()
        placeTilesContext = .empty
        backdropPlaceTilesContext = .empty
        buildingPlaceTilesContext = .empty
        plannedCoverageVersion = nil
        plannedContentVersion = nil
        placementVersion &+= 1
    }
}
