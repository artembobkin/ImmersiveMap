// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

import Foundation

/// Third first-party provider: self-hosted OpenMapTiles-schema vector tiles
/// (the ImmersiveMap Tiles service backed by an OpenFreeMap planet). Rendered by
/// `OpenMapTilesDefaultMapStyle`, styled in the spirit of the Mapbox default but
/// reading the OpenMapTiles layer/field contract.
public struct OpenMapTilesTileProvider: ImmersiveMapTileProvider {
    public static let defaultMaximumTileZoomLevel = 14

    /// Manual "invalidate every cached tile" lever: bump to force all clients to
    /// re-fetch and re-parse. Routine content updates at a stable URL no longer need
    /// a bump - the prepared cache is keyed by the raw tile's ETag and raw tiles
    /// revalidate via URLCache, so a changed tile self-invalidates end to end.
    public static let contentRevision = 3

    public let tileBaseURL: URL
    public let apiKey: String?

    public var id: String { "openmaptiles" }

    public var cacheNamespace: String { "openmaptiles" }

    public var configurationFingerprint: UInt64 {
        var hasher = StableFNV1aHasher()
        hasher.combine(id)
        hasher.combine(cacheNamespace)
        hasher.combine(tileBaseURL.absoluteString)
        hasher.combine(apiKey ?? "")
        hasher.combine(String(Self.defaultMaximumTileZoomLevel))
        hasher.combine(String(Self.contentRevision))
        return hasher.finalize()
    }

    public var tileSource: ImmersiveMapTileSource {
        .openMapTiles(tileBaseURL: tileBaseURL, apiKey: apiKey)
    }

    public var maximumTileZoomLevel: Int? {
        Self.defaultMaximumTileZoomLevel
    }

    /// - Parameters:
    ///   - tileBaseURL: base of the tile endpoint, e.g. `http://host:8080/tiles`.
    ///     The loader appends `/{z}/{x}/{y}.mvt`.
    ///   - apiKey: optional API key, sent as `?key=`.
    public init(tileBaseURL: URL, apiKey: String? = nil) {
        self.tileBaseURL = tileBaseURL
        self.apiKey = apiKey
    }
}

extension OpenMapTilesTileProvider: ImmersiveMapTileProviderRuntime {
    func makeLabelProviderProfile(settings: ImmersiveMapSettings) -> any VectorTileLabelProviderProfile {
        OpenMapTilesVectorTileLabelProviderProfile(settings: settings)
    }
}

public struct OpenMapTilesMapStyle: ImmersiveMapMapStyle {
    public let configuration: OpenMapTilesDefaultMapStyleConfiguration

    public var configurationFingerprint: UInt64 {
        UInt64(configuration.cacheFingerprint)
    }

    public var vectorTileStyle: any ImmersiveMapVectorTileStyle {
        OpenMapTilesProviderVectorTileStyle(configuration: configuration)
    }

    public init(configuration: OpenMapTilesDefaultMapStyleConfiguration = .openMapTilesDefault) {
        self.configuration = configuration
    }
}

extension OpenMapTilesMapStyle: ImmersiveMapMapStyleRuntime {
    func makeRuntimeMapStyle(providerID: String,
                             settings: ImmersiveMapSettings.StyleSettings) -> any ImmersiveMapStyle {
        OpenMapTilesDefaultMapStyle(configuration: configuration, settings: settings)
    }
}

private struct OpenMapTilesProviderVectorTileStyle: ImmersiveMapVectorTileStyle {
    let configuration: OpenMapTilesDefaultMapStyleConfiguration

    var cacheFingerprint: UInt32 {
        configuration.cacheFingerprint
    }

    func makeStyle(for feature: ImmersiveMapFeatureStyleContext) -> ImmersiveMapFeatureStyle {
        .hidden
    }
}
