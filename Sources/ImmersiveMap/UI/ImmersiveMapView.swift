// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

// The `UI` folder: the public SwiftUI surface, the platform host views
// (`ImmersiveMapUIView` on iOS, `ImmersiveMapNSView` on macOS, unified as
// `ImmersiveMapHostView`) and the runtime controllers that connect gestures,
// camera commands, selection, settings, tiles and the render driver to the
// engine. Platform code lives in per-platform files under `#if
// canImport(UIKit)` and `#if os(macOS)`, never `targetEnvironment(macCatalyst)`.
// No Metal pipelines or render graph internals (`Render`), no tile parsing,
// styling or caching, no label policy, no host-app delegates or
// launch environment, no keys or secrets.

public struct ImmersiveMapView: View {
    var settings: ImmersiveMapSettings
    private var cameraPosition: ImmersiveMapCameraPosition?
    private var avatarsController: ImmersiveMapAvatarsController?
    private var sceneModelsController: ImmersiveMapSceneModelsController?
    private var cameraController: ImmersiveMapCameraController?
    private var cameraUIControls: CameraUIControls?
    /// The controller the camera buttons drive when the app attaches none:
    /// a controller is the app's handle on the camera from code, the
    /// buttons are a modifier of their own (`enableCameraUIControls`), and
    /// one must not need the other.
    @State private var builtInCameraController = ImmersiveMapCameraController()
    private var selectionController: ImmersiveMapSelectionController?
    private var avatarTapAction: ((ImmersiveMapAvatarTapEvent) -> Void)?
    private var sceneModelTapAction: ((ImmersiveMapSceneModelTapEvent) -> Void)?
    private var frameRenderedAction: ((ImmersiveMapRenderedFrame) -> Void)?
    private var terrainSurroundingsAction: ((ImmersiveMapTerrainSurroundings?) -> Void)?
    private var markerContent: MarkerViewContent?
    private var tourVideoRecorder: ImmersiveMapTourVideoRecorder?

    public init(settings: ImmersiveMapSettings = .default,
                avatarsController: ImmersiveMapAvatarsController? = nil,
                cameraPosition: ImmersiveMapCameraPosition? = nil,
                cameraController: ImmersiveMapCameraController? = nil,
                selectionController: ImmersiveMapSelectionController? = nil) {
        self.settings = settings
        self.avatarsController = avatarsController
        self.cameraPosition = cameraPosition
        self.cameraController = cameraController
        self.selectionController = selectionController
    }

    /// The body tree is identity-stable under any combination of modifiers:
    /// toggling `enableCameraUIControls` must not change the tree type,
    /// otherwise SwiftUI destroys and recreates the entire platform map view
    /// (renderer, caches, controller bindings).
    public var body: some View {
        let cameraController = resolvedCameraController
        return ImmersiveMapUIViewRepresentable(settings: settings,
                                        avatarsController: avatarsController,
                                        sceneModelsController: sceneModelsController,
                                        cameraPosition: cameraPosition,
                                        cameraController: cameraController,
                                        selectionController: selectionController,
                                        avatarTapAction: avatarTapAction,
                                        sceneModelTapAction: sceneModelTapAction,
                                        frameRenderedAction: frameRenderedAction,
                                        terrainSurroundingsAction: terrainSurroundingsAction,
                                        markerContent: markerContent,
                                        tourVideoRecorder: tourVideoRecorder)
            .immersiveMapCameraControlsOverlay(
                isEnabled: isCameraUIControlsEnabled && settings.controls.isHidden == false,
                camera: cameraController,
                initialCameraPosition: cameraPosition ?? Self.defaultCameraControlsPosition,
                maximumPitch: cameraUIControls?.maximumPitch ?? ImmersiveMapSettings.default.camera.maximumPitch
            )
    }

    private var isCameraUIControlsEnabled: Bool {
        cameraUIControls?.isEnabled ?? false
    }

    /// The app's controller, or with the camera buttons on and no
    /// controller of the app's the built-in one, so the buttons work on
    /// a bare `ImmersiveMapView().enableCameraUIControls()`. Without the
    /// buttons and without a controller none is attached, as before.
    private var resolvedCameraController: ImmersiveMapCameraController? {
        cameraController ?? (isCameraUIControlsEnabled ? builtInCameraController : nil)
    }

}

#if canImport(UIKit)
private struct ImmersiveMapUIViewRepresentable: UIViewRepresentable {
    let settings: ImmersiveMapSettings
    let avatarsController: ImmersiveMapAvatarsController?
    let sceneModelsController: ImmersiveMapSceneModelsController?
    let cameraPosition: ImmersiveMapCameraPosition?
    let cameraController: ImmersiveMapCameraController?
    let selectionController: ImmersiveMapSelectionController?
    let avatarTapAction: ((ImmersiveMapAvatarTapEvent) -> Void)?
    let sceneModelTapAction: ((ImmersiveMapSceneModelTapEvent) -> Void)?
    let frameRenderedAction: ((ImmersiveMapRenderedFrame) -> Void)?
    let terrainSurroundingsAction: ((ImmersiveMapTerrainSurroundings?) -> Void)?
    let markerContent: MarkerViewContent?
    let tourVideoRecorder: ImmersiveMapTourVideoRecorder?

    public func makeUIView(context: Context) -> ImmersiveMapUIView {
        // Adopt a parked view when reuse is on: renderer and tile cache come
        // back warm, and the update path reconciles the settings.
        if settings.viewReuse.isEnabled,
           let adopted = ImmersiveMapHostViewPool.shared.adopt() {
            adopted.prepareForAdoption(settings: settings,
                                       avatarsController: avatarsController,
                                       sceneModelsController: sceneModelsController,
                                       cameraPosition: cameraPosition,
                                       cameraController: cameraController,
                                       selectionController: selectionController,
                                       avatarTapAction: avatarTapAction,
                                       sceneModelTapAction: sceneModelTapAction,
                                       frameRenderedAction: frameRenderedAction,
                                       terrainSurroundingsAction: terrainSurroundingsAction,
                                       markerContent: markerContent)
            return adopted
        }
        let uiView = ImmersiveMapUIView(frame: .zero,
                                        settings: settings,
                                        avatarsController: avatarsController,
                                        sceneModelsController: sceneModelsController,
                                        cameraPosition: cameraPosition,
                                        cameraController: cameraController,
                                        selectionController: selectionController,
                                        avatarTapAction: avatarTapAction,
                                        sceneModelTapAction: sceneModelTapAction,
                                        frameRenderedAction: frameRenderedAction,
                                        terrainSurroundingsAction: terrainSurroundingsAction,
                                        markerContent: markerContent)
        return uiView
    }

    public func updateUIView(_ uiView: ImmersiveMapUIView, context: Context) {
        uiView.update(settings: settings,
                      avatarsController: avatarsController,
                      sceneModelsController: sceneModelsController,
                      cameraController: cameraController,
                      selectionController: selectionController,
                      avatarTapAction: avatarTapAction,
                      sceneModelTapAction: sceneModelTapAction,
                      frameRenderedAction: frameRenderedAction,
                      terrainSurroundingsAction: terrainSurroundingsAction,
                      markerContent: markerContent,
                      cameraPosition: cameraPosition,
                      tourVideoRecorder: tourVideoRecorder)
    }

    public static func dismantleUIView(_ uiView: ImmersiveMapUIView, coordinator: ()) {
        uiView.dismantleForReuse()
    }
}
#elseif canImport(AppKit)
private struct ImmersiveMapUIViewRepresentable: NSViewRepresentable {
    let settings: ImmersiveMapSettings
    let avatarsController: ImmersiveMapAvatarsController?
    let sceneModelsController: ImmersiveMapSceneModelsController?
    let cameraPosition: ImmersiveMapCameraPosition?
    let cameraController: ImmersiveMapCameraController?
    let selectionController: ImmersiveMapSelectionController?
    let avatarTapAction: ((ImmersiveMapAvatarTapEvent) -> Void)?
    let sceneModelTapAction: ((ImmersiveMapSceneModelTapEvent) -> Void)?
    let frameRenderedAction: ((ImmersiveMapRenderedFrame) -> Void)?
    let terrainSurroundingsAction: ((ImmersiveMapTerrainSurroundings?) -> Void)?
    let markerContent: MarkerViewContent?
    let tourVideoRecorder: ImmersiveMapTourVideoRecorder?

    public func makeNSView(context: Context) -> ImmersiveMapNSView {
        // Adopt a parked view when reuse is on: renderer and tile cache come
        // back warm, and the update path reconciles the settings.
        if settings.viewReuse.isEnabled,
           let adopted = ImmersiveMapHostViewPool.shared.adopt() {
            adopted.prepareForAdoption(settings: settings,
                                       avatarsController: avatarsController,
                                       sceneModelsController: sceneModelsController,
                                       cameraPosition: cameraPosition,
                                       cameraController: cameraController,
                                       selectionController: selectionController,
                                       avatarTapAction: avatarTapAction,
                                       sceneModelTapAction: sceneModelTapAction,
                                       frameRenderedAction: frameRenderedAction,
                                       terrainSurroundingsAction: terrainSurroundingsAction,
                                       markerContent: markerContent)
            return adopted
        }
        let nsView = ImmersiveMapNSView(frame: .zero,
                                        settings: settings,
                                        avatarsController: avatarsController,
                                        sceneModelsController: sceneModelsController,
                                        cameraPosition: cameraPosition,
                                        cameraController: cameraController,
                                        selectionController: selectionController,
                                        avatarTapAction: avatarTapAction,
                                        sceneModelTapAction: sceneModelTapAction,
                                        frameRenderedAction: frameRenderedAction,
                                        terrainSurroundingsAction: terrainSurroundingsAction,
                                        markerContent: markerContent)
        return nsView
    }

