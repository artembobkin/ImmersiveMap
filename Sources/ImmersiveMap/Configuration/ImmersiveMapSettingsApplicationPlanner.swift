// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

public enum ImmersiveMapSettingsChangeDomain: String, CaseIterable, Equatable {
    case renderLoop
    case camera
    case presentation
    case tiles
    case labels
    case scene
    case style
    case avatars
    case attribution
    case postProcessing
    case debug
    case controls
    case landmarks
    case modelArchive
}

public enum ImmersiveMapSettingsApplyAction: String, CaseIterable, Equatable {
    case liveApply
    case invalidateCaches
    case rebuildPreparedData
    case rebuildGPUResources
    case recreateRenderer
}

public struct ImmersiveMapSettingsApplicationPlan: Equatable {
    public let changedDomains: Set<ImmersiveMapSettingsChangeDomain>
    public let actions: Set<ImmersiveMapSettingsApplyAction>

    public var requiresRendererRecreation: Bool {
        actions.contains(.recreateRenderer)
    }
}

public enum ImmersiveMapSettingsApplicationPlanner {
    /// Builds a plan for applying new settings, separating live updates from changes
    /// that require recreating the renderer because of caches, prepared data, or GPU resources.
    /// This logic lives outside `ImmersiveMapSettings` because settings describe state,
    /// while deciding how to apply them belongs to the map's runtime policy.
    public static func makePlan(from oldValue: ImmersiveMapSettings,
                                to newValue: ImmersiveMapSettings) -> ImmersiveMapSettingsApplicationPlan {
        var changedDomains = Set<ImmersiveMapSettingsChangeDomain>()
        var actions = Set<ImmersiveMapSettingsApplyAction>()

        func mark(_ domain: ImmersiveMapSettingsChangeDomain,
                  actions domainActions: [ImmersiveMapSettingsApplyAction]) {
            changedDomains.insert(domain)
            actions.formUnion(domainActions)
        }

        if oldValue.renderLoop != newValue.renderLoop {
            mark(.renderLoop, actions: [.liveApply])
        }
        if oldValue.camera != newValue.camera {
            mark(.camera, actions: [.liveApply])
        }
        if oldValue.presentation != newValue.presentation {
            mark(.presentation, actions: [.liveApply])
        }
        if oldValue.mapStyle != newValue.mapStyle {
            mark(.style, actions: [.invalidateCaches, .rebuildPreparedData, .rebuildGPUResources, .recreateRenderer])
        }
        if oldValue.debug.enableDebugPanel != newValue.debug.enableDebugPanel {
            mark(.debug, actions: [.recreateRenderer])
        } else if oldValue.debug != newValue.debug {
            mark(.debug, actions: [.liveApply])
        }

        // Light, shadows and the atmosphere are per-frame uniforms read from
        // `FrameContext`; the shadow-map texture is reallocated lazily on
        // resolution change, so all of them apply live without recreating the
        // renderer.
        let sceneLiveChanged = oldValue.scene.space != newValue.scene.space
            || oldValue.scene.light != newValue.scene.light
            || oldValue.scene.shadows != newValue.scene.shadows
            || oldValue.scene.atmosphere != newValue.scene.atmosphere
            || oldValue.scene.fog != newValue.scene.fog
            || oldValue.scene.groundFog != newValue.scene.groundFog
            || oldValue.scene.mountainGroundFog != newValue.scene.mountainGroundFog
        if sceneLiveChanged {
            mark(.scene, actions: [.liveApply])
        }
        let sceneBootstrapChanged = oldValue.scene.starfield != newValue.scene.starfield
        if sceneBootstrapChanged {
            mark(.scene, actions: [.rebuildGPUResources, .recreateRenderer])
        }

        if oldValue.tiles.coverage != newValue.tiles.coverage {
            mark(.tiles, actions: [.liveApply])
        }
        if oldValue.tiles.network != newValue.tiles.network
            || oldValue.tiles.cache != newValue.tiles.cache {
            mark(.tiles, actions: [.invalidateCaches, .recreateRenderer])
        }
        if oldValue.tiles.parsing != newValue.tiles.parsing {
            mark(.tiles, actions: [.invalidateCaches, .rebuildPreparedData, .recreateRenderer])
        }
        // The raster tiles' sampler is built with the renderer, and the
        // textures are drawn anew every frame.
        if oldValue.tiles.rasterization != newValue.tiles.rasterization {
            mark(.tiles, actions: [.recreateRenderer])
        }
        // The offline mode decides which transports the load pipeline is even
        // built with (offline-only maps never create a downloader), so it
        // applies by recreating the renderer; caches stay valid because the
        // bytes come from the same tile source either way.
        if oldValue.tiles.offline != newValue.tiles.offline {
            mark(.tiles, actions: [.recreateRenderer])
        }
        // The overview is laid into the tiles by the load pipeline, built
        // with the renderer, and baked into the prepared tiles, whose
        // identity it is part of.
        if oldValue.tiles.overview.isEnabled != newValue.tiles.overview.isEnabled {
            mark(.tiles, actions: [.invalidateCaches, .rebuildPreparedData, .recreateRenderer])
        }

        // Every label field, the on/off switch included, changes what a
        // prepared tile carries: with labels off the parser bakes no text.
        if oldValue.labels != newValue.labels {
            mark(.labels, actions: [.invalidateCaches, .rebuildPreparedData, .recreateRenderer])
        }
        if oldValue.avatars != newValue.avatars {
            mark(.avatars, actions: [.rebuildGPUResources, .recreateRenderer])
        }
        // The badge shows the resolved attribution, which the overview's
        // credit is part of: its zoom is badge text, applied in place.
        if oldValue.attribution != newValue.attribution
            || oldValue.tiles.overview != newValue.tiles.overview {
            mark(.attribution, actions: [.liveApply])
        }
        // The controls are views over the map: hidden and shown in place.
        if oldValue.controls != newValue.controls {
            mark(.controls, actions: [.liveApply])
        }
        // FXAA is a pass-plan flag read per frame; the sample count is baked
        // into every pipeline state, so it rebuilds the renderer.
        if oldValue.postProcessing != newValue.postProcessing {
            if oldValue.postProcessing.multisampleCount == newValue.postProcessing.multisampleCount {
                mark(.postProcessing, actions: [.liveApply])
            } else {
                mark(.postProcessing, actions: [.rebuildGPUResources, .recreateRenderer])
            }
        }

        // The landmarks are read per frame, the buildings they replace
        // included: a tile keeps every building, and the frame leaves out
        // the ones a drawn model stands in for.
        if oldValue.landmarks != newValue.landmarks {
            mark(.landmarks, actions: [.liveApply])
        }
        // The archive client, the disk cache and the memory budget are
        // built with the renderer. The map's own tiles are untouched: they
        // do not depend on the models. The depth bias alone is read per
        // frame.
        if oldValue.modelArchive != newValue.modelArchive {
            if let oldArchive = oldValue.modelArchive, let newArchive = newValue.modelArchive,
               oldArchive.withDepthBias(newArchive.depthBias) == newArchive {
                mark(.modelArchive, actions: [.liveApply])
            } else {
                mark(.modelArchive, actions: [.recreateRenderer])
            }
        }

        return ImmersiveMapSettingsApplicationPlan(changedDomains: changedDomains, actions: actions)
    }
}
