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
                 diagnostics: (any FrameDiagnosticsService)? = nil) -> VisibleContentState {
        let zoomPlan = TileCoverageZoomPolicy.resolve(cameraZoom: cameraFrameState.mapCameraState.zoom,
                                                      renderSurfaceMode: resolvedPresentation.renderSurfaceMode,
                                                      maximumZoomLevel: tileSettings.coverage.maximumZoomLevel)
        // Culling is a pure function of the camera pose, drawSize, and presentation
        // state: with an unchanged fingerprint the previous result is reused (along
        // with its coverageVersion, which the demand pipeline's dirty-gate relies on).
        let fingerprint = Self.makeFingerprint(cameraFrameState: cameraFrameState,
                                               resolvedPresentation: resolvedPresentation,
                                               targetZoom: zoomPlan.baseZoom)
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
                                                        diagnostics: diagnostics)
        cachedFingerprint = fingerprint
        cachedContent = content
        return content
    }

    private static func makeFingerprint(cameraFrameState: CameraFrameState,
                                        resolvedPresentation: ResolvedPresentationState,
                                        targetZoom: Int) -> Int {
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
        return hasher.finalize()
    }
}
