// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

#if os(macOS)

import AppKit

/// Owns the main map surface gestures on macOS and translates AppKit events
/// into camera, selection, and render-loop commands for `ImmersiveMapNSView`.
///
/// Input layout:
/// - left-button drag - pan; with ⌥ held - pitch/bearing;
/// - right-button drag - pitch/bearing;
/// - trackpad pinch - zoom, trackpad rotate - rotation;
/// - scroll wheel / two-finger scroll - zoom (handled by the host view via `handleScrollWheel`);
/// - click - object selection or background tap.
@MainActor
final class MapGestureController: NSObject, NSGestureRecognizerDelegate {
    private enum PanMode {
        case pan
        case tilt
    }

    private enum ScrollZoom {
        /// Precise (trackpad) scroll: a full swipe of ~150pt = 1 zoom level.
        static let preciseDivisor: CGFloat = 150.0
        /// Discrete mouse wheel: scrollingDeltaY ~10 per click, ~0.33 zoom per click.
        static let lineDivisor: CGFloat = 30.0
    }

    private weak var mapView: ImmersiveMapNSView?
    let panGesture: NSPanGestureRecognizer
    private let tiltPanGesture: NSPanGestureRecognizer
    private let clickGesture: NSClickGestureRecognizer
    private let doubleClickGesture: NSClickGestureRecognizer
    private let rotationGesture: NSRotationGestureRecognizer
    private let magnificationGesture: NSMagnificationGestureRecognizer
    private var panMode: PanMode = .pan

    init(mapView: ImmersiveMapNSView) {
        self.mapView = mapView
        self.panGesture = NSPanGestureRecognizer()
        self.tiltPanGesture = NSPanGestureRecognizer()
        self.clickGesture = NSClickGestureRecognizer()
        self.doubleClickGesture = NSClickGestureRecognizer()
        self.rotationGesture = NSRotationGestureRecognizer()
        self.magnificationGesture = NSMagnificationGestureRecognizer()
        super.init()

        configureGestures(in: mapView)
    }

    func setPanInteractionActiveForTesting(_ isActive: Bool) {
        setInteractionActive(isActive,
                             source: .mapPan)
    }

    func gestureRecognizer(_ gestureRecognizer: NSGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith otherGestureRecognizer: NSGestureRecognizer) -> Bool {
        if (gestureRecognizer is NSRotationGestureRecognizer && otherGestureRecognizer is NSMagnificationGestureRecognizer) ||
            (gestureRecognizer is NSMagnificationGestureRecognizer && otherGestureRecognizer is NSRotationGestureRecognizer) {
            return true
        }
        return false
    }

    /// A single click (selection) waits for the double click (anchored zoom) to fail:
    /// the AppKit analog of UIKit's `require(toFail:)`.
    func gestureRecognizer(_ gestureRecognizer: NSGestureRecognizer,
                           shouldRequireFailureOf otherGestureRecognizer: NSGestureRecognizer) -> Bool {
        gestureRecognizer === clickGesture && otherGestureRecognizer === doubleClickGesture
    }

    /// Map gestures are recognized only over the "bare" map surface. If the event
    /// hits an interactive overlay subview (debug HUD, attribution badge), we yield
    /// it to that `NSControl` - otherwise the gesture recognizer intercepts `mouseDown`
    /// and the panel's buttons/toggles cannot be pressed.
    func gestureRecognizer(_ gestureRecognizer: NSGestureRecognizer,
                           shouldAttemptToRecognizeWith event: NSEvent) -> Bool {
        guard let mapView, let superview = mapView.superview else {
            return true
        }

        let pointInSuperview = superview.convert(event.locationInWindow, from: nil)
        return mapView.hitTest(pointInSuperview) === mapView
    }

    private func configureGestures(in mapView: ImmersiveMapNSView) {
        panGesture.target = self
        panGesture.action = #selector(handlePan(_:))
        panGesture.buttonMask = 0x1
        panGesture.delegate = self
        mapView.addGestureRecognizer(panGesture)

        tiltPanGesture.target = self
        tiltPanGesture.action = #selector(handleTiltPan(_:))
        tiltPanGesture.buttonMask = 0x2
        tiltPanGesture.delegate = self
        mapView.addGestureRecognizer(tiltPanGesture)

        doubleClickGesture.target = self
        doubleClickGesture.action = #selector(handleDoubleClick(_:))
        doubleClickGesture.buttonMask = 0x1
        doubleClickGesture.numberOfClicksRequired = 2
        doubleClickGesture.delegate = self
        mapView.addGestureRecognizer(doubleClickGesture)

        clickGesture.target = self
        clickGesture.action = #selector(handleClick(_:))
        clickGesture.buttonMask = 0x1
        clickGesture.delegate = self
        mapView.addGestureRecognizer(clickGesture)

        rotationGesture.target = self
        rotationGesture.action = #selector(handleRotation(_:))
        rotationGesture.delegate = self
        mapView.addGestureRecognizer(rotationGesture)

        magnificationGesture.target = self
        magnificationGesture.action = #selector(handleMagnification(_:))
        magnificationGesture.delegate = self
        mapView.addGestureRecognizer(magnificationGesture)
    }

