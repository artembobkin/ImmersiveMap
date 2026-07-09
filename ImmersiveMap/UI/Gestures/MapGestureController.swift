// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

#if canImport(UIKit)

import UIKit

/// Владеет жестами основного полотна карты и переводит события UIKit в команды
/// камеры, выбора и render-loop для `ImmersiveMapUIView`.
/// Control-zone жестами не управляет, но отдает `panGesture`, чтобы зоны могли
/// настроить приоритет распознавания через `require(toFail:)`.
final class MapGestureController: NSObject, UIGestureRecognizerDelegate {
    private enum InteractionGestureKind {
        case pan
        case pinch
        case rotation

        var interactionSource: ImmersiveMapInteractionRuntime.Source {
            switch self {
            case .pan:
                return .mapPan
            case .pinch:
                return .mapPinch
            case .rotation:
                return .mapRotation
            }
        }
    }

    private weak var mapView: ImmersiveMapUIView?
    let panGesture: UIPanGestureRecognizer
    private let tapGesture: UITapGestureRecognizer
    private let rotationGesture: UIRotationGestureRecognizer
    private let pinchGesture: UIPinchGestureRecognizer

    init(mapView: ImmersiveMapUIView) {
        self.mapView = mapView
        self.panGesture = UIPanGestureRecognizer()
        self.tapGesture = UITapGestureRecognizer()
        self.rotationGesture = UIRotationGestureRecognizer()
        self.pinchGesture = UIPinchGestureRecognizer()
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
        return false
    }

    private func configureGestures(in mapView: ImmersiveMapUIView) {
        panGesture.addTarget(self, action: #selector(handlePan(_:)))
        panGesture.delegate = self
        panGesture.maximumNumberOfTouches = 1
        mapView.addGestureRecognizer(panGesture)

        tapGesture.addTarget(self, action: #selector(handleTap(_:)))
        tapGesture.numberOfTapsRequired = 1
        mapView.addGestureRecognizer(tapGesture)

        rotationGesture.addTarget(self, action: #selector(handleRotation(_:)))
        rotationGesture.delegate = self
        mapView.addGestureRecognizer(rotationGesture)

        pinchGesture.addTarget(self, action: #selector(handlePinch(_:)))
        pinchGesture.delegate = self
        mapView.addGestureRecognizer(pinchGesture)
    }

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        guard let mapView else { return }

        mapView.tapHandler.handleMapTap(at: gesture.location(in: mapView))
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
            mapView.cameraAnimationRuntime.startGlobeCameraPanInertiaIfNeeded(initialVelocity: gesture.velocity(in: mapView))
        case .cancelled, .failed:
            mapView.cameraAnimationRuntime.cancelGlobeCameraPanInertia()
        case .began, .changed, .possible:
            break
        @unknown default:
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
                                         velocity: gesture.velocity)
        gesture.scale = 1.0
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
