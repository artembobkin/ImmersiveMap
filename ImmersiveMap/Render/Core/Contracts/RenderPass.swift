// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

//
//  RenderPass.swift
//  ImmersiveMap
//

import Foundation

enum RenderLayer: String, CaseIterable {
    case shadowCasters
    case buildingImage
    case starfield
    case globeSurface
    case globeCap
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
    /// The starfield layer, which paints the space background, the stars and the
    /// Sun, is off because space is configured transparent.
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
    /// painted, so the space background, the stars and the Sun are skipped.
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
            [.flatMapSurface, .buildingExtrusion, .sceneModels]
        case .spherical:
            [.starfield, .globeSurface, .globeCap, .sceneModels, .routes]
        }

        return worldLayers.map { layer in
            guard layer == .starfield, availability.starfieldEnabled == false else {
                return RenderLayerPlanItem(layer: layer, enabled: true, skipReason: nil)
            }
            return RenderLayerPlanItem(layer: layer, enabled: false, skipReason: .transparentSpace)
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
