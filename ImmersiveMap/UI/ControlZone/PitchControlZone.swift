// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

#if canImport(UIKit)

import CoreGraphics
import UIKit

/// Владеет pitch control zone и ее pan gesture.
/// Переводит vertical drag в изменение camera pitch и сообщает состояние control interaction.
final class PitchControlZone {
    private enum Layout {
        static let size = CGSize(width: 88, height: 188)
        static let bottomInset: CGFloat = 0
        static let leadingInset: CGFloat = 0
    }

    private weak var mapView: ImmersiveMapUIView?
    private let view = ControlZoneView()
    private let panGesture: UIPanGestureRecognizer
    private var controlValue: Float = 0

    init(mapView: ImmersiveMapUIView,
         mapPanGesture: UIPanGestureRecognizer) {
        self.mapView = mapView
        self.panGesture = UIPanGestureRecognizer()
        view.accessibilityIdentifier = "ImmersiveMapUIView.pitchControlZone"
        mapView.addSubview(view)

        panGesture.addTarget(self, action: #selector(handlePan(_:)))
        panGesture.maximumNumberOfTouches = 1
        view.addGestureRecognizer(panGesture)
        mapPanGesture.require(toFail: panGesture)
    }

    func layout(in bounds: CGRect) {
        view.frame = CGRect(
            x: Layout.leadingInset,
            y: bounds.height - Layout.bottomInset - Layout.size.height,
            width: Layout.size.width,
            height: Layout.size.height
        )
    }

    func contains(_ point: CGPoint) -> Bool {
        view.frame.contains(point)
    }

    func syncValue(cameraPosition: ImmersiveMapCameraPosition?,
                   maximumPitch: Float) {
        if let cameraPosition {
            setControlValue(PitchControlMath.controlValue(forActualPitch: cameraPosition.pitch,
                                                          maximumPitch: maximumPitch),
                            maximumPitch: maximumPitch,
                            updateCamera: false)
        } else {
            setControlValue(maximumPitch,
                            maximumPitch: maximumPitch,
                            updateCamera: false)
        }
    }

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        guard let mapView else { return }

        switch gesture.state {
        case .began:
            gesture.setTranslation(.zero, in: view)
            setInteractionActive(true)
        case .changed:
            let maximumPitch = currentMaximumPitch()
            let translation = gesture.translation(in: view)
            let delta = PitchControlMath.controlValueDelta(
                forVerticalTranslation: translation.y,
                interactionHeight: view.bounds.height,
                maximumPitch: maximumPitch
            )
            setControlValue(controlValue + delta,
                            maximumPitch: maximumPitch,
                            updateCamera: true)
            gesture.setTranslation(.zero, in: view)
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
                                             source: .pitchControl,
                                             notifiesUserInteractionBegan: false,
                                             requestsFrameOnStart: true)
    }

    private func setControlValue(_ value: Float,
                                 maximumPitch: Float,
                                 updateCamera: Bool) {
        guard let mapView else { return }

        let clampedValue = PitchControlMath.clampedControlValue(value, maximumPitch: maximumPitch)
        controlValue = clampedValue

        guard updateCamera,
              mapView.cameraRuntime.currentCameraState() != nil else {
            return
        }

        mapView.cameraAnimationRuntime.setPitchTarget(PitchControlMath.actualPitch(forControlValue: clampedValue,
                                                                                   maximumPitch: maximumPitch))
    }

    private func currentMaximumPitch() -> Float {
        guard let mapView else {
            return 0
        }
        return mapView.cameraRuntime.currentMaximumPitch()
    }
}

#endif
