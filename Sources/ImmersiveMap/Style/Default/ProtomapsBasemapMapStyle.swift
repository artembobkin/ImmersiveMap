// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation

/// The built-in style: draws the Protomaps basemap tiles of the hosted
/// archive. The default for a bare `ImmersiveMapView()`, and
/// `.default.apply { ... }` is the same look with a few colours changed (see
/// `ProtomapsBasemapTheme`). A source in another schema pairs a
/// `VectorTileMapStyle` with its own schema and per-feature style instead.
public struct ProtomapsBasemapMapStyle: ImmersiveMapMapStyle {
    /// The built-in look, unchanged.
    public static let `default` = ProtomapsBasemapMapStyle()

    public let theme: ProtomapsBasemapTheme

    public var configurationFingerprint: UInt64 {
        UInt64(theme.cacheFingerprint)
    }

    /// The reading of the Protomaps basemap schema.
    public var schema: any ImmersiveMapTileSchema {
        ProtomapsBasemapSchema()
    }

    /// The rules, reading the palette and the label appearances from the
    /// theme. A public value like any other style's: an app can ask
    /// it directly what a feature draws as.
    public var vectorTileStyle: any ImmersiveMapVectorTileStyle {
        ProtomapsBasemapDefaultMapStyle(theme: theme)
    }

    public init(theme: ProtomapsBasemapTheme = .default) {
        self.theme = theme
    }

    /// The same style with the changes the closure makes to its theme.
    public func apply(_ change: (inout ProtomapsBasemapTheme) -> Void) -> ProtomapsBasemapMapStyle {
        ProtomapsBasemapMapStyle(theme: theme.apply(change))
    }
}

extension AnyImmersiveMapMapStyle {
    /// The theme of a map style that is the built-in one, for an app that
    /// reads a theme value back out of its settings; nil for any other
    /// style.
    public var basemapTheme: ProtomapsBasemapTheme? {
        (vectorTileStyle as? ProtomapsBasemapDefaultMapStyle)?.theme
    }
}

extension ImmersiveMapMapStyle where Self == ProtomapsBasemapMapStyle {
    /// The built-in style, so `.mapStyle(.default)` and
    /// `.mapStyle(.default.apply { ... })` read without the type name.
    public static var `default`: ProtomapsBasemapMapStyle { ProtomapsBasemapMapStyle.default }
}
