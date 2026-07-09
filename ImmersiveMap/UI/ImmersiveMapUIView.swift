// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

#if canImport(UIKit)

import Metal
import QuartzCore
import UIKit

/// UIKit/Metal host view для ImmersiveMap.
/// Владеет `CAMetalLayer`, UIKit lifecycle, layout и мостом обновлений из SwiftUI;
/// состояние и поведение отдельных функций живут в runtime-объектах из `ImmersiveMapRuntimeGraph`.
public class ImmersiveMapUIView: UIView {
    public override class var layerClass: AnyClass { return CAMetalLayer.self }

    // MARK: - Rendering

    private var renderer: RenderFrameEngine?
    private var memoryWarningObserver: NSObjectProtocol?

    var metalLayer: CAMetalLayer {
        return layer as! CAMetalLayer
    }

    // MARK: - Controllers

    private(set) var runtimeGraph: ImmersiveMapRuntimeGraph!
    var gestureController: MapGestureController { runtimeGraph.gestureController }
    var renderRuntime: ImmersiveMapRenderRuntime { runtimeGraph.renderRuntime }
    var viewportRuntime: ImmersiveMapViewportRuntime { runtimeGraph.viewportRuntime }
    var avatarRuntime: ImmersiveMapAvatarRuntime { runtimeGraph.avatarRuntime }
    var controlsRuntime: ImmersiveMapControlsRuntime { runtimeGraph.controlsRuntime }
    var cameraRuntime: ImmersiveMapCameraRuntime { runtimeGraph.cameraRuntime }
    var cameraCommandHandler: ImmersiveMapCameraCommandHandler { runtimeGraph.cameraCommandHandler }
    var interactionRuntime: ImmersiveMapInteractionRuntime { runtimeGraph.interactionRuntime }
    var cameraAnimationRuntime: ImmersiveMapCameraAnimationRuntime { runtimeGraph.cameraAnimationRuntime }
    var selectionHandler: ImmersiveMapSelectionHandler { runtimeGraph.selectionHandler }
    var debugOverlayRuntime: ImmersiveMapDebugOverlayRuntime { runtimeGraph.debugOverlayRuntime }
    var tapHandler: ImmersiveMapTapHandler { runtimeGraph.tapHandler }
    var rendererBuilder: ImmersiveMapRendererBuilder { runtimeGraph.rendererBuilder }

