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
        if oldValue.tileProvider != newValue.tileProvider {
            if oldValue.tileProvider.tileSource != newValue.tileProvider.tileSource {
                mark(.tiles, actions: [.invalidateCaches, .recreateRenderer])
            } else if oldValue.tileProvider.configurationFingerprint != newValue.tileProvider.configurationFingerprint
                || oldValue.tileProvider.id != newValue.tileProvider.id
                || oldValue.tileProvider.cacheNamespace != newValue.tileProvider.cacheNamespace
                || oldValue.tileProvider.maximumTileZoomLevel != newValue.tileProvider.maximumTileZoomLevel {
                mark(.tiles, actions: [.invalidateCaches, .rebuildPreparedData, .recreateRenderer])
            }
        }
        if oldValue.mapStyle != newValue.mapStyle {
            mark(.style, actions: [.invalidateCaches, .rebuildPreparedData, .rebuildGPUResources, .recreateRenderer])
        }
        if oldValue.debug.enableDebugPanel != newValue.debug.enableDebugPanel {
            mark(.debug, actions: [.recreateRenderer])
        } else if oldValue.debug != newValue.debug {
            mark(.debug, actions: [.liveApply])
        }

        // Light and shadows are per-frame uniforms read from `FrameContext`;
        // the shadow-map texture is reallocated lazily on resolution change,
        // so all of them apply live without recreating the renderer.
        let sceneLiveChanged = oldValue.scene.mapClearColor != newValue.scene.mapClearColor
            || oldValue.scene.space != newValue.scene.space
            || oldValue.scene.earth != newValue.scene.earth
            || oldValue.scene.light != newValue.scene.light
            || oldValue.scene.shadows != newValue.scene.shadows
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

        if oldValue.labels != newValue.labels {
            mark(.labels, actions: [.invalidateCaches, .rebuildPreparedData, .recreateRenderer])
        }
        if oldValue.style != newValue.style {
            if isOnlyBuildingExtrusionChanged(from: oldValue.style, to: newValue.style) {
                mark(.style, actions: [.liveApply])
            } else {
                mark(.style, actions: [.invalidateCaches, .rebuildPreparedData, .rebuildGPUResources, .recreateRenderer])
            }
        }
        if oldValue.avatars != newValue.avatars {
            mark(.avatars, actions: [.rebuildGPUResources, .recreateRenderer])
        }
        // The badge also changes when the tile provider changed without the settings
        // themselves changing: the default attribution text belongs to the provider.
        if oldValue.attribution != newValue.attribution
            || oldValue.resolvedAttribution != newValue.resolvedAttribution {
            mark(.attribution, actions: [.liveApply])
        }
        if oldValue.postProcessing != newValue.postProcessing {
            mark(.postProcessing, actions: [.liveApply])
        }

        return ImmersiveMapSettingsApplicationPlan(changedDomains: changedDomains, actions: actions)
    }

    /// Building extrusion alpha and mode are per-frame uniforms: the subsystem reads
    /// them from `FrameContext`, they never enter prepared tiles or GPU resources,
    /// so changing only these fields does not require recreating the renderer.
    private static func isOnlyBuildingExtrusionChanged(from oldStyle: ImmersiveMapSettings.StyleSettings,
                                                       to newStyle: ImmersiveMapSettings.StyleSettings) -> Bool {
        var oldStyleWithNewBuildingExtrusion = oldStyle
        oldStyleWithNewBuildingExtrusion.buildingExtrusionAlpha = newStyle.buildingExtrusionAlpha
        oldStyleWithNewBuildingExtrusion.buildingExtrusionMode = newStyle.buildingExtrusionMode
        return oldStyleWithNewBuildingExtrusion == newStyle
    }
}
