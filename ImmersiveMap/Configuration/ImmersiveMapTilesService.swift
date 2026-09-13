// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation

/// The hosted ImmersiveMap Tiles service: vector tiles built by the
/// ImmersiveMap tile pipeline from OpenStreetMap data, under ODbL.
/// These constants are what a bare `ImmersiveMapView()` renders with; pointing
/// the map elsewhere is one `.tileURLTemplate(_:headers:)` call.
public enum ImmersiveMapTilesService {
    /// Base URL of the hosted tile endpoint. The loader appends
    /// `/{z}/{x}/{y}.mvt`.
    public static let tileBaseURL = URL(string: "https://immersivemap.dev/tiles")!

    /// The deepest zoom the hosted planet build ships.
    public static let maximumTileZoomLevel = 16

    /// The streetscape archive: the measured carriageway surfaces and road
    /// paint, served next to the map tiles for the keys that ask for it and
    /// requested only when `ImmersiveMapView.streetscape(isEnabled:)` is on.
    public static let streetscapeTileURLTemplate = "https://immersivemap.dev/tiles/streetscape/{z}/{x}/{y}.mvt"

    /// The first tile zoom the streetscape archive covers; it runs to
    /// `maximumTileZoomLevel`.
    public static let streetscapeMinimumTileZoom = 15

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

    /// The credit the hosted data requires: OpenStreetMap, per ODbL, and the
    /// link carries the full story. Nothing else is owed. The tiles are built
    /// by the ImmersiveMap tile pipeline in a schema of its own, so there is
    /// no second party whose terms ask to be named; the badge used to add
    /// "© OpenMapTiles" back when the planet was an OpenFreeMap build in that
    /// project's schema.
    public static let attribution = ImmersiveMapAttribution(
        title: "© OpenStreetMap",
        copyright: "",
        linkURL: URL(string: "https://www.openstreetmap.org/copyright")
    )
}
