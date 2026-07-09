// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

#if canImport(UIKit)

import CoreGraphics
import UIKit

/// Владеет persistent map overlay controls одного map view.
/// Создает pitch/zoom controls и attribution badge, раскладывает их и предоставляет control hit-testing.
final class ImmersiveMapControlsRuntime {
    private let pitchControlZone: PitchControlZone
    private let zoomControlZone: ZoomControlZone
    private let attributionBadge: AttributionBadgeView

    init(mapView: ImmersiveMapUIView,
         mapPanGesture: UIPanGestureRecognizer,
         settings: ImmersiveMapSettings) {
        self.pitchControlZone = PitchControlZone(mapView: mapView,
                                                 mapPanGesture: mapPanGesture)
        self.zoomControlZone = ZoomControlZone(mapView: mapView,
                                               mapPanGesture: mapPanGesture)
        self.attributionBadge = AttributionBadgeView(settings: settings.attribution)
        mapView.addSubview(attributionBadge)
    }

    func layout(in bounds: CGRect,
                safeAreaInsets: UIEdgeInsets) {
        pitchControlZone.layout(in: bounds)
        zoomControlZone.layout(in: bounds)
        attributionBadge.layout(in: bounds,
                                safeAreaInsets: safeAreaInsets)
    }

    func containsControlPoint(_ point: CGPoint) -> Bool {
        pitchControlZone.contains(point) || zoomControlZone.contains(point)
    }

    func applyAttributionSettings(_ settings: ImmersiveMapSettings.AttributionSettings) {
        attributionBadge.apply(settings)
    }

    func syncPitch(cameraPosition: ImmersiveMapCameraPosition?,
                   maximumPitch: Float) {
        pitchControlZone.syncValue(cameraPosition: cameraPosition,
                                   maximumPitch: maximumPitch)
    }
}

#endif
