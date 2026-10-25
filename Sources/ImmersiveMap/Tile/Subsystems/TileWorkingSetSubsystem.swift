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
/// A raster target (`VisibleContentState.rasterTiles`) is a target like
/// any other: its tile is demanded, kept and placed as a vector tile, and
/// the frame draws the placement through a texture
/// (`RasterTileRenderSubsystem`).
///
/// On the ground relief (`GroundReliefStore`) a tile is placed with its
/// terrain or not at all: the terrain tile its ground rises by in its
/// slot is demanded with the tile and has to be in before the planner
/// places it (`TilePlacementPlanner`), and what stood on the ground
/// stands on meanwhile, by the terrain it was placed with. The terrain
/// lives as long as a placement rises by it or a target asks for it
/// (`GroundReliefDemand`), and goes with the tile.
final class TileWorkingSetSubsystem: RenderSubsystem {
    let name: String = "TileWorkingSet"

    private let tileRenderStore: TileRenderStore
    private let tileTraceRecorder: TileTraceRecorder
    /// The terrain store as the planner sees it, nil while the relief is
    /// off. How the frame draws the relief is the frame's
    /// (`FrameContextServices.groundRelief`).
    private let terrainDemand: (any GroundReliefTerrainDemand)?

    private var placeTilesContext: PlaceTilesContext = .empty
    /// The planner's placements alone, without the horizon backdrop: what
    /// the next plan remembers as the last frame's ground, and what the
    /// buildings and the terrain are planned from.
    private var plannedPlacements: [PlaceTile] = []
    private var buildingPlaceTilesContext: PlaceTilesContext = .empty
    private var placementVersion: UInt64 = 0
    /// The coverage and the working set the last placements were planned
    /// over, nil until the first plan.
    private var plannedCoverageVersion: UInt64?
    private var plannedContentVersion: UInt64?
    private var plannedReliefVersion: UInt64?
    /// Whether the frame was on the terrain when the placements were last
    /// planned: a tile parsed in layers draws differently on it
    /// (`drawingOnTheRelief`).
    private var plannedReliefActive: Bool?
    /// The terrain tiles the last plan wanted and found out
    /// (`TilePlacementPlanner`'s `terrainResident`): asked for with the
    /// frame's demand until a plan no longer wants them.
    private var plannedMissingTerrain: [Tile] = []
    private var latestRequestedTilesCount: Int = 0
    private var latestCounts = (visible: 0, demanded: 0, ready: 0)

    /// The tile zoom the buildings draw from
    /// (`BuildingCoveragePlanner.minimumDrawZoom(settings:)`): no coarser
    /// frame plans them.
    private let buildingsMinimumTileZoom: Int

    init(tileRenderStore: TileRenderStore,
         tileTraceRecorder: TileTraceRecorder,
         terrainDemand: (any GroundReliefTerrainDemand)? = nil,
         buildingsMinimumTileZoom: Int = BuildingCoveragePlanner.minimumSourceZoom) {
        self.tileRenderStore = tileRenderStore
        self.tileTraceRecorder = tileTraceRecorder
        self.terrainDemand = terrainDemand
        self.buildingsMinimumTileZoom = buildingsMinimumTileZoom
    }

    /// The texture's size a tile parsed in layers draws at on the relief
    /// (`drawingOnTheRelief`): a stand-in near the camera, for the moments
    /// its slot's own tile loads.
    static let layeredTileRasterSize = 512

