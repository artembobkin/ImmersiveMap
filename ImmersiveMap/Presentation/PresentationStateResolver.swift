// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation
import simd

struct PresentationStateResolver {
    static func resolve(cameraState: ImmersiveMapCameraState,
                        renderSurfaceMode: ViewMode) -> ResolvedPresentationState {
        return resolve(cameraState: cameraState,
                       settings: ImmersiveMapSettings.default.presentation,
                       forcedRenderSurfaceMode: renderSurfaceMode)
    }

    static func resolve(cameraState: ImmersiveMapCameraState,
                        settings: ImmersiveMapSettings.PresentationSettings,
                        renderSurfaceMode: ViewMode) -> ResolvedPresentationState {
        return resolve(cameraState: cameraState,
                       settings: settings,
                       forcedRenderSurfaceMode: renderSurfaceMode)
    }

    static func resolve(cameraState: ImmersiveMapCameraState,
                        settings: ImmersiveMapSettings.PresentationSettings,
                        forcedRenderSurfaceMode: ViewMode? = nil) -> ResolvedPresentationState {
        let renderZoomScale = pow(2.0, floor(cameraState.zoom))
        let automaticTransition = automaticTransition(zoom: cameraState.zoom,
                                                      settings: settings)
        let transition = resolvedTransition(automaticTransition: automaticTransition,
                                            forcedRenderSurfaceMode: forcedRenderSurfaceMode)
        let globeRenderRadius = settings.globeRadiusScale * renderZoomScale
        let flatRenderMapSize = 2.0 * Double.pi * globeRenderRadius
        let globePan = ImmersiveMapProjection.globePan(fromCenterWorldMercator: cameraState.centerWorldMercator)
        let flatPan = ImmersiveMapProjection.flatPan(fromCenterWorldMercator: cameraState.centerWorldMercator)

        let globe = GlobeUniform(panX: Float(globePan.x),
                          panY: Float(globePan.y),
                          radius: Float(globeRenderRadius),
                          transition: transition)
        let renderSurfaceMode = resolveRenderSurfaceMode(transition: transition)
        let screenSpaceProjectionMode = resolveScreenSpaceProjectionMode(renderSurfaceMode: renderSurfaceMode)

        return ResolvedPresentationState(
            semanticWorldState: SemanticWorldState(cameraState: cameraState),
            presentationState: ImmersiveMapPresentationState(transition: transition),
            renderNormalizationState: RenderNormalizationState(zoomScale: renderZoomScale,
                                                               globeRenderRadius: globeRenderRadius,
                                                               flatRenderMapSize: flatRenderMapSize),
            renderSurfaceMode: renderSurfaceMode,
            screenSpaceProjectionMode: screenSpaceProjectionMode,
            globeRenderState: GlobeRenderState(pan: globePan,
                                               renderRadius: globeRenderRadius,
                                               globeUniform: globe),
            flatRenderState: FlatRenderState(pan: flatPan,
                                             renderMapSize: flatRenderMapSize)
        )
    }

    private static func automaticTransition(zoom: Double,
                                            settings: ImmersiveMapSettings.PresentationSettings) -> Float {
        let from = Float(settings.automaticTransitionStartZoom)
        let span = max(Float.leastNonzeroMagnitude, Float(settings.automaticTransitionSpan))
        let to = from + span
        return max(0.0, min(1.0, (Float(zoom) - from) / (to - from)))
    }

    private static func resolvedTransition(automaticTransition: Float,
                                           forcedRenderSurfaceMode: ViewMode?) -> Float {
        switch forcedRenderSurfaceMode {
        case nil:
            return automaticTransition
        case .spherical:
            return 0.0
        case .flat:
            return 1.0
        }
    }

    private static func resolveRenderSurfaceMode(transition: Float) -> ViewMode {
        transition >= 1.0 ? .flat : .spherical
    }

    private static func resolveScreenSpaceProjectionMode(renderSurfaceMode: ViewMode) -> ScreenSpaceProjectionMode {
        renderSurfaceMode == .flat ? .flat : .globe
    }
}