    public func updateNSView(_ nsView: ImmersiveMapNSView, context: Context) {
        nsView.update(settings: settings,
                      avatarsController: avatarsController,
                      sceneModelsController: sceneModelsController,
                      cameraController: cameraController,
                      selectionController: selectionController,
                      avatarTapAction: avatarTapAction,
                      sceneModelTapAction: sceneModelTapAction,
                      frameRenderedAction: frameRenderedAction,
                      terrainSurroundingsAction: terrainSurroundingsAction,
                      markerContent: markerContent,
                      cameraPosition: cameraPosition,
                      tourVideoRecorder: tourVideoRecorder)
    }

    public static func dismantleNSView(_ nsView: ImmersiveMapNSView, coordinator: ()) {
        nsView.dismantleForReuse()
    }
}
#endif

public extension ImmersiveMapView {

    /// Builds the GPU resources every map view in the process shares (the
    /// shader library and its pipeline states, which is where the device
    /// compiles the shaders on the first launch after an install or an
    /// update, the text atlases, the marker and globe geometry) ahead of
    /// the first map view, off the main thread. Call it once at app
    /// launch, before a screen with a map is likely: the first map view
    /// then appears with its renderer at once instead of waiting for it,
    /// and an app that skips the call loses nothing but that, since the
    /// first view builds the same resources on its own background task and
    /// shows its first frame when they are ready. Returns when the
    /// resources are built; a second call, or a map view created while the
    /// build runs, waits for the same build. Safe to call from any task.
    ///
    /// - Parameter settings: the settings the map views will use; only the
    ///   multisample count of ``ImmersiveMapSettings/PostProcessingSettings``
    ///   selects a resource set.
    static func prewarm(settings: ImmersiveMapSettings = .default) async {
        await SharedRenderResources.prewarm(sampleCount: settings.postProcessing.multisampleCount)
    }

    func avatars(_ controller: ImmersiveMapAvatarsController?) -> ImmersiveMapView {
        var view = self
        view.avatarsController = controller
        return view
    }

    /// Attaches 3D scene models anchored at geo coordinates. Models render
    /// inside the map world pass (with depth: hidden behind the globe horizon
    /// and, in solid building mode, behind buildings) in flat, globe, and the
    /// morph between them. See ``ImmersiveMapSceneModelsController``.
    func sceneModels(_ controller: ImmersiveMapSceneModelsController?) -> ImmersiveMapView {
        var view = self
        view.sceneModelsController = controller
        return view
    }

    func camera(_ controller: ImmersiveMapCameraController?) -> ImmersiveMapView {
        var view = self
        view.cameraController = controller
        return view
    }

    func camera(_ controller: ImmersiveMapCameraController?,
                position: ImmersiveMapCameraPosition) -> ImmersiveMapView {
        var view = self
        view.cameraController = controller
        view.cameraPosition = position
        return view
    }

    func cameraPosition(_ position: ImmersiveMapCameraPosition?) -> ImmersiveMapView {
        var view = self
        view.cameraPosition = position
        return view
    }

    /// Attaches a controller to drive the camera from the app's code: jumps,
    /// flights, following a path, and the camera's position read back. The
    /// on-screen camera buttons need none (`enableCameraUIControls`).
    func cameraController(_ controller: ImmersiveMapCameraController?) -> ImmersiveMapView {
        var view = self
        view.cameraController = controller
        return view
    }

    func cameraController(_ controller: ImmersiveMapCameraController?,
                          position: ImmersiveMapCameraPosition) -> ImmersiveMapView {
        var view = self
        view.cameraController = controller
        view.cameraPosition = position
        return view
    }

    /// Shows the on-screen camera buttons, the bearing and the pitch, on
    /// their own or beside a controller of the app's (`cameraController`),
    /// which they then drive.
    ///
    ///     ImmersiveMapView()
    ///         .enableCameraUIControls()
    func enableCameraUIControls(_ isEnabled: Bool = true,
                                maximumPitch: Float = ImmersiveMapSettings.default.camera.maximumPitch) -> ImmersiveMapView {
        var view = self
        view.cameraUIControls = CameraUIControls(isEnabled: isEnabled, maximumPitch: maximumPitch)
        return view
    }

    /// Restricts the zoom levels the camera can reach. Gestures, zoom commands
    /// and camera flights are all clamped to the range, so a minimum above the
    /// globe-to-flat transition keeps the map flat for good.
    ///
    ///     ImmersiveMapView()
    ///         .zoomRange(minimum: 3, maximum: 18)
    ///
    /// An omitted bound is left as configured.
    func zoomRange(minimum: Double? = nil, maximum: Double? = nil) -> ImmersiveMapView {
        var view = self
        var camera = view.settings.camera
        if let minimum {
            camera.minimumZoom = minimum
        }
        if let maximum {
            camera.maximumZoom = maximum
        }
        view.settings = view.settings.cameraSettings(camera)
        return view
    }

    /// How fast the animated zoom follows the camera's: the seconds in
    /// which it closes half of what is left of the way. The camera's zoom
    /// is the fact of a frame, and the tiles, the rings and the camera's
    /// pose read it as it is. What dresses the frame by the zoom (the
    /// styles' zoom fades, the labels' reach) reads the
    /// animated one, and the relief's collapse a zoom held through a drag and
    /// then followed the same way, so a zoom that jumps in one frame, as
    /// it does over a relief when the point the camera looks at drops off
    /// a ridge onto the plain below, dresses the frame over a few frames
    /// rather than at once. A camera set outright snaps it. Zero makes the
    /// two one.
    ///
    ///     ImmersiveMapView()
    ///         .animatedZoom(halfLife: 0.3)
    ///
    /// See `ImmersiveMapSettings.CameraSettings.animatedZoomHalfLife`.
    func animatedZoom(halfLife: Double) -> ImmersiveMapView {
        var view = self
        view.settings = view.settings.animatedZoom(halfLife: halfLife)
        return view
    }

    /// Restricts the tilt angles the camera can reach, in radians from straight
    /// down. Gestures, camera commands and flights are all clamped to the range
    /// on both surfaces alike; a minimum above the maximum yields to it.
    ///
    ///     ImmersiveMapView()
    ///         .pitchRange(minimum: 0.3, maximum: 1.1)
    ///
    /// An omitted bound is left as configured.
    func pitchRange(minimum: Float? = nil, maximum: Float? = nil) -> ImmersiveMapView {
        var view = self
        var camera = view.settings.camera
        if let minimum {
            camera.minimumPitch = minimum
        }
        if let maximum {
            camera.maximumPitch = maximum
        }
        view.settings = view.settings.cameraSettings(camera)
        return view
    }

    /// Caps how far the camera may rotate away from north, in radians, symmetric
    /// around it, on both surfaces. `nil` (the default) leaves rotation
    /// unbounded. With a `globeBearingLimit` the cap becomes the widest the
    /// globe's window opens instead of the full half turn.
    ///
    ///     ImmersiveMapView()
    ///         .bearingLimit(.pi / 2)   // at most a quarter turn from north
    ///         .bearingLimit(nil)       // unbounded again
    func bearingLimit(_ maximumAbsoluteBearing: Float?) -> ImmersiveMapView {
        var view = self
        var camera = view.settings.camera
        camera.maximumAbsoluteBearing = maximumAbsoluteBearing
        view.settings = view.settings.cameraSettings(camera)
        return view
    }

    /// Narrows how far a zoomed-out globe may rotate away from north: at zoom 0
    /// at most `minimum` radians, opening linearly to the `bearingLimit` (or
    /// the half turn) at `unlockZoom`. Off by default, so the globe turns as
    /// freely as the flat map.
    ///
    ///     ImmersiveMapView()
    ///         .globeBearingLimit(minimum: .pi / 12, unlockZoom: 6)
    func globeBearingLimit(minimum: Float, unlockZoom: Double) -> ImmersiveMapView {
        globeBearingLimit(ImmersiveMapSettings.CameraSettings.GlobeBearingLimit(minimumAbsoluteBearing: minimum,
                                                                                unlockZoom: unlockZoom))
    }

    /// Sets or clears (`nil`) the globe's zoom-dependent rotation window.
    func globeBearingLimit(_ limit: ImmersiveMapSettings.CameraSettings.GlobeBearingLimit?) -> ImmersiveMapView {
        var view = self
        var camera = view.settings.camera
        camera.globeBearingLimit = limit
        view.settings = view.settings.cameraSettings(camera)
        return view
    }

    /// Tunes the pull that keeps a zoomed-out globe upright, north up and
    /// seen from straight above. It is on by default. Across `zoomRange` the
    /// bearing and the pitch the camera may rest at close in, from the
    /// camera's own limits at the upper bound to upright at the lower bound
    /// and below it. A camera outside that is eased back, halving what is
    /// left every `halfLife` seconds: zooming out straightens the globe on
    /// the way, and a rotation past the allowed bearing springs back when
    /// the fingers let go.
    ///
    ///     ImmersiveMapView()
    ///         .globeUprightPull(zoomRange: 2...5, halfLife: 0.3)
    func globeUprightPull(zoomRange: ClosedRange<Double> = 3...6,
                          halfLife: Double = 0.2) -> ImmersiveMapView {
        globeUprightPull(ImmersiveMapSettings.CameraSettings.GlobeUprightPull(zoomRange: zoomRange,
                                                                              halfLife: halfLife))
    }

    /// Sets the globe's upright pull, or turns it off with `nil`: the globe
    /// then keeps any bearing and pitch at every zoom.
    ///
    ///     ImmersiveMapView()
    ///         .globeUprightPull(nil)
    func globeUprightPull(_ pull: ImmersiveMapSettings.CameraSettings.GlobeUprightPull?) -> ImmersiveMapView {
        var view = self
        var camera = view.settings.camera
        camera.globeUprightPull = pull
        view.settings = view.settings.cameraSettings(camera)
        return view
    }

