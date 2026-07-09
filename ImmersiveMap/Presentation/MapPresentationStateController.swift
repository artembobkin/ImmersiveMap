// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

/// Хранит текущий surface mode карты и резолвит presentation state для frame pipeline.
final class MapPresentationStateController {
    private var settings: ImmersiveMapSettings
    private var forcedRenderSurfaceMode: ViewMode?

    init(settings: ImmersiveMapSettings) {
        self.settings = settings
    }

    func applySettings(_ settings: ImmersiveMapSettings) {
        self.settings = settings
    }

    func resolve(cameraState: ImmersiveMapCameraState) -> ResolvedPresentationState {
        PresentationStateResolver.resolve(cameraState: cameraState,
                                          settings: settings.presentation,
                                          forcedRenderSurfaceMode: forcedRenderSurfaceMode)
    }

    func switchRenderSurfaceMode(cameraState: ImmersiveMapCameraState) {
        guard forcedRenderSurfaceMode == nil else {
            forcedRenderSurfaceMode = nil
            return
        }

        let resolvedPresentation = resolve(cameraState: cameraState)

        switch resolvedPresentation.renderSurfaceMode {
        case .spherical:
            forcedRenderSurfaceMode = .flat
        case .flat:
            forcedRenderSurfaceMode = .spherical
        }
    }

    func isSphericalSurfaceActive(cameraState: ImmersiveMapCameraState) -> Bool {
        resolve(cameraState: cameraState).renderSurfaceMode == .spherical
    }

    func cameraConstraints(cameraState: ImmersiveMapCameraState) -> CameraConstraints {
        CameraConstraintResolver.resolve(cameraState: cameraState,
                                         cameraSettings: settings.camera,
                                         renderSurfaceMode: resolve(cameraState: cameraState).renderSurfaceMode)
    }
}
