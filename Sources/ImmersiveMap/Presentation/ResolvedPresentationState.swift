// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

import simd

enum ScreenSpaceProjectionMode {
    case globe
    case flat
}

struct ImmersiveMapPresentationState {
    var transition: Float
}

struct SemanticWorldState {
    let cameraState: ImmersiveMapCameraState
}

struct RenderNormalizationState {
    let zoomScale: Double
    let globeRenderRadius: Double
    let flatRenderMapSize: Double
}

struct GlobeRenderState {
    var pan: SIMD2<Double>
    var renderRadius: Double
    var globeUniform: GlobeUniform
}

struct FlatRenderState {
    var pan: SIMD2<Double>
    var renderMapSize: Double
}

struct ResolvedPresentationState {
    let semanticWorldState: SemanticWorldState
    let presentationState: ImmersiveMapPresentationState
    let renderNormalizationState: RenderNormalizationState
    let renderSurfaceMode: ViewMode
    let screenSpaceProjectionMode: ScreenSpaceProjectionMode
    let globeRenderState: GlobeRenderState
    let flatRenderState: FlatRenderState

    var transition: Float {
        presentationState.transition
    }

    var globeRenderUniform: GlobeUniform {
        globeRenderState.globeUniform
    }

    var cameraState: ImmersiveMapCameraState {
        semanticWorldState.cameraState
    }

    var flatProjectionInputsEnabled: Bool {
        screenSpaceProjectionMode == .flat
    }
}
