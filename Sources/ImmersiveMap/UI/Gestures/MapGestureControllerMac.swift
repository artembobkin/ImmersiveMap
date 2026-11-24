// Copyright (c) 2025-2026 Artem Bobkin.
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
    /// The presses of either button that are not drags: the clicks, the
    /// double clicks and the secondary clicks all come from it.
    private let clickObserver: MapClickObserver
    private var clickSequence = MapClickSequence()
    private let rotationGesture: NSRotationGestureRecognizer
    private let magnificationGesture: NSMagnificationGestureRecognizer
    private var panMode: PanMode = .pan

    init(mapView: ImmersiveMapNSView) {
        self.mapView = mapView
        self.panGesture = MapPanGestureRecognizer()
        self.tiltPanGesture = MapPanGestureRecognizer()
        self.clickObserver = MapClickObserver()
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

    /// Whether the double click does anything: it zooms
    /// (`CameraSettings.isDoubleTapZoomEnabled`), or a feature of the map
    /// takes it as its own (the tile grid selecting by it). When it does
    /// nothing the single click waits for nothing: it acts on the
    /// mouse's release.
    private var isDoubleClickWanted: Bool {
        guard let mapView else { return true }
        return mapView.cameraRuntime.currentSettings.camera.isDoubleTapZoomEnabled
            || mapView.tapHandler.isClaimed(.double)
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

        // A movement within the tolerance is a press, past it a drag:
        // the pans and the observer read the one setting.
        let tolerance: () -> CGFloat = { [weak mapView] in
            CGFloat(mapView?.cameraRuntime.currentSettings.camera.tapMovementTolerancePoints ?? 4)
        }
        (panGesture as? MapPanGestureRecognizer)?.tolerance = tolerance
        (tiltPanGesture as? MapPanGestureRecognizer)?.tolerance = tolerance
        clickObserver.tolerance = tolerance
        clickObserver.onPress = { [weak self] button, locationInWindow, time in
            self?.handlePress(button, locationInWindow: locationInWindow, time: time)
        }
        clickObserver.delegate = self
        mapView.addGestureRecognizer(clickObserver)

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

    /// A press of a button on the map (`MapClickObserver`). The secondary
    /// button picks for a feature that picks by it (the tile grid, by its
    /// settings). The main button is a click, or half of a double click
    /// (`MapClickSequence`): while a double click means something, a
    /// click waits the system's interval to learn it is not one.
    private func handlePress(_ button: MapClickObserver.Button, locationInWindow: CGPoint, time: TimeInterval) {
        guard let mapView else { return }
        let point = mapView.convert(locationInWindow, from: nil)
        guard button == .primary else {
            if mapView.tapHandler.isClaimed(.secondary) {
                mapView.tapHandler.handleClaimedTap(.secondary, at: point)
            }
            return
        }

        let interval = NSEvent.doubleClickInterval
        // The second press of a double click lands near the first, not on
        // it: three times what a single press may move.
        let reach = clickObserver.tolerance() * 3
        switch clickSequence.press(at: point, time: time, interval: interval, reach: reach,
                                   waitsForDouble: isDoubleClickWanted) {
        case .click:
            handleClick(at: point)
        case .doubleClick:
            handleDoubleClick(at: point)
        case let .pending(flushed):
            if let flushed { handleClick(at: flushed) }
            DispatchQueue.main.asyncAfter(deadline: .now() + interval) { [weak self] in
                guard let self, let point = self.clickSequence.expire(pressedAt: time) else { return }
                self.handleClick(at: point)
            }
        }
    }

    private func handleClick(at point: CGPoint) {
        mapView?.tapHandler.handleMapTap(at: point)
    }

    /// A double click zooms the map in by one zoom level toward the click point:
    /// the world point under the cursor stays in place (see `zoomAnchorFactor`).
    private func handleDoubleClick(at anchorPoint: CGPoint) {
        guard let mapView,
              mapView.cameraRuntime.currentCameraState() != nil else {
            return
        }
        // A feature that picks by the double click has it, and the map
        // does not zoom.
        if mapView.tapHandler.isClaimed(.double) {
            mapView.tapHandler.handleClaimedTap(.double, at: anchorPoint)
            return
        }

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
            mapView.cameraRuntime.endPan()
            mapView.cameraAnimationRuntime.startGlobeCameraPanInertiaIfNeeded(initialVelocity: gesture.velocity(in: mapView))
        case .cancelled, .failed:
            mapView.cameraRuntime.endPan()
            mapView.cameraAnimationRuntime.cancelGlobeCameraPanInertia()
        case .began, .changed, .possible:
            break
        @unknown default:
            mapView.cameraRuntime.endPan()
            mapView.cameraAnimationRuntime.cancelGlobeCameraPanInertia()
        }
    }

    /// Vertical dragging changes pitch (down - more tilt, inverted by a
    /// negative `tiltGestureSensitivity`), horizontal dragging rotates the
    /// camera.
    private func applyTilt(_ gesture: NSPanGestureRecognizer,
                           in mapView: ImmersiveMapNSView) {
        updateInteractionState(for: gesture.state,
                               source: .mapTilt)

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
