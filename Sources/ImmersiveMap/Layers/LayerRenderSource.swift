// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

/// The one seam between the layers' drawing and whoever holds the app's
/// layers: the map view's runtime over the app's controller, an export over
/// the layers it was handed. The frame reads it once, on the main thread.
protocol LayerRenderSource: AnyObject {
    /// The layers to draw, in the order they draw.
    var currentLayers: [ImmersiveMapLayer] { get }
}

/// Layers that do not change: what a picture or a video is made with, and
/// the source of a renderer that was given none.
final class FixedLayerRenderSource: LayerRenderSource {
    let currentLayers: [ImmersiveMapLayer]

    init(_ layers: [ImmersiveMapLayer] = []) {
        currentLayers = layers
    }
}