    /// Holds the camera to a geographic region while keeping the globe. Up to
    /// the lower bound of `pullZoomRange` the whole world is open, so the
    /// zoomed-out globe turns freely. Across the range the area the map
    /// center belongs in closes in on the region along `pullCurve`, and from
    /// the upper bound it is the region itself. With the default elastic
    /// `edgeBehavior` the camera may leave the area, and a pull that grows
    /// with the distance draws it back all the time, during a gesture too. `.hard` makes the edge a wall that
    /// gestures, camera commands and flights all stop at. Flights always
    /// land inside the area. A west longitude greater than the east one
    /// spans the antimeridian.
    ///
    ///     ImmersiveMapView()
    ///         .cameraBounds(southWest: GeoCoordinate(latitude: 55.57, longitude: 37.36),
    ///                       northEast: GeoCoordinate(latitude: 55.92, longitude: 37.86),
    ///                       pullZoomRange: 1...2,
    ///                       pullCurve: .init(x1: 0.2, y1: 0.8, x2: 0.4, y2: 1),
    ///                       edgeBehavior: .elastic(maximumStretch: 150, pullHalfLife: 0.3, pullProgression: 2))
    func cameraBounds(southWest: GeoCoordinate,
                      northEast: GeoCoordinate,
                      pullZoomRange: ClosedRange<Double> = 1...2,
                      pullCurve: ImmersiveMapSettings.CameraSettings.Bounds.PullCurve = .easeInOut,
                      edgeBehavior: ImmersiveMapSettings.CameraSettings.Bounds.EdgeBehavior = .elastic()) -> ImmersiveMapView {
        cameraBounds(ImmersiveMapSettings.CameraSettings.Bounds(southWest: southWest,
                                                                northEast: northEast,
                                                                pullZoomRange: pullZoomRange,
                                                                pullCurve: pullCurve,
                                                                edgeBehavior: edgeBehavior))
    }

    /// Sets or clears (`nil`, the whole world) the region the camera is held to.
    func cameraBounds(_ bounds: ImmersiveMapSettings.CameraSettings.Bounds?) -> ImmersiveMapView {
        var view = self
        var camera = view.settings.camera
        camera.bounds = bounds
        view.settings = view.settings.cameraSettings(camera)
        return view
    }

    /// Sets how fast a tilt drag tilts, and which way: the multiple of the
    /// pitch range that a drag across the full view height sweeps. Applies to
    /// the two-finger vertical drag on touch platforms and to the tilt drag
    /// (right button, or Option-drag) on macOS. Positive tilts as the fingers
    /// pull down, negative inverts the drag so pulling up tilts instead, and
    /// zero leaves the drag without effect. The default is 2: half the view
    /// height covers the whole pitch range.
    ///
    ///     ImmersiveMapView()
    ///         .tiltGestureSensitivity(3)    // faster
    ///         .tiltGestureSensitivity(-2)   // inverted, default speed
    ///         .tiltGestureSensitivity(0)    // tilt drags do nothing
    func tiltGestureSensitivity(_ sensitivity: Float) -> ImmersiveMapView {
        var view = self
        var camera = view.settings.camera
        camera.tiltGestureSensitivity = sensitivity
        view.settings = view.settings.cameraSettings(camera)
        return view
    }

    /// Controls reuse of dismantled map views (on by default). When the screen
    /// with this map goes away, the platform view (renderer, GPU tile cache,
    /// text atlases) is parked briefly and the next `ImmersiveMapView` adopts
    /// it warm, so switching between map screens skips the first-frame rebuild.
    /// An adopted view keeps its previous camera unless this view provides an
    /// explicit camera position or an attached camera controller.
    ///
    ///     ImmersiveMapView()
    ///         .viewReuse(false)   // always build a fresh renderer
    func viewReuse(_ isEnabled: Bool = true) -> ImmersiveMapView {
        var view = self
        var viewReuse = view.settings.viewReuse
        viewReuse.isEnabled = isEnabled
        view.settings = view.settings.viewReuseSettings(viewReuse)
        return view
    }

    /// Turns on the invisible one-thumb camera drag zones in the bottom corners:
    /// dragging in the bottom leading corner tilts the camera, dragging in the
    /// bottom trailing one zooms. Both are off by default, because a zone
    /// captures drags that would otherwise pan the map and nothing on screen
    /// announces it.
    ///
    ///     ImmersiveMapView()
    ///         .cameraControlZones()            // both zones
    ///         .cameraControlZones(pitch: false) // zoom only
    ///
    /// Touch platforms only; the modifier is accepted and ignored on macOS.
    /// Pointer scroll zoom (trackpad, mouse wheel) is independent of these zones.
    func cameraControlZones(pitch: Bool = true, zoom: Bool = true) -> ImmersiveMapView {
        var view = self
        var camera = view.settings.camera
        camera.controlZones = ImmersiveMapSettings.CameraSettings.ControlZoneSettings(isPitchZoneEnabled: pitch,
                                                                                      isZoomZoneEnabled: zoom)
        view.settings = view.settings.cameraSettings(camera)
        return view
    }

    func selection(_ controller: ImmersiveMapSelectionController?) -> ImmersiveMapView {
        var view = self
        view.selectionController = controller
        return view
    }

    /// Attaches a tour video recorder to this map. The recorder exports camera
    /// tours offline using the map's current configuration (tile provider,
    /// style, labels, avatars); see ``ImmersiveMapTourVideoRecorder``.
    func tourVideoRecorder(_ recorder: ImmersiveMapTourVideoRecorder?) -> ImmersiveMapView {
        var view = self
        view.tourVideoRecorder = recorder
        return view
    }

    /// Calls `action` on every tap on an avatar marker.
    /// Works without ``ImmersiveMapSelectionController``: the event arrives even
    /// when selection is not used, and again on a tap on an already selected marker.
    func onAvatarTap(_ action: @escaping (ImmersiveMapAvatarTapEvent) -> Void) -> ImmersiveMapView {
        var view = self
        view.avatarTapAction = action
        return view
    }

    /// Calls `action` on every tap that lands on a 3D scene model.
    ///
    /// The tap is tested against the model's bounding box exactly where the
    /// frame drew it, so it follows the model through flat mode, the globe, the
    /// morph between them, and any animation; a model hidden behind the globe
    /// horizon is not hittable. When models overlap, the one nearest the camera
    /// wins, and an avatar marker over a model takes the tap first. A model too
    /// small to aim at grows to a 44 pt touch target.
    ///
    /// Works without ``ImmersiveMapSelectionController``: the event arrives even
    /// when selection is not used, and again on a tap on an already selected model.
    func onSceneModelTap(_ action: @escaping (ImmersiveMapSceneModelTapEvent) -> Void) -> ImmersiveMapView {
        var view = self
        view.sceneModelTapAction = action
        return view
    }

    /// Calls `action` on the main thread once per frame the map draws on
    /// screen, right after the frame's command buffer was committed to the
    /// GPU; see ``ImmersiveMapRenderedFrame`` for what the event carries and
    /// what moment it marks. Rendering is on-demand, so a still map delivers
    /// nothing: the frames come while the camera moves, labels fade or tiles
    /// arrive. Offscreen rendering (video export, still capture) never
    /// reports here.
    ///
    /// The action runs inside the frame's display-link callback: keep it to
    /// bookkeeping (a counter, a timestamp, a ring buffer) and hand anything
    /// heavier to a later turn of the run loop, or it delays the next frame.
    func onFrameRendered(_ action: @escaping (ImmersiveMapRenderedFrame) -> Void) -> ImmersiveMapView {
        var view = self
        view.frameRenderedAction = action
        return view
    }

    /// Calls `action` on the main thread when the country around the point
    /// the camera looks at changes between mountains and a plain, or in
    /// how mountainous it reads (``ImmersiveMapTerrainSurroundings``): with
    /// the first frame, then with every change, and with nil when the map
    /// leaves the terrain (the relief disabled, collapsed by the zoom, or
    /// the globe on screen). For the effects an app turns on in the
    /// mountains, a mountain atmosphere for one:
    ///
    ///     ImmersiveMapView()
    ///         .onTerrainSurroundingsChange { surroundings in
    ///             inMountains = surroundings?.kind == .mountains
    ///         }
    ///         .atmosphereSettings(inMountains ? mountainAir : plainAir)
    ///
    /// The reading is tuned with `terrainSurroundings(...)` and shown live on
    /// the debug panel's Relief tab. The action runs inside the frame's
    /// display-link callback, after the frame committed: setting SwiftUI
    /// state there is fine, heavier work goes to a later turn of the run loop.
    func onTerrainSurroundingsChange(_ action: @escaping (ImmersiveMapTerrainSurroundings?) -> Void) -> ImmersiveMapView {
        var view = self
        view.terrainSurroundingsAction = action
        return view
    }

    /// Declarative SwiftUI markers bound to geo coordinates.
    /// The content is repositioned on every rendered frame (flat, globe and
    /// the morph between them); beyond the globe's horizon the marker fades
    /// out by alpha. Touches inside a marker are handled by the content itself
    /// (Button, onTapGesture); touches outside the markers go to the map.
    /// A repeated call replaces the previous set entirely. Z-order equals the
    /// collection order: the last element is on top.
    func markers<Items: RandomAccessCollection, Content: View>(
        _ items: Items,
        coordinate: (Items.Element) -> GeoCoordinate,
        anchor: UnitPoint = .center,
        @ViewBuilder content: (Items.Element) -> Content
    ) -> ImmersiveMapView where Items.Element: Identifiable {
        var view = self
        view.markerContent = MarkerViewContent(
            anchor: anchor,
            items: items.map { item in
                MarkerViewItem(id: AnyHashable(item.id),
                               coordinate: coordinate(item),
                               content: AnyView(content(item)))
            }
        )
        return view
    }

