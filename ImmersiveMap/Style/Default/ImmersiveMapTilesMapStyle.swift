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

    public var vectorTileStyle: any ImmersiveMapVectorTileStyle {
        ImmersiveMapTilesVectorTileStyle(configuration: configuration)
    }

    public init(configuration: ImmersiveMapTilesDefaultMapStyleConfiguration = .immersiveMapTilesDefault) {
        self.configuration = configuration
    }
}

extension ImmersiveMapTilesMapStyle: ImmersiveMapMapStyleRuntime {
    func makeRuntimeMapStyle(settings: ImmersiveMapSettings.StyleSettings) -> any ImmersiveMapStyle {
        ImmersiveMapTilesDefaultMapStyle(configuration: configuration, settings: settings)
    }

    func makeLabelProfile(settings: ImmersiveMapSettings) -> any LabelStyleProfile {
        ImmersiveMapTilesLabelStyleProfile(settings: settings)
    }
}

private struct ImmersiveMapTilesVectorTileStyle: ImmersiveMapVectorTileStyle {
    let configuration: ImmersiveMapTilesDefaultMapStyleConfiguration

    var cacheFingerprint: UInt32 {
        configuration.cacheFingerprint
    }

    func makeStyle(for feature: ImmersiveMapFeatureStyleContext) -> ImmersiveMapFeatureStyle {
        .hidden
    }
}
