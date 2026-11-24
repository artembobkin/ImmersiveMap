// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

#if canImport(UIKit)

import UIKit

/// Owns the main map canvas gestures and translates UIKit events into camera,
/// selection, and render-loop commands for `ImmersiveMapUIView`.
/// Does not manage control-zone gestures, but exposes `panGesture` so zones can
/// set up recognition priority via `require(toFail:)`.
final class MapGestureController: NSObject, UIGestureRecognizerDelegate {
    private enum InteractionGestureKind {
        case pan
        case pinch
        case rotation
        case tilt

        var interactionSource: ImmersiveMapInteractionRuntime.Source {
            switch self {
            case .pan:
                return .mapPan
            case .pinch:
                return .mapPinch
            case .rotation:
                return .mapRotation
            case .tilt:
                return .mapTilt
            }
        }
    }

    /// Where the two-finger drag stands between competing readings: it starts
    /// undecided, commits to tilting once the movement is clearly vertical,
    /// and once rejected stays inert until the fingers lift, leaving the drag
    /// to the pinch and rotation recognizers running alongside it.
    private enum TiltPhase {
        case undecided
        case tilting
        case rejected
    }

    private weak var mapView: ImmersiveMapUIView?
    let panGesture: UIPanGestureRecognizer
    private let tapGesture: UITapGestureRecognizer
    private let doubleTapGesture: UITapGestureRecognizer
    /// The touch screen's secondary tap: a long press, for a feature that
    /// picks by it.
    private let longPressGesture: UILongPressGestureRecognizer
    private let rotationGesture: UIRotationGestureRecognizer
    private let pinchGesture: UIPinchGestureRecognizer
    private let tiltGesture: UIPanGestureRecognizer
    private var tiltPhase: TiltPhase = .rejected

    init(mapView: ImmersiveMapUIView) {
        self.mapView = mapView
        self.panGesture = UIPanGestureRecognizer()
        self.tapGesture = UITapGestureRecognizer()
        self.doubleTapGesture = UITapGestureRecognizer()
        self.longPressGesture = UILongPressGestureRecognizer()
        self.rotationGesture = UIRotationGestureRecognizer()
        self.pinchGesture = UIPinchGestureRecognizer()
        self.tiltGesture = UIPanGestureRecognizer()
        super.init()

        configureGestures(in: mapView)
    }

    func setPanInteractionActiveForTesting(_ isActive: Bool) {
        setInteractionActive(isActive,
                             gestureKind: .pan)
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        if (gestureRecognizer is UIRotationGestureRecognizer && otherGestureRecognizer is UIPinchGestureRecognizer) ||
            (gestureRecognizer is UIPinchGestureRecognizer && otherGestureRecognizer is UIRotationGestureRecognizer) {
            return true
        }
        // The two-finger tilt must run alongside pinch and rotation: all three
        // recognize the same pair of touches, and without this the first one
        // to begin would lock the other two out for the whole touch sequence.
        if gestureRecognizer === tiltGesture || otherGestureRecognizer === tiltGesture {
            return otherGestureRecognizer is UIPinchGestureRecognizer ||
                otherGestureRecognizer is UIRotationGestureRecognizer ||
                gestureRecognizer is UIPinchGestureRecognizer ||
                gestureRecognizer is UIRotationGestureRecognizer
        }
        return false
    }

