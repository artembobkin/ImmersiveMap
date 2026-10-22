// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation

/// The 3D buildings group's graph axes and titles, kept out of the AppKit
/// view so they can be tested without a window. The panel edits the depth
/// bias of the buildings' models from the model archive
/// (`ImmersiveMapSettings.ModelArchiveSettings.depthBias`) live, on a
/// graph over the zoom like the air's. Nothing else has such a bias.
enum DebugOverlayModelArchiveSettingsPlanner {
    /// The bias over the zoom, zero to the setting's own ceiling.
    static let depthBiasAxes = DebugOverlayZoomCurveAxes(
        zoomRange: DebugOverlayGroundFogSettingsPlanner.zoomRange,
        valueRange: 0...Double(ImmersiveMapSettings.ModelArchiveSettings.maximumDepthBias))

    static func depthBiasTitle(_ depthBias: ImmersiveMapZoomCurve, cameraZoom: Double) -> String {
        depthBiasText(Double(depthBias.value(atZoom: cameraZoom, interpolation: depthBiasAxes.interpolation)))
    }

    static func depthBiasText(_ depthBias: Double) -> String {
        String(format: "Depth bias %.3f", depthBias)
    }
}