    public func renderLoopSettings(_ renderLoop: ImmersiveMapSettings.RenderLoopSettings) -> ImmersiveMapView {
        var view = self
        view.settings = view.settings.renderLoopSettings(renderLoop)
        return view
    }

    public func cameraSettings(_ camera: ImmersiveMapSettings.CameraSettings) -> ImmersiveMapView {
        var view = self
        view.settings = view.settings.cameraSettings(camera)
        return view
    }

    public func presentationSettings(_ presentation: ImmersiveMapSettings.PresentationSettings) -> ImmersiveMapView {
        var view = self
        view.settings = view.settings.presentationSettings(presentation)
        return view
    }

    /// Whether the map is a globe at low zoom. On by default: the world is
    /// a sphere until the camera zooms in and unrolls it into the plane.
    /// Off, the world is the Mercator plane at every zoom, with no sphere,
    /// no morph and no stars, and the flat map's sky and haze from zoom 0
    /// up. Applies live; stills and video exports of the same settings come
    /// out flat too.
    ///
    /// `airHandoverStart` and `airHandoverEnd` are where in the unroll, as
    /// fractions `0...1` of the transition window, the globe's air (the
    /// atmosphere over space and the stars) gives way to the plane's (the
    /// sky over the map's colour, the world tile under the far ground):
    /// 0.7 to 0.9 by default, the end where the unroll's geometry is a
    /// finished plane. An omitted value is left as configured:
    ///
    ///     ImmersiveMapView()
    ///         .globe(airHandoverStart: 0.6, airHandoverEnd: 0.85)
    ///
    /// See `ImmersiveMapSettings.PresentationSettings`.
    public func globe(isEnabled: Bool = true,
                      airHandoverStart: Float? = nil,
                      airHandoverEnd: Float? = nil) -> ImmersiveMapView {
        var view = self
        view.settings = view.settings.globe(isEnabled: isEnabled,
                                            airHandoverStart: airHandoverStart,
                                            airHandoverEnd: airHandoverEnd)
        return view
    }

    /// Points the map at a PMTiles archive:
    ///
    ///     ImmersiveMapView()
    ///         .tileArchive(URL(string: "https://tiles.example.com/planet.pmtiles")!)
    ///
    /// The archive is one file of MVT tiles (PMTiles v3, gzip or
    /// uncompressed), read over HTTP range requests, so any static host
    /// serves it. The query string is sent as written, so a key can live in
    /// the URL. Credentials that travel as headers go in `headers`, added to
    /// every archive request:
    ///
    ///     .tileArchive(URL(string: "https://tiles.example.com/planet.pmtiles")!,
    ///                  headers: ["Authorization": "Bearer xxx"])
    ///
    /// The source is only where bytes come from. How they are parsed and drawn
    /// is configured separately by `.mapStyle(_:)`: the default
    /// `ProtomapsBasemapMapStyle` draws Protomaps basemap tiles, and any
    /// other schema pairs the archive with
    /// `VectorTileMapStyle(style:schema:)`.
    ///
    /// An archive may be replaced under the same URL. The engine notices by
    /// the ETag the host gives the file, checked once a session, and loads
    /// again the tiles it kept from the older upload. A host that sends no
    /// ETag needs a new URL for a new archive.
    ///
    /// A file URL reads the archive from disk, which is how an app ships a
    /// map in its bundle and renders it with no network at all:
    ///
    ///     .tileArchive(Bundle.main.url(forResource: "city", withExtension: "pmtiles")!)
    ///
    /// An archive built to a depth other
    /// than the default states it via `tileMaximumZoomLevel(_:)`, and its
    /// data credit via `attributionSettings`.
    public func tileArchive(_ archiveURL: URL,
                            headers: [String: String] = [:]) -> ImmersiveMapView {
        var view = self
        view.settings = view.settings.tileArchive(archiveURL, headers: headers)
        return view
    }

    public func mapStyle<S: ImmersiveMapMapStyle>(_ mapStyle: S) -> ImmersiveMapView {
        self.mapStyle(AnyImmersiveMapMapStyle(mapStyle))
    }

    /// The map of a night: the night palette (`ProtomapsBasemapTheme.night`,
    /// the land a deep blue-grey, the water a navy, the labels a light grey)
    /// with the night's air (`ImmersiveMapSettings.FogSettings.night`, a
    /// navy sky and horizon the ground fog follows). `night(false)` is the
    /// day again: the built-in style and the day's air. Both are live
    /// switches, and the change of palette re-prepares the tiles as any
    /// change of style does:
    ///
    ///     ImmersiveMapView()
    ///         .night()
    ///
    /// For a night of your own, `.mapStyle(.night.apply { theme in ... })`
    /// and `.fogSettings(...)` set the two apart.
    public func night(_ isEnabled: Bool = true) -> ImmersiveMapView {
        var view = self
        view.settings = view.settings.night(isEnabled)
        return view
    }

    /// The built-in style, spelled without its type name:
    /// `.mapStyle(.default)` or `.mapStyle(.default.apply { theme in ... })`.
    /// A concrete overload, so the leading dot resolves on the built-in style
    /// whatever the closure body does.
    public func mapStyle(_ mapStyle: ProtomapsBasemapMapStyle) -> ImmersiveMapView {
        self.mapStyle(AnyImmersiveMapMapStyle(mapStyle))
    }

    public func mapStyle(_ mapStyle: AnyImmersiveMapMapStyle) -> ImmersiveMapView {
        var view = self
        view.settings = view.settings.mapStyle(mapStyle)
        return view
    }

    /// Layers of the app's own data drawn over the map, in the order given:
    /// zones (polygons), lines and points, from Swift values or a GeoJSON
    /// document. They lie on the ground of the globe and the flat map,
    /// over the roads and under the names painted on the map and the
    /// buildings. A later call replaces the layers of an earlier one. A
    /// change applies in place: a layer whose data changed is prepared
    /// off the main thread and replaces the old one when ready.
    ///
    ///     ImmersiveMapView()
    ///         .layers([
    ///             try ImmersiveMapLayer(id: "districts", geoJSON: districts),
    ///             ImmersiveMapLayer(id: "sensors", points: sensors.map { ImmersiveMapPoint(coordinate: $0) },
    ///                               pointStyle: ImmersiveMapPointStyle(radiusPoints: 3))
    ///         ])
    ///
    /// See ``ImmersiveMapLayer``.
    public func layers(_ layers: [ImmersiveMapLayer]) -> ImmersiveMapView {
        var view = self
        view.settings = view.settings.layers(layers)
        return view
    }

    /// Models that take the place of the map's own buildings: the OSM
    /// elements each one lists (its building's outline and parts) are left
    /// out once the model is loaded, and the model is drawn where they
    /// stood. See ``ImmersiveMapLandmark``. A change applies in place.
    public func landmarks(_ landmarks: [ImmersiveMapLandmark]) -> ImmersiveMapView {
        var view = self
        view.settings = view.settings.landmarks(landmarks)
        return view
    }

    /// Loads the 3D models of the map's buildings from an archive of model
    /// tiles, the hosted one by default
    /// (`ImmersiveMapTilesService.modelArchiveURL`):
    ///
    ///     ImmersiveMapView()
    ///         .modelArchive(URL(string: "https://tiles.example.com/models.pmtiles")!)
    ///
    /// `modelArchiveSettings(nil)` turns the models off.
    ///
    /// The archive is one PMTiles v3 file whose zoom 14 tiles hold models
    /// ready for the GPU (`ModelTileContents` is the format). It is read over HTTP
    /// range requests like the map's archive, and apart from it: the models
    /// of the tiles in view are requested as the camera moves, kept on disk
    /// once loaded, and released from memory when the camera has left them
    /// and the budget is passed. `headers` are added to every request, and a
    /// file URL reads the archive from disk.
    ///
    /// A model stands in for the map's own building: the building is drawn
    /// until its model is loaded, and left out from that frame on, so the
    /// map is never missing either. The models show on the flat map,
    /// wherever the map draws tiles of the archive's zoom or deeper.
    ///
    /// `depthBias` draws the models nearer in depth than they stand, by a
    /// share of their distance from the camera, by the camera zoom, so a
    /// model covers the map's own building it stands in for where the map
    /// could not leave it out, and a building well in front of it still
    /// covers the model. Nil keeps the curve set, by default 0.05 at zoom
    /// 14 and 0.01 from zoom 15.5. Applies live. See
    /// ``ImmersiveMapSettings/ModelArchiveSettings/depthBias``.
    ///
    /// The budgets are set with `modelArchiveSettings(_:)`.
    public func modelArchive(_ archiveURL: URL,
                             headers: [String: String] = [:],
                             depthBias: ImmersiveMapZoomCurve? = nil) -> ImmersiveMapView {
        var view = self
        view.settings = view.settings.modelArchive(archiveURL, headers: headers, depthBias: depthBias)
        return view
    }

    /// The model archive with its memory and disk budgets, or nil to turn
    /// the models off. See ``ImmersiveMapSettings/ModelArchiveSettings``.
    public func modelArchiveSettings(_ modelArchive: ImmersiveMapSettings.ModelArchiveSettings?) -> ImmersiveMapView {
        var view = self
        view.settings = view.settings.modelArchiveSettings(modelArchive)
        return view
    }

    public func tileSettings(_ tiles: ImmersiveMapSettings.TileSettings) -> ImmersiveMapView {
        var view = self
        view.settings = view.settings.tileSettings(tiles)
        return view
    }

