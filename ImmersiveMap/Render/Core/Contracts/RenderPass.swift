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
    /// The space around the globe: the opaque sky background, the stars and
    /// the Sun. Drawn after the globe surface at the far plane, depth-tested
    /// so the pixels the sphere covered reject its fragments instead of
    /// being painted first and painted over.
    case starfield
    /// The atmosphere halo in space around the globe: drawn after the
    /// starfield it blends over, depth-tested at the far plane like it, so
    /// only the space outside the sphere's silhouette is shaded.
    case atmosphere
    case globeSurface
    /// The tile geometry of the globe drawn straight onto the sphere, over
    /// the placeholder grid the `globeSurface` layer painted; it neither
    /// tests nor writes depth: what the planet hides is clipped against the
    /// sphere itself, see `GlobeVectorSurfaceRenderSubsystem`.
    case globeVectorSurface
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
    /// Sun, is off because space is configured transparent. The atmosphere halo
    /// reports the same reason: it too is painted in space.
    case transparentSpace
    /// The atmosphere halo is off by setting.
    case atmosphereDisabled
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
    /// False when the atmosphere is off by setting, or when space is
    /// transparent (the halo is painted in space).
    let atmosphereEnabled: Bool
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
            // Surface first, sky after: the sky layers (the starfield and
            // the atmosphere halo) rasterize at the far plane and depth-test
            // against the surface depth the globe wrote, so only the pixels
            // the sphere left uncovered are shaded instead of the whole
            // screen being painted and then painted over. The polar caps
            // stay after the sky: the poles lie outside the Mercator slots,
            // so no grid depth covers them, and the caps must paint over
            // the sky there the way they always did.
            [.globeSurface, .globeVectorSurface, .starfield, .atmosphere, .globeCap, .sceneModels, .routes]
        }

        return worldLayers.map { layer in
            switch layer {
            case .starfield where availability.starfieldEnabled == false:
                return RenderLayerPlanItem(layer: layer, enabled: false, skipReason: .transparentSpace)
            case .atmosphere where availability.atmosphereEnabled == false:
                // The halo is painted in space, so transparent space takes it
                // with the starfield; otherwise it is off by its own setting.
                let reason: RenderSkipReason = availability.starfieldEnabled ? .atmosphereDisabled : .transparentSpace
                return RenderLayerPlanItem(layer: layer, enabled: false, skipReason: reason)
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
