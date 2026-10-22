// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation

/// The hosted ImmersiveMap archives: one PMTiles file of vector tiles built
/// from OpenStreetMap data, under ODbL, and one of building models, both
/// read over HTTP range requests. These constants are what a bare
/// `ImmersiveMapView()` renders with, the ground relief on Mapterhorn's open
/// terrain beside them (`GroundReliefSettings.tileURLTemplate`). Pointing
/// the map elsewhere is one `.tileArchive(_:headers:)` or
/// `.modelArchive(_:headers:depthBias:)` call.
public enum ImmersiveMapTilesService {
    /// The hosted PMTiles archive. The file name carries the planet's date:
    /// a new planet is a new URL, which starts new cache namespaces. An
    /// archive may also be overwritten under one fixed name: the engine
    /// tells the uploads apart by the ETag the host gives the file, and
    /// parses again the tiles it kept from the older one.
    public static let tileArchiveURL = URL(string: "https://tiles.immersivemap.dev/20260922.pmtiles")!

    /// The deepest zoom the hosted archive ships.
    public static let maximumTileZoomLevel = 15

    /// The hosted archive of building models (`ModelArchiveSettings`), one
    /// fixed name overwritten by each bake: the engine tells the uploads
    /// apart by the ETag the host gives the file.
    public static let modelArchiveURL = URL(string: "https://tiles.immersivemap.dev/models.pmtiles")!

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

    /// The credit the data requires: OpenStreetMap, per ODbL, for the
    /// hosted archive, with the link carrying the full story. The overview
    /// the engine ships and the relief's terrain add their own credits to
    /// the line (`ImmersiveMapSettings.resolvedAttribution`,
    /// `OverviewTileSource`, `GroundReliefSettings.credit`).
    public static let attribution = ImmersiveMapAttribution(
        "© OpenStreetMap",
        linkURL: URL(string: "https://www.openstreetmap.org/copyright")
    )
}
