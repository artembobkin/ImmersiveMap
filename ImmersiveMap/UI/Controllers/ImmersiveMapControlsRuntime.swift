// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import CoreGraphics
import os
#if canImport(UIKit)
import UIKit
#endif

/// Owns the persistent map overlay controls of one map view.
/// Creates the opt-in pitch/zoom control zones and pointer scroll zoom on touch
/// platforms; the attribution badge exists on all platforms. Lays out the
/// controls and provides hit-testing.
@MainActor
final class ImmersiveMapControlsRuntime {
    #if canImport(UIKit)
    private let pitchControlZone: PitchControlZone
    private let zoomControlZone: ZoomControlZone
    private let scrollZoomGesture: ScrollZoomGesture
    #endif
    private let attributionBadge: AttributionBadgeView

    #if canImport(UIKit)
    init(mapView: ImmersiveMapHostView,
         mapPanGesture: UIPanGestureRecognizer,
         settings: ImmersiveMapSettings) {
        let controlZones = settings.camera.controlZones
        self.pitchControlZone = PitchControlZone(mapView: mapView,
                                                 mapPanGesture: mapPanGesture,
                                                 isEnabled: controlZones.isPitchZoneEnabled)
        self.zoomControlZone = ZoomControlZone(mapView: mapView,
                                               mapPanGesture: mapPanGesture,
                                               isEnabled: controlZones.isZoomZoneEnabled)
        self.scrollZoomGesture = ScrollZoomGesture(mapView: mapView)
        self.attributionBadge = AttributionBadgeView(attribution: settings.resolvedAttribution,
                                                     settings: settings.attribution)
        mapView.addSubview(attributionBadge)
        Self.warnIfAttributionHidden(settings: settings)
    }
    #else
    init(mapView: ImmersiveMapHostView,
         settings: ImmersiveMapSettings) {
        self.attributionBadge = AttributionBadgeView(attribution: settings.resolvedAttribution,
                                                     settings: settings.attribution)
        mapView.addSubview(attributionBadge)
        Self.warnIfAttributionHidden(settings: settings)
    }
    #endif

    private static let logger = Logger(subsystem: "ImmersiveMap", category: "Attribution")

    /// The app hid the badge (or emptied the attribution) at map startup and
    /// did not declare its own credit: remind once per process that the data
    /// license still requires visible attribution near the map.
    private static func warnIfAttributionHidden(settings: ImmersiveMapSettings) {
        guard AttributionHiddenNotice.isWarningWarranted(for: settings),
              AttributionHiddenNotice.shared.shouldLog() else {
            return
        }
        logger.warning("""
        ImmersiveMap: the attribution badge is hidden or empty, but map data licenses \
        (ODbL for OpenStreetMap data) require visible attribution near the map. Show the \
        data credit in your app, or make the badge visible. If your app already shows the \
        credit, declare it with .attributionProvidedExternally() to silence this warning. \
        What has to be credited and where it has to appear: \
        https://github.com/artembobkin/ImmersiveMap/blob/main/ATTRIBUTION.md
        """)
    }

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

    func applyAttribution(_ attribution: ImmersiveMapAttribution,
                          settings: ImmersiveMapSettings.AttributionSettings) {
        attributionBadge.apply(attribution, settings: settings)
    }

    func applyControlZones(_ controlZones: ImmersiveMapSettings.CameraSettings.ControlZoneSettings) {
        #if canImport(UIKit)
        pitchControlZone.isEnabled = controlZones.isPitchZoneEnabled
        zoomControlZone.isEnabled = controlZones.isZoomZoneEnabled
        #endif
    }

    func syncPitch(cameraPosition: ImmersiveMapCameraPosition?,
                   maximumPitch: Float) {
        #if canImport(UIKit)
        pitchControlZone.syncValue(cameraPosition: cameraPosition,
                                   maximumPitch: maximumPitch)
        #endif
    }
}
