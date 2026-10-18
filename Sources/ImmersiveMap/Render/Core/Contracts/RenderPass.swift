// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

//
//  RenderPass.swift
//  ImmersiveMap
//

import Foundation

enum RenderLayer: String, CaseIterable {
    /// The casters of the shadow map's near window, in its own depth-only
    /// pass (`ShadowCascadeSlot.near`).
    case shadowCasters
    /// The same casters into the far window, in a second pass of its own
    /// (`ShadowCascadeSlot.far`), run only when the frame has that window
    /// and it went stale.
    case farShadowCasters
    /// The per-pixel shadow factor of the flat ground plane, written by its
    /// own pass right after the shadow map and read by every ground layer of
    /// the world pass in place of a cascade lookup per layer.
    case groundShadowMask
    /// The stars around the globe, painted first over the pass's clear
    /// color (which is space); the tile geometry blends over them.
    case starfield
    /// The tile geometry of the globe drawn straight onto the sphere; it
    /// neither tests nor writes depth: what the planet hides is clipped
    /// against the sphere itself, see `GlobeVectorSurfaceRenderSubsystem`.
    case globeVectorSurface
    case globeCap
    /// The placement prepass of either surface, right before its ground:
    /// the planner's decision in the tile-priority stencil, see
    /// `PlacementStencilRenderSubsystem`.
    case placementStencil
    /// The flat map's ground: the fills, as geometry and as textures. The
    /// roads and the lines over it are a layer of their own.
    case flatMapSurface
    /// What lies on the flat map's ground: the ground's line ribbons, the
    /// roads and the bridges, after the buildings and the models, which
    /// have raised the surface mask bit where they stand
    /// (`TileSourceStencilPriority.surfaceMaskBit`), so nothing of this
    /// layer paints over a building or a model, whatever the depth says
    /// over a relief, see `FlatMapSurfaceRenderSubsystem`.
    case flatMapRoads
    /// The labels painted on the map, after the ground and the roads on
    /// either surface: over them, under the buildings and the models, see
    /// `SurfaceLabelRenderSubsystem`.
    case surfaceLabels
    case buildingExtrusion
    case sceneModels
    /// The air around the surface's edge, last of the world layers on both
    /// surfaces: the globe's atmosphere and limb feather, the flat map's fog
    /// band, and their handover through the morph. Two depth-split
    /// fullscreen draws, see `HorizonRenderSubsystem`.
    case horizon
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
    /// Extruded buildings are switched off in the style: the tiles carry no
    /// building geometry, so the building layer and the ownership prepass
    /// that exists only for it are left out of the flat world pass.
    /// The starfield layer, which paints the space background and the stars,
    /// is off because space is configured transparent.
    case transparentSpace
}

struct RenderPassAvailability {
    let renderSurfaceMode: ViewMode
    let labelsEnabled: Bool
    let avatarsEnabled: Bool
    let debugOverlayEnabled: Bool
    /// False when space is configured transparent: nothing outside the globe is
    /// painted, so the space background and the stars are skipped.
    let starfieldEnabled: Bool
    /// True when the frame has scene models to draw; without any the model
    /// layer is left out of the world pass instead of encoding nothing.
    var sceneModelsEnabled: Bool = true
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
            // The ground, then what stands on it (the buildings before the
            // ground in the drawn order, `RenderPassGraph.worldLayerOrder`,
            // the models after), then what lies on it, the roads, which
            // the standing things have marked their pixels against. The
            // horizon last: the fog band hazes everything painted near the
            // horizon line, buildings and models included, and the labels,
            // which come after, stay crisp.
            [.placementStencil, .flatMapSurface, .buildingExtrusion, .sceneModels, .flatMapRoads, .surfaceLabels, .horizon]
        case .spherical:
            // Sky first: nothing writes surface depth any more (the
            // placeholder grid is gone), so the space background and the
            // stars paint the whole frame and the tile geometry blends over
            // them, opaque where its background quad lands. The horizon last,
            // over the models near the limb.
            [.starfield, .placementStencil, .globeVectorSurface, .surfaceLabels, .globeCap, .sceneModels, .horizon]
        }

        return worldLayers.map { layer in
            switch layer {
            case .starfield where availability.starfieldEnabled == false:
                return RenderLayerPlanItem(layer: layer, enabled: false, skipReason: .transparentSpace)
            case .sceneModels where availability.sceneModelsEnabled == false:
                return RenderLayerPlanItem(layer: layer, enabled: false, skipReason: .noSceneModelContent)
            default:
                return RenderLayerPlanItem(layer: layer, enabled: true, skipReason: nil)
            }
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
