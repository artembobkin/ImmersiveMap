// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation

/// The built-in style: draws the hosted service's tiles. The default for a
/// bare `ImmersiveMapView()`, and `.default.apply { ... }` is the same look
/// with a few colours changed (see `ImmersiveMapTilesTheme`). A source in
/// another schema pairs a `VectorTileMapStyle` with its own per-feature
/// style instead.
public struct ImmersiveMapTilesMapStyle: ImmersiveMapMapStyle {
    /// The built-in look, unchanged.
    public static let `default` = ImmersiveMapTilesMapStyle()

    public let theme: ImmersiveMapTilesTheme

    public var configurationFingerprint: UInt64 {
        UInt64(theme.cacheFingerprint)
    }

    /// The reading of the hosted tiles' schema.
    public var schema: any ImmersiveMapTileSchema {
        ImmersiveMapTilesSchema()
    }

    /// The rules, reading the palette and the label appearances from the
    /// theme. A public value like any other style's: an app can ask
    /// it directly what a feature draws as.
    public var vectorTileStyle: any ImmersiveMapVectorTileStyle {
        ImmersiveMapTilesDefaultMapStyle(theme: theme)
    }

    public init(theme: ImmersiveMapTilesTheme = .default) {
        self.theme = theme
    }

    /// The same style with the changes the closure makes to its theme.
    public func apply(_ change: (inout ImmersiveMapTilesTheme) -> Void) -> ImmersiveMapTilesMapStyle {
        ImmersiveMapTilesMapStyle(theme: theme.apply(change))
    }
}

extension AnyImmersiveMapMapStyle {
    /// The theme of a map style that is the built-in one, for an app that
    /// reads a theme value back out of its settings; nil for any other
    /// style.
    public var tilesTheme: ImmersiveMapTilesTheme? {
        (vectorTileStyle as? ImmersiveMapTilesDefaultMapStyle)?.theme
    }
}

extension ImmersiveMapMapStyle where Self == ImmersiveMapTilesMapStyle {
    /// The built-in style, so `.mapStyle(.default)` and
    /// `.mapStyle(.default.apply { ... })` read without the type name.
    public static var `default`: ImmersiveMapTilesMapStyle { ImmersiveMapTilesMapStyle.default }
}