    /// The deepest tile zoom level the renderer requests from the source.
    ///
    /// The default is the hosted archive's depth
    /// (`ImmersiveMapTilesService.maximumTileZoomLevel`). An archive built
    /// to a different depth states it here, next to its
    /// `tileArchive(_:headers:)`: an archive that stops at z14 sets
    /// `.tileMaximumZoomLevel(14)` so the renderer never asks for tiles the
    /// archive cannot answer. Past the deepest level the camera keeps
    /// zooming and the deepest tiles are scaled up, exactly as before; offline
    /// region downloads clamp to the same level.
    /// How far past the visible ground the flat map's far texture bands
    /// ask for their tiles, as a share of the footprint's reach from the
    /// camera (`ImmersiveMapSettings.TileSettings.CoverageSettings
    /// .rasterBandMarginShare`): a turn of the camera then finds the far
    /// tiles in already. 0.25 by default, 0 for none. Applies live.
    public func tileCoverage(rasterBandMarginShare: Float) -> ImmersiveMapView {
        var view = self
        view.settings = view.settings.tileCoverage(rasterBandMarginShare: rasterBandMarginShare)
        return view
    }

    public func tileMaximumZoomLevel(_ maximumZoomLevel: Int) -> ImmersiveMapView {
        var view = self
        view.settings = view.settings.tileMaximumZoomLevel(maximumZoomLevel)
        return view
    }

    /// How many tiles are parsed at once, 4 by default
    /// (`ImmersiveMapSettings.TileSettings.ParsingSettings.maximumConcurrentParses`).
    /// Lower it when a fast zoom crowds a small device, raise it on a
    /// machine with cores to spare. An omitted value is left as
    /// configured:
    ///
    ///     ImmersiveMapView()
    ///         .tileParsing(maximumConcurrentParses: 2)
    public func tileParsing(maximumConcurrentParses: Int? = nil) -> ImmersiveMapView {
        var view = self
        view.settings = view.settings.tileParsing(maximumConcurrentParses: maximumConcurrentParses)
        return view
    }

    /// The byte quota of the prepared tile cache on disk: parsed and
    /// tessellated tiles, which is where every tile the camera has already
    /// looked at comes back from.
    ///
    /// The default is 2 GiB
    /// (`ImmersiveMapSettings.TileSettings.CacheSettings.defaultPreparedDiskCacheSizeInBytes`).
    /// Tiles stay in GPU memory only while a frame draws them, so this quota
    /// decides how much of a revisited area returns without a re-download and
    /// re-parse: a looped tour wants it to hold every tile of a lap, an app
    /// short on storage lowers it. The quota is root-wide, shared by every
    /// map in the process, and the most recently created map's value is the
    /// active policy; entries older than `preparedDiskTimeToLive` leave
    /// regardless of it.
    public func preparedTileDiskCacheSize(bytes: Int) -> ImmersiveMapView {
        var view = self
        view.settings = view.settings.preparedTileDiskCacheSize(bytes: bytes)
        return view
    }

    /// The flattened ground: from this tile zoom on a tile's ground fills
    /// are one layer of triangles that do not overlap, cut to a grid of
    /// `grid` cells a side, instead of the layers a coarser tile stacks.
    /// Nothing of such a ground has to be ordered in depth, which keeps the
    /// near ground whole when the camera stands in the street with the
    /// tiles blown up to many screens, and the mesh is ready for a
    /// heightmap. The default is the tileset's deepest zoom
    /// (`tileMaximumZoomLevel(_:)`, 15 for the hosted archive), on a grid
    /// of 16. `gridByTileZoom` gives a zoom a grid of its own, over `grid`:
    /// with the ground relief on from a coarse zoom, a coarse tile's cell
    /// covers far more ground, and more cells keep its relief as fine. By
    /// default the relief's zooms take a cell of about the same ground,
    /// 128 cells at zooms 9 to 12, 64 at 13 and 32 at 14, and
    /// the globe's zooms the grid the sphere was split by, 64 at 0 and 1
    /// and 32 at 2 and 3 (`GroundFlatteningSettings.defaultGridByTileZoom`).
    /// An omitted value is left as configured:
    ///
    ///     ImmersiveMapView()
    ///         .groundFlattening(fromTileZoom: 15, grid: 32, gridByTileZoom: [12: 128, 13: 96, 14: 64])
    ///
    /// Baked into the prepared tiles, so a change re-parses them. See
    /// `ImmersiveMapSettings.TileSettings.GroundFlatteningSettings`.
    public func groundFlattening(fromTileZoom: Int? = nil, grid: Int? = nil, gridByTileZoom: [Int: Int]? = nil) -> ImmersiveMapView {
        var view = self
        view.settings = view.settings.groundFlattening(fromTileZoom: fromTileZoom, grid: grid, gridByTileZoom: gridByTileZoom)
        return view
    }

    /// The flattened ground raised by a heightmap: each flattened tile
    /// takes its heights from the terrain tile of its address, images
    /// behind `tileURLTemplate` (`{z}`, `{x}` and `{y}` in it) in the
    /// `encoding` (Terrarium by default, or Mapbox's), and its ground
    /// rises `exaggeration` times as high as the terrain is. The relief
    /// rises out of the plane when the camera zoom crosses `appearZoom`
    /// (10 by default) and collapses into it when the zoom crosses
    /// `collapseZoom` (13.7), each a short animation over
    /// `transitionSeconds` (0.3), everywhere alike, and never a scaling
    /// with the zoom, which would breathe with every drag over the
    /// slopes. An `appearZoom` of 0, or a `collapseZoom` past the deepest
    /// zoom, keeps the relief at every zoom. Which terrain tiles the
    /// ground reads is the ring rules' (`FlatRingRule.terrainZoomDrop`,
    /// edited in the debug panel's Tiles tab): each ring reads the
    /// terrain so many zooms coarser than its own tiles, the near ring its
    /// own zoom's by default. The camera flies over one map at every zoom,
    /// the terrain tiles of `cameraTerrainZoom` (10), and the ground's
    /// vertices rise by terrain no finer than `displacementMaximumZoom`
    /// (10), the finer terrain of a near ring shading its slopes pixel by
    /// pixel. The roads, the
    /// buildings and the labels rise with it. The tiles of `appearZoom`'s tile zoom and deeper are flattened
    /// for it whatever the flattening's own zoom says, since only a
    /// flattened tile rises as geometry, and a coarser one, which the
    /// relief shows only from a texture on a raised grid, is spared the
    /// flattening: one zoom for both, so they never part. The camera
    /// keeps its height and flies right up to a ridge between it and the
    /// point it looks at, or stays `cameraClearanceMetres` over one when
    /// that is set. The mountains cast their shadows into the shadow map
    /// unless `castsShadows` is false. The decoded terrain tiles
    /// live with the tiles they raise, and `maximumConcurrentLoads` of them
    /// load at once, the frame's nearest first. On by default, on
    /// Mapterhorn's open terrain: `isEnabled: false` lays the map flat. An
    /// omitted value is left as configured:
    ///
    ///     ImmersiveMapView()
    ///         .groundFlattening(grid: 64)
    ///         .groundRelief(isEnabled: true, exaggeration: 2, appearZoom: 11, cameraTerrainZoom: 12)
    ///
    /// The relief is as fine as the flattening's grid. See
    /// `ImmersiveMapSettings.TileSettings.GroundReliefSettings`.
    public func groundRelief(isEnabled: Bool? = nil,
                             tileURLTemplate: String? = nil,
                             encoding: ImmersiveMapSettings.TileSettings.GroundReliefEncoding? = nil,
                             exaggeration: Float? = nil,
                             appearZoom: Double? = nil,
                             collapseZoom: Double? = nil,
                             transitionSeconds: TimeInterval? = nil,
                             cameraTerrainZoom: Int? = nil,
                             displacementMaximumZoom: Int? = nil,
                             maximumConcurrentLoads: Int? = nil,
                             cameraClearanceMetres: Float? = nil,
                             castsShadows: Bool? = nil) -> ImmersiveMapView {
        var view = self
        view.settings = view.settings.groundRelief(isEnabled: isEnabled,
                                                   tileURLTemplate: tileURLTemplate,
                                                   encoding: encoding,
                                                   exaggeration: exaggeration,
                                                   appearZoom: appearZoom,
                                                   collapseZoom: collapseZoom,
                                                   transitionSeconds: transitionSeconds,
                                                   cameraTerrainZoom: cameraTerrainZoom,
                                                   displacementMaximumZoom: displacementMaximumZoom,
                                                   maximumConcurrentLoads: maximumConcurrentLoads,
                                                   cameraClearanceMetres: cameraClearanceMetres,
                                                   castsShadows: castsShadows)
        return view
    }

    /// How the country around the point the camera looks at is read as
    /// mountains or a plain, the reading `onTerrainSurroundingsChange`
    /// reports: the radius of the disc of terrain read around the point,
    /// the spans of its heights under which it is a plain and from which it
    /// is mountains (the band between them the kind's hysteresis), and how
    /// long the reading takes to follow a move. An omitted value is left
    /// as configured:
    ///
    ///     ImmersiveMapView()
    ///         .terrainSurroundings(sampleRadiusMetres: 6000, mountainsAboveMetres: 800)
    ///
    /// The debug panel's Relief tab drags the same values and shows the
    /// reading. See `ImmersiveMapSettings.TileSettings.TerrainSurroundingsSettings`.
    public func terrainSurroundings(sampleRadiusMetres: Float? = nil,
                                    plainBelowMetres: Float? = nil,
                                    mountainsAboveMetres: Float? = nil,
                                    smoothingHalfLife: TimeInterval? = nil) -> ImmersiveMapView {
        var view = self
        view.settings = view.settings.terrainSurroundings(sampleRadiusMetres: sampleRadiusMetres,
                                                          plainBelowMetres: plainBelowMetres,
                                                          mountainsAboveMetres: mountainsAboveMetres,
                                                          smoothingHalfLife: smoothingHalfLife)
        return view
    }

