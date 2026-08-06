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
    case debugOverlayDisabled
    case transparentSpace
}

struct RenderPassAvailability {
    let renderSurfaceMode: ViewMode
    let labelsEnabled: Bool
    let avatarsEnabled: Bool
    let debugOverlayEnabled: Bool
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
