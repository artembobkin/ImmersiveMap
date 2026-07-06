// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

import simd

class TileCulling {
    private let globeVisibleTileResolver: any GlobeVisibleTileResolving
    private var coverageVersion: UInt64 = 0

    init(globeVisibleTileResolver: (any GlobeVisibleTileResolving)? = nil) {
        self.globeVisibleTileResolver = globeVisibleTileResolver ?? GlobeVisibleTileResolver()
    }

    func resolveVisibleContent(cameraState: ImmersiveMapCameraState,
                               resolvedPresentation: ResolvedPresentationState,
                               targetZoom: Int,
                               cameraMatrix: matrix_float4x4?,
                               cameraFrustum: Frustum?,
                               cameraEye: SIMD3<Float>,
                               diagnostics: (any FrameDiagnosticsService)? = nil) -> VisibleContentState {
        let semanticCenterWorldMercator = cameraState.centerWorldMercator
        let center = makeCenter(centerWorldMercator: semanticCenterWorldMercator,
                                targetZoom: targetZoom)
        let visibleTiles: [VisibleTile]

        switch resolvedPresentation.renderSurfaceMode {
        case .spherical:
            let resolution = iSeeTilesGlobe(targetZoom: targetZoom,
                                            center: center,
                                            globeRenderState: resolvedPresentation.globeRenderState,
                                            cameraFrustum: cameraFrustum,
                                            cameraEye: cameraEye)
            visibleTiles = resolution.visibleTiles
            recordGlobeMetrics(resolution.metrics, diagnostics: diagnostics)
        case .flat:
            visibleTiles = Array(iSeeTilesFlat(targetZoom: targetZoom,
                                               center: center,
                                               flatRenderState: resolvedPresentation.flatRenderState,
                                               cameraMatrix: cameraMatrix))
        }

        coverageVersion &+= 1
        return VisibleContentState(centerWorldMercator: semanticCenterWorldMercator,
                                   center: center,
                                   visibleTiles: visibleTiles,
                                   tileZoomLevel: targetZoom,
                                   coverageVersion: coverageVersion)
    }

    func iSeeTilesGlobe(targetZoom: Int,
                        center: Center,
                        globeRenderState: GlobeRenderState,
                        cameraFrustum: Frustum?,
                        cameraEye: SIMD3<Float>) -> GlobeVisibleTileResolution {
        return globeVisibleTileResolver.resolveVisibleTiles(targetZoom: targetZoom,
                                                            globe: globeRenderState.globeUniform,
                                                            cameraFrustum: cameraFrustum,
                                                            cameraEye: cameraEye)
    }

    func iSeeTilesFlat(targetZoom: Int,
                       center: Center,
                       flatRenderState: FlatRenderState,
                       cameraMatrix: matrix_float4x4?) -> Set<VisibleTile> {
        return FlatVisibleTileResolver.resolveVisibleTiles(targetZoom: targetZoom,
                                                           center: center,
                                                           flatRenderState: flatRenderState,
                                                           cameraMatrix: cameraMatrix)
    }

    private func makeCenter(centerWorldMercator: SIMD2<Double>,
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
        diagnostics?.setCounter(.globeCullingAcceptedLeafTiles,
                                value: metrics.acceptedLeafTileCount)
        diagnostics?.setCounter(.globeCullingAcceptedWholeSubtrees,
                                value: metrics.acceptedWholeSubtreeCount)
    }
}
