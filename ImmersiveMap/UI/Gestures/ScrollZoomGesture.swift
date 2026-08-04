// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

#if canImport(UIKit)

import CoreGraphics
import UIKit

/// Owns pointer scroll zoom (trackpad, mouse wheel) over the whole map view.
/// Deliberately separate from ``ZoomControlZone``: scrolling is a pointer gesture
/// that stays available even when the opt-in corner drag zones are off.
@MainActor
final class ScrollZoomGesture {
    /// Scroll translation is normalized against a fixed height so zoom speed does
    /// not depend on the view size; the value matches the zoom control zone,
    /// where this gesture used to live.
    private static let interactionHeight: CGFloat = 240

    private weak var mapView: ImmersiveMapUIView?
    private let gesture: UIPanGestureRecognizer

    init(mapView: ImmersiveMapUIView) {
        self.mapView = mapView
        self.gesture = UIPanGestureRecognizer()

        gesture.addTarget(self, action: #selector(handleScrollZoom(_:)))
        gesture.allowedTouchTypes = []
        gesture.allowedScrollTypesMask = .all
        mapView.addGestureRecognizer(gesture)
    }

    @objc private func handleScrollZoom(_ gesture: UIPanGestureRecognizer) {
        guard let mapView,
              mapView.cameraRuntime.currentCameraState() != nil else {
            return
        }

        switch gesture.state {
        case .began:
            gesture.setTranslation(.zero, in: mapView)
            setInteractionActive(true)
        case .changed:
            let settings = mapView.cameraRuntime.currentSettings
            let translation = gesture.translation(in: mapView)
            let velocity = gesture.velocity(in: mapView)
            let delta = -ZoomControlMath.zoomDelta(forVerticalTranslation: translation.y,
                                                   velocityY: velocity.y,
                                                   interactionHeight: Self.interactionHeight,
                                                   zoomFactor: settings.camera.dragZoomFactor,
                                                   velocityFactor: settings.camera.dragZoomVelocityFactor,
                                                   velocityLimit: settings.camera.dragZoomVelocityLimit)
            mapView.cameraRuntime.zoomCamera(delta: delta)
            gesture.setTranslation(.zero, in: mapView)
        case .ended, .cancelled, .failed:
            setInteractionActive(false)
        case .possible:
            break
        @unknown default:
            setInteractionActive(false)
        }
    }

    private func setInteractionActive(_ isActive: Bool) {
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
