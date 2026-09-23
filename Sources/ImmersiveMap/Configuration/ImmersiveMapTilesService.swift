// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation

/// The hosted ImmersiveMap tile archive: one PMTiles file of vector tiles
/// built from OpenStreetMap data, under ODbL, read over HTTP range requests.
/// These constants are what a bare `ImmersiveMapView()` renders with. Pointing
/// the map elsewhere is one `.tileArchive(_:headers:)` call.
public enum ImmersiveMapTilesService {
    /// The hosted PMTiles archive. The file name carries the planet's date:
    /// a new planet is a new URL, which starts new cache namespaces.
    public static let tileArchiveURL = URL(string: "https://tiles.immersivemap.dev/20260922.pmtiles")!

    /// The deepest zoom the hosted archive ships.
    public static let maximumTileZoomLevel = 15

    /// Manual "invalidate every cached tile" lever: bump to force all clients
    /// to re-fetch and re-parse. A new planet at a new URL does not need a
    /// bump, the URL is in the cache identity already.
    static let contentRevision = 4

    /// Folded into `NetworkSettings.cacheIdentity` for the default source, so a
    /// `contentRevision` bump lands in both disk-cache namespaces.
    static var cacheIdentity: UInt64 {
        var hasher = StableFNV1aHasher()
        hasher.combine("immersivemaptiles")
        hasher.combine(tileArchiveURL.absoluteString)
        hasher.combine(String(maximumTileZoomLevel))
        hasher.combine(String(contentRevision))
        return hasher.finalize()
    }

    /// The credit the hosted data requires: OpenStreetMap, per ODbL, and the
    /// link carries the full story.
    public static let attribution = ImmersiveMapAttribution(
        title: "© OpenStreetMap",
        copyright: "",
        linkURL: URL(string: "https://www.openstreetmap.org/copyright")
    )
}
