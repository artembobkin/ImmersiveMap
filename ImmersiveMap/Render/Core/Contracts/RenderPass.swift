// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

//
//  RenderPass.swift
//  ImmersiveMap
//

import Foundation

enum RenderLayer: String, CaseIterable {
    case shadowCasters
    /// The per-pixel shadow factor of the flat ground plane, written by its
    /// own pass right after the shadow map and read by every ground layer of
    /// the world pass in place of a cascade lookup per layer.
    case groundShadowMask
    case buildingImage
    /// The stars around the globe, painted first over the pass's clear
    /// color (which is space); the tile geometry blends over them.
    case starfield
    /// The luminous planet body: an opaque coarse sphere at the very back
    /// of the rank-depth band, drawn after the stars and before the tiles,
    /// so a slot whose tile has not arrived shows glowing planet instead of
    /// space; hidden surface removal erases it under every painted slot.
    /// Gated with the starfield: transparent space paints no body either.
    case globeBackdrop
    /// The tile geometry of the globe drawn straight onto the sphere; it
    /// neither tests nor writes depth: what the planet hides is clipped
    /// against the sphere itself, see `GlobeVectorSurfaceRenderSubsystem`.
    case globeVectorSurface
    case globeCap
    /// The atmosphere around the globe's limb: the halo into space and the
    /// rim glow over the surface, one analytic fullscreen draw after the
    /// surface and the caps. Gated with the starfield: transparent space
    /// paints nothing around the globe.
    case atmosphere
    /// The flat passes' stencil prepass: one full-extent quad per unique
    /// source writes the tile-priority stencil before anything else draws,
    /// so the buildings (drawn before the ground) can test a complete
    /// ownership map instead of carrying slot clip distances.
    case tileOwnership
    case flatMapSurface
    case buildingExtrusion
    case sceneModels
    /// Depth-only replay of the scene models at the start of the overlay pass:
    /// label fragments depth-test against it, so model silhouettes clip them
    /// while the visible models stay in the world pass with MSAA and shadows.
    case sceneModelOcclusion
    case routes
    case postProcessing
    case labels
    case avatars
    case debugOverlay
}

enum RenderSkipReason: String, CaseIterable, Hashable {
    case zeroDrawableSize
    case missingScreenMatrix
    case missingCameraState
    case inFlightSlotsExhausted
    case missingDrawable
    case missingCommandBuffer
    case flatTileOriginUnavailable
    case noLabelContent
    case noAvatarContent
    case noSceneModelContent
    case debugOverlayDisabled
    /// The starfield layer, which paints the space background and the stars,
    /// is off because space is configured transparent.
    case transparentSpace
}

struct RenderPassAvailability {
    let renderSurfaceMode: ViewMode
    let labelsEnabled: Bool
    let avatarsEnabled: Bool
    let debugOverlayEnabled: Bool
    /// True when the frame has drawn scene models whose silhouettes should
    /// clip the labels via the overlay-pass depth prepass.
    let sceneModelOcclusionEnabled: Bool
    /// False when space is configured transparent: nothing outside the globe is
    /// painted, so the space background and the stars are skipped.
    let starfieldEnabled: Bool
}

struct RenderLayerPlanItem {
    let layer: RenderLayer
    let enabled: Bool
    let skipReason: RenderSkipReason?
}

struct RenderLayerPlanner {
    static func plan(availability: RenderPassAvailability) -> [RenderLayerPlanItem] {
        let worldLayers: [RenderLayer] = switch availability.renderSurfaceMode {
        case .flat:
            // The sky after the ground and the buildings: it paints only
            // where they left the far plane (above the horizon, coverage
            // holes), under the sky's depth test.
            [.tileOwnership, .flatMapSurface, .buildingExtrusion, .atmosphere, .sceneModels]
        case .spherical:
            // Sky first: nothing writes surface depth any more (the
            // placeholder grid is gone), so the space background and the
            // stars paint the whole frame and the tile geometry blends over
            // them, opaque where its background quad lands.
            [.starfield, .globeBackdrop, .globeVectorSurface, .globeCap, .atmosphere, .sceneModels, .routes]
        }

        return worldLayers.map { layer in
            switch layer {
            case .starfield where availability.starfieldEnabled == false,
                 .globeBackdrop where availability.starfieldEnabled == false,
                 .atmosphere where availability.starfieldEnabled == false:
                return RenderLayerPlanItem(layer: layer, enabled: false, skipReason: .transparentSpace)
            default:
                return RenderLayerPlanItem(layer: layer, enabled: true, skipReason: nil)
            }
        } + [
            // First in the overlay pass: the depth it writes is what the label
            // draws test against. It only serves labels, so it is off without
            // them (the labels item reports that skip on its own).
            RenderLayerPlanItem(layer: .sceneModelOcclusion,
                                enabled: availability.sceneModelOcclusionEnabled && availability.labelsEnabled,
                                skipReason: availability.sceneModelOcclusionEnabled ? nil : .noSceneModelContent),
            RenderLayerPlanItem(layer: .labels,
                                enabled: availability.labelsEnabled,
                                skipReason: availability.labelsEnabled ? nil : .noLabelContent),
            RenderLayerPlanItem(layer: .avatars,
                                enabled: availability.avatarsEnabled,
                                skipReason: availability.avatarsEnabled ? nil : .noAvatarContent),
            RenderLayerPlanItem(layer: .debugOverlay,
                                enabled: availability.debugOverlayEnabled,
                                skipReason: availability.debugOverlayEnabled ? nil : .debugOverlayDisabled)
        ]
    }
}
