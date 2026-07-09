// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

#if canImport(UIKit)

import CoreGraphics
import UIKit

/// Владеет zoom control zone, включая drag zoom и scroll zoom gestures.
/// Переводит движение control в camera zoom commands и сообщает состояние zoom interaction.
final class ZoomControlZone {
    private enum Layout {
        static let size = CGSize(width: 132, height: 240)
        static let bottomInset: CGFloat = 0
        static let trailingInset: CGFloat = 0
    }

    private weak var mapView: ImmersiveMapUIView?
    private let view = ControlZoneView()
    private let panGesture: UIPanGestureRecognizer
    private let scrollGesture: UIPanGestureRecognizer

    init(mapView: ImmersiveMapUIView,
         mapPanGesture: UIPanGestureRecognizer) {
        self.mapView = mapView
        self.panGesture = UIPanGestureRecognizer()
        self.scrollGesture = UIPanGestureRecognizer()

        scrollGesture.addTarget(self, action: #selector(handleScrollZoom(_:)))
        scrollGesture.allowedTouchTypes = []
        scrollGesture.allowedScrollTypesMask = .all
        mapView.addGestureRecognizer(scrollGesture)

        view.accessibilityIdentifier = "ImmersiveMapUIView.zoomControlZone"
        mapView.addSubview(view)

        panGesture.addTarget(self, action: #selector(handlePan(_:)))
        panGesture.maximumNumberOfTouches = 1
        view.addGestureRecognizer(panGesture)
        mapPanGesture.require(toFail: panGesture)
    }

    func layout(in bounds: CGRect) {
        view.frame = CGRect(
            x: bounds.width - Layout.trailingInset - Layout.size.width,
            y: bounds.height - Layout.bottomInset - Layout.size.height,
            width: Layout.size.width,
            height: Layout.size.height
        )
    }

    func contains(_ point: CGPoint) -> Bool {
        view.frame.contains(point)
    }

    @objc private func handleScrollZoom(_ gesture: UIPanGestureRecognizer) {
        guard let mapView,
              mapView.cameraRuntime.currentCameraState() != nil else {
            return
        }

        switch gesture.state {
        case .began:
            gesture.setTranslation(.zero, in: mapView)
            setScrollInteractionActive(true)
        case .changed:
            let settings = mapView.cameraRuntime.currentSettings
            let translation = gesture.translation(in: mapView)
            let velocity = gesture.velocity(in: mapView)
            let delta = -ZoomControlMath.zoomDelta(forVerticalTranslation: translation.y,
                                                   velocityY: velocity.y,
                                                   interactionHeight: Layout.size.height,
                                                   zoomFactor: settings.camera.dragZoomFactor,
                                                   velocityFactor: settings.camera.dragZoomVelocityFactor,
                                                   velocityLimit: settings.camera.dragZoomVelocityLimit)
            mapView.cameraRuntime.zoomCamera(delta: delta)
            gesture.setTranslation(.zero, in: mapView)
        case .ended, .cancelled, .failed:
            setScrollInteractionActive(false)
        case .possible:
            break
        @unknown default:
            setScrollInteractionActive(false)
        }
    }

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        guard let mapView,
              mapView.cameraRuntime.currentCameraState() != nil else {
            return
        }

        switch gesture.state {
        case .began:
            gesture.setTranslation(.zero, in: view)
            setControlInteractionActive(true)
        case .changed:
            let settings = mapView.cameraRuntime.currentSettings
            let translation = gesture.translation(in: view)
            let velocity = gesture.velocity(in: view)
            let delta = ZoomControlMath.zoomDelta(forVerticalTranslation: translation.y,
                                                  velocityY: velocity.y,
                                                  interactionHeight: view.bounds.height,
                                                  zoomFactor: settings.camera.dragZoomFactor,
                                                  velocityFactor: settings.camera.dragZoomVelocityFactor,
                                                  velocityLimit: settings.camera.dragZoomVelocityLimit)
            mapView.cameraRuntime.zoomCamera(delta: delta)
            gesture.setTranslation(.zero, in: view)
        case .ended, .cancelled, .failed:
            setControlInteractionActive(false)
        case .possible:
            break
        @unknown default:
            setControlInteractionActive(false)
        }
    }

    private func setControlInteractionActive(_ isActive: Bool) {
        guard let mapView else { return }

        if isActive {
            mapView.cameraAnimationRuntime.cancelAnimations()
        }

        mapView.interactionRuntime.setActive(isActive,
                                             source: .zoomControl,
                                             notifiesUserInteractionBegan: false,
                                             requestsFrameOnStart: true)
    }

    private func setScrollInteractionActive(_ isActive: Bool) {
        guard let mapView else { return }

        if isActive {
            mapView.cameraAnimationRuntime.cancelAnimations()
        }

        mapView.interactionRuntime.setActive(isActive,
                                             source: .scrollZoom,
                                             notifiesUserInteractionBegan: true,
                                             requestsFrameOnStart: true)
    }
}

#endif
