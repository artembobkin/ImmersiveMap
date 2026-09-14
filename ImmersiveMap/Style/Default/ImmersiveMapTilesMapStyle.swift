// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation

/// The built-in style: draws the hosted service's tiles. The default for a
/// bare `ImmersiveMapView()`; a source in another schema pairs a
/// `VectorTileMapStyle` with its own per-feature style instead.
public struct ImmersiveMapTilesMapStyle: ImmersiveMapMapStyle {
    public let configuration: ImmersiveMapTilesDefaultMapStyleConfiguration

    public var configurationFingerprint: UInt64 {
        UInt64(configuration.cacheFingerprint)
    }

    /// The reading of the hosted tiles' schema.
    public var schema: any ImmersiveMapTileSchema {
        ImmersiveMapTilesSchema()
    }

    /// The rules, reading the palette and the label appearances from the
    /// configuration. A public value like any other style's: an app can ask
    /// it directly what a feature draws as.
    public var vectorTileStyle: any ImmersiveMapVectorTileStyle {
        ImmersiveMapTilesDefaultMapStyle(configuration: configuration)
    }

    public init(configuration: ImmersiveMapTilesDefaultMapStyleConfiguration = .immersiveMapTilesDefault) {
        self.configuration = configuration
    }
}