    /// A touch that starts on an interactive SwiftUI annotation goes entirely to
    /// its content: the map gestures (pan/pinch/rotation/tap/doubleTap) never
    /// receive such a touch. The recognizers are attached to the host view and
    /// without this filter would see touches on all subviews.
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldReceive touch: UITouch) -> Bool {
        if gestureRecognizer === doubleTapGesture, isDoubleTapWanted == false {
            return false
        }
        // The long press exists only while a feature picks by it.
        if gestureRecognizer === longPressGesture, mapView?.tapHandler.isClaimed(.secondary) != true {
            return false
        }
        guard let mapView,
              let annotationContainer = mapView.annotationRuntime.annotationContainerViewIfLoaded,
              let touchView = touch.view else {
            return true
        }
        return touchView.isDescendant(of: annotationContainer) == false
    }

    /// A single tap (selection) waits for the double tap (anchored zoom)
    /// to fail, while the double tap zooms. Asked for every tap, so the
    /// setting applies live.
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRequireFailureOf otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        gestureRecognizer === tapGesture && otherGestureRecognizer === doubleTapGesture && isDoubleTapWanted
    }

    /// Whether the double tap does anything: it zooms
    /// (`CameraSettings.isDoubleTapZoomEnabled`), or a feature of the map
    /// takes it as its own (the tile grid selecting by it). When it does
    /// nothing it receives no touch, and the single tap waits for
    /// nothing: it acts as the finger lifts.
    private var isDoubleTapWanted: Bool {
        guard let mapView else { return true }
        return mapView.cameraRuntime.currentSettings.camera.isDoubleTapZoomEnabled
            || mapView.tapHandler.isClaimed(.double)
    }

    private func configureGestures(in mapView: ImmersiveMapUIView) {
        panGesture.addTarget(self, action: #selector(handlePan(_:)))
        panGesture.delegate = self
        panGesture.maximumNumberOfTouches = 1
        mapView.addGestureRecognizer(panGesture)

        doubleTapGesture.addTarget(self, action: #selector(handleDoubleTap(_:)))
        doubleTapGesture.delegate = self
        doubleTapGesture.numberOfTapsRequired = 2
        mapView.addGestureRecognizer(doubleTapGesture)

        tapGesture.addTarget(self, action: #selector(handleTap(_:)))
        tapGesture.delegate = self
        tapGesture.numberOfTapsRequired = 1
        mapView.addGestureRecognizer(tapGesture)

        longPressGesture.addTarget(self, action: #selector(handleLongPress(_:)))
        longPressGesture.delegate = self
        mapView.addGestureRecognizer(longPressGesture)

        rotationGesture.addTarget(self, action: #selector(handleRotation(_:)))
        rotationGesture.delegate = self
        mapView.addGestureRecognizer(rotationGesture)

        pinchGesture.addTarget(self, action: #selector(handlePinch(_:)))
        pinchGesture.delegate = self
        mapView.addGestureRecognizer(pinchGesture)

        tiltGesture.addTarget(self, action: #selector(handleTilt(_:)))
        tiltGesture.delegate = self
        tiltGesture.minimumNumberOfTouches = 2
        tiltGesture.maximumNumberOfTouches = 2
        mapView.addGestureRecognizer(tiltGesture)
    }

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        guard let mapView else { return }

        mapView.tapHandler.handleMapTap(at: gesture.location(in: mapView))
    }

    /// A long press picks for a feature that picks by the secondary tap
    /// (the tile grid, by its settings), as the press is recognized.
    @objc private func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
        guard let mapView, gesture.state == .began else { return }

        mapView.tapHandler.handleClaimedTap(.secondary, at: gesture.location(in: mapView))
    }

    /// Double tap zooms the map in by one zoom level toward the tap point:
    /// the world point under the finger stays put (see `zoomAnchorFactor`).
    @objc private func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
        guard let mapView,
              mapView.cameraRuntime.currentCameraState() != nil else {
            return
        }
        // A feature that picks by the double tap has it, and the map does
        // not zoom.
        if mapView.tapHandler.isClaimed(.double) {
            mapView.tapHandler.handleClaimedTap(.double, at: gesture.location(in: mapView))
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

    @objc private func handleRotation(_ gesture: UIRotationGestureRecognizer) {
        guard let mapView,
              mapView.cameraRuntime.currentCameraState() != nil else {
            return
        }

        updateInteractionState(for: gesture.state,
                               gestureKind: .rotation)
        let rotation = gesture.rotation
        let settings = mapView.cameraRuntime.currentSettings.camera
        mapView.cameraRuntime.rotateCameraYaw(delta: Float(rotation) * settings.rotationGestureSensitivity)
        gesture.rotation = 0
    }

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        guard let mapView,
              mapView.cameraRuntime.currentCameraState() != nil else {
            return
        }

        updateInteractionState(for: gesture.state,
                               gestureKind: .pan)

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

    @objc private func handlePinch(_ gesture: UIPinchGestureRecognizer) {
        guard let mapView,
              mapView.cameraRuntime.currentCameraState() != nil else {
            return
        }

        updateInteractionState(for: gesture.state,
                               gestureKind: .pinch)
        mapView.cameraRuntime.zoomCamera(scale: gesture.scale,
                                         velocity: gesture.velocity,
                                         anchorPoint: gesture.location(in: mapView))
        gesture.scale = 1.0
    }

    /// Two-finger vertical drag tilts the camera (down for more tilt), the touch
    /// counterpart of the macOS right-button drag. The drag commits to tilting
    /// only when the fingers sit roughly side by side and move together mostly
    /// vertically; anything else is left untouched for the pinch and rotation
    /// recognizers running simultaneously on the same touches.
    @objc private func handleTilt(_ gesture: UIPanGestureRecognizer) {
        guard let mapView,
              mapView.cameraRuntime.currentCameraState() != nil else {
            return
        }

        switch gesture.state {
        case .began:
            gesture.setTranslation(.zero, in: mapView)
            if gesture.numberOfTouches >= 2,
               TwoFingerTiltGestureMath.touchLayoutAllowsTilt(gesture.location(ofTouch: 0, in: mapView),
                                                              gesture.location(ofTouch: 1, in: mapView)) {
                tiltPhase = .undecided
            } else {
                tiltPhase = .rejected
            }
        case .changed:
            // The recognizer only requires two touches to begin: after one
            // finger lifts it keeps delivering .changed from the remaining
            // touch, so without this check a lone finger would keep tilting,
            // or a lone vertical drag would newly commit an undecided tilt.
            if gesture.numberOfTouches < 2 {
                if tiltPhase == .tilting {
                    setInteractionActive(false,
                                         gestureKind: .tilt)
                }
                tiltPhase = .rejected
                return
            }
            switch tiltPhase {
            case .undecided:
                // Translation keeps accumulating until the drag reveals its
                // direction; only then does the tilt engage, applying the
                // whole accumulated movement so nothing is lost to the wait.
                switch TwoFingerTiltGestureMath.intent(ofTranslation: gesture.translation(in: mapView)) {
                case .undecided:
                    break
                case .tilt:
                    tiltPhase = .tilting
                    setInteractionActive(true,
                                         gestureKind: .tilt)
                    applyTiltTranslation(gesture, in: mapView)
                case .other:
                    tiltPhase = .rejected
                }
            case .tilting:
                applyTiltTranslation(gesture, in: mapView)
            case .rejected:
                break
            }
        case .ended, .cancelled, .failed:
            if tiltPhase == .tilting {
                setInteractionActive(false,
                                     gestureKind: .tilt)
            }
            tiltPhase = .rejected
        case .possible:
            break
        @unknown default:
            if tiltPhase == .tilting {
                setInteractionActive(false,
                                     gestureKind: .tilt)
            }
            tiltPhase = .rejected
        }
    }

    private func applyTiltTranslation(_ gesture: UIPanGestureRecognizer,
                                      in mapView: ImmersiveMapUIView) {
        let translation = gesture.translation(in: mapView)
        gesture.setTranslation(.zero, in: mapView)
        guard let currentPitch = mapView.cameraRuntime.currentPitch else {
            return
        }

        let settings = mapView.cameraRuntime.currentSettings.camera
        let pitchDelta = TwoFingerTiltGestureMath.pitchDelta(forVerticalTranslation: translation.y,
                                                             viewHeight: mapView.bounds.height,
                                                             maximumPitch: mapView.cameraRuntime.currentMaximumPitch(),
                                                             sensitivity: settings.tiltGestureSensitivity)
        mapView.cameraAnimationRuntime.setPitchTarget(currentPitch + pitchDelta)
    }

    private func updateInteractionState(for state: UIGestureRecognizer.State,
                                        gestureKind: InteractionGestureKind) {
        switch state {
        case .began, .changed:
            setInteractionActive(true,
                                 gestureKind: gestureKind)
        case .ended, .cancelled, .failed:
            setInteractionActive(false,
                                 gestureKind: gestureKind)
        case .possible:
            return
        @unknown default:
            setInteractionActive(false,
                                 gestureKind: gestureKind)
        }
    }

    private func setInteractionActive(_ isActive: Bool,
                                      gestureKind: InteractionGestureKind) {
        guard let mapView else { return }

        if isActive {
            mapView.cameraAnimationRuntime.cancelAnimations()
        }

        mapView.interactionRuntime.setActive(isActive,
                                             source: gestureKind.interactionSource,
                                             notifiesUserInteractionBegan: true)
    }
}

#endif
