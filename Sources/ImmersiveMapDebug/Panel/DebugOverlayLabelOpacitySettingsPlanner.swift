// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import ImmersiveMap
import Foundation

/// The Labels tab's opacity graphs, kept out of the AppKit view so the
/// titles can be tested without a window. The panel drags the style's
/// curves (`ImmersiveMapLabelOpacity`) live over the style's own: the names'
/// and the POIs', each a factor 0 to 1 over every label's own opacity, by
/// the zoom, on a graph like the air's.
enum DebugOverlayLabelOpacitySettingsPlanner {
    /// A factor over the zoom, none to the label's own opacity.
    static let opacityAxes = DebugOverlayZoomCurveAxes(zoomRange: DebugOverlayShadowSettingsPlanner.zoomRange,
                                                       valueRange: 0...1)

    static func namesTitle(_ curve: ImmersiveMapZoomCurve, cameraZoom: Double) -> String {
        "Names opacity \(opacityText(Double(curve.value(atZoom: cameraZoom))))"
    }

    static func poisTitle(_ curve: ImmersiveMapZoomCurve, cameraZoom: Double) -> String {
        "POI opacity \(opacityText(Double(curve.value(atZoom: cameraZoom))))"
    }

    static func opacityText(_ opacity: Double) -> String {
        String(format: "%.2f", opacity)
    }
}
