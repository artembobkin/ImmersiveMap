// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation

/// The first-party provider: OpenMapTiles-schema vector tiles from the
/// ImmersiveMap Tiles service (backed by an OpenFreeMap planet) or a self-hosted
/// endpoint with the same contract. Rendered by `ImmersiveMapTilesDefaultMapStyle`,
/// which reads the OpenMapTiles layer/field contract.
public struct ImmersiveMapTilesProvider: ImmersiveMapTileProvider {
    public static let defaultMaximumTileZoomLevel = 14

    /// Base URL of the hosted ImmersiveMap Tiles service. Used as the out-of-the-box
    /// default so a bare `ImmersiveMapView()` renders without any provider wiring.
    public static let defaultTileBaseURL = URL(string: "https://tiles.immersivemap.dev/tiles")!

    /// TileJSON endpoint of the hosted service. The loader reads the versioned,
    /// immutable tile URL template from here so tiles are fetched over the CDN-
    /// cacheable `/v/<version>/…` path instead of the always-revalidated base path.
    public static let defaultTileJSONURL = URL(string: "https://tiles.immersivemap.dev/tiles.json")!

    /// Manual "invalidate every cached tile" lever: bump to force all clients to
    /// re-fetch and re-parse. Routine content updates at a stable URL no longer need
    /// a bump - the prepared cache is keyed by the raw tile's ETag and raw tiles
    /// revalidate via URLCache, so a changed tile self-invalidates end to end.
    public static let contentRevision = 3

    public let tileBaseURL: URL
    // Set by `init(tileSource:)`; when present, `tileSource` returns it verbatim
    // instead of deriving the hosted-service source from `tileBaseURL`.
    private let overrideTileSource: ImmersiveMapTileSource?

    public var id: String { "immersivemaptiles" }

    public var cacheNamespace: String { "immersivemaptiles" }

    public var configurationFingerprint: UInt64 {
        var hasher = StableFNV1aHasher()
        hasher.combine(id)
        hasher.combine(cacheNamespace)
        hasher.combine(tileBaseURL.absoluteString)
        if let overrideTileSource {
            hasher.combine(overrideTileSource.urlTemplate ?? "")
            for field in overrideTileSource.headers.keys.sorted() {
                hasher.combine("header:\(field)")
            }
        }
        hasher.combine(String(Self.defaultMaximumTileZoomLevel))
        hasher.combine(String(Self.contentRevision))
        return hasher.finalize()
    }

    public var tileSource: ImmersiveMapTileSource {
        overrideTileSource ?? .immersiveMapTiles(tileBaseURL: tileBaseURL)
    }

    public var maximumTileZoomLevel: Int? {
        Self.defaultMaximumTileZoomLevel
    }

    /// The hosted service serves an OpenFreeMap planet build in the OpenMapTiles
    /// schema, which is OpenStreetMap data under ODbL. The one-line credit names
    /// the data (OpenStreetMap, per ODbL) and the schema (OpenMapTiles, per its
    /// attribution terms); the link carries the full story. OpenFreeMap asks for
    /// no credit of its own.
    public var attribution: ImmersiveMapAttribution {
        ImmersiveMapAttribution(
            title: "© OpenStreetMap © OpenMapTiles",
            copyright: "",
            linkURL: URL(string: "https://www.openstreetmap.org/copyright")
        )
    }

    /// - Parameter tileBaseURL: base of the tile endpoint, e.g.
    ///   `http://host:8080/tiles`. The loader appends `/{z}/{x}/{y}.mvt`.
    ///   Defaults to the hosted service. An endpoint that needs credentials or
    ///   its own URL shape is configured through `init(tileSource:)` instead.
    public init(tileBaseURL: URL = ImmersiveMapTilesProvider.defaultTileBaseURL) {
        self.tileBaseURL = tileBaseURL
        self.overrideTileSource = nil
    }

    /// Runs the built-in OpenMapTiles-schema style over any endpoint described
    /// by a full tile source: a URL template (`.template("https://…/{x}/{y}/{z}")`),
    /// custom request headers, or a TileJSON endpoint. The endpoint must serve
    /// OpenMapTiles-schema MVT for the default style to have something to draw;
    /// for another schema pair a `VectorTileProvider` with your own style
    /// instead.
    public init(tileSource: ImmersiveMapTileSource) {
        self.tileBaseURL = tileSource.tileBaseURL
        self.overrideTileSource = tileSource
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
