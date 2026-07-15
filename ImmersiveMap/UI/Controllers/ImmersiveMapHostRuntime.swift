// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import CoreGraphics
import QuartzCore

/// Общая для UIKit/AppKit host view логика владения runtime graph и `RenderFrameEngine`:
/// применение настроек, синхронизация контроллеров, создание и пересоздание рендерера.
/// Платформенный view отвечает только за layer, layout, ввод и lifecycle-события.
@MainActor
final class ImmersiveMapHostRuntime {
    let runtimeGraph: ImmersiveMapRuntimeGraph
    private(set) var renderer: RenderFrameEngine?
    private let metalLayer: CAMetalLayer
    private let requestsLayout: () -> Void

    init(mapView: ImmersiveMapHostView,
         layer: CAMetalLayer,
         settings: ImmersiveMapSettings,
         initialCameraPosition: ImmersiveMapCameraPosition?,
         requestsLayout: @escaping () -> Void) {
        self.metalLayer = layer
        self.requestsLayout = requestsLayout
        self.runtimeGraph = ImmersiveMapRuntimeGraph(mapView: mapView,
                                                     layer: layer,
                                                     settings: settings,
                                                     initialCameraPosition: initialCameraPosition)
        runtimeGraph.debugOverlayRuntime.apply(settings: settings)

        createRenderer(settings: settings,
                       cameraPosition: initialCameraPosition)
        runtimeGraph.cameraRuntime.syncPitchControlValue()
    }

    func start(displayLinkFactory: DisplayLinkFactory) {
        runtimeGraph.renderRuntime.start(frameDelegate: runtimeGraph.frameRenderDelegate,
                                         displayLinkFactory: displayLinkFactory)
    }

    func requestFrame() {
        runtimeGraph.renderRuntime.requestFrame()
    }

    func handleMemoryPressure() {
        renderer?.handleMemoryWarning()
        // Warning отменяет in-flight загрузки и сбрасывает demand-гейт;
        // on-demand цикл при этом спит, и без явного кадра отменённые тайлы
        // остаются дырами до следующего жеста - кадр перезапускает demand.
        requestFrame()
    }

    /// Синхронизирует новые параметры из SwiftUI update-хука с уже созданным host view.
    func update(settings: ImmersiveMapSettings,
                avatarsController: ImmersiveMapAvatarsController?,
                cameraController: ImmersiveMapCameraController?,
                selectionController: ImmersiveMapSelectionController?,
                markerTapAction: ((ImmersiveMapMarkerTapEvent) -> Void)?,
                cameraPosition: ImmersiveMapCameraPosition?) {
        applySettings(settings)
        syncControllers(avatarsController: avatarsController,
                        cameraController: cameraController,
                        selectionController: selectionController,
                        markerTapAction: markerTapAction)
        runtimeGraph.cameraCommandHandler.applyCameraPosition(cameraPosition)
    }

    func dismantle() {
        syncControllers(avatarsController: nil,
                        cameraController: nil,
                        selectionController: nil,
                        markerTapAction: nil)
    }

    func setEarthSceneEnabled(_ isEnabled: Bool) {
        var settings = runtimeGraph.cameraRuntime.currentSettings
        settings.scene.earth.isEnabled = isEnabled
        applySettings(settings)
    }

    /// Применяет новые настройки к runtime карты и через planner выбирает:
    /// обновить существующий renderer на лету или пересоздать его для изменений,
    /// которые затрагивают кэши, подготовленные данные или GPU-ресурсы.
    func applySettings(_ settings: ImmersiveMapSettings) {
        let currentSettings = runtimeGraph.cameraRuntime.currentSettings
        guard currentSettings != settings else {
            return
        }

        let plan = ImmersiveMapSettingsApplicationPlanner.makePlan(from: currentSettings,
                                                                   to: settings)
        runtimeGraph.cameraRuntime.updateSettings(settings,
                                                  notifiesCameraPositionChanged: plan.requiresRendererRecreation == false)
        runtimeGraph.cameraAnimationRuntime.updateSettings()
        runtimeGraph.controlsRuntime.applyAttributionSettings(settings.attribution)
        runtimeGraph.debugOverlayRuntime.apply(settings: settings)
        requestsLayout()
        runtimeGraph.renderRuntime.updateRenderLoopSettings(settings.renderLoop)
        if plan.requiresRendererRecreation {
            recreateRenderer(with: settings)
        } else {
            renderer?.applySettings(settings)
        }

        runtimeGraph.cameraRuntime.syncPitchControlValue()
        requestFrame()
    }

    func syncControllers(avatarsController newAvatarsController: ImmersiveMapAvatarsController?,
                         cameraController newCameraController: ImmersiveMapCameraController?,
                         selectionController newSelectionController: ImmersiveMapSelectionController?,
                         markerTapAction newMarkerTapAction: ((ImmersiveMapMarkerTapEvent) -> Void)?) {
        runtimeGraph.selectionHandler.setMarkerTapAction(newMarkerTapAction)
        let shouldUpdateAvatarsController = runtimeGraph.avatarRuntime.isAttachedController(newAvatarsController) == false
        let shouldUpdateCameraController = runtimeGraph.cameraRuntime.isAttachedController(newCameraController) == false
        guard shouldUpdateAvatarsController
            || shouldUpdateCameraController else {
            runtimeGraph.selectionHandler.syncController(newSelectionController)
            return
        }

        if shouldUpdateAvatarsController {
            runtimeGraph.avatarRuntime.attachController(newAvatarsController,
                                                        selectionHandler: runtimeGraph.selectionHandler,
                                                        renderRuntime: runtimeGraph.renderRuntime)
        }
        if shouldUpdateCameraController {
            runtimeGraph.cameraRuntime.attachController(newCameraController,
                                                        commandHandler: runtimeGraph.cameraCommandHandler)
        }
        runtimeGraph.selectionHandler.syncController(newSelectionController)
    }

    private func createRenderer(settings: ImmersiveMapSettings,
                                cameraPosition: ImmersiveMapCameraPosition?) {
        let renderer = runtimeGraph.rendererBuilder.makeRenderer(layer: metalLayer,
                                                                 settings: settings,
                                                                 cameraPosition: cameraPosition)
        self.renderer = renderer
        runtimeGraph.renderRuntime.attachRenderer(renderer)
        runtimeGraph.avatarRuntime.markSnapshotDirty()
        requestFrame()
    }

    private func recreateRenderer(with settings: ImmersiveMapSettings) {
        runtimeGraph.cameraAnimationRuntime.cancelAnimations(notifyFlightCompletion: false)
        let cameraPosition = runtimeGraph.cameraRuntime.cameraPositionForRendererRecreation()
        runtimeGraph.renderRuntime.detachRenderer()
        renderer = nil
        runtimeGraph.cameraRuntime.clearRenderCamera()
        createRenderer(settings: settings,
                       cameraPosition: cameraPosition)
    }

    deinit {
        let detachedGraph = runtimeGraph
        Task { @MainActor in
            detachedGraph.cameraAnimationRuntime.reset()
            detachedGraph.avatarRuntime.detachController()
            detachedGraph.cameraRuntime.detachController()
            detachedGraph.selectionHandler.syncController(nil)
            detachedGraph.renderRuntime.stop()
        }
    }
}
