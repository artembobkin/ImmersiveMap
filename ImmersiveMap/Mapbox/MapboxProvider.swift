// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

public struct MapboxTileProvider: ImmersiveMapTileProvider {
    public static let defaultTilesetID = "mapbox.mapbox-streets-v8,mapbox.mapbox-terrain-v2"
    public static let defaultMaximumTileZoomLevel = 20

    public let accessToken: String?
    public let tilesetID: String

    public var id: String {
        "mapbox"
    }

    public var cacheNamespace: String {
        "mapbox"
    }

    public var configurationFingerprint: UInt64 {
        var hasher = StableFNV1aHasher()
        hasher.combine(id)
        hasher.combine(cacheNamespace)
        hasher.combine(tilesetID)
        hasher.combine(String(Self.defaultMaximumTileZoomLevel))
        return hasher.finalize()
    }

    public var tileSource: ImmersiveMapTileSource {
        .mapbox(tilesetID: tilesetID, accessToken: accessToken)
    }

    public var maximumTileZoomLevel: Int? {
        Self.defaultMaximumTileZoomLevel
    }

    public init(accessToken: String?,
                tilesetID: String = MapboxTileProvider.defaultTilesetID) {
        self.accessToken = accessToken
        self.tilesetID = tilesetID
    }
}

extension MapboxTileProvider: ImmersiveMapTileProviderRuntime {
    func makeLabelProviderProfile(settings: ImmersiveMapSettings) -> any VectorTileLabelProviderProfile {
        MapboxVectorTileLabelProviderProfile(settings: settings)
    }
}

public struct MapboxMapStyle: ImmersiveMapMapStyle {
    public let configuration: MapboxDefaultMapStyleConfiguration

    public var configurationFingerprint: UInt64 {
        UInt64(configuration.cacheFingerprint)
    }

    public var vectorTileStyle: any ImmersiveMapVectorTileStyle {
        MapboxProviderVectorTileStyle(configuration: configuration)
    }

    public init(configuration: MapboxDefaultMapStyleConfiguration = .mapboxDefault) {
        self.configuration = configuration
    }
}

extension MapboxMapStyle: ImmersiveMapMapStyleRuntime {
    func makeRuntimeMapStyle(providerID: String,
                             settings: ImmersiveMapSettings.StyleSettings) -> any ImmersiveMapStyle {
        MapboxDefaultMapStyle(configuration: configuration, settings: settings)
    }
}

private struct MapboxProviderVectorTileStyle: ImmersiveMapVectorTileStyle {
    let configuration: MapboxDefaultMapStyleConfiguration

    var cacheFingerprint: UInt32 {
        configuration.cacheFingerprint
    }

    func makeStyle(for feature: ImmersiveMapFeatureStyleContext) -> ImmersiveMapFeatureStyle {
        .hidden
    }
}
