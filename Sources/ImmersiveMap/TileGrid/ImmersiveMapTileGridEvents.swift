// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

import CoreGraphics

/// A change of the tiles selected on the grid, by a tap or from code.
public struct ImmersiveMapTileGridSelectionChange: Sendable {
    /// Every selected tile after the change.
    public let selectedTiles: Set<ImmersiveMapTileID>
    /// The tiles the change selected.
    public let added: Set<ImmersiveMapTileID>
    /// The tiles the change deselected.
    public let removed: Set<ImmersiveMapTileID>
    /// Who made the change: `.tap` for the user, `.programmatic` for the
    /// app's own call.
    public let source: ImmersiveMapSelectionSource
}

/// A tap on a tile of the grid that selected nothing.
public struct ImmersiveMapTileGridTapRejection: Sendable {
    public enum Reason: Equatable, Sendable {
        /// As many tiles are selected as `TileGridSettings.selectionLimit`
        /// allows.
        case limitReached(limit: Int)
        /// The tile lies outside `TileGridSettings.selectableBounds`.
        case outsideSelectableBounds
    }

    /// The tile under the tap.
    public let tile: ImmersiveMapTileID
    public let reason: Reason
    /// The place on the map under the tap.
    public let coordinate: GeoCoordinate
    /// The tap in the map view's points, origin top-left.
    public let screenPoint: CGPoint
}
