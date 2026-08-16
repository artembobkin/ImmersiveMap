// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation

/// The hosted ImmersiveMap Tiles service: OpenMapTiles-schema vector tiles
/// from an OpenFreeMap planet build, which is OpenStreetMap data under ODbL.
/// These constants are what a bare `ImmersiveMapView()` renders with; pointing
/// the map elsewhere is one `.tileURLTemplate(_:headers:)` call.
public enum ImmersiveMapTilesService {
    /// Base URL of the hosted tile endpoint. The loader appends
    /// `/{z}/{x}/{y}.mvt`.
    public static let tileBaseURL = URL(string: "https://tiles.immersivemap.dev/tiles")!

    /// TileJSON endpoint of the hosted service. The loader reads the versioned,
    /// immutable tile URL template from here so tiles are fetched over the CDN-
    /// cacheable `/v/<version>/…` path instead of the always-revalidated base path.
    public static let tileJSONURL = URL(string: "https://tiles.immersivemap.dev/tiles.json")!

    /// The deepest zoom the hosted planet build ships.
    public static let maximumTileZoomLevel = 14

    /// Manual "invalidate every cached tile" lever: bump to force all clients to
    /// re-fetch and re-parse. Routine content updates at a stable URL do not need
    /// a bump - the prepared cache is keyed by the raw tile's ETag and raw tiles
    /// revalidate via URLCache, so a changed tile self-invalidates end to end.
    static let contentRevision = 3

    /// Folded into `NetworkSettings.cacheIdentity` for the default source, so a
    /// `contentRevision` bump lands in both disk-cache namespaces.
    static var cacheIdentity: UInt64 {
        var hasher = StableFNV1aHasher()
        hasher.combine("immersivemaptiles")
        hasher.combine(tileBaseURL.absoluteString)
        hasher.combine(String(maximumTileZoomLevel))
        hasher.combine(String(contentRevision))
        return hasher.finalize()
    }

    /// The credit the hosted data requires: the data (OpenStreetMap, per ODbL)
    /// and the schema (OpenMapTiles, per its attribution terms); the link
    /// carries the full story. OpenFreeMap asks for no credit of its own.
    public static let attribution = ImmersiveMapAttribution(
        title: "© OpenStreetMap © OpenMapTiles",
        copyright: "",
        linkURL: URL(string: "https://www.openstreetmap.org/copyright")
    )
}
