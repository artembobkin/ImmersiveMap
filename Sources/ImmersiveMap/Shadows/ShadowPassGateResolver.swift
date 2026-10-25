// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Metal

/// What a receiver binds at its shadow slots this frame: the real map with the
/// live uniform when the pass ran, otherwise the 1x1 fallback with `.disabled`
/// (the shader's strength guard then skips sampling entirely).
struct ShadowReceiverBinding {
    let uniform: ShadowUniform
    let texture: MTLTexture

    static func resolve(frameContext: FrameContext,
                        shadowMapTexture: MTLTexture?,
                        fallbackTexture: MTLTexture) -> ShadowReceiverBinding {
        guard let shadowState = ShadowPassGateResolver.resolve(frameContext: frameContext),
              let shadowMapTexture else {
            return ShadowReceiverBinding(uniform: .disabled, texture: fallbackTexture)
        }
        return ShadowReceiverBinding(uniform: shadowState.shadowUniform, texture: shadowMapTexture)
    }
}

/// What a flat ground layer binds at its ground shadow mask slot: the mask
/// the pass wrote this frame with the live uniform, otherwise the 1x1 lit
/// fallback with `.disabled` (the shader's strength guard then never reads
/// it). Same gate as the shadow map, so the mask pass and the readers
/// always agree within a frame.
///
/// The mask is the shadow of the plane, z = 0, and a ground raised by the
/// relief is not on it: the relief's draws (Tile.metal, TileRaster.metal,
/// their relief variants) sample the cascades at their own raised point
/// instead, from `cascades`, the shadow map, or the depth fallback with
/// `.disabled`. A flattened tile has one fill per pixel, so that is one
/// lookup a pixel, as the mask's.
struct GroundShadowMaskBinding {
    let uniform: ShadowUniform
    let texture: MTLTexture
    let cascades: MTLTexture

    static func resolve(frameContext: FrameContext,
                        maskTexture: MTLTexture?,
                        fallbackTexture: MTLTexture,
                        shadowMapTexture: MTLTexture?,
                        shadowFallbackTexture: MTLTexture) -> GroundShadowMaskBinding {
        guard let shadowState = ShadowPassGateResolver.resolve(frameContext: frameContext),
              frameContext.renderSurfaceMode == .flat,
              let maskTexture,
              let shadowMapTexture else {
            return GroundShadowMaskBinding(uniform: .disabled, texture: fallbackTexture, cascades: shadowFallbackTexture)
        }
        return GroundShadowMaskBinding(uniform: shadowState.shadowUniform, texture: maskTexture, cascades: shadowMapTexture)
    }
}

/// The single per-frame decision "does the shadow pass run": the resolved
/// shadow state must exist AND at least one caster must be present. Called
/// identically by `RenderPassGraph.plan` (pass injection) and by the receiver
/// bind sites, so the pass and the samplers can never disagree within a frame
/// (the same trick as `RenderLayerPlanner`). Both call after
/// subsystem updates, when `sharedState` is final for the frame.
enum ShadowPassGateResolver {
    /// The buildings cast only where they draw
    /// (`FrameContextSharedState.drawnBuildingPlacements`): planned but off
    /// the buildings' zoom, or waiting for a model tile, they cast nothing.
    /// The mountains cast wherever the relief stands
    /// (`GroundReliefFrame.castsShadows`), with no building in sight.
    static func resolve(frameContext: FrameContext) -> ShadowFrameState? {
        resolve(shadowFrameState: frameContext.shadowFrameState,
                hasBuildingCasters: frameContext.sharedState.drawnBuildingPlacements.isEmpty == false,
                hasModelCasters: frameContext.sharedState.sceneModelState.hasShadowCasters,
                hasTerrainCasters: frameContext.services.groundRelief?.castsShadows ?? false)
    }

    static func resolve(shadowFrameState: ShadowFrameState?,
                        hasBuildingCasters: Bool,
                        hasModelCasters: Bool,
                        hasTerrainCasters: Bool = false) -> ShadowFrameState? {
        guard let shadowFrameState, hasBuildingCasters || hasModelCasters || hasTerrainCasters else {
            return nil
        }
        return shadowFrameState
    }

}