    /// The tiles drawn from a texture: a ring rule with a raster size draws
    /// its tiles' ground through a texture of their fills, drawn from the
    /// tile each frame. `maximumAnisotropy` is the textures' anisotropic
    /// filtering (1 to 16) and `mipLevelBias` how soft the far ground is
    /// (above 0 softer, below 0 sharper). An omitted value is left as
    /// configured:
    ///
    ///     ImmersiveMapView()
    ///         .tileRasterization(mipLevelBias: 0.5)
    ///
    /// See `ImmersiveMapSettings.TileSettings.RasterizationSettings`.
    public func tileRasterization(maximumAnisotropy: Int? = nil,
                                  mipLevelBias: Float? = nil) -> ImmersiveMapView {
        var view = self
        view.settings = view.settings.tileRasterization(maximumAnisotropy: maximumAnisotropy,
                                                        mipLevelBias: mipLevelBias)
        return view
    }

    /// The flattened ground on or off. Off, every tile keeps its layers at
    /// every zoom, as before the flattening.
    public func groundFlattening(isEnabled: Bool) -> ImmersiveMapView {
        var view = self
        view.settings = view.settings.groundFlattening(isEnabled: isEnabled)
        return view
    }

    /// The overview of the globe the engine ships, on or off: hand-drawn
    /// biomes laid into the tiles of zooms 0 to 7 under the tile source's
    /// raster-derived land cover, which the built-in style paints and draws
    /// the land cover over (`ProtomapsBasemapTheme.BiomeStyles`, with the
    /// zooms of both).
    /// On by default. Off, the overview zooms draw the tile source's own
    /// land cover: for a source in another schema whose style has no use
    /// for the layers. Part of the prepared tiles' identity, so a change
    /// re-parses them. `creditMaximumZoom` is the camera zoom the
    /// overview's credit stays on the attribution line up to, 8 by default,
    /// where the built-in style has faded the biomes out. An omitted value
    /// is left as configured:
    ///
    ///     ImmersiveMapView()
    ///         .overviewTiles(isEnabled: false)
    ///
    /// See `ImmersiveMapSettings.TileSettings.OverviewSettings`.
    public func overviewTiles(isEnabled: Bool? = nil,
                              creditMaximumZoom: Double? = nil) -> ImmersiveMapView {
        var view = self
        view.settings = view.settings.overviewTiles(isEnabled: isEnabled,
                                                    creditMaximumZoom: creditMaximumZoom)
        return view
    }

    /// Adjusts only the provided cache fields; nil leaves a field unchanged.
    /// `memoryCacheSizeInBytes` is accepted for source compatibility and
    /// ignored: tiles stay in GPU memory only while a frame draws them.
    public func tileSettings(clearDiskCachesOnLaunch: Bool? = nil,
                             urlCacheEnabled: Bool? = nil,
                             preparedTileCacheEnabled: Bool? = nil,
                             preparedDiskCompressionEnabled: Bool? = nil,
                             preparedDiskTimeToLive: TimeInterval? = nil,
                             memoryCacheSizeInBytes: Int? = nil) -> ImmersiveMapView {
        tileSettings(clearDiskCachesOnLaunch: clearDiskCachesOnLaunch,
                     urlCacheEnabled: urlCacheEnabled,
                     preparedTileCacheEnabled: preparedTileCacheEnabled,
                     preparedDiskCompressionEnabled: preparedDiskCompressionEnabled,
                     preparedDiskTimeToLive: preparedDiskTimeToLive,
                     preparedDiskCacheSizeInBytes: nil,
                     memoryCacheSizeInBytes: memoryCacheSizeInBytes)
    }

    /// Adjusts only the provided cache fields; nil leaves a field unchanged.
    /// `memoryCacheSizeInBytes` is accepted for source compatibility and
    /// ignored: tiles stay in GPU memory only while a frame draws them.
    public func tileSettings(clearDiskCachesOnLaunch: Bool? = nil,
                             urlCacheEnabled: Bool? = nil,
                             preparedTileCacheEnabled: Bool? = nil,
                             preparedDiskCompressionEnabled: Bool? = nil,
                             preparedDiskTimeToLive: TimeInterval? = nil,
                             preparedDiskCacheSizeInBytes: Int?,
                             memoryCacheSizeInBytes: Int? = nil) -> ImmersiveMapView {
        var view = self
        view.settings = view.settings.tileSettings(
            clearDiskCachesOnLaunch: clearDiskCachesOnLaunch,
            urlCacheEnabled: urlCacheEnabled,
            preparedTileCacheEnabled: preparedTileCacheEnabled,
            preparedDiskCompressionEnabled: preparedDiskCompressionEnabled,
            preparedDiskTimeToLive: preparedDiskTimeToLive,
            preparedDiskCacheSizeInBytes: preparedDiskCacheSizeInBytes,
            memoryCacheSizeInBytes: memoryCacheSizeInBytes
        )
        return view
    }

    public func offlineTileSettings(_ offline: ImmersiveMapSettings.TileSettings.OfflineSettings) -> ImmersiveMapView {
        var view = self
        view.settings = view.settings.offlineTileSettings(offline)
        return view
    }

    /// How the map uses regions downloaded through
    /// `ImmersiveMapOfflineController`: `.automatic` (the default) falls back
    /// to them whenever a tile request fails, `.offlineOnly` renders from them
    /// without ever touching the network. Serving needs no other wiring; any
    /// region downloaded for the same tile provider is found on disk.
    public func offlineTileMode(_ mode: ImmersiveMapSettings.TileSettings.OfflineSettings.Mode) -> ImmersiveMapView {
        var view = self
        view.settings = view.settings.offlineTileMode(mode)
        return view
    }

    public func labelSettings(_ labels: ImmersiveMapSettings.LabelSettings) -> ImmersiveMapView {
        var view = self
        view.settings = view.settings.labelSettings(labels)
        return view
    }

    /// The language the labels are written in, and what a label shows when
    /// a feature has no name in it. Adjusts only the provided fields; nil
    /// leaves a field unchanged:
    ///
    /// ```swift
    /// ImmersiveMapView()
    ///     .labelSettings(language: .russian)
    /// ```
    ///
    /// Both are baked into the prepared tiles, so a change re-prepares them.
    public func labelSettings(language: ImmersiveMapSettings.LabelLanguage? = nil,
                              fallbackPolicy: ImmersiveMapSettings.LabelFallbackPolicy? = nil) -> ImmersiveMapView {
        var view = self
        view.settings = view.settings.labelSettings(language: language, fallbackPolicy: fallbackPolicy)
        return view
    }

    /// Turns map labels on or off: place names, points of interest, house
    /// numbers and road names alike. Off skips the label layer and the
    /// placement and collision work behind it. It applies live and never
    /// re-prepares a tile, so a control the user scrubs can drive it,
    /// unlike the other label settings. On by default.
    public func labels(isEnabled: Bool = true) -> ImmersiveMapView {
        var view = self
        view.settings = view.settings.labels(isEnabled: isEnabled)
        return view
    }

    /// The extruded buildings and the models of a model archive: the
    /// camera zoom the buildings draw from, how long a layer takes to
    /// rise out of the ground when the camera reaches its zoom, and
    /// whether it rises at all (`ImmersiveMapSettings.ExtrusionSettings`).
    /// The buildings grow from the ground to their height, the models come
    /// up out of it whole. `risesFromTheGround` off stands a layer up at
    /// once, on it takes `riseSeconds`, or the default 0.6 seconds when
    /// that is zero. An omitted value is left as configured:
    ///
    ///     ImmersiveMapView()
    ///         .buildingExtrusion(buildingsMinimumZoom: 14, riseSeconds: 0.6)
    ///         .buildingExtrusion(risesFromTheGround: false)
    ///
    /// Applies live.
    public func buildingExtrusion(buildingsMinimumZoom: Double? = nil,
                                  riseSeconds: TimeInterval? = nil,
                                  risesFromTheGround: Bool? = nil) -> ImmersiveMapView {
        var view = self
        view.settings = view.settings.buildingExtrusion(buildingsMinimumZoom: buildingsMinimumZoom,
                                                        riseSeconds: riseSeconds,
                                                        risesFromTheGround: risesFromTheGround)
        return view
    }

    /// The trees that stand on the woods and the parks of the flat map
    /// (`ImmersiveMapSettings.TreeSettings`): whether they draw, the
    /// camera zoom they draw from, the zoom from which every tree of a
    /// tile draws (thinned below it), the zoom from which they draw in
    /// their near detail, and the most a tile keeps. An omitted value is
    /// left as configured:
    ///
    ///     ImmersiveMapView()
    ///         .trees(minimumZoom: 14, fullDensityZoom: 17)   // thinned until zoom 17
    ///         .trees(isEnabled: false)
    ///
    /// `isEnabled` and `maximumPerTile` are baked into the prepared
    /// tiles, the rest applies live.
    public func trees(isEnabled: Bool? = nil,
                      minimumZoom: Double? = nil,
                      fullDensityZoom: Double? = nil,
                      nearDetailZoom: Double? = nil,
                      maximumPerTile: Int? = nil) -> ImmersiveMapView {
        var view = self
        view.settings = view.settings.trees(isEnabled: isEnabled,
                                            minimumZoom: minimumZoom,
                                            fullDensityZoom: fullDensityZoom,
                                            nearDetailZoom: nearDetailZoom,
                                            maximumPerTile: maximumPerTile)
        return view
    }

