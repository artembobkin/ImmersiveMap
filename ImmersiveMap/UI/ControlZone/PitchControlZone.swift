// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

#if canImport(UIKit)

import CoreGraphics
import UIKit

/// Owns the pitch control zone in the bottom leading corner: a vertical drag
/// inside it tilts the camera instead of panning the map.
/// Opt-in through `cameraSettings.controlZones`.
@MainActor
final class PitchControlZone {
    private enum Layout {
        static let size = CGSize(width: 88, height: 188)
        static let bottomInset: CGFloat = 0
        static let leadingInset: CGFloat = 0
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
    private var controlValue: Float = 0

    init(mapView: ImmersiveMapUIView,
         mapPanGesture: UIPanGestureRecognizer,
         isEnabled: Bool) {
        self.mapView = mapView
        self.panGesture = UIPanGestureRecognizer()
        self.isEnabled = isEnabled
        view.accessibilityIdentifier = "ImmersiveMapUIView.pitchControlZone"
        mapView.addSubview(view)

        panGesture.addTarget(self, action: #selector(handlePan(_:)))
        panGesture.maximumNumberOfTouches = 1
        view.addGestureRecognizer(panGesture)
        mapPanGesture.require(toFail: panGesture)
        applyEnabledState()
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
        isEnabled && view.frame.contains(point)
    }

    private func applyEnabledState() {
        view.isHidden = isEnabled == false
        panGesture.isEnabled = isEnabled
    }

    func syncValue(cameraPosition: ImmersiveMapCameraPosition?,
                   minimumPitch: Float,
                   maximumPitch: Float) {
        if let cameraPosition {
            setControlValue(PitchControlMath.controlValue(forActualPitch: cameraPosition.pitch,
                                                          minimumPitch: minimumPitch,
                                                          maximumPitch: maximumPitch),
                            minimumPitch: minimumPitch,
                            maximumPitch: maximumPitch,
                            updateCamera: false)
        } else {
            setControlValue(maximumPitch,
                            minimumPitch: minimumPitch,
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
            let minimumPitch = currentMinimumPitch()
            let maximumPitch = currentMaximumPitch()
            let translation = gesture.translation(in: view)
            let delta = PitchControlMath.controlValueDelta(
                forVerticalTranslation: translation.y,
                interactionHeight: view.bounds.height,
                minimumPitch: minimumPitch,
                maximumPitch: maximumPitch
            )
            setControlValue(controlValue + delta,
                            minimumPitch: minimumPitch,
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
                                 minimumPitch: Float,
                                 maximumPitch: Float,
                                 updateCamera: Bool) {
        guard let mapView else { return }

        let clampedValue = PitchControlMath.clampedControlValue(value,
                                                                minimumPitch: minimumPitch,
                                                                maximumPitch: maximumPitch)
        controlValue = clampedValue

        guard updateCamera,
              mapView.cameraRuntime.currentCameraState() != nil else {
            return
        }

        mapView.cameraAnimationRuntime.setPitchTarget(PitchControlMath.actualPitch(forControlValue: clampedValue,
                                                                                   minimumPitch: minimumPitch,
                                                                                   maximumPitch: maximumPitch))
    }

    private func currentMaximumPitch() -> Float {
        guard let mapView else {
            return 0
        }
        return mapView.cameraRuntime.currentMaximumPitch()
    }

    private func currentMinimumPitch() -> Float {
        guard let mapView else {
            return 0
        }
        return mapView.cameraRuntime.currentMinimumPitch()
    }
}

#endif
