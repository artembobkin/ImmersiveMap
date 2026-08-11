// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

#if canImport(UIKit)

import Metal
import QuartzCore
import UIKit

/// UIKit/Metal host view for ImmersiveMap.
/// Owns the `CAMetalLayer`, UIKit lifecycle, layout, and the bridge for updates
/// from SwiftUI; per-feature state and behavior live in `ImmersiveMapHostRuntime`
/// and its `ImmersiveMapRuntimeGraph`.
public class ImmersiveMapUIView: UIView {
    public override class var layerClass: AnyClass { return CAMetalLayer.self }

    // MARK: - Rendering

    private var hostRuntime: ImmersiveMapHostRuntime!
    // nonisolated(unsafe): written once on main; the nonisolated deinit only
    // removes it from NotificationCenter (removeObserver is thread-safe).
    nonisolated(unsafe) private var memoryWarningObserver: NSObjectProtocol?

    var metalLayer: CAMetalLayer {
        return layer as! CAMetalLayer
    }

    /// Transparent space needs the drawable composited over whatever is behind
    /// the map: UIKit must stop treating the view as fully covering its frame,
    /// otherwise the alpha the frame carries is ignored.
    func applyBackgroundTransparency(_ isTransparent: Bool) {
        isOpaque = isTransparent == false
        backgroundColor = isTransparent ? .clear : nil
        metalLayer.isOpaque = isTransparent == false
    }

    // MARK: - Controllers

    var runtimeGraph: ImmersiveMapRuntimeGraph { hostRuntime.runtimeGraph }
    var gestureController: MapGestureController { runtimeGraph.gestureController }
    var renderRuntime: ImmersiveMapRenderRuntime { runtimeGraph.renderRuntime }
    var viewportRuntime: ImmersiveMapViewportRuntime { runtimeGraph.viewportRuntime }
    var avatarRuntime: ImmersiveMapAvatarRuntime { runtimeGraph.avatarRuntime }
    var markerRuntime: ImmersiveMapMarkerRuntime { runtimeGraph.markerRuntime }
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
                  avatarTapAction: nil)
    }

    init(frame: CGRect,
         settings: ImmersiveMapSettings,
         avatarsController: ImmersiveMapAvatarsController?,
         sceneModelsController: ImmersiveMapSceneModelsController? = nil,
         routesController: ImmersiveMapRoutesController? = nil,
         cameraPosition: ImmersiveMapCameraPosition?,
         cameraController: ImmersiveMapCameraController?,
         selectionController: ImmersiveMapSelectionController?,
         avatarTapAction: ((ImmersiveMapAvatarTapEvent) -> Void)?,
         sceneModelTapAction: ((ImmersiveMapSceneModelTapEvent) -> Void)? = nil,
         markerContent: MarkerViewContent? = nil) {
        super.init(frame: frame)
        setup(settings: settings,
              initialCameraPosition: cameraPosition)
        hostRuntime.syncControllers(avatarsController: avatarsController,
                                    sceneModelsController: sceneModelsController,
                                    routesController: routesController,
                                    cameraController: cameraController,
                                    selectionController: selectionController,
                                    avatarTapAction: avatarTapAction,
                                    sceneModelTapAction: sceneModelTapAction)
        hostRuntime.updateMarkerContent(markerContent)
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
        hostRuntime.start()
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
        markerRuntime.layout(in: bounds)
    }

    // MARK: - Updates

    /// Synchronizes fresh parameters from SwiftUI `updateUIView` with the already created UIKit/Metal view.
    func update(settings: ImmersiveMapSettings,
                avatarsController: ImmersiveMapAvatarsController?,
                sceneModelsController: ImmersiveMapSceneModelsController? = nil,
                routesController: ImmersiveMapRoutesController? = nil,
                cameraController: ImmersiveMapCameraController?,
                selectionController: ImmersiveMapSelectionController?,
                avatarTapAction: ((ImmersiveMapAvatarTapEvent) -> Void)?,
                sceneModelTapAction: ((ImmersiveMapSceneModelTapEvent) -> Void)? = nil,
                markerContent: MarkerViewContent?,
                cameraPosition: ImmersiveMapCameraPosition?,
                tourVideoRecorder: ImmersiveMapTourVideoRecorder? = nil) {
        hostRuntime.update(settings: settings,
                           avatarsController: avatarsController,
                           sceneModelsController: sceneModelsController,
                           routesController: routesController,
                           cameraController: cameraController,
                           selectionController: selectionController,
                           avatarTapAction: avatarTapAction,
                           sceneModelTapAction: sceneModelTapAction,
                           markerContent: markerContent,
                           cameraPosition: cameraPosition,
                           tourVideoRecorder: tourVideoRecorder)
    }

    func dismantle() {
        hostRuntime.dismantle()
    }

    /// Dismantle driven by SwiftUI teardown: detaches app-owned state and, when
    /// view reuse is enabled, parks this view for the next `ImmersiveMapView`
    /// to adopt warm instead of releasing the renderer.
    func dismantleForReuse() {
        let viewReuse = cameraRuntime.currentSettings.viewReuse
        // Animations are cancelled BEFORE the controllers detach: a flight
        // completion fired after detach would queue any follow-up command in
        // the app's controller and replay it onto the next screen.
        cameraAnimationRuntime.cancelAnimations()
        dismantle()
        guard viewReuse.isEnabled else {
            return
        }
        // A parked view must idle. Interaction sources stuck by an interrupted
        // gesture are cleared, the declared camera position is forgotten (the
        // adopting screen's declaration must re-apply even when equal), and
        // the render loop is gated off so the display link stays paused no
        // matter what invalidations arrive.
        interactionRuntime.resetForParking()
        cameraRuntime.clearAppliedCameraPositionForReuse()
        renderRuntime.setParked(true)
        ImmersiveMapHostViewPool.shared.park(self, timeToLive: viewReuse.parkedTimeToLive)
    }

    /// Rewires an adopted (previously parked) view for a new `ImmersiveMapView`:
    /// the regular update path reconciles settings and controllers, so adoption
    /// behaves like an update of a live view rather than a fresh build.
    func prepareForAdoption(settings: ImmersiveMapSettings,
                            avatarsController: ImmersiveMapAvatarsController?,
                            sceneModelsController: ImmersiveMapSceneModelsController?,
                            routesController: ImmersiveMapRoutesController?,
                            cameraPosition: ImmersiveMapCameraPosition?,
                            cameraController: ImmersiveMapCameraController?,
                            selectionController: ImmersiveMapSelectionController?,
                            avatarTapAction: ((ImmersiveMapAvatarTapEvent) -> Void)?,
                            sceneModelTapAction: ((ImmersiveMapSceneModelTapEvent) -> Void)? = nil,
                            markerContent: MarkerViewContent?) {
        hostRuntime.update(settings: settings,
                           avatarsController: avatarsController,
                           sceneModelsController: sceneModelsController,
                           routesController: routesController,
                           cameraController: cameraController,
                           selectionController: selectionController,
                           avatarTapAction: avatarTapAction,
                           sceneModelTapAction: sceneModelTapAction,
                           markerContent: markerContent,
                           cameraPosition: cameraPosition)
        renderRuntime.setParked(false)
        setNeedsLayout()
        requestFrame()
    }

    func requestFrame() {
        hostRuntime.requestFrame()
    }

    #if DEBUG
    var hostRuntimeForTesting: ImmersiveMapHostRuntime {
        hostRuntime
    }
    #endif

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