    /// A placement as it draws on the relief. A tile parsed in layers, one
    /// coarser than the relief's zoom (`GroundReliefSettings.appearZoom`),
    /// cannot rise as geometry: placed to draw as geometry (a stand-in for
    /// a slot still loading, a ring the rules draw as geometry), it draws
    /// its ground from a texture on the raster tiles' raised grid instead
    /// (`RasterTileRenderSubsystem`), and leaves its lines out, which could
    /// not rise either. Every other placement is as planned.
    ///
    /// One exception, the planner's own principle carried to the look: a
    /// stand-in that was shown as geometry in the last frame
    /// (`shownAsGeometry`, the tiles of the last plan's geometry
    /// placements) and rises by no terrain goes on as geometry, flat on
    /// the plane, with its lines, until its slot's own tile lands. The
    /// camera crossing onto the relief turns the tiles of the zoom before
    /// into stand-ins for the relief's first targets, which arrive with
    /// their terrain some frames later, and a texture of them in between
    /// is a flash of blur without roads over the whole view, where the
    /// same tiles drawn as they were show nothing changing. A tile in its
    /// own slot is not a stand-in and draws as a texture as before: a ring
    /// the rules draw as geometry below the relief's zoom is a raised
    /// texture on it, not a sheet lying flat among the mountains for as
    /// long as it is shown. A stand-in bound to a terrain is placed anew
    /// this frame, its square marked raised, and draws raised, from a
    /// texture.
    /// The world tile, the flat map's horizon backdrop
    /// (`TileWorkingSetStore.pinnedWorldCoverMaxZoomLevel`).
    static let horizonBackdropTile = Tile(x: 0, y: 0, z: TileWorkingSetStore.pinnedWorldCoverMaxZoomLevel)
    /// The texture the backdrop draws its ground from: the smallest, the
    /// backdrop is the far ground under the haze.
    static let horizonBackdropRasterSize = 64

    /// The flat map's horizon backdrop: the world tile placed under every
    /// placement, once per world copy the targets stand in, flat on the
    /// plane, a 64-texel texture without lines or labels
    /// (`PlaceTile.isHorizonBackdrop`). The rules' bands end somewhere,
    /// and from a tilted camera the ground beyond the last band showed the
    /// clear colour under the sky, an edge the haze drew over: the
    /// backdrop is the ground there, the same at every zoom and whatever
    /// the rules. Its mark has the lowest priority of all
    /// (`TileSourceStencilPriority`), so every other placement paints over
    /// it. Nothing while the world tile is not resident yet.
    ///
    /// Laid from the air handover of the unroll on (`drawsHorizonBackdrop`),
    /// through the sphere's path like every placement: the limb of the
    /// flattening surface runs out past the coverage's reach there, and the
    /// backdrop is the ground up to the line before the surface switch, so
    /// the switch changes nothing under it.
    static func horizonBackdrops(targets: [VisibleTile], resident: [Tile: MetalTile]) -> [PlaceTile] {
        guard let cover = resident[horizonBackdropTile] else { return [] }
        let rules = TileDrawRules(drawsLines: false,
                                  drawsLabels: false,
                                  raster: RasterTileSpec(size: horizonBackdropRasterSize))
        return Set(targets.map(\.worldWrap)).sorted().map { worldWrap in
            PlaceTile(metalTile: cover,
                      placeIn: VisibleTile(tile: horizonBackdropTile, worldWrap: worldWrap),
                      rules: rules,
                      isHorizonBackdrop: true)
        }
    }

    /// Whether the frame lays the horizon backdrop: on the plane, and on
    /// the sphere's path once the air handover of the unroll has begun
    /// (`PresentationSettings.airHandover(atTransition:)`).
    static func drawsHorizonBackdrop(frameContext: FrameContext) -> Bool {
        frameContext.renderSurfaceMode == .flat
            || frameContext.services.settings.presentation.airHandover(atTransition: frameContext.transition) > 0
    }

    static func drawingOnTheRelief(_ placement: PlaceTile, shownAsGeometry: Set<Tile>) -> PlaceTile {
        guard placement.rules.raster == nil, placement.metalTile.tileBuffers.ground.isFlattened == false else {
            return placement
        }
        if placement.inOwnSlot == false, placement.displacement == nil, shownAsGeometry.contains(placement.metalTile.tile) {
            return placement
        }
        var rules = placement.rules
        rules.raster = RasterTileSpec(size: layeredTileRasterSize)
        rules.drawsLines = false
        return PlaceTile(metalTile: placement.metalTile, placeIn: placement.placeIn, slot: placement.slot, rules: rules,
                         terrain: placement.terrain, displacement: placement.displacement)
    }