    public func sceneSettings(_ scene: ImmersiveMapSettings.SceneSettings) -> ImmersiveMapView {
        var view = self
        view.settings = view.settings.sceneSettings(scene)
        return view
    }


    /// Leaves the area outside the globe unpainted: the space background and
    /// the stars are not drawn, and the map view becomes
    /// transparent there, so the app's own background shows through and around
    /// the globe. A marker hanging off the limb no longer needs the map view
    /// clipped to a circle.
    public func transparentSpace(_ isTransparent: Bool = true) -> ImmersiveMapView {
        var view = self
        view.settings = view.settings.transparentSpace(isTransparent)
        return view
    }

    /// World-space direction pointing towards the static sun
    /// (+X east, +Y north, +Z up). Defines where buildings and scene models
    /// cast their shadows.
    public func sceneLight(direction: SIMD3<Float>) -> ImmersiveMapView {
        var view = self
        view.settings = view.settings.sceneLight(direction: direction)
        return view
    }

    /// Directional shadows cast by buildings and scene models in the flat
    /// presentation.
    public func shadowSettings(_ shadows: ImmersiveMapSettings.ShadowSettings) -> ImmersiveMapView {
        var view = self
        view.settings = view.settings.shadowSettings(shadows)
        return view
    }

    /// The globe's atmosphere: the halo of scattered light around the
    /// planet's limb and the glow on the surface toward it. Globe
    /// presentation only; it fades into the flat map's fog band through the
    /// morph. On by default.
    public func atmosphereSettings(_ atmosphere: ImmersiveMapSettings.AtmosphereSettings) -> ImmersiveMapView {
        var view = self
        view.settings = view.settings.atmosphereSettings(atmosphere)
        return view
    }

    /// The sun on the globe (`ImmersiveMapSettings.GlobeLightSettings`),
    /// whole. Applies live.
    public func globeLightSettings(_ globeLight: ImmersiveMapSettings.GlobeLightSettings) -> ImmersiveMapView {
        var view = self
        view.settings = view.settings.globeLightSettings(globeLight)
        return view
    }

    /// The sun on the globe: the planet's surface shaded by the sphere
    /// against a sun fixed over the subsolar point
    /// (`subsolarLatitudeDegrees`, `subsolarLongitudeDegrees`), the night
    /// side drawn toward `nightColor`, `strength` by the camera zoom and
    /// the terminator `terminatorSoftness` wide. On by default. An omitted
    /// value is left as configured:
    ///
    ///     ImmersiveMapView()
    ///         .globeLight(subsolarLongitudeDegrees: 30, strength: [2: 0.8, 6: 0.2])
    ///
    /// See `ImmersiveMapSettings.GlobeLightSettings`. Applies live.
    public func globeLight(isEnabled: Bool = true,
                           subsolarLatitudeDegrees: Float? = nil,
                           subsolarLongitudeDegrees: Float? = nil,
                           strength: ImmersiveMapZoomCurve? = nil,
                           terminatorSoftness: Float? = nil,
                           nightColor: SIMD3<Float>? = nil) -> ImmersiveMapView {
        var view = self
        view.settings = view.settings.globeLight(isEnabled: isEnabled,
                                                 subsolarLatitudeDegrees: subsolarLatitudeDegrees,
                                                 subsolarLongitudeDegrees: subsolarLongitudeDegrees,
                                                 strength: strength,
                                                 terminatorSoftness: terminatorSoftness,
                                                 nightColor: nightColor)
        return view
    }

    /// Turns the globe's atmosphere on or off. Off leaves the planet bare
    /// against space, apart from the thin glow at the limb that hides the
    /// tile mesh's edge; the flat map's fog band is not affected.
    public func atmosphere(isEnabled: Bool = true) -> ImmersiveMapView {
        var view = self
        view.settings = view.settings.atmosphere(isEnabled: isEnabled)
        return view
    }

    /// The fog on the ground of the flat map: thickest at the ground,
    /// thinning upward, gathered along the view past a distance from the
    /// camera, so the far ground and its detail sink in it while the near
    /// ground and the tops of tall buildings stay clear.
    /// `densityPerKilometer` is how thick it is at the ground,
    /// `heightMeters` how high it rises, `startDistanceMeters` where it
    /// begins and `startSoftnessMeters` how far past that it takes to come
    /// in, all in meters on the ground, `color` its colour (the horizon's
    /// by default) and `maximumOpacity` the most it veils. `veilsBuildings`
    /// sinks the buildings and the models into it with the ground (on by
    /// default), and `takesSkyColor` turns the fog into the sky's colour
    /// above the horizon line (off by default). On the ground relief
    /// `heightsFromSeaLevel` measures the fog's height from sea level (on
    /// by default), so the valleys lie deeper in it than the summits, and
    /// `baseAltitudeMeters` is the altitude the density is stated at. On
    /// by default, and the globe has none.
    ///
    /// Every value but the colour is a value or a curve over the camera
    /// zoom (`ImmersiveMapZoomCurve`), so the fog never changes at a step.
    /// The lengths and the density run geometrically between their stops,
    /// the way the map's scale changes. An omitted value is left as
    /// configured:
    ///
    ///     ImmersiveMapView()
    ///         .groundFog(heightMeters: 120,
    ///                    startDistanceMeters: [12: 3000, 16: 400],
    ///                    startSoftnessMeters: [12: 20_000, 16: 800],
    ///                    maximumOpacity: [18: 1, 19: 0])
    ///
    /// See `ImmersiveMapSettings.GroundFogSettings`. Applies live.
    public func groundFog(isEnabled: Bool = true,
                          densityPerKilometer: ImmersiveMapZoomCurve? = nil,
                          heightMeters: ImmersiveMapZoomCurve? = nil,
                          startDistanceMeters: ImmersiveMapZoomCurve? = nil,
                          startSoftnessMeters: ImmersiveMapZoomCurve? = nil,
                          color: SIMD3<Float>? = nil,
                          maximumOpacity: ImmersiveMapZoomCurve? = nil,
                          veilsBuildings: Bool? = nil,
                          takesSkyColor: Bool? = nil,
                          heightsFromSeaLevel: Bool? = nil,
                          baseAltitudeMeters: Float? = nil) -> ImmersiveMapView {
        var view = self
        view.settings = view.settings.groundFog(isEnabled: isEnabled,
                                                densityPerKilometer: densityPerKilometer,
                                                heightMeters: heightMeters,
                                                startDistanceMeters: startDistanceMeters,
                                                startSoftnessMeters: startSoftnessMeters,
                                                color: color,
                                                maximumOpacity: maximumOpacity,
                                                veilsBuildings: veilsBuildings,
                                                takesSkyColor: takesSkyColor,
                                                heightsFromSeaLevel: heightsFromSeaLevel,
                                                baseAltitudeMeters: baseAltitudeMeters)
        return view
    }

    /// The air over the mountains, the same values as `groundFog(...)`: the
    /// frame draws the air between the plain's (`groundFog`) and this one by
    /// how mountainous the country around the camera reads
    /// (`onTerrainSurroundingsChange`, tuned with `terrainSurroundings(...)`),
    /// so a pan from a plain into a range fades one air into the other. The
    /// values start from the mountain air set so far, or from a copy of the
    /// plain's, and an omitted value is left as it is:
    ///
    ///     ImmersiveMapView()
    ///         .mountainGroundFog(densityPerKilometer: [7: 0.02, 12: 0.02, 16: 17, 22: 6],
    ///                            heightMeters: [7: 2500, 12: 2500, 16: 150, 22: 60],
    ///                            baseAltitudeMeters: 1500)
    ///
    /// Without it the air is one everywhere. The debug panel's Air tab
    /// switches it on with a preset and edits either air. See
    /// `ImmersiveMapSettings.SceneSettings.mountainGroundFog`. Applies live.
    public func mountainGroundFog(isEnabled: Bool = true,
                                  densityPerKilometer: ImmersiveMapZoomCurve? = nil,
                                  heightMeters: ImmersiveMapZoomCurve? = nil,
                                  startDistanceMeters: ImmersiveMapZoomCurve? = nil,
                                  startSoftnessMeters: ImmersiveMapZoomCurve? = nil,
                                  color: SIMD3<Float>? = nil,
                                  maximumOpacity: ImmersiveMapZoomCurve? = nil,
                                  veilsBuildings: Bool? = nil,
                                  takesSkyColor: Bool? = nil,
                                  heightsFromSeaLevel: Bool? = nil,
                                  baseAltitudeMeters: Float? = nil) -> ImmersiveMapView {
        var view = self
        view.settings = view.settings.mountainGroundFog(isEnabled: isEnabled,
                                                        densityPerKilometer: densityPerKilometer,
                                                        heightMeters: heightMeters,
                                                        startDistanceMeters: startDistanceMeters,
                                                        startSoftnessMeters: startSoftnessMeters,
                                                        color: color,
                                                        maximumOpacity: maximumOpacity,
                                                        veilsBuildings: veilsBuildings,
                                                        takesSkyColor: takesSkyColor,
                                                        heightsFromSeaLevel: heightsFromSeaLevel,
                                                        baseAltitudeMeters: baseAltitudeMeters)
        return view
    }

    /// The air over the mountains as a whole (`SceneSettings.mountainGroundFog`),
    /// nil for one air everywhere.
    public func mountainGroundFog(_ fog: ImmersiveMapSettings.GroundFogSettings?) -> ImmersiveMapView {
        var view = self
        view.settings = view.settings.mountainGroundFog(fog)
        return view
    }