    // MARK: - Click

    @objc private func handleClick(_ gesture: NSClickGestureRecognizer) {
        guard let mapView else { return }

        mapView.tapHandler.handleMapTap(at: gesture.location(in: mapView))
    }

    /// A double click zooms the map in by one zoom level toward the click point:
    /// the world point under the cursor stays in place (see `zoomAnchorFactor`).
    @objc private func handleDoubleClick(_ gesture: NSClickGestureRecognizer) {
        guard let mapView,
              mapView.cameraRuntime.currentCameraState() != nil else {
            return
        }

        let anchorPoint = gesture.location(in: mapView)
        guard let targetPosition = mapView.cameraRuntime.anchoredZoomTargetPosition(zoomDelta: 1.0,
                                                                                    anchorPoint: anchorPoint) else {
            return
        }

        mapView.cameraRuntime.notifyUserInteractionBegan()
        mapView.cameraAnimationRuntime.startCameraFlight(to: targetPosition,
                                                         options: CameraFlightOptions(duration: 0.35),
                                                         completion: nil,
                                                         currentTime: CACurrentMediaTime())
    }

    // MARK: - Pan / tilt

    @objc private func handlePan(_ gesture: NSPanGestureRecognizer) {
        guard let mapView,
              mapView.cameraRuntime.currentCameraState() != nil else {
            return
        }

        if gesture.state == .began {
            let isOptionHeld = NSApplication.shared.currentEvent?.modifierFlags.contains(.option) ?? false
            panMode = isOptionHeld ? .tilt : .pan
        }

        switch panMode {
        case .pan:
            applyPan(gesture, in: mapView)
        case .tilt:
            applyTilt(gesture, in: mapView)
        }
    }

    @objc private func handleTiltPan(_ gesture: NSPanGestureRecognizer) {
        guard let mapView,
              mapView.cameraRuntime.currentCameraState() != nil else {
            return
        }

        applyTilt(gesture, in: mapView)
    }

    private func applyPan(_ gesture: NSPanGestureRecognizer,
                          in mapView: ImmersiveMapNSView) {
        updateInteractionState(for: gesture.state,
                               source: .mapPan)

        let translation = gesture.translation(in: mapView)
        let settings = mapView.cameraRuntime.currentSettings.camera
        mapView.cameraRuntime.panCamera(deltaX: Double(translation.x) * settings.gesturePanTranslationScale,
                                        deltaY: Double(translation.y) * settings.gesturePanTranslationScale)
        gesture.setTranslation(.zero, in: mapView)

        switch gesture.state {
        case .ended:
            mapView.cameraAnimationRuntime.startGlobeCameraPanInertiaIfNeeded(initialVelocity: gesture.velocity(in: mapView))
        case .cancelled, .failed:
            mapView.cameraAnimationRuntime.cancelGlobeCameraPanInertia()
        case .began, .changed, .possible:
            break
        @unknown default:
            mapView.cameraAnimationRuntime.cancelGlobeCameraPanInertia()
        }
    }

    /// Vertical dragging changes pitch (up - more tilt),
    /// horizontal dragging rotates the camera.
    private func applyTilt(_ gesture: NSPanGestureRecognizer,
                           in mapView: ImmersiveMapNSView) {
        updateInteractionState(for: gesture.state,
                               source: .pitchControl)

        let translation = gesture.translation(in: mapView)
        gesture.setTranslation(.zero, in: mapView)
        let bounds = mapView.bounds
        guard bounds.width > 0, bounds.height > 0 else {
            return
        }

        if translation.y != 0,
           let currentPitch = mapView.cameraRuntime.currentPitch {
            let settings = mapView.cameraRuntime.currentSettings.camera
            let pitchDelta = TwoFingerTiltGestureMath.pitchDelta(forVerticalTranslation: translation.y,
                                                                 viewHeight: bounds.height,
                                                                 maximumPitch: mapView.cameraRuntime.currentMaximumPitch(),
                                                                 sensitivity: settings.tiltGestureSensitivity)
            mapView.cameraAnimationRuntime.setPitchTarget(currentPitch + pitchDelta)
        }

        if translation.x != 0 {
            let yawDelta = Float(translation.x / bounds.width) * .pi
            mapView.cameraRuntime.rotateCameraYaw(delta: yawDelta)
        }
    }

