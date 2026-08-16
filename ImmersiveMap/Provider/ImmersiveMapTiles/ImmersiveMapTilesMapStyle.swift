// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation

/// The built-in style: draws OpenMapTiles-schema vector tiles (the schema the
/// hosted service and any self-hosted OpenFreeMap/OpenMapTiles planet build
/// serve). The default for a bare `ImmersiveMapView()`; a source in another
/// schema pairs a `VectorTileMapStyle` with its own per-feature style instead.
public struct ImmersiveMapTilesMapStyle: ImmersiveMapMapStyle {
    public let configuration: ImmersiveMapTilesDefaultMapStyleConfiguration

    public var configurationFingerprint: UInt64 {
        UInt64(configuration.cacheFingerprint)
    }

    public var vectorTileStyle: any ImmersiveMapVectorTileStyle {
        ImmersiveMapTilesProviderVectorTileStyle(configuration: configuration)
    }

    public init(configuration: ImmersiveMapTilesDefaultMapStyleConfiguration = .immersiveMapTilesDefault) {
        self.configuration = configuration
    }
}

extension ImmersiveMapTilesMapStyle: ImmersiveMapMapStyleRuntime {
    func makeRuntimeMapStyle(settings: ImmersiveMapSettings.StyleSettings) -> any ImmersiveMapStyle {
        ImmersiveMapTilesDefaultMapStyle(configuration: configuration, settings: settings)
    }

    func makeLabelProviderProfile(settings: ImmersiveMapSettings) -> any VectorTileLabelProviderProfile {
        ImmersiveMapTilesVectorTileLabelProviderProfile(settings: settings)
    }
}

private struct ImmersiveMapTilesProviderVectorTileStyle: ImmersiveMapVectorTileStyle {
    let configuration: ImmersiveMapTilesDefaultMapStyleConfiguration

    var cacheFingerprint: UInt32 {
        configuration.cacheFingerprint
    }

    func makeStyle(for feature: ImmersiveMapFeatureStyleContext) -> ImmersiveMapFeatureStyle {
        .hidden
    }
}