    /// The sky of the flat presentation: a sky gradient above the horizon
    /// line and a thin band whitening the ground into the horizon colour at
    /// the line. The far ground is the ground fog's
    /// (`groundFog(isEnabled:densityPerKilometer:heightMeters:startDistanceMeters:startSoftnessMeters:color:maximumOpacity:veilsBuildings:takesSkyColor:heightsFromSeaLevel:baseAltitudeMeters:)`).
    /// Applies live.
    public func fogSettings(_ fog: ImmersiveMapSettings.FogSettings) -> ImmersiveMapView {
        var view = self
        view.settings = view.settings.fogSettings(fog)
        return view
    }

    /// The flat map's sky on or off. On by default. Off leaves the sky the
    /// map's clear colour and keeps only a thin band at the horizon line
    /// that hides the seam between the far ground and the sky. The ground
    /// fog has its own switch.
    public func fog(isEnabled: Bool = true) -> ImmersiveMapView {
        var view = self
        view.settings = view.settings.fog(isEnabled: isEnabled)
        return view
    }

    /// Directional shadows cast by the buildings and the scene models in the
    /// flat presentation, on or off, with any of their values set in place.
    /// An omitted value is left as configured, so a value set here never
    /// resets the others:
    ///
    ///     ImmersiveMapView()
    ///         .shadows(nearCoverageMeters: [14: 4000, 18: 300])
    ///
    /// The values are `ImmersiveMapSettings.ShadowSettings`'s, where each is
    /// described. `strength`, `nearCoverageMeters` and `farCoverageMeters`
    /// are curves over the camera zoom (`ImmersiveMapZoomCurve`, a single
    /// value being the same at every zoom): the strength from the zoom the
    /// shadows come in at, the coverages the ground the sharp near window
    /// and the coarse far window reach, in metres. Applies live.
    public func shadows(isEnabled: Bool = true,
                        strength: ImmersiveMapZoomCurve? = nil,
                        mapResolution: Int? = nil,
                        nearCoverageMeters: ImmersiveMapZoomCurve? = nil,
                        farCoverageMeters: ImmersiveMapZoomCurve? = nil,
                        maxCasterHeightMeters: Float? = nil,
                        normalOffsetTexels: Float? = nil,
                        softness: Float? = nil,
                        tint: SIMD3<Float>? = nil) -> ImmersiveMapView {
        var view = self
        var shadows = view.settings.scene.shadows
        shadows.isEnabled = isEnabled
        if let strength { shadows.strength = strength }
        if let mapResolution { shadows.mapResolution = mapResolution }
        if let nearCoverageMeters { shadows.nearCoverageMeters = nearCoverageMeters }
        if let farCoverageMeters { shadows.farCoverageMeters = farCoverageMeters }
        if let maxCasterHeightMeters { shadows.maxCasterHeightMeters = maxCasterHeightMeters }
        if let normalOffsetTexels { shadows.normalOffsetTexels = normalOffsetTexels }
        if let softness { shadows.softness = softness }
        if let tint { shadows.tint = tint }
        view.settings = view.settings.shadowSettings(shadows)
        return view
    }



    public func avatarSettings(_ avatars: ImmersiveMapSettings.AvatarSettings) -> ImmersiveMapView {
        var view = self
        view.settings = view.settings.avatarSettings(avatars)
        return view
    }

    public func avatarSettings(size: ImmersiveMapSettings.AvatarSettings.Size? = nil,
                               sizeScale: Float? = nil,
                               compressedScale: Float? = nil,
                               atlasSizePx: Int? = nil,
                               atlasPagesMax: Int? = nil,
                               borderWidthPx: Float? = nil,
                               borderColor: SIMD4<Float>? = nil,
                               beamColor: SIMD4<Float>? = nil,
                               collisionPaddingPx: Float? = nil,
                               groupingThreshold: Int? = nil,
                               maxOffsetPx: Float? = nil,
                               collisionIterations: Int? = nil,
                               springK: Float? = nil,
                               smoothing: Float? = nil) -> ImmersiveMapView {
        var view = self
        view.settings = view.settings.avatarSettings(size: size,
                                                     sizeScale: sizeScale,
                                                     compressedScale: compressedScale,
                                                     atlasSizePx: atlasSizePx,
                                                     atlasPagesMax: atlasPagesMax,
                                                     borderWidthPx: borderWidthPx,
                                                     borderColor: borderColor,
                                                     beamColor: beamColor,
                                                     collisionPaddingPx: collisionPaddingPx,
                                                     groupingThreshold: groupingThreshold,
                                                     maxOffsetPx: maxOffsetPx,
                                                     collisionIterations: collisionIterations,
                                                     springK: springK,
                                                     smoothing: smoothing)
        return view
    }

    public func attributionSettings(_ attribution: ImmersiveMapSettings.AttributionSettings) -> ImmersiveMapView {
        var view = self
        view.settings = view.settings.attributionSettings(attribution)
        return view
    }

    /// Restyles the attribution badge without replacing the whole settings
    /// value: `nil` leaves a field unchanged. Because of that, `textColor`
    /// cannot be reset to the default here; pass a full `AttributionSettings`
    /// to `attributionSettings(_:)` instead.
    ///
    ///     ImmersiveMapView()
    ///         .attributionSettings(size: .large, position: .topLeading)
    public func attributionSettings(isVisible: Bool? = nil,
                                    size: ImmersiveMapSettings.AttributionSettings.Size? = nil,
                                    position: ImmersiveMapSettings.AttributionSettings.Position? = nil,
                                    margin: Double? = nil,
                                    textColor: SIMD4<Float>? = nil,
                                    emphasizesLeadingCredit: Bool? = nil,
                                    isProvidedExternally: Bool? = nil,
                                    showsEngineCredit: Bool? = nil) -> ImmersiveMapView {
        var view = self
        view.settings = view.settings.attributionSettings(isVisible: isVisible,
                                                          size: size,
                                                          position: position,
                                                          margin: margin,
                                                          textColor: textColor,
                                                          emphasizesLeadingCredit: emphasizesLeadingCredit,
                                                          isProvidedExternally: isProvidedExternally,
                                                          showsEngineCredit: showsEngineCredit)
        return view
    }

    /// Declares that the app shows the data credit itself (its own overlay, an
    /// about screen), so hiding the badge stops logging the attribution
    /// warning. The license obligation stays with the app: the credit has to
    /// stay visible on or next to the map, on every screen that shows one.
    ///
    /// What each provider requires and where it has to appear:
    /// https://github.com/artembobkin/ImmersiveMap#attribution
    public func attributionProvidedExternally(_ isProvidedExternally: Bool = true) -> ImmersiveMapView {
        var view = self
        view.settings = view.settings.attributionProvidedExternally(isProvidedExternally)
        return view
    }

    public func postProcessingSettings(_ postProcessing: ImmersiveMapSettings.PostProcessingSettings) -> ImmersiveMapView {
        var view = self
        view.settings = view.settings.postProcessingSettings(postProcessing)
        return view
    }

    /// FXAA over the finished frame, applied as the last pass. Off by
    /// default: the map's own lines are antialiased analytically, and FXAA
    /// adds the optional smoothing of geometry silhouettes (building edges
    /// most visibly) at the price of one fullscreen pass.
    public func fxaa(isEnabled: Bool = true) -> ImmersiveMapView {
        var view = self
        view.settings = view.settings.fxaa(isEnabled: isEnabled)
        return view
    }

    /// MSAA 4x on the world pass. Off by default: four depth and colour
    /// samples per pixel clean geometry silhouettes (buildings, models most
    /// visibly) at a real cost in memory bandwidth, while the map's own
    /// lines are antialiased analytically either way. Falls back to what
    /// the device supports; changing it recreates the renderer. See
    /// `PostProcessingSettings.multisampleCount` for other counts.
    public func msaa(isEnabled: Bool = true) -> ImmersiveMapView {
        var view = self
        view.settings = view.settings.msaa(isEnabled: isEnabled)
        return view
    }

    public func debugSettings(_ debug: ImmersiveMapSettings.DebugSettings) -> ImmersiveMapView {
        var view = self
        view.settings = view.settings.debugSettings(debug)
        return view
    }

    /// The debug panel: camera coordinates, renderer diagnostics and the
    /// bench controls, drawn over the map. A development aid, off by
    /// default. `zoomBadge` shows or hides the panel's zoom badge in the
    /// map's top trailing corner, the camera's zoom and the planning zoom
    /// (`DebugSettings.showsZoomBadge`, on by default), an omitted value
    /// left as configured:
    ///
    ///     ImmersiveMapView()
    ///         .debugPanel(zoomBadge: false)
    public func debugPanel(_ isEnabled: Bool = true, zoomBadge: Bool? = nil) -> ImmersiveMapView {
        var view = self
        view.settings = view.settings.debugPanel(isEnabled, zoomBadge: zoomBadge)
        return view
    }

    /// Hides every control drawn over the map at once, for a clean frame:
    /// the debug panel, the camera's on-screen controls and the control
    /// zones. Each keeps its configuration and the debug panel the values
    /// dragged in it, so `controlsHidden(false)` brings them back as they
    /// were, without rebuilding the renderer. The attribution stays, as
    /// the map data's license requires.
    ///
    ///     ImmersiveMapView()
    ///         .debugPanel()
    ///         .controlsHidden(isRecording)
    ///
    /// See `ImmersiveMapSettings.ControlsSettings`.
    public func controlsHidden(_ isHidden: Bool = true) -> ImmersiveMapView {
        var view = self
        view.settings = view.settings.controlsHidden(isHidden)
        return view
    }

}

private extension ImmersiveMapView {
    struct CameraUIControls {
        let isEnabled: Bool
        let maximumPitch: Float
    }

    static var defaultCameraControlsPosition: ImmersiveMapCameraPosition {
        ImmersiveMapCameraPosition(latitudeDegrees: 0,
                                   longitudeDegrees: 0,
                                   zoom: 0)
    }
}
