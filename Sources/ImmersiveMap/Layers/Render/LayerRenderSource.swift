// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

/// The one seam between the layers' drawing and whoever holds the app's
/// layers: the map view's runtime over the app's controller, an export over
/// the layers it was handed. The frame reads it once, on the main thread.
protocol LayerRenderSource: AnyObject {
    /// The layers to draw, in the order they draw.
    var currentLayers: [ImmersiveMapLayer] { get }
    /// Where the layers' sources are registered and read, nil when there
    /// are no layers.
    var sourceLibrary: LayerSourceLibrary? { get }
}

/// Layers that do not change: what a picture or a video is made with, and
/// the source of a renderer that was given none. The layers are the
/// controller's as they are when this is made. Their sources stay the
/// controller's own.
final class FixedLayerRenderSource: LayerRenderSource {
    let currentLayers: [ImmersiveMapLayer]
    let sourceLibrary: LayerSourceLibrary?

    init(_ controller: ImmersiveMapLayersController? = nil) {
        currentLayers = controller?.layers ?? []
        sourceLibrary = controller?.library
    }
}
