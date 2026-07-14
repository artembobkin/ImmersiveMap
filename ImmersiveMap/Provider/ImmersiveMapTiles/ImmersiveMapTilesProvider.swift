// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation

/// Third first-party provider: self-hosted OpenMapTiles-schema vector tiles
/// (the ImmersiveMap Tiles service backed by an OpenFreeMap planet). Rendered by
/// `ImmersiveMapTilesDefaultMapStyle`, styled in the spirit of the Mapbox default but
/// reading the OpenMapTiles layer/field contract.
public struct ImmersiveMapTilesProvider: ImmersiveMapTileProvider {
    public static let defaultMaximumTileZoomLevel = 14

    /// Base URL of the hosted ImmersiveMap Tiles service. Used as the out-of-the-box
    /// default so a bare `ImmersiveMapView()` renders without any provider wiring.
    public static let defaultTileBaseURL = URL(string: "https://tiles.immersivemap.dev/tiles")!

    /// TileJSON endpoint of the hosted service. The loader reads the versioned,
    /// immutable tile URL template from here so tiles are fetched over the CDN-
    /// cacheable `/v/<version>/…` path instead of the always-revalidated base path.
    public static let defaultTileJSONURL = URL(string: "https://tiles.immersivemap.dev/tiles.json")!

    /// Manifest URL of the hosted night-lights tile set served alongside the tiles.
    public static let defaultNightLightsManifestURL = URL(string: "https://tiles.immersivemap.dev/night-lights/v1/night_lights_manifest.json")!

    /// Manual "invalidate every cached tile" lever: bump to force all clients to
    /// re-fetch and re-parse. Routine content updates at a stable URL no longer need
    /// a bump - the prepared cache is keyed by the raw tile's ETag and raw tiles
    /// revalidate via URLCache, so a changed tile self-invalidates end to end.
    public static let contentRevision = 3

    public let tileBaseURL: URL
    public let apiKey: String?

    public var id: String { "immersivemaptiles" }

    public var cacheNamespace: String { "immersivemaptiles" }

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
        .immersiveMapTiles(tileBaseURL: tileBaseURL, apiKey: apiKey)
    }

    public var maximumTileZoomLevel: Int? {
        Self.defaultMaximumTileZoomLevel
    }

    /// - Parameters:
    ///   - tileBaseURL: base of the tile endpoint, e.g. `http://host:8080/tiles`.
    ///     The loader appends `/{z}/{x}/{y}.mvt`. Defaults to the hosted service.
    ///   - apiKey: optional API key, sent as `?key=`.
    public init(tileBaseURL: URL = ImmersiveMapTilesProvider.defaultTileBaseURL, apiKey: String? = nil) {
        self.tileBaseURL = tileBaseURL
        self.apiKey = apiKey
    }
}

extension ImmersiveMapTilesProvider: ImmersiveMapTileProviderRuntime {
    func makeLabelProviderProfile(settings: ImmersiveMapSettings) -> any VectorTileLabelProviderProfile {
        ImmersiveMapTilesVectorTileLabelProviderProfile(settings: settings)
    }
}

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
    func makeRuntimeMapStyle(providerID: String,
                             settings: ImmersiveMapSettings.StyleSettings) -> any ImmersiveMapStyle {
        ImmersiveMapTilesDefaultMapStyle(configuration: configuration, settings: settings)
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
