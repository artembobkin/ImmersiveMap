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
        let automaticTransition = automaticTransition(cameraState: cameraState,
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
                          transition: geometryTransition(transition))
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

    /// Over the transition window the flat morph target grows from `cos(center latitude)`
    /// to the full Mercator size (see `globeTransitionMapSize` in the shader),
    /// i.e. it plays back `log2(1/cos)` levels of visible inflation. The window
    /// is stretched by that same amount so the inflation speed while the sphere
    /// unfurls into the plane does not depend on latitude.
    private static func automaticTransition(cameraState: ImmersiveMapCameraState,
                                            settings: ImmersiveMapSettings.PresentationSettings) -> Float {
        let from = settings.automaticTransitionStartZoom
        let latitude = ImmersiveMapProjection.latitude(fromNormalizedWorldY: cameraState.centerWorldMercator.y)
        let latitudeSpanExtension = log2(1.0 / max(cos(latitude), 0.01))
        let span = max(.leastNonzeroMagnitude, settings.automaticTransitionSpan + latitudeSpanExtension)
        return Float(max(0.0, min(1.0, (cameraState.zoom - from) / span)))
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

    /// Fraction of the transition phase by which the morph geometry fully
    /// unfolds into the plane.
    private static let geometryCompletionPhase: Float = 0.9

    /// Transition for shader geometry (GlobeUniform): the unfurl animation
    /// completes by `geometryCompletionPhase`, and for the rest of the phase the
    /// globe path renders an already finished plane, so the surface switch at
    /// t = 1 happens between geometrically identical frames. The semantic
    /// transition (fades, fog, surface selection) stays continuous up to 1.
    private static func geometryTransition(_ transition: Float) -> Float {
        min(1.0, transition / geometryCompletionPhase)
    }

    private static func resolveRenderSurfaceMode(transition: Float) -> ViewMode {
        transition >= 1.0 ? .flat : .spherical
    }

    private static func resolveScreenSpaceProjectionMode(renderSurfaceMode: ViewMode) -> ScreenSpaceProjectionMode {
        renderSurfaceMode == .flat ? .flat : .globe
    }
}
