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
///
/// A raster target (`VisibleContentState.rasterTiles`) asks the raster
/// store for its texture, and the vector store for its tile only while the
/// rule draws its lines or labels, or while the texture is to be baked
/// from it. A texture that is to be baked is baked here once its vector
/// tile is resident, a few a frame.
final class TileWorkingSetSubsystem: RenderSubsystem {
    let name: String = "TileWorkingSet"

    private let tileRenderStore: TileRenderStore
    private let rasterTileStore: RasterTileStore?
    private let tileTraceRecorder: TileTraceRecorder

    private var placeTilesContext: PlaceTilesContext = .empty
    private var rasterPlacements: [RasterTilePlacement] = []
    private var buildingPlaceTilesContext: PlaceTilesContext = .empty
    private var placementVersion: UInt64 = 0
    /// The coverage and the working set the last placements were planned
    /// over, nil until the first plan.
    private var plannedCoverageVersion: UInt64?
    private var plannedContentVersion: UInt64?
    private var plannedRasterVersion: UInt64?
    private var latestRequestedTilesCount: Int = 0
    private var latestCounts = (visible: 0, demanded: 0, ready: 0)

    /// The tile zoom the buildings draw from
    /// (`BuildingCoveragePlanner.minimumDrawZoom(settings:)`): no coarser
    /// frame plans them.
    private let buildingsMinimumTileZoom: Int

    init(tileRenderStore: TileRenderStore,
         rasterTileStore: RasterTileStore? = nil,
         tileTraceRecorder: TileTraceRecorder,
         buildingsMinimumTileZoom: Int = BuildingCoveragePlanner.minimumSourceZoom) {
        self.tileRenderStore = tileRenderStore
        self.rasterTileStore = rasterTileStore
        self.tileTraceRecorder = tileTraceRecorder
        self.buildingsMinimumTileZoom = buildingsMinimumTileZoom
    }

    func update(frameContext: FrameContext) {
        // The coverage: the frame's targets, every tile at the zoom its
        // place on screen wants (`TileCulling`).
        let visibleContent = frameContext.visibleContent
        let center = visibleContent.center
        let targets = visibleContent.visibleTiles
        let tileZoomLevel = visibleContent.tileZoomLevel

        // The gate: the demand, the loads and the placements depend on the
        // coverage (its version moves when the targets change) and on the
        // working set's contents (its version moves
        // when a tile lands and when memory pressure releases one; the
        // releases the demand itself causes touch only tiles it stopped
        // asking about), on nothing else. Both as they were when the
        // placements were last planned, and no tile in flight: nothing to
        // do. A tile in flight keeps the per-frame request going, which
        // the loader's retries rely on.
        let coverageVersion = visibleContent.coverageVersion
        if coverageVersion == plannedCoverageVersion,
           tileRenderStore.cacheContentVersion == plannedContentVersion,
           rasterTileStore?.contentVersion == plannedRasterVersion,
           latestRequestedTilesCount == 0 {
            publishState(frameContext: frameContext,
                         visibleTilesCount: latestCounts.visible,
                         readyTilesCount: latestCounts.ready,
                         requestedTilesCount: 0)
            return
        }

        // On the plane the world cover's zoom is the floor of the planner's
        // stand-ins: a target still loading is never covered by the pinned
        // world tile, which at a street zoom is a plain of one colour with
        // nothing on it. The globe keeps its cover as a stand-in.
        let backdropZoomLevel: Int? = frameContext.renderSurfaceMode == .flat ? TileCulling.flatBackdropZoomLevel : nil
        // The demand is the targets, nothing else: no stand-in is asked
        // for. What covers a loading target is what is resident already
        // (the working set keeps the tiles that stand in for one, see
        // `TileWorkingSetStore`), and beneath it the pinned world cover.
        // `VisibleTile` includes `worldWrap`, so flat-mode wrapped copies
        // share one content tile (`Tile`); the list is deduplicated.
        // Demand order = network and parsing priority: tiles closest to the
        // camera start first.
        let prioritizedTargets = TileDemandPriorityMath.sortedByCameraProximity(targets,
                                                                                centerWorldMercator: visibleContent.centerWorldMercator,
                                                                                renderSurfaceMode: frameContext.renderSurfaceMode)
        // The raster targets ask for their textures first: which of them
        // is to be baked decides whether its vector tile is wanted.
        let raster = requestRasters(prioritizedTargets: prioritizedTargets, visibleContent: visibleContent)
        let vectorTargets = targets.filter { raster.wantsVector($0) }
        let demandedSourceTiles = Self.uniqueSourceTiles(of: vectorTargets)
        let prioritizedDemand = Self.uniqueSourceTiles(of: prioritizedTargets.filter { raster.wantsVector($0) })
        // The store keeps the demand and releases the rest.
        let tileRequestResult = tileRenderStore.requestTiles(prioritizedDemand,
                                                             frameIndex: frameContext.frameIndex)
        let contentVersion = tileRenderStore.cacheContentVersion

        // The placement is a function of the targets and of what is
        // resident now (the stand-ins included, which are never demanded):
        // replanned from scratch when either moved, kept otherwise.
        let rasterVersion = rasterTileStore?.contentVersion
        let placementChanged = coverageVersion != plannedCoverageVersion
            || contentVersion != plannedContentVersion
            || rasterVersion != plannedRasterVersion
        // What is resident now, read only when something is planned or
        // baked over it.
        let resident = placementChanged || raster.toBake.isEmpty == false ? tileRenderStore.residentTiles() : [:]
        if placementChanged {
            placeTilesContext = TilePlacementPlanner.buildPlacements(targets: vectorTargets,
                                                                     resident: resident,
                                                                     zoom: tileZoomLevel,
                                                                     backdropZoomLevel: backdropZoomLevel)
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
                                                                     targetZoom: tileZoomLevel,
                                                                     minimumZoom: buildingsMinimumTileZoom)
            rasterPlacements = raster.placements
            placementVersion &+= 1
            plannedCoverageVersion = coverageVersion
            plannedContentVersion = contentVersion
            plannedRasterVersion = rasterVersion
        }
        bakeRasters(raster.toBake, resident: resident)

