// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

import Metal

/// The names the frame's own GPU resources go by in a GPU capture and in
/// Instruments: the label of a texture or a buffer the engine makes.
enum RenderResourceName: String {
    case labelGlyphAtlas = "LabelGlyphAtlas"
    case poiSpriteAtlas = "PoiSpriteAtlas"
    case baseLabelRuntimeBuffer = "BaseLabelRuntimeBuffer"
    case roadLabelRuntimeBuffer = "RoadLabelRuntimeBuffer"
    case colorTexture = "ColorTexture"
    case postProcessingInputTexture = "PostProcessingInputTexture"
    case overlayDepthTexture = "OverlayDepthTexture"
    case depthTexture = "DepthTexture"
    case shadowMapTexture = "ShadowMapTexture"
    case groundShadowMaskTexture = "GroundShadowMaskTexture"
    case tileOriginDataBuffer = "TileOriginDataBuffer"

    /// Names a buffer that has no name yet.
    func name(_ buffer: MTLBuffer) {
        if buffer.label == nil {
            buffer.label = rawValue
        }
    }
}
