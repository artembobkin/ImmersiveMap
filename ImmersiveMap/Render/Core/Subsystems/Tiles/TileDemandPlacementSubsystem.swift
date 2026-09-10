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
    /// The debug panel's coverage reach knob; nil outside a debug build of the graph.
    private let debugOverlayControls: DebugOverlayControlState?

    private var preprocessedVisibleTilesHashTracker = StagedHashChangeTracker()
    private var placeTilesContext: PlaceTilesContext = .empty
    private var backdropPlaceTilesContext: PlaceTilesContext = .empty
    private var buildingPlaceTilesContext: PlaceTilesContext = .empty
    private var globeSurfaceSlots: [Tile] = []
    private var placementVersion: UInt64 = 0
    private var demandGateFingerprint: Int?
    private var latestRequestedTilesCount: Int = 0
    private var latestCounts = (visible: 0, preprocessed: 0, demanded: 0, ready: 0)

    init(tileRenderStore: TileRenderStore,
         tileTraceRecorder: TileTraceRecorder,
         visibleTilesPreprocessor: VisibleTilesPreprocessor = VisibleTilesPreprocessor(),
         debugOverlayControls: DebugOverlayControlState? = nil) {
        self.tileRenderStore = tileRenderStore
        self.tileTraceRecorder = tileTraceRecorder
        self.visibleTilesPreprocessor = visibleTilesPreprocessor
        self.debugOverlayControls = debugOverlayControls
    }

    func update(frameContext: FrameContext) {
        // Tile culling stage: resolves current map-space center and
        // computes which tiles are visible for the active view mode.
        let visibleContent = frameContext.visibleContent
        let center = visibleContent.center
        let visibleTiles = visibleContent.visibleTiles
        let tileZoomLevel = visibleContent.tileZoomLevel

        // Dirty-gate: preprocess/demand/request depend only on the coverage
        // (coverageVersion changes when the camera/mode changes) and the
        // working set's contents (contentVersion changes on insert/release).
        // Skipping is allowed only when there are no requested-but-not-ready tiles:
        // the loader's retry logic relies on the per-frame request().
        // The coverage reach is a debug knob: a moved slider re-runs the
        // demand like a camera change would.
        let coverageFarRadius = debugOverlayControls.map { Double($0.snapshot().coverageFarRadiusCameraDistances) }
            ?? FlatDistanceCoverage.farRadius
        var gateHasher = Hasher()
        gateHasher.combine(visibleContent.coverageVersion)
        gateHasher.combine(tileRenderStore.cacheContentVersion)
        gateHasher.combine(coverageFarRadius.bitPattern)
        let gateFingerprint = gateHasher.finalize()
        if gateFingerprint == demandGateFingerprint,
           latestRequestedTilesCount == 0 {
            publishState(frameContext: frameContext,
                         visibleTilesCount: latestCounts.visible,
                         readyTilesCount: latestCounts.ready,
                         requestedTilesCount: 0)
            return
        }

        // Visible-tiles post-processing: shortens the raw visible list and
        // substitutes tiles with coarser parents to reduce load/placement
        // pressure. On the plane every tile's zoom follows its distance from
        // the eye (`FlatDistanceCoverage`).
        let flatCamera: FlatCoverageCamera? = frameContext.renderSurfaceMode == .flat
            ? Self.makeFlatCoverageCamera(frameContext: frameContext,
                                          center: center,
                                          tileZoomLevel: tileZoomLevel,
                                          hasBackdrop: visibleContent.backdropTiles.isEmpty == false,
                                          farRadius: coverageFarRadius)
            : nil
        // On the sphere the same rule reads the eye and the globe; the far
        // field is asked for at the pinned world cover's zoom.
        let globeCamera: GlobeCoverageCamera? = frameContext.renderSurfaceMode == .spherical
            ? GlobeCoverageCamera(eye: frameContext.cameraEye,
                                  globe: frameContext.resolvedPresentation.globeRenderState.globeUniform,
                                  farRadius: coverageFarRadius)
            : nil
        let preprocessedVisibleTiles = visibleTilesPreprocessor.preprocess(visibleTiles: visibleTiles,
                                                                           center: center,
                                                                           renderSurfaceMode: frameContext.renderSurfaceMode,
                                                                           flatCamera: flatCamera,
                                                                           globeCamera: globeCamera)
        // The horizon backdrop bypasses the preprocessor: its distance filter
        // measures distances in target-zoom tiles and would discard the coarse
        // backdrop tiles. Its demand and placements are shared with the coverage.
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
        let demandedSourceTiles = Self.uniqueSourceTiles(of: preprocessedVisibleTiles + backdropTiles)
        // Demand order = network and parsing priority: tiles closest to the camera
        // start first. The placement hash uses the stable
        // `demandedSourceTiles` (center-based sorting would change on every
        // camera shift and cause needless rebuilds) - both lists have the same contents.
        let prioritizedTargets = TileDemandPriorityMath.sortedByCameraProximity(preprocessedVisibleTiles,
                                                                                centerWorldMercator: visibleContent.centerWorldMercator,
                                                                                renderSurfaceMode: frameContext.renderSurfaceMode)
        let prioritizedDemand = Self.uniqueSourceTiles(of: prioritizedTargets + backdropTiles)
        // Returns source-tile availability map for GPU rendering:
        // value contains Metal-ready tile buffers, or `nil` while still loading.
        let tileRequestResult = tileRenderStore.requestTiles(prioritizedDemand,
                                                             frameIndex: frameContext.frameIndex)
        let readyTilesBySource = tileRequestResult.readyTilesBySource

        var hashBuilder = Hasher()
        hashBuilder.combine(PreprocessedVisibleTilesHasher.computePreprocessedVisibleTilesHash(
            preprocessedVisibleTiles: preprocessedVisibleTiles + backdropTiles,
            demandedSourceTiles: demandedSourceTiles,
            readyTilesBySource: readyTilesBySource
        ))
        // The placement also reads the stand-ins (descendants standing in
        // are never demanded), so a tile landing outside the demand, which
        // bumps the content version, rebuilds it too.
        hashBuilder.combine(tileRenderStore.cacheContentVersion)
        let preprocessedVisibleTilesHash = hashBuilder.finalize()

        let placementChanged = preprocessedVisibleTilesHashTracker.stage(preprocessedVisibleTilesHash)
        if placementChanged {
            // The placement is a function of the targets and of what is
            // resident now (the stand-ins included): nothing is carried
            // over from the previous frame's placement.
            let resident = tileRenderStore.residentTiles()
            placeTilesContext = TilePlacementPlanner.buildPlacements(targets: preprocessedVisibleTiles,
                                                                     resident: resident,
                                                                     zoom: tileZoomLevel,
                                                                     backdropZoomLevel: backdropZoomLevel)
            backdropPlaceTilesContext = TilePlacementPlanner.buildPlacements(targets: backdropTiles,
                                                                             resident: resident,
                                                                             zoom: tileZoomLevel,
                                                                             descendantSearchDepth: 0)
            // The buildings: a partition of the near field over the resident
            // tiles, never a substitute (see the planner).
            let eyeGroundCell = flatCamera.map { camera in
                camera.eyeGround * pow(2.0, Double(BuildingCoveragePlanner.minimumSourceZoom - tileZoomLevel))
            }
            buildingPlaceTilesContext = BuildingCoveragePlanner.plan(resident: resident,
                                                                     visibleTiles: visibleTiles,
                                                                     eyeGroundCell: eyeGroundCell)
            globeSurfaceSlots = preprocessedVisibleTiles.map(\.tile)
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


    /// The flat camera looks at the world origin (the pan moves the world
    /// under it), so the eye is taken as it is, and its ground point is its
    /// x and y over the exact tile's world size, away from the look-at
    /// point in tile units. World y grows north while tile y grows south.
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

    private static func makeFlatCoverageCamera(frameContext: FrameContext,
                                               center: Center,
                                               tileZoomLevel: Int,
                                               hasBackdrop: Bool,
                                               farRadius: Double = FlatDistanceCoverage.farRadius) -> FlatCoverageCamera {
        let flatRenderState = frameContext.resolvedPresentation.flatRenderState
        let tileUnits = flatRenderState.renderMapSize / Double(1 << max(0, tileZoomLevel))
        let eye = frameContext.cameraEye
        let lookAt = SIMD2<Double>(center.tileX, center.tileY)
        let eyeGround = lookAt + SIMD2<Double>(Double(eye.x), -Double(eye.y)) / tileUnits
        return FlatCoverageCamera(eye: SIMD3<Double>(Double(eye.x), Double(eye.y), Double(eye.z)),
                                  flatRenderState: flatRenderState,
                                  eyeGround: eyeGround,
                                  lookAt: lookAt,
                                  overzoomLevels: max(0, frameContext.zoomLevel - tileZoomLevel),
                                  backdropZoom: hasBackdrop ? TileCulling.flatBackdropZoomLevel : nil,
                                  farRadius: farRadius)
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
        // Placement contexts are kept and hold their tiles strongly; the store
        // keeps the demanded set, so the map doesn't go blank; the next frame
        // rebuilds placements from scratch.
        preprocessedVisibleTilesHashTracker.invalidate()
        demandGateFingerprint = nil
        placementVersion &+= 1
    }

    func evict() {
        tileRenderStore.evict()
        placeTilesContext = .empty
        backdropPlaceTilesContext = .empty
        buildingPlaceTilesContext = .empty
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