    // MARK: - Initialization

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup(settings: .default,
              initialCameraPosition: nil)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup(settings: .default,
              initialCameraPosition: nil)
    }

    public convenience init(frame: CGRect,
                            settings: ImmersiveMapSettings,
                            avatarsController: ImmersiveMapAvatarsController? = nil,
                            cameraPosition: ImmersiveMapCameraPosition? = nil) {
        self.init(frame: frame,
                  settings: settings,
                  avatarsController: avatarsController,
                  cameraPosition: cameraPosition,
                  cameraController: nil,
                  selectionController: nil)
    }

    init(frame: CGRect,
         settings: ImmersiveMapSettings,
         avatarsController: ImmersiveMapAvatarsController?,
         cameraPosition: ImmersiveMapCameraPosition?,
         cameraController: ImmersiveMapCameraController?,
         selectionController: ImmersiveMapSelectionController?) {
        super.init(frame: frame)
        setup(settings: settings,
              initialCameraPosition: cameraPosition)
        syncControllers(avatarsController: avatarsController,
                        cameraController: cameraController,
                        selectionController: selectionController)
    }

    private func setup(settings: ImmersiveMapSettings,
                       initialCameraPosition: ImmersiveMapCameraPosition?) {
        metalLayer.contentsScale = UIScreen.main.scale
        memoryWarningObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.renderer?.handleMemoryWarning()
            // Warning отменяет in-flight загрузки и сбрасывает demand-гейт;
            // on-demand цикл при этом спит, и без явного кадра отменённые тайлы
            // остаются дырами до следующего жеста - кадр перезапускает demand.
            self?.requestFrame()
        }

        runtimeGraph = ImmersiveMapRuntimeGraph(mapView: self,
                                                layer: metalLayer,
                                                settings: settings,
                                                initialCameraPosition: initialCameraPosition)
        debugOverlayRuntime.apply(settings: settings)

        createRenderer(settings: settings,
                       cameraPosition: initialCameraPosition)
        cameraRuntime.syncPitchControlValue()

        renderRuntime.start(frameDelegate: runtimeGraph.frameRenderDelegate)
    }

    // MARK: - Layout

    public override func layoutSubviews() {
        super.layoutSubviews()

        let didChangeDrawableSize = viewportRuntime.layout(layer: metalLayer,
                                                           bounds: bounds,
                                                           contentsScale: metalLayer.contentsScale)
        if didChangeDrawableSize {
            requestFrame()
        }

        controlsRuntime.layout(in: bounds,
                               safeAreaInsets: safeAreaInsets)
        debugOverlayRuntime.layout(in: bounds)
    }

    // MARK: - Updates

    /// Синхронизирует новые параметры из SwiftUI `updateUIView` с уже созданным UIKit/Metal view.
    func update(settings: ImmersiveMapSettings,
                avatarsController: ImmersiveMapAvatarsController?,
                cameraController: ImmersiveMapCameraController?,
                selectionController: ImmersiveMapSelectionController?,
                cameraPosition: ImmersiveMapCameraPosition?) {
        applySettings(settings)
        syncControllers(avatarsController: avatarsController,
                        cameraController: cameraController,
                        selectionController: selectionController)
        cameraCommandHandler.applyCameraPosition(cameraPosition)
    }

    func dismantle() {
        syncControllers(avatarsController: nil,
                        cameraController: nil,
                        selectionController: nil)
    }

    /// Применяет новые SwiftUI-настройки к runtime карты и через planner выбирает:
    /// обновить существующий renderer на лету или пересоздать его для изменений,
    /// которые затрагивают кэши, подготовленные данные или GPU-ресурсы.
    private func applySettings(_ settings: ImmersiveMapSettings) {
        let currentSettings = cameraRuntime.currentSettings
        guard currentSettings != settings else {
            return
        }

        let plan = ImmersiveMapSettingsApplicationPlanner.makePlan(from: currentSettings,
                                                                   to: settings)
        cameraRuntime.updateSettings(settings,
                                     notifiesCameraPositionChanged: plan.requiresRendererRecreation == false)
        cameraAnimationRuntime.updateSettings()
        controlsRuntime.applyAttributionSettings(settings.attribution)
        debugOverlayRuntime.apply(settings: settings)
        setNeedsLayout()
        renderRuntime.updateRenderLoopSettings(settings.renderLoop)
        if plan.requiresRendererRecreation {
            recreateRenderer(with: settings)
        } else {
            renderer?.applySettings(settings)
        }

        cameraRuntime.syncPitchControlValue()
        requestFrame()
    }

    func requestFrame() {
        renderRuntime.requestFrame()
    }

    func setEarthSceneEnabledFromDebugOverlay(_ isEnabled: Bool) {
        var settings = cameraRuntime.currentSettings
        settings.scene.earth.isEnabled = isEnabled
        applySettings(settings)
    }

    // MARK: - Controller Sync

    @MainActor
    private func syncControllers(avatarsController newAvatarsController: ImmersiveMapAvatarsController?,
                         cameraController newCameraController: ImmersiveMapCameraController?,
                         selectionController newSelectionController: ImmersiveMapSelectionController?) {
        let shouldUpdateAvatarsController = avatarRuntime.isAttachedController(newAvatarsController) == false
        let shouldUpdateCameraController = cameraRuntime.isAttachedController(newCameraController) == false
        guard shouldUpdateAvatarsController
            || shouldUpdateCameraController else {
            selectionHandler.syncController(newSelectionController)
            return
        }

        if shouldUpdateAvatarsController {
            avatarRuntime.attachController(newAvatarsController,
                                           selectionHandler: selectionHandler,
                                           renderRuntime: renderRuntime)
        }
        if shouldUpdateCameraController {
            cameraRuntime.attachController(newCameraController,
                                           commandHandler: cameraCommandHandler)
        }
        selectionHandler.syncController(newSelectionController)
    }

    // MARK: - Render Engine

    private func createRenderer(settings: ImmersiveMapSettings,
                                cameraPosition: ImmersiveMapCameraPosition?) {
        let renderer = rendererBuilder.makeRenderer(layer: metalLayer,
                                                    settings: settings,
                                                    cameraPosition: cameraPosition)
        self.renderer = renderer
        renderRuntime.attachRenderer(renderer)
        avatarRuntime.markSnapshotDirty()
        requestFrame()
    }

    private func recreateRenderer(with settings: ImmersiveMapSettings) {
        cameraAnimationRuntime.cancelAnimations(notifyFlightCompletion: false)
        let cameraPosition = cameraRuntime.cameraPositionForRendererRecreation()
        renderRuntime.detachRenderer()
        renderer = nil
        cameraRuntime.clearRenderCamera()
        createRenderer(settings: settings,
                       cameraPosition: cameraPosition)
    }

    // MARK: - Cleanup

    deinit {
        cameraAnimationRuntime.reset()
        let detachedAvatarRuntime = avatarRuntime
        Task { @MainActor in
            detachedAvatarRuntime.detachController()
        }
        cameraRuntime.detachController()
        let detachedSelectionHandler = selectionHandler
        Task { @MainActor in
            detachedSelectionHandler.syncController(nil)
        }
        renderRuntime.stop()
        if let memoryWarningObserver {
            NotificationCenter.default.removeObserver(memoryWarningObserver)
        }
    }
}

#endif
