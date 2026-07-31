// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import CoreGraphics
#if canImport(UIKit)
import UIKit
#endif

/// Owns the persistent map overlay controls of one map view.
/// Creates pitch/zoom control zones on touch platforms; the attribution badge
/// exists on all platforms. Lays out the controls and provides hit-testing.
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
        self.attributionBadge = AttributionBadgeView(attribution: settings.resolvedAttribution,
                                                     isVisible: settings.attribution.isVisible)
        mapView.addSubview(attributionBadge)
    }
    #else
    init(mapView: ImmersiveMapHostView,
         settings: ImmersiveMapSettings) {
        self.attributionBadge = AttributionBadgeView(attribution: settings.resolvedAttribution,
                                                     isVisible: settings.attribution.isVisible)
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

    func applyAttribution(_ attribution: ImmersiveMapAttribution, isVisible: Bool) {
        attributionBadge.apply(attribution, isVisible: isVisible)
    }

    func syncPitch(cameraPosition: ImmersiveMapCameraPosition?,
                   maximumPitch: Float) {
        #if canImport(UIKit)
        pitchControlZone.syncValue(cameraPosition: cameraPosition,
                                   maximumPitch: maximumPitch)
        #endif
    }
}
