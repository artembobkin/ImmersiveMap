// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation

/// One download result out of a map tile and its streetscape tile.
///
/// The two are merged on the wire. A vector tile is one protobuf `Tile`
/// message whose layers are a repeated field, and the protobuf encoding
/// makes the concatenation of two messages a message whose repeated fields
/// are the concatenation of both; `MvtTileDecoder` walks the whole buffer
/// and appends every layer it meets. So the map tile's bytes followed by
/// the streetscape tile's decode as one tile carrying both layer sets, and
/// nothing between the download and the parser has to know there were two
/// requests. The parser then folds the `streetscape` layer into the road
/// layer (`MvtRoadLayerFold`).
///
/// What the streetscape's answer means:
/// - success: the merged bytes, under an ETag naming both tiles, so a
///   change in either re-prepares the tile;
/// - not found, gone, or an empty body: the archive covers only where the
///   road graph was reconstructed, so an absent streetscape tile is a fact
///   about the ground and the map tile stands alone (its ETag marked so it
///   never matches a prepared tile that was merged);
/// - anything else (a network error, a server error, a rate limit, a
///   rejected credential): the load fails and the retry backoff runs it
///   again. A map tile prepared without its streetscape because of a
///   passing failure would sit in the prepared cache, streetscape-less, for
///   the cache's whole time to live, and a key that the archive is not
///   handed out to gets one throttled warning and missing tiles rather than
///   a map that quietly looks as if the streetscape were off.
enum TileStreetscapeMerge {
    static func merge(map: TileDownloader.DownloadResult,
                      streetscape: TileDownloader.DownloadResult?) -> TileDownloader.DownloadResult {
        guard case let .success(mapData, mapETag) = map else {
            return map
        }
        switch streetscape {
        case nil, .failure(.notFound), .failure(.gone), .failure(.emptyBody):
            return .success(mapData, etag: mapETag.map { $0 + "|-" })
        case let .success(streetscapeData, streetscapeETag):
            let etag: String? = if let mapETag, let streetscapeETag {
                mapETag + "|" + streetscapeETag
            } else {
                nil
            }
            return .success(mapData + streetscapeData, etag: etag)
        case let .failure(failure):
            return .failure(failure)
        }
    }
}