    func update(frameContext: FrameContext) {
        // The coverage: the frame's targets, every tile at the zoom its
        // place on screen wants (`TileCulling`).
        let visibleContent = frameContext.visibleContent
        let center = visibleContent.center
        let targets = visibleContent.visibleTiles
        let tileZoomLevel = visibleContent.tileZoomLevel

        // The gate: the demand, the loads and the placements depend on the
        // coverage (its version moves when the targets change), on the
        // working set's contents (its version moves
        // when a tile lands and when memory pressure releases one; the
        // releases the demand itself causes touch only tiles it stopped
        // asking about) and on the terrain in (its version moves when a
        // terrain tile lands, goes, or turns out not to come, and a
        // placement waits for its terrain as it waits for its tile), on
        // nothing else. All as they were when the placements were last
        // planned, and no tile in flight, map or terrain: nothing to do. A
        // tile in flight keeps the per-frame request going, which the
        // loaders' retries rely on.
        let coverageVersion = visibleContent.coverageVersion
        let groundRelief = frameContext.services.groundRelief
        let reliefActive = groundRelief?.isActive ?? false
        let reliefVersion = terrainDemand?.version
        let terrainInFlight = terrainDemand?.hasLoadsPending ?? false
        if coverageVersion == plannedCoverageVersion,
           tileRenderStore.cacheContentVersion == plannedContentVersion,
           reliefActive == plannedReliefActive,
           reliefVersion == plannedReliefVersion,
           latestRequestedTilesCount == 0,
           terrainInFlight == false {
            publishState(frameContext: frameContext,
                         visibleTilesCount: latestCounts.visible,
                         readyTilesCount: latestCounts.ready,
                         requestedTilesCount: 0)
            return
        }

        // Under the horizon backdrop the world cover's zoom is the floor
        // of the planner's stand-ins: a target still loading is never
        // covered by the pinned world tile, which at a street zoom is a
        // plain of one colour with nothing on it, and the backdrop paints
        // the hole anyway. The globe keeps its cover as a stand-in.
        let drawsBackdrop = Self.drawsHorizonBackdrop(frameContext: frameContext)
        let backdropZoomLevel: Int? = drawsBackdrop ? TileCulling.flatBackdropZoomLevel : nil
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
        let demandedSourceTiles = Self.uniqueSourceTiles(of: targets)
        let prioritizedDemand = Self.uniqueSourceTiles(of: prioritizedTargets)
        // The store keeps the demand and what the last frame showed, and
        // releases the rest.
        let shownTiles = Set(placeTilesContext.tilePlacements.map(\.metalTile.tile))
        // A frame with the backdrop asks for the world tile too, last
        // (`horizonBackdrops`), pinned once it lands.
        let demand = drawsBackdrop && prioritizedDemand.contains(Self.horizonBackdropTile) == false
            ? prioritizedDemand + [Self.horizonBackdropTile]
            : prioritizedDemand
        let tileRequestResult = tileRenderStore.requestTiles(demand,
                                                             shown: shownTiles,
                                                             frameIndex: frameContext.frameIndex)
        let contentVersion = tileRenderStore.cacheContentVersion

        // The placement is a function of the targets and of what is
        // resident now (the stand-ins included, which are never demanded):
        // replanned from scratch when either moved, kept otherwise.
        let placementChanged = coverageVersion != plannedCoverageVersion
            || contentVersion != plannedContentVersion
            || reliefVersion != plannedReliefVersion
            || reliefActive != plannedReliefActive
        // What is resident now, read only when something is planned over it.
        let resident = placementChanged ? tileRenderStore.residentTiles() : [:]
        if placementChanged {
            // The terrain the plan asks about and finds out: a stand-in's,
            // which no target demands. Asked for with the frame's demand.
            var missingTerrain: [Tile] = []
            var missingTerrainSeen: Set<Tile> = []
            let planned = TilePlacementPlanner.buildPlacements(targets: targets,
                                                               resident: resident,
                                                               zoom: tileZoomLevel,
                                                               backdropZoomLevel: backdropZoomLevel,
                                                               previous: plannedPlacements,
                                                               slotRules: { slot in
                                                                   TileDrawRules(drawsLines: visibleContent.linelessTiles.contains(slot) == false,
                                                                                 drawsLabels: visibleContent.unlabelledTiles.contains(slot) == false,
                                                                                 raster: visibleContent.rasterTiles[slot])
                                                               },
                                                               // On the relief a tile is placed with the terrain of its
                                                               // slot's ring, once that is in.
                                                               terrain: { tile, slotZoom in
                                                                   guard reliefActive, frameContext.renderSurfaceMode == .flat,
                                                                         let store = terrainDemand else { return nil }
                                                                   return (store.terrainSource(for: tile, targetZoom: slotZoom),
                                                                           store.displacementSource(for: tile, targetZoom: slotZoom))
                                                               },
                                                               terrainResident: { tile in
                                                                   let resident = terrainDemand?.isResident(tile) ?? false
                                                                   if resident == false, missingTerrainSeen.insert(tile).inserted {
                                                                       missingTerrain.append(tile)
                                                                   }
                                                                   return resident
                                                               })
            plannedMissingTerrain = missingTerrain
            if reliefActive, frameContext.renderSurfaceMode == .flat {
                // What the last frame drew as geometry keeps its look while
                // it stands in (`drawingOnTheRelief`).
                let shownAsGeometry = Set(plannedPlacements.filter { $0.rules.raster == nil }.map(\.metalTile.tile))
                plannedPlacements = planned.tilePlacements.map { Self.drawingOnTheRelief($0, shownAsGeometry: shownAsGeometry) }
            } else {
                plannedPlacements = planned.tilePlacements
            }
            // The horizon backdrop under the plan, on the flat map and
            // through the unroll's air handover.
            let backdrops = drawsBackdrop
                ? Self.horizonBackdrops(targets: targets, resident: resident)
                : []
            placeTilesContext = PlaceTilesContext(tilePlacements: plannedPlacements + backdrops)
            // The buildings: the tiles the ground shows, from the
            // buildings' zoom on, in the near field (see the planner).
            let eyeGroundCell: SIMD2<Double>? = frameContext.renderSurfaceMode == .flat
                ? BuildingCoveragePlanner.eyeGroundCell(eye: frameContext.cameraEye,
                                                        flatRenderState: frameContext.resolvedPresentation.flatRenderState,
                                                        lookAt: SIMD2<Double>(center.tileX, center.tileY),
                                                        targetZoom: tileZoomLevel)
                : nil
            buildingPlaceTilesContext = BuildingCoveragePlanner.plan(groundPlacements: plannedPlacements,
                                                                     eyeGroundCell: eyeGroundCell,
                                                                     minimumZoom: buildingsMinimumTileZoom)
            placementVersion &+= 1
            plannedCoverageVersion = coverageVersion
            plannedContentVersion = contentVersion
            plannedReliefVersion = reliefVersion
            plannedReliefActive = reliefActive
        }

        // The terrain the frame reads, asked for once a frame, as the map
        // tiles are: what the camera reads moves with it between replans.
        // Which terrain that is, is the relief's own business
        // (`GroundReliefTerrainDemand.request(for:...)`).
        if let terrainDemand, let groundRelief {
            terrainDemand.request(for: groundRelief,
                                  onFlatMap: frameContext.renderSurfaceMode == .flat,
                                  tileZoom: tileZoomLevel,
                                  targets: targets,
                                  shown: plannedPlacements,
                                  missing: plannedMissingTerrain,
                                  centerWorldMercator: visibleContent.centerWorldMercator)
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
        // The terrain goes too: the placements bound to it are planned
        // again when it is back.
        terrainDemand?.removeAll()
        // The placement contexts are kept and hold their tiles strongly, and
        // the store keeps the demanded set, so the map does not go blank.
        // The next frame replans from scratch.
        plannedCoverageVersion = nil
        plannedContentVersion = nil
        placementVersion &+= 1
    }

    func evict() {
        tileRenderStore.evict()
        terrainDemand?.removeAll()
        placeTilesContext = .empty
        buildingPlaceTilesContext = .empty
        plannedCoverageVersion = nil
        plannedContentVersion = nil
        placementVersion &+= 1
    }
}
