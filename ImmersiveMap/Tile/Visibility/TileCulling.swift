// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import simd

/// The frame's coverage: which tiles the frame draws, at which zooms,
/// from the camera pose. The plane's ring rules (`FlatRingRuleCoverage`)
/// or the sphere's walk (`GlobeTileCoverage`) over the same rules, both
/// counted from the tile the camera looks at.
class TileCulling {
    /// Zoom of the flat-mode horizon backdrop: the pinned world cover's,
    /// so the footprint is covered by the one z0 tile per world copy it
    /// meets, always resident, and after warm-up the backdrop costs
    /// nothing.
    static let flatBackdropZoomLevel = TileWorkingSetStore.pinnedWorldCoverMaxZoomLevel

    /// Moves when the targets or the backdrop differ from the last frame's,
    /// not when the walk merely ran again: the working set gates on it.
    private var coverageVersion: UInt64 = 0
    private var previousVisibleTiles: [VisibleTile] = []
    private var previousBackdropTiles: [VisibleTile] = []

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
        let backdropTiles: [VisibleTile]
        var flatRingBands: [FlatRingBand] = []
        var rasterizedTiles: [VisibleTile: Int] = [:]
        var linelessTiles = Set<VisibleTile>()

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
            rasterizedTiles = resolution.rasterizedTargets
            backdropTiles = []
            recordGlobeMetrics(resolution.metrics, diagnostics: diagnostics)
        case .flat:
            let flatRenderState = resolvedPresentation.flatRenderState
            if let polygon = CoveragePolygonBuilder.make(cameraMatrix: cameraMatrix) {
                // No horizon backdrop: the flat map draws the rules' bands
                // and nothing under them, and the world cover's zoom stays
                // the floor no band and no stand-in goes down to. Beyond
                // the last rule the haze paints the horizon over the clear
                // colour.
                let resolution = FlatRingRuleCoverage.resolve(flatRenderState: flatRenderState,
                                                              targetZoom: targetZoom,
                                                              backdropZoom: Self.flatBackdropZoomLevel,
                                                              rules: rules,
                                                              polygon: polygon)
                visibleTiles = resolution.targets
                flatRingBands = resolution.bands
                rasterizedTiles = resolution.rasterizedTargets
                linelessTiles = resolution.linelessTargets
                backdropTiles = []
                diagnostics?.setCounter(.globeCullingVisitedNodes, value: resolution.visitedNodeCount)
            } else {
                visibleTiles = []
                backdropTiles = []
            }
        }

        if visibleTiles != previousVisibleTiles || backdropTiles != previousBackdropTiles {
            coverageVersion &+= 1
            previousVisibleTiles = visibleTiles
            previousBackdropTiles = backdropTiles
        }
        return VisibleContentState(centerWorldMercator: semanticCenterWorldMercator,
                                   center: center,
                                   visibleTiles: visibleTiles,
                                   backdropTiles: backdropTiles,
                                   tileZoomLevel: targetZoom,
                                   coverageVersion: coverageVersion,
                                   flatRingBands: flatRingBands,
                                   rasterizedTiles: rasterizedTiles,
                                   linelessTiles: linelessTiles)
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
