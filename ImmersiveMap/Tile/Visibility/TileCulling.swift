// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import simd

/// The frame's coverage: which tiles the frame draws, at which zooms,
/// from the camera pose. One walk of the tile tree per surface
/// (`FlatTileCoverage`, `GlobeTileCoverage`) over the distance rule
/// (`FlatDistanceCoverage`), plus the flat map's horizon backdrop.
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

    /// `farRadius` is the coverage's reach in camera distances
    /// (`FlatDistanceCoverage.farRadius` unless the debug panel moves it).
    func resolveVisibleContent(cameraState: ImmersiveMapCameraState,
                               resolvedPresentation: ResolvedPresentationState,
                               targetZoom: Int,
                               cameraMatrix: matrix_float4x4?,
                               cameraFrustum: Frustum?,
                               cameraEye: SIMD3<Float>,
                               farRadius: Double = FlatDistanceCoverage.farRadius,
                               diagnostics: (any FrameDiagnosticsService)? = nil) -> VisibleContentState {
        let semanticCenterWorldMercator = cameraState.centerWorldMercator
        let center = Self.makeCenter(centerWorldMercator: semanticCenterWorldMercator,
                                     targetZoom: targetZoom)
        let visibleTiles: [VisibleTile]
        let backdropTiles: [VisibleTile]

        switch resolvedPresentation.renderSurfaceMode {
        case .spherical:
            let inputs = GlobeCoverageInputs(eye: cameraEye,
                                             globe: resolvedPresentation.globeRenderState.globeUniform,
                                             farRadius: farRadius)
            let resolution = GlobeTileCoverage.targets(targetZoom: targetZoom, inputs: inputs, frustum: cameraFrustum)
            visibleTiles = resolution.targets
            backdropTiles = []
            recordGlobeMetrics(resolution.metrics, diagnostics: diagnostics)
        case .flat:
            let flatRenderState = resolvedPresentation.flatRenderState
            if let polygon = CoveragePolygonBuilder.make(cameraMatrix: cameraMatrix) {
                let hasBackdrop = targetZoom > Self.flatBackdropZoomLevel
                let inputs = FlatCoverageInputs.make(eye: cameraEye,
                                                     flatRenderState: flatRenderState,
                                                     center: center,
                                                     targetZoom: targetZoom,
                                                     cameraZoom: cameraState.zoom,
                                                     backdropZoom: hasBackdrop ? Self.flatBackdropZoomLevel : nil,
                                                     farRadius: farRadius)
                let resolution = FlatTileCoverage.targets(targetZoom: targetZoom, inputs: inputs, polygon: polygon)
                visibleTiles = resolution.targets
                // The backdrop: the coarse tiles under the whole footprint, all
                // the way to the horizon, so the coverage's edge is never
                // drawn in.
                backdropTiles = hasBackdrop
                    ? FlatTileCoverage.tiles(atZoom: Self.flatBackdropZoomLevel, polygon: polygon, flatRenderState: flatRenderState)
                    : []
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
                                   coverageVersion: coverageVersion)
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
