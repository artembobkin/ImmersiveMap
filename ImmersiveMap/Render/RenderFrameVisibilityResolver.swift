// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

/// Computes the visible tile content for a frame from the camera snapshot, presentation state, and tile settings.
final class RenderFrameVisibilityResolver {
    private let tileCulling: TileCulling
    private var cachedFingerprint: Int?
    private var cachedContent: VisibleContentState?

    init(tileCulling: TileCulling = TileCulling()) {
        self.tileCulling = tileCulling
    }

    func resolve(cameraFrameState: CameraFrameState,
                 resolvedPresentation: ResolvedPresentationState,
                 tileSettings: ImmersiveMapSettings.TileSettings,
                 sceneSettings: ImmersiveMapSettings.SceneSettings,
                 diagnostics: (any FrameDiagnosticsService)? = nil) -> VisibleContentState {
        let zoomPlan = TileCoverageZoomPolicy.resolve(cameraZoom: cameraFrameState.mapCameraState.zoom,
                                                      renderSurfaceMode: resolvedPresentation.renderSurfaceMode,
                                                      maximumZoomLevel: tileSettings.coverage.maximumZoomLevel)
        let shadowCasterSweep = ShadowCasterSweepResolver.resolve(
            renderSurfaceMode: resolvedPresentation.renderSurfaceMode,
            scene: sceneSettings,
            centerWorldMercator: cameraFrameState.mapCameraState.centerWorldMercator,
            renderMapSize: resolvedPresentation.flatRenderState.renderMapSize)
        // Culling is a pure function of the camera pose, drawSize, presentation
        // state, and the caster sweep: with an unchanged fingerprint the previous
        // result is reused (along with its coverageVersion, which the demand
        // pipeline's dirty-gate relies on).
        let fingerprint = Self.makeFingerprint(cameraFrameState: cameraFrameState,
                                               resolvedPresentation: resolvedPresentation,
                                               targetZoom: zoomPlan.baseZoom,
                                               shadowCasterSweep: shadowCasterSweep)
        if fingerprint == cachedFingerprint,
           let cachedContent {
            return cachedContent
        }

        let content = tileCulling.resolveVisibleContent(cameraState: cameraFrameState.mapCameraState,
                                                        resolvedPresentation: resolvedPresentation,
                                                        targetZoom: zoomPlan.baseZoom,
                                                        cameraMatrix: cameraFrameState.cameraMatrices.projectionView,
                                                        cameraFrustum: cameraFrameState.cameraFrustum,
                                                        cameraEye: cameraFrameState.cameraEye,
                                                        shadowCasterSweep: shadowCasterSweep,
                                                        diagnostics: diagnostics)
        cachedFingerprint = fingerprint
        cachedContent = content
        return content
    }

    private static func makeFingerprint(cameraFrameState: CameraFrameState,
                                        resolvedPresentation: ResolvedPresentationState,
                                        targetZoom: Int,
                                        shadowCasterSweep: SIMD2<Float>?) -> Int {
        var hasher = Hasher()
        let cameraState = cameraFrameState.mapCameraState
        hasher.combine(cameraState.centerWorldMercator.x.bitPattern)
        hasher.combine(cameraState.centerWorldMercator.y.bitPattern)
        hasher.combine(cameraState.zoom.bitPattern)
        hasher.combine(cameraState.bearing.bitPattern)
        hasher.combine(cameraState.pitch.bitPattern)
        hasher.combine(cameraFrameState.drawSize.width.bitPattern)
        hasher.combine(cameraFrameState.drawSize.height.bitPattern)
        hasher.combine(targetZoom)
        hasher.combine(resolvedPresentation.renderSurfaceMode == .flat)
        let globeUniform = resolvedPresentation.globeRenderState.globeUniform
        hasher.combine(globeUniform.panX.bitPattern)
        hasher.combine(globeUniform.panY.bitPattern)
        hasher.combine(globeUniform.radius.bitPattern)
        hasher.combine(globeUniform.transition.bitPattern)
        hasher.combine(shadowCasterSweep?.x.bitPattern ?? 0)
        hasher.combine(shadowCasterSweep?.y.bitPattern ?? 0)
        return hasher.finalize()
    }
}
