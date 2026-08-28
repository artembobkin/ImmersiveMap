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
struct GroundShadowMaskBinding {
    let uniform: ShadowUniform
    let texture: MTLTexture

    static func resolve(frameContext: FrameContext,
                        maskTexture: MTLTexture?,
                        fallbackTexture: MTLTexture) -> GroundShadowMaskBinding {
        guard let shadowState = ShadowPassGateResolver.resolve(frameContext: frameContext),
              frameContext.renderSurfaceMode == .flat,
              let maskTexture else {
            return GroundShadowMaskBinding(uniform: .disabled, texture: fallbackTexture)
        }
        return GroundShadowMaskBinding(uniform: shadowState.shadowUniform, texture: maskTexture)
    }
}

/// The single per-frame decision "does the shadow pass run": the resolved
/// shadow state must exist AND at least one caster must be present. Called
/// identically by `RenderPassGraph.plan` (pass injection) and by the receiver
/// bind sites, so the pass and the samplers can never disagree within a frame
/// (the same trick as `BuildingExtrusionPathResolver`). Both call after
/// subsystem updates, when `sharedState` is final for the frame.
enum ShadowPassGateResolver {
    static func resolve(frameContext: FrameContext) -> ShadowFrameState? {
        let tilePlacementState = frameContext.sharedState.tilePlacementState
        return resolve(shadowFrameState: frameContext.shadowFrameState,
                       hasBuildingCasters: hasBuildingCasters(
                           placeTilesContext: tilePlacementState.placeTilesContext)
                           || hasBuildingCasters(
                               placeTilesContext: tilePlacementState.shadowCasterPlaceTilesContext),
                       hasModelCasters: frameContext.sharedState.sceneModelState.hasShadowCasters)
    }

    static func resolve(shadowFrameState: ShadowFrameState?,
                        hasBuildingCasters: Bool,
                        hasModelCasters: Bool) -> ShadowFrameState? {
        guard let shadowFrameState, hasBuildingCasters || hasModelCasters else {
            return nil
        }
        return shadowFrameState
    }

    static func hasBuildingCasters(placeTilesContext: PlaceTilesContext) -> Bool {
        placeTilesContext.tilePlacements.contains { $0.metalTile.tileBuffers.extruded.indicesCount > 0 }
    }
}
