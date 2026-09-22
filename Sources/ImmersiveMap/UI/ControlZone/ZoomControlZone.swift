// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

#if canImport(UIKit)

import CoreGraphics
import UIKit

/// Owns the drag zoom zone in the bottom trailing corner: a vertical drag inside
/// it changes camera zoom instead of panning the map.
/// Opt-in through `cameraSettings.controlZones`; pointer scroll zoom lives in
/// ``ScrollZoomGesture`` and is unaffected by it.
@MainActor
final class ZoomControlZone {
    private enum Layout {
        static let size = CGSize(width: 132, height: 240)
        static let bottomInset: CGFloat = 0
        static let trailingInset: CGFloat = 0
    }

    /// While disabled the hit surface is hidden and its gesture is off, so a drag
    /// in the corner pans the map exactly like a drag anywhere else.
    var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            applyEnabledState()
        }
    }

    private weak var mapView: ImmersiveMapUIView?
    private let view = ControlZoneView()
    private let panGesture: UIPanGestureRecognizer

    init(mapView: ImmersiveMapUIView,
         mapPanGesture: UIPanGestureRecognizer,
         isEnabled: Bool) {
        self.mapView = mapView
        self.panGesture = UIPanGestureRecognizer()
        self.isEnabled = isEnabled

        view.accessibilityIdentifier = "ImmersiveMapUIView.zoomControlZone"
        mapView.addSubview(view)

        panGesture.addTarget(self, action: #selector(handlePan(_:)))
        panGesture.maximumNumberOfTouches = 1
        view.addGestureRecognizer(panGesture)
        mapPanGesture.require(toFail: panGesture)
        applyEnabledState()
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
        isEnabled && view.frame.contains(point)
    }

    private func applyEnabledState() {
        view.isHidden = isEnabled == false
        panGesture.isEnabled = isEnabled
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
}

#endif
