// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import simd

/// The frame's coverage: which tiles the frame draws, at which zooms,
/// from the camera pose. The plane's depth rules (`FlatDepthRuleCoverage`)
/// plus its horizon backdrop, or the sphere's walk (`GlobeTileCoverage`)
/// over the distance rule (`FlatDistanceCoverage`).
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

    /// `rules` are the plane's depth rules (`FlatDepthRules.default`
    /// unless the debug panel edits them).
    func resolveVisibleContent(cameraState: ImmersiveMapCameraState,
                               resolvedPresentation: ResolvedPresentationState,
                               targetZoom: Int,
                               cameraMatrix: matrix_float4x4?,
                               cameraFrustum: Frustum?,
                               cameraEye: SIMD3<Float>,
                               rules: FlatDepthRules = .default,
                               diagnostics: (any FrameDiagnosticsService)? = nil) -> VisibleContentState {
        let semanticCenterWorldMercator = cameraState.centerWorldMercator
        let center = Self.makeCenter(centerWorldMercator: semanticCenterWorldMercator,
                                     targetZoom: targetZoom)
        let visibleTiles: [VisibleTile]
        let backdropTiles: [VisibleTile]
        var flatDepthBands: [FlatDepthBand] = []

        switch resolvedPresentation.renderSurfaceMode {
        case .spherical:
            let inputs = GlobeCoverageInputs(eye: cameraEye,
                                             globe: resolvedPresentation.globeRenderState.globeUniform)
            let resolution = GlobeTileCoverage.targets(targetZoom: targetZoom, inputs: inputs, frustum: cameraFrustum)
            visibleTiles = resolution.targets
            backdropTiles = []
            recordGlobeMetrics(resolution.metrics, diagnostics: diagnostics)
        case .flat:
            let flatRenderState = resolvedPresentation.flatRenderState
            if let polygon = CoveragePolygonBuilder.make(cameraMatrix: cameraMatrix) {
                let hasBackdrop = targetZoom > Self.flatBackdropZoomLevel
                let resolution = FlatDepthRuleCoverage.resolve(eye: cameraEye,
                                                               flatRenderState: flatRenderState,
                                                               targetZoom: targetZoom,
                                                               backdropZoom: hasBackdrop ? Self.flatBackdropZoomLevel : nil,
                                                               rules: rules,
                                                               polygon: polygon)
                visibleTiles = resolution.targets
                flatDepthBands = resolution.bands
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
                                   coverageVersion: coverageVersion,
                                   flatDepthBands: flatDepthBands)
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