        let visibleTilesCount = targets.count
        let readyTilesCount = tileRequestResult.readyTilesCount + raster.readyCount
        // A texture on its way or still to be baked is a tile the frame is
        // waiting for, as a loading vector tile is: the gate keeps running
        // and an export waits for it.
        let requestedTilesCount = tileRequestResult.requestedTilesCount + raster.waitingCount
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

    /// What the raster targets asked of the raster store this frame.
    private struct RasterDemand {
        var rasterTiles: [VisibleTile: RasterTileSpec] = [:]
        var visibleContent: VisibleContentState?
        var availability: [RasterTileKey: RasterTileStore.Availability] = [:]
        var placements: [RasterTilePlacement] = []
        /// The textures to bake, nearest first, with the tile each is
        /// drawn from.
        var toBake: [RasterTileKey] = []
        var readyCount = 0
        var waitingCount = 0

        /// Whether a target wants its vector tile: every vector target,
        /// and a raster target whose rule draws its lines or labels, or
        /// whose texture is to be baked from it.
        func wantsVector(_ target: VisibleTile) -> Bool {
            guard let spec = rasterTiles[target], let visibleContent else { return true }
            return visibleContent.rasterTargetWantsVector(target)
                || availability[RasterTileKey(tile: target.tile, spec: spec)] == .needsBake
        }
    }

    private func requestRasters(prioritizedTargets: [VisibleTile],
                                visibleContent: VisibleContentState) -> RasterDemand {
        guard let rasterTileStore, visibleContent.rasterTiles.isEmpty == false else { return RasterDemand() }
        var demand = RasterDemand(rasterTiles: visibleContent.rasterTiles, visibleContent: visibleContent)
        var keys: [RasterTileKey] = []
        var seen = Set<RasterTileKey>()
        for target in prioritizedTargets {
            guard let spec = visibleContent.rasterTiles[target] else { continue }
            let key = RasterTileKey(tile: target.tile, spec: spec)
            if seen.insert(key).inserted {
                keys.append(key)
            }
        }
        let request = rasterTileStore.request(keys)
        demand.availability = request.availability
        for key in keys {
            switch request.availability[key] {
            case .resident:
                demand.readyCount += 1
            case .needsBake:
                demand.toBake.append(key)
                demand.waitingCount += 1
            case .pending, nil:
                demand.waitingCount += 1
            }
        }
        // Finest first, as the vector sources draw: the finer texture marks
        // the tile-priority stencil before a coarser one reaches its pixels.
        for target in prioritizedTargets {
            guard let spec = visibleContent.rasterTiles[target] else { continue }
            let key = RasterTileKey(tile: target.tile, spec: spec)
            if let texture = request.textures[key] {
                demand.placements.append(RasterTilePlacement(key: key, texture: texture, placeIn: target))
            }
        }
        demand.placements.sort { $0.placeIn.z > $1.placeIn.z }
        return demand
    }

    /// Bakes the textures whose vector tile is resident, nearest first, as
    /// many as the store takes this frame.
    private func bakeRasters(_ keys: [RasterTileKey], resident: [Tile: MetalTile]) {
        guard let rasterTileStore, keys.isEmpty == false else { return }
        let capacity = rasterTileStore.bakeCapacity
        guard capacity > 0 else { return }
        var jobs: [(key: RasterTileKey, metalTile: MetalTile)] = []
        for key in keys {
            guard jobs.count < capacity else { break }
            if let metalTile = resident[key.tile] {
                jobs.append((key, metalTile))
            }
        }
        rasterTileStore.bake(jobs)
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
            buildingPlaceTilesContext: buildingPlaceTilesContext,
            rasterPlacements: rasterPlacements,
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
        rasterTileStore?.handleMemoryWarning()
        // The placement contexts are kept and hold their tiles strongly, and
        // the store keeps the demanded set, so the map does not go blank.
        // The next frame replans from scratch.
        plannedCoverageVersion = nil
        plannedContentVersion = nil
        plannedRasterVersion = nil
        placementVersion &+= 1
    }

    func evict() {
        tileRenderStore.evict()
        rasterTileStore?.evict()
        placeTilesContext = .empty
        buildingPlaceTilesContext = .empty
        rasterPlacements = []
        plannedCoverageVersion = nil
        plannedContentVersion = nil
        plannedRasterVersion = nil
        placementVersion &+= 1
    }
}
