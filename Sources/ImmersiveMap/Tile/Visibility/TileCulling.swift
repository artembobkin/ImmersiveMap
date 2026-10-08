// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import simd

/// The frame's coverage: which tiles the frame draws, at which zooms,
/// from the camera pose. The plane's ring rules (`FlatRingRuleCoverage`)
/// or the sphere's walk (`GlobeTileCoverage`) over the same rules, both
/// counted from the tile the camera looks at.
class TileCulling {
    /// The floor zoom of the flat placements: the pinned world cover's, so
    /// no band and no stand-in goes below the tiles that are always
    /// resident.
    static let flatBackdropZoomLevel = TileWorkingSetStore.pinnedWorldCoverMaxZoomLevel

    /// Moves when the targets differ from the last frame's, not when the
    /// walk merely ran again: the working set gates on it.
    private var coverageVersion: UInt64 = 0
    private var previousVisibleTiles: [VisibleTile] = []
    private var previousRasterDemand: [VisibleTile: RasterDemand] = [:]

    /// What the demand reads of a raster target: how it is baked, and
    /// whether the target wants its vector tile too.
    private struct RasterDemand: Hashable {
        let spec: RasterTileSpec
        let wantsVector: Bool
    }

    init() {}

    /// `rules` are the ring rules of both surfaces (`FlatRingRules.default`
    /// unless the debug panel edits them).
    func resolveVisibleContent(cameraState: ImmersiveMapCameraState,
                               resolvedPresentation: ResolvedPresentationState,
                               targetZoom: Int,
                               cameraMatrix: matrix_float4x4?,
                               cameraFrustum: Frustum?,
                               cameraEye: SIMD3<Float>,
                               rules: FlatRingRules = .default,
                               diagnostics: (any FrameDiagnosticsService)? = nil) -> VisibleContentState {
        let semanticCenterWorldMercator = cameraState.centerWorldMercator
        let center = Self.makeCenter(centerWorldMercator: semanticCenterWorldMercator,
                                     targetZoom: targetZoom)
        let visibleTiles: [VisibleTile]
        var flatRingBands: [FlatRingBand] = []
        var linelessTiles = Set<VisibleTile>()
        var unlabelledTiles = Set<VisibleTile>()
        var rasterTiles: [VisibleTile: RasterTileSpec] = [:]

        switch resolvedPresentation.renderSurfaceMode {
        case .spherical:
            let inputs = GlobeCoverageInputs(eye: cameraEye,
                                             globe: resolvedPresentation.globeRenderState.globeUniform,
                                             rules: rules,
                                             lookAtTile: GlobeRingMath.lookAtTile(center: center, targetZoom: targetZoom))
            let resolution = GlobeTileCoverage.targets(targetZoom: targetZoom, inputs: inputs, frustum: cameraFrustum)
            visibleTiles = resolution.targets
            flatRingBands = resolution.bands
            linelessTiles = resolution.linelessTargets
            unlabelledTiles = resolution.unlabelledTargets
            rasterTiles = resolution.rasterTargets
            recordGlobeMetrics(resolution.metrics, diagnostics: diagnostics)
        case .flat:
            let flatRenderState = resolvedPresentation.flatRenderState
            if let polygon = CoveragePolygonBuilder.make(cameraMatrix: cameraMatrix) {
                // The flat map draws the rules' bands and nothing under
                // them, and the world cover's zoom stays the floor no band
                // and no stand-in goes down to. Beyond the last rule the
                // haze paints the horizon over the clear colour.
                let resolution = FlatRingRuleCoverage.resolve(flatRenderState: flatRenderState,
                                                              targetZoom: targetZoom,
                                                              backdropZoom: Self.flatBackdropZoomLevel,
                                                              rules: rules,
                                                              polygon: polygon)
                visibleTiles = resolution.targets
                flatRingBands = resolution.bands
                linelessTiles = resolution.linelessTargets
                unlabelledTiles = resolution.unlabelledTargets
                rasterTiles = resolution.rasterTargets
                diagnostics?.setCounter(.globeCullingVisitedNodes, value: resolution.visitedNodeCount)
            } else {
                visibleTiles = []
            }
        }

        // The demand reads which targets are rasters and which of them
        // want their vector tile, so a change of either is a new coverage
        // even over the same targets.
        let rasterDemand = Self.rasterDemand(rasterTiles: rasterTiles,
                                             linelessTiles: linelessTiles,
                                             unlabelledTiles: unlabelledTiles)
        if visibleTiles != previousVisibleTiles || rasterDemand != previousRasterDemand {
            coverageVersion &+= 1
            previousVisibleTiles = visibleTiles
            previousRasterDemand = rasterDemand
        }
        return VisibleContentState(centerWorldMercator: semanticCenterWorldMercator,
                                   center: center,
                                   visibleTiles: visibleTiles,
                                   tileZoomLevel: targetZoom,
                                   coverageVersion: coverageVersion,
                                   flatRingBands: flatRingBands,
                                   linelessTiles: linelessTiles,
                                   unlabelledTiles: unlabelledTiles,
                                   rasterTiles: rasterTiles)
    }

    /// The raster targets with how each is baked, and whether each wants its
    /// vector tile too, which is what the demand is made of.
    private static func rasterDemand(rasterTiles: [VisibleTile: RasterTileSpec],
                                     linelessTiles: Set<VisibleTile>,
                                     unlabelledTiles: Set<VisibleTile>) -> [VisibleTile: RasterDemand] {
        rasterTiles.reduce(into: [:]) { demand, entry in
            let wantsVector = linelessTiles.contains(entry.key) == false || unlabelledTiles.contains(entry.key) == false
            demand[entry.key] = RasterDemand(spec: entry.value, wantsVector: wantsVector)
        }
    }

    static func makeCenter(centerWorldMercator: SIMD2<Double>,
                           targetZoom: Int) -> Center {
        let tilesCount = Double(1 << targetZoom)
        return Center(tileX: ImmersiveMapProjection.wrapNormalizedWorldX(centerWorldMercator.x) * tilesCount,
                      tileY: ImmersiveMapProjection.clampNormalizedWorldY(centerWorldMercator.y) * tilesCount)
    }

    private func recordGlobeMetrics(_ metrics: GlobeCullingMetrics,
                                    diagnostics: (any FrameDiagnosticsService)?) {
        diagnostics?.setMeasurement(.globeCullingDurationMs,
                                    value: metrics.duration * 1000.0)
        diagnostics?.setCounter(.globeCullingVisitedNodes,
                                value: metrics.visitedNodeCount)
        diagnostics?.setCounter(.globeCullingFrustumRejects,
                                value: metrics.frustumRejectCount)
        diagnostics?.setCounter(.globeCullingHorizonRejects,
                                value: metrics.horizonRejectCount)
        diagnostics?.setCounter(.globeCullingPlacedTiles,
                                value: metrics.placedTileCount)
        diagnostics?.setCounter(.globeCullingAcceptedWholeSubtrees,
                                value: metrics.acceptedWholeSubtreeCount)
    }
}
