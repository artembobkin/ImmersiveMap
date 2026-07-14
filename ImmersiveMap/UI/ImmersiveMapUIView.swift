// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

#if canImport(UIKit)

import Metal
import QuartzCore
import UIKit

/// UIKit/Metal host view для ImmersiveMap.
/// Владеет `CAMetalLayer`, UIKit lifecycle, layout и мостом обновлений из SwiftUI;
/// состояние и поведение отдельных функций живут в `ImmersiveMapHostRuntime`
/// и его `ImmersiveMapRuntimeGraph`.
public class ImmersiveMapUIView: UIView {
    public override class var layerClass: AnyClass { return CAMetalLayer.self }

    // MARK: - Rendering

    private var hostRuntime: ImmersiveMapHostRuntime!
    private var memoryWarningObserver: NSObjectProtocol?

    var metalLayer: CAMetalLayer {
        return layer as! CAMetalLayer
    }

    // MARK: - Controllers

    var runtimeGraph: ImmersiveMapRuntimeGraph { hostRuntime.runtimeGraph }
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
                  selectionController: nil,
                  markerTapAction: nil)
    }

    init(frame: CGRect,
         settings: ImmersiveMapSettings,
         avatarsController: ImmersiveMapAvatarsController?,
         cameraPosition: ImmersiveMapCameraPosition?,
         cameraController: ImmersiveMapCameraController?,
         selectionController: ImmersiveMapSelectionController?,
         markerTapAction: ((ImmersiveMapMarkerTapEvent) -> Void)?) {
        super.init(frame: frame)
        setup(settings: settings,
              initialCameraPosition: cameraPosition)
        hostRuntime.syncControllers(avatarsController: avatarsController,
                                    cameraController: cameraController,
                                    selectionController: selectionController,
                                    markerTapAction: markerTapAction)
    }

    private func setup(settings: ImmersiveMapSettings,
                       initialCameraPosition: ImmersiveMapCameraPosition?) {
        metalLayer.contentsScale = UIScreen.main.scale
        memoryWarningObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.hostRuntime?.handleMemoryPressure()
            }
        }

        hostRuntime = ImmersiveMapHostRuntime(mapView: self,
                                              layer: metalLayer,
                                              settings: settings,
                                              initialCameraPosition: initialCameraPosition,
                                              requestsLayout: { [weak self] in
                                                  self?.setNeedsLayout()
                                              })
        hostRuntime.start(displayLinkFactory: { target, selector in
            CADisplayLink(target: target, selector: selector)
        })
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
        debugOverlayRuntime.layout(in: bounds,
                                   safeAreaTopInset: safeAreaInsets.top)
    }

    // MARK: - Updates

    /// Синхронизирует новые параметры из SwiftUI `updateUIView` с уже созданным UIKit/Metal view.
    func update(settings: ImmersiveMapSettings,
                avatarsController: ImmersiveMapAvatarsController?,
                cameraController: ImmersiveMapCameraController?,
                selectionController: ImmersiveMapSelectionController?,
                markerTapAction: ((ImmersiveMapMarkerTapEvent) -> Void)?,
                cameraPosition: ImmersiveMapCameraPosition?) {
        hostRuntime.update(settings: settings,
                           avatarsController: avatarsController,
                           cameraController: cameraController,
                           selectionController: selectionController,
                           markerTapAction: markerTapAction,
                           cameraPosition: cameraPosition)
    }

    func dismantle() {
        hostRuntime.dismantle()
    }

    func requestFrame() {
        hostRuntime.requestFrame()
    }

    func setEarthSceneEnabledFromDebugOverlay(_ isEnabled: Bool) {
        hostRuntime.setEarthSceneEnabled(isEnabled)
    }

    // MARK: - Cleanup

    deinit {
        if let memoryWarningObserver {
            NotificationCenter.default.removeObserver(memoryWarningObserver)
        }
    }
}

#endif
