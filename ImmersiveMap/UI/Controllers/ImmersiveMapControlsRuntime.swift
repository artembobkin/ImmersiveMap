// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import CoreGraphics
#if canImport(UIKit)
import UIKit
#endif

/// Владеет persistent map overlay controls одного map view.
/// На touch-платформах создает pitch/zoom control zones; attribution badge
/// существует на всех платформах. Раскладывает контролы и предоставляет hit-testing.
@MainActor
final class ImmersiveMapControlsRuntime {
    #if canImport(UIKit)
    private let pitchControlZone: PitchControlZone
    private let zoomControlZone: ZoomControlZone
    #endif
    private let attributionBadge: AttributionBadgeView

    #if canImport(UIKit)
    init(mapView: ImmersiveMapHostView,
         mapPanGesture: UIPanGestureRecognizer,
         settings: ImmersiveMapSettings) {
        self.pitchControlZone = PitchControlZone(mapView: mapView,
                                                 mapPanGesture: mapPanGesture)
        self.zoomControlZone = ZoomControlZone(mapView: mapView,
                                               mapPanGesture: mapPanGesture)
        self.attributionBadge = AttributionBadgeView(settings: settings.attribution)
        mapView.addSubview(attributionBadge)
    }
    #else
    init(mapView: ImmersiveMapHostView,
         settings: ImmersiveMapSettings) {
        self.attributionBadge = AttributionBadgeView(settings: settings.attribution)
        mapView.addSubview(attributionBadge)
    }
    #endif

    func layout(in bounds: CGRect,
                safeAreaInsets: PlatformEdgeInsets) {
        #if canImport(UIKit)
        pitchControlZone.layout(in: bounds)
        zoomControlZone.layout(in: bounds)
        #endif
        attributionBadge.layout(in: bounds,
                                safeAreaInsets: safeAreaInsets)
    }

    func containsControlPoint(_ point: CGPoint) -> Bool {
        #if canImport(UIKit)
        return pitchControlZone.contains(point) || zoomControlZone.contains(point)
        #else
        return false
        #endif
    }

    func applyAttributionSettings(_ settings: ImmersiveMapSettings.AttributionSettings) {
        attributionBadge.apply(settings)
    }

    func syncPitch(cameraPosition: ImmersiveMapCameraPosition?,
                   maximumPitch: Float) {
        #if canImport(UIKit)
        pitchControlZone.syncValue(cameraPosition: cameraPosition,
                                   maximumPitch: maximumPitch)
        #endif
    }
}
