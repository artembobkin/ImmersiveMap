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
    /// Строит план применения новых настроек, отделяя live-обновления от изменений,
    /// для которых нужно пересоздать renderer из-за кэшей, подготовленных данных или GPU-ресурсов.
    /// Эта логика вынесена из `ImmersiveMapSettings`, потому что настройки описывают состояние,
    /// а решение о способе применения относится к runtime-политике карты.
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

        let sceneLiveChanged = oldValue.scene.mapClearColor != newValue.scene.mapClearColor
            || oldValue.scene.space != newValue.scene.space
            || oldValue.scene.earth != newValue.scene.earth
        if sceneLiveChanged {
            mark(.scene, actions: [.liveApply])
        }
        if oldValue.scene.earth.nightLights.tileManifestURL != newValue.scene.earth.nightLights.tileManifestURL {
            mark(.scene, actions: [.recreateRenderer])
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
            mark(.style, actions: [.invalidateCaches, .rebuildPreparedData, .rebuildGPUResources, .recreateRenderer])
        }
        if oldValue.avatars != newValue.avatars {
            mark(.avatars, actions: [.rebuildGPUResources, .recreateRenderer])
        }
        if oldValue.attribution != newValue.attribution {
            mark(.attribution, actions: [.liveApply])
        }
        if oldValue.postProcessing != newValue.postProcessing {
            mark(.postProcessing, actions: [.liveApply])
        }

        return ImmersiveMapSettingsApplicationPlan(changedDomains: changedDomains, actions: actions)
    }
}
