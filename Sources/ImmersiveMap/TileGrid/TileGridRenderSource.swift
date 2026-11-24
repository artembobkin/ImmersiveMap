// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

/// What a frame draws of the grid besides its settings: the app's side of
/// it, as the controller holds it at the frame.
struct TileGridContent {
    let selectedTiles: Set<ImmersiveMapTileID>
    /// Changes whenever the app's texts may have (`labelProvider` set,
    /// `reloadLabels()`): the texts laid out for the tiles are kept until
    /// it does.
    let labelRevision: UInt64
    let labelProvider: (@Sendable (ImmersiveMapTileID) -> String?)?
}

/// The one seam between the grid's drawing and whoever holds the app's
/// controller: the map view's runtime. The frame reads it once, on the
/// main thread.
protocol TileGridRenderSource: AnyObject {
    /// The grid to draw, nil when no controller is attached: then there is
    /// no grid.
    var tileGridContent: TileGridContent? { get }
}

/// No grid: the source of a renderer that was given none, a picture or a
/// video export.
final class EmptyTileGridRenderSource: TileGridRenderSource {
    var tileGridContent: TileGridContent? { nil }
}
