// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import simd

class TileCulling {
    /// Zoom of the flat-mode horizon backdrop: at this zoom the whole world is
    /// 64 generalized tiles, the frustum footprint is covered by 1-4 of them,
    /// and all of them fall into the world-coverage pinning (z <= 3) - after
    /// warm-up the backdrop costs nothing.
    static let flatBackdropZoomLevel = 3

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
        let backdropTiles: [VisibleTile]

        switch resolvedPresentation.renderSurfaceMode {
        case .spherical:
            let resolution = iSeeTilesGlobe(targetZoom: targetZoom,
                                            center: center,
                                            globeRenderState: resolvedPresentation.globeRenderState,
                                            cameraFrustum: cameraFrustum,
                                            cameraEye: cameraEye)
            visibleTiles = resolution.visibleTiles
            backdropTiles = []
            recordGlobeMetrics(resolution.metrics, diagnostics: diagnostics)
        case .flat:
            visibleTiles = Array(iSeeTilesFlat(targetZoom: targetZoom,
                                               center: center,
                                               flatRenderState: resolvedPresentation.flatRenderState,
                                               cameraMatrix: cameraMatrix))
            backdropTiles = resolveFlatBackdropTiles(centerWorldMercator: semanticCenterWorldMercator,
                                                     targetZoom: targetZoom,
                                                     flatRenderState: resolvedPresentation.flatRenderState,
                                                     cameraMatrix: cameraMatrix)
        }

        coverageVersion &+= 1
        return VisibleContentState(centerWorldMercator: semanticCenterWorldMercator,
                                   center: center,
                                   visibleTiles: visibleTiles,
                                   backdropTiles: backdropTiles,
                                   tileZoomLevel: targetZoom,
                                   coverageVersion: coverageVersion)
    }

    /// The backdrop is enumerated by the same flat resolver at a fixed coarse
    /// zoom: there the radius clamp (15 tiles) is wider than the world, so the
    /// frustum footprint is covered entirely - all the way to the horizon. The
    /// order is deterministic to keep placement hashes stable.
    private func resolveFlatBackdropTiles(centerWorldMercator: SIMD2<Double>,
                                          targetZoom: Int,
                                          flatRenderState: FlatRenderState,
                                          cameraMatrix: matrix_float4x4?) -> [VisibleTile] {
        let backdropZoom = Self.flatBackdropZoomLevel
        guard targetZoom > backdropZoom else {
            return []
        }

        let backdropCenter = makeCenter(centerWorldMercator: centerWorldMercator,
                                        targetZoom: backdropZoom)
        return iSeeTilesFlat(targetZoom: backdropZoom,
                             center: backdropCenter,
                             flatRenderState: flatRenderState,
                             cameraMatrix: cameraMatrix)
            .sorted { lhs, rhs in
                if lhs.loop != rhs.loop {
                    return lhs.loop < rhs.loop
                }
                if lhs.x != rhs.x {
                    return lhs.x < rhs.x
                }
                return lhs.y < rhs.y
            }
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