    // MARK: - Rotation

    @objc private func handleRotation(_ gesture: NSRotationGestureRecognizer) {
        guard let mapView,
              mapView.cameraRuntime.currentCameraState() != nil else {
            return
        }

        updateInteractionState(for: gesture.state,
                               source: .mapRotation)
        // AppKit treats counterclockwise rotation as positive (y-up);
        // UIKit - clockwise. Invert so the map rotates with the fingers.
        let rotation = -gesture.rotation
        let settings = mapView.cameraRuntime.currentSettings.camera
        mapView.cameraRuntime.rotateCameraYaw(delta: Float(rotation) * settings.rotationGestureSensitivity)
        gesture.rotation = 0
    }

    // MARK: - Magnification

    @objc private func handleMagnification(_ gesture: NSMagnificationGestureRecognizer) {
        guard let mapView,
              mapView.cameraRuntime.currentCameraState() != nil else {
            return
        }

        updateInteractionState(for: gesture.state,
                               source: .mapPinch)
        let scale = 1.0 + gesture.magnification
        guard scale > 0 else {
            return
        }

        mapView.cameraRuntime.zoomCamera(scale: scale,
                                         velocity: 0,
                                         anchorPoint: gesture.location(in: mapView))
        gesture.magnification = 0
    }

    // MARK: - Scroll zoom

    func handleScrollWheel(_ event: NSEvent) {
        guard let mapView,
              mapView.cameraRuntime.currentCameraState() != nil else {
            return
        }

        let anchorPoint = mapView.convert(event.locationInWindow, from: nil)
        let isTrackpadGesture = event.phase != [] || event.momentumPhase != []
        if isTrackpadGesture {
            // The momentum half of the gesture moves the camera just as the
            // finger-down half does, so it counts as interaction too; see
            // ScrollZoomInteractionPhaseResolver.
            let transition = ScrollZoomInteractionPhaseResolver.transition(phase: event.phase,
                                                                           momentumPhase: event.momentumPhase)
            if transition == .begin {
                setInteractionActive(true,
                                     source: .scrollZoom)
            }
            applyScrollZoom(deltaY: event.scrollingDeltaY,
                            divisor: ScrollZoom.preciseDivisor,
                            anchorPoint: anchorPoint,
                            in: mapView)
            if transition == .end {
                setInteractionActive(false,
                                     source: .scrollZoom)
            }
            return
        }

        // Discrete mouse wheel: single events without phases.
        mapView.cameraAnimationRuntime.cancelAnimations()
        let divisor = event.hasPreciseScrollingDeltas ? ScrollZoom.preciseDivisor : ScrollZoom.lineDivisor
        applyScrollZoom(deltaY: event.scrollingDeltaY,
                        divisor: divisor,
                        anchorPoint: anchorPoint,
                        in: mapView)
    }

    private func applyScrollZoom(deltaY: CGFloat,
                                 divisor: CGFloat,
                                 anchorPoint: CGPoint,
                                 in mapView: ImmersiveMapNSView) {
        guard deltaY != 0 else {
            return
        }

        // Wheel/scroll "up" zooms the map in.
        mapView.cameraRuntime.zoomCamera(delta: Double(deltaY / divisor),
                                         anchorPoint: anchorPoint)
    }

    // MARK: - Interaction state

    private func updateInteractionState(for state: NSGestureRecognizer.State,
                                        source: ImmersiveMapInteractionRuntime.Source) {
        switch state {
        case .began, .changed:
            setInteractionActive(true,
                                 source: source)
        case .ended, .cancelled, .failed:
            setInteractionActive(false,
                                 source: source)
        case .possible:
            return
        @unknown default:
            setInteractionActive(false,
                                 source: source)
        }
    }

    private func setInteractionActive(_ isActive: Bool,
                                      source: ImmersiveMapInteractionRuntime.Source) {
        guard let mapView else { return }

        if isActive {
            mapView.cameraAnimationRuntime.cancelAnimations()
        }

        mapView.interactionRuntime.setActive(isActive,
                                             source: source,
                                             notifiesUserInteractionBegan: true)
    }
}

#endif
