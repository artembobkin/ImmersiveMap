// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation
import PMTiles
import os

/// The overview of the globe the engine ships: a small PMTiles archive in
/// the package's resources (`Resources/overview.pmtiles`, under a megabyte)
/// whose tiles are laid into the map's own tiles at the zooms it covers,
/// tile zoom 0 to 7, the zooms the tile service ships its land cover for.
/// That land cover is vectorised from a raster, blobs with thousands of
/// holes between them, and the globe looked moth-eaten. The overview paints
/// the land by hand-drawn boundaries instead, the land cover draws its
/// forests and fields over the painting from the country zooms, with the
/// biome showing through its holes, and the tiles keep everything else of
/// theirs: the coast, the ocean, the lakes, the borders and the names.
///
/// The archive is two layers of polygons and one of lines in the tile's
/// own space. `biome`
/// is the fourteen biomes of RESOLVE Ecoregions 2017 (CC BY 4.0, credited
/// by `credit`), each dissolved into one
/// feature per tile, with a fifth of the source's vertices and thinned per
/// zoom by the bake, so the deepest tiles carry the valleys and the globe's
/// tile stays small, and with `kind` naming the biome
/// (`tropical_moist_forest`, `boreal_forest`, `desert`, `tundra` and the
/// rest, listed where they are coloured, `ProtomapsBasemapTheme.BiomeStyles`).
/// The biomes are fitted to the Natural Earth 1:50m coast the Protomaps
/// basemap draws through tile zoom 4, so they meet the tiles' own shore
/// without a rim, every island with them: they paint no ice, so the
/// glaciers of Greenland and Antarctica are left to the tiles' own glacier
/// polygons, which stay. `lake` is the Natural Earth 1:110m lakes at tile
/// zoom 0 alone, since the basemap's lakes start at zoom 1 and the Caspian
/// and the Great Lakes were land on the globe. `road` is the Natural Earth
/// 1:10m road network at tile zooms 2 to 5, with `kind` (the type) and
/// `rank` (the scalerank, 3 continental to 7 regional, which decides the
/// first zoom of a road), since the basemap's roads at those zooms are the
/// motorways alone and the trunks arrive at zoom 6: the style draws the
/// network in their place (`ProtomapsBasemapTheme.OverviewRoadStyles`).
///
/// The merge is bytes. An MVT tile is a protobuf message of repeated
/// `layer` fields, so the overview tile's bytes appended to the map tile's
/// are one well-formed tile carrying both tiles' layers, and the parser sees
/// one tile (`DefaultTileLoadPipeline.download`). Nothing here knows what a
/// layer means: the style reads the new layers by name and decides what of
/// the tiles' own land cover gives way to them
/// (`ProtomapsBasemapDefaultMapStyle.biomeStyle`), and a style that does not
/// name them draws nothing of them.
///
/// The archive is baked by `Tools/Overview/bake_overview.sh` (mapshaper and
/// tippecanoe over the published RESOLVE and Natural Earth files, outside
/// the SwiftPM build) and is a contract
/// with the style: its layer names and kinds are the style's rules. A new
/// archive bumps `PreparedTileDiskCaching.preparedFormatVersion`, since
/// the prepared tiles bake its polygons, and the setting
/// (`ImmersiveMapSettings.TileSettings.OverviewSettings`) is part of the
/// prepared tiles' identity.
///
/// `@unchecked Sendable`: the one stored property is immutable after
/// `init`, and the archive client synchronises its own state.
final class OverviewTileSource: @unchecked Sendable {
    private static let logger = Logger(subsystem: "ImmersiveMap", category: "Tiles")

    /// The credit the biomes' license (CC BY 4.0) asks for, laid on the
    /// attribution line after the tile source's own while the overview is
    /// on (`ImmersiveMapSettings.resolvedAttribution`), at the camera zooms
    /// up to `maximumZoom`, the zoom the style has faded the biomes out by
    /// (`TileSettings.OverviewSettings.creditMaximumZoom`). Natural Earth,
    /// the coast the biomes are fitted to and the lakes, is public domain
    /// and asks for none.
    static func credit(maximumZoom: Double) -> ImmersiveMapAttribution.Credit {
        ImmersiveMapAttribution.Credit(creditText, zoomRange: 0..<maximumZoom)
    }

    static let creditText = "Biomes © RESOLVE, CC BY 4.0"

    /// The resource's name in the package bundle.
    static let resourceName = "overview"
    static let resourceExtension = "pmtiles"

    private let archive: PMTilesArchiveClient

    /// The archive shipped in the package, or nil when the bundle lacks the
    /// resource, which is logged: the map then draws the tiles' own land
    /// cover, as it did before the overview.
    static func bundled() -> OverviewTileSource? {
        guard let archiveURL = Bundle.module.url(forResource: resourceName, withExtension: resourceExtension) else {
            logger.warning("ImmersiveMap: the overview archive \(resourceName, privacy: .public).\(resourceExtension, privacy: .public) is missing from the package resources, so the overview zooms draw the tile source's own land cover.")
            return nil
        }
        return OverviewTileSource(archiveURL: archiveURL)
    }

    /// An overview read from the archive at the URL, on disk or over the
    /// network: the tests write their own.
    init(archiveURL: URL) {
        archive = PMTilesArchiveClient(archiveURL: archiveURL,
                                       requestHeaders: [:],
                                       session: .shared)
    }

    /// The overview's bytes for the tile, decompressed, or nil: a tile zoom
    /// past the archive's, a tile the archive does not carry (open ocean),
    /// or an archive that cannot be read, which is logged once a minute.
    func tileBytes(_ tile: Tile) async -> Data? {
        do {
            guard case let .tile(data, _) = try await archive.tileBytes(z: tile.z, x: tile.x, y: tile.y),
                  data.isEmpty == false else {
                return nil
            }
            return data
        } catch {
            if TileNoticeThrottle.overviewUnreadable.shouldLog() {
                Self.logger.warning("ImmersiveMap: the overview archive could not be read (\(String(describing: error), privacy: .public)), so the overview zooms draw the tile source's own land cover.")
            }
            return nil
        }
    }

    /// The map tile's bytes with the overview's layers laid in: the
    /// overview's message appended to the tile's, which protobuf reads as
    /// one message whose `layer` fields are both tiles' in order.
    static func merge(mapTile: Data, overview: Data) -> Data {
        var merged = Data(capacity: mapTile.count + overview.count)
        merged.append(mapTile)
        merged.append(overview)
        return merged
    }
}
