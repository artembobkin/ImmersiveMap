// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

#if os(macOS)

import AppKit
import Metal
import QuartzCore

/// AppKit/Metal host view для ImmersiveMap.
/// Владеет `CAMetalLayer` (backing layer), AppKit lifecycle, layout и мостом обновлений
/// из SwiftUI; состояние и поведение отдельных функций живут в `ImmersiveMapHostRuntime`
/// и его `ImmersiveMapRuntimeGraph`.
public class ImmersiveMapNSView: NSView {
    // MARK: - Rendering

    private var hostRuntime: ImmersiveMapHostRuntime!
    private var memoryPressureSource: DispatchSourceMemoryPressure?

    var metalLayer: CAMetalLayer {
        return layer as! CAMetalLayer
    }

    /// Top-left origin, как в UIKit: общие layout-расчеты контролов, HUD
    /// и координаты жестов совпадают между платформами.
    public override var isFlipped: Bool { true }

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

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup(settings: .default,
              initialCameraPosition: nil)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup(settings: .default,
              initialCameraPosition: nil)
    }

    public convenience init(frame: NSRect,
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

    init(frame: NSRect,
         settings: ImmersiveMapSettings,
         avatarsController: ImmersiveMapAvatarsController?,
         cameraPosition: ImmersiveMapCameraPosition?,
         cameraController: ImmersiveMapCameraController?,
         selectionController: ImmersiveMapSelectionController?) {
        super.init(frame: frame)
        setup(settings: settings,
              initialCameraPosition: cameraPosition)
        hostRuntime.syncControllers(avatarsController: avatarsController,
                                    cameraController: cameraController,
                                    selectionController: selectionController)
    }

    public override func makeBackingLayer() -> CALayer {
        CAMetalLayer()
    }

    private func setup(settings: ImmersiveMapSettings,
                       initialCameraPosition: ImmersiveMapCameraPosition?) {
        wantsLayer = true
        // Содержимое слоя целиком рисует Metal - AppKit не должен просить redraw.
        layerContentsRedrawPolicy = .never
        metalLayer.contentsScale = currentBackingScaleFactor()

        hostRuntime = ImmersiveMapHostRuntime(mapView: self,
                                              layer: metalLayer,
                                              settings: settings,
                                              initialCameraPosition: initialCameraPosition,
                                              requestsLayout: { [weak self] in
                                                  self?.needsLayout = true
                                              })
        // CADisplayLink от NSView привязан к дисплею окна и сам следует
        // за перемещением окна между мониторами.
        hostRuntime.start(displayLinkFactory: { [unowned self] target, selector in
            self.displayLink(target: target, selector: selector)
        })

        startMemoryPressureMonitoring()
        needsLayout = true
    }

    private func startMemoryPressureMonitoring() {
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical],
                                                             queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                self?.hostRuntime?.handleMemoryPressure()
            }
        }
        source.activate()
        memoryPressureSource = source
    }

    private func currentBackingScaleFactor() -> CGFloat {
        let scale = window?.backingScaleFactor
            ?? NSScreen.main?.backingScaleFactor
            ?? 2.0
        return max(scale, 1.0)
    }

    // MARK: - Layout

    public override func layout() {
        super.layout()

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

    public override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }

    public override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        applyBackingScaleIfNeeded()
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else {
            return
        }

        applyBackingScaleIfNeeded()
        requestFrame()
    }

    private func applyBackingScaleIfNeeded() {
        let scale = currentBackingScaleFactor()
        guard metalLayer.contentsScale != scale else {
            return
        }

        metalLayer.contentsScale = scale
        needsLayout = true
        requestFrame()
    }

    // MARK: - Input

    public override func scrollWheel(with event: NSEvent) {
        gestureController.handleScrollWheel(event)
    }

    // MARK: - Updates

    /// Синхронизирует новые параметры из SwiftUI `updateNSView` с уже созданным AppKit/Metal view.
    func update(settings: ImmersiveMapSettings,
                avatarsController: ImmersiveMapAvatarsController?,
                cameraController: ImmersiveMapCameraController?,
                selectionController: ImmersiveMapSelectionController?,
                cameraPosition: ImmersiveMapCameraPosition?) {
        hostRuntime.update(settings: settings,
                           avatarsController: avatarsController,
                           cameraController: cameraController,
                           selectionController: selectionController,
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
        memoryPressureSource?.cancel()
    }
}

#endif
