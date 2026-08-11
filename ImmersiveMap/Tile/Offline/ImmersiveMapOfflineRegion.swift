// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation

/// A geographic rectangle plus a zoom span, describing the tiles an app wants
/// available without a network connection.
///
/// The region covers every tile that overlaps the rectangle at every zoom in
/// `zoomLevels`, edges included. Low zooms are almost free (a city occupies a
/// single tile per zoom below ~10), so a range starting at 0 keeps the map
/// usable while zooming out over a downloaded area; the cost of a region is
/// dominated by its top zoom level.
///
/// A region whose west edge is east of its east edge crosses the antimeridian
/// and is handled as such; a region whose south edge is north of its north
/// edge is empty.
public struct ImmersiveMapOfflineRegion: Hashable, Codable, Sendable, Identifiable {
    /// Stable identifier of the region. Downloading again under the same id
    /// resumes or refreshes the same on-disk region instead of creating a
    /// second one, and the id is how a region is cancelled and removed.
    public var id: String
    public var southWest: GeoCoordinate
    public var northEast: GeoCoordinate
    /// Zoom levels to download. Clamped at download time to the tile
    /// provider's `maximumTileZoomLevel`, past which the renderer never
    /// requests tiles anyway (it overzooms by stretching).
    public var zoomLevels: ClosedRange<Int>

    public init(id: String,
                southWest: GeoCoordinate,
                northEast: GeoCoordinate,
                zoomLevels: ClosedRange<Int>) {
        self.id = id
        self.southWest = southWest
        self.northEast = northEast
        self.zoomLevels = zoomLevels
    }

    /// Number of tiles the region covers as declared. The download itself may
    /// expect fewer: zoom levels above the provider maximum are clamped away.
    public var tileCount: Int {
        OfflineRegionTileMath.tileCount(in: self)
    }

    func clampingZoomLevels(toMaximum maximumZoomLevel: Int?) -> ImmersiveMapOfflineRegion {
        guard let maximumZoomLevel else {
            return self
        }
        var region = self
        let lowerBound = min(zoomLevels.lowerBound, maximumZoomLevel)
        let upperBound = min(zoomLevels.upperBound, maximumZoomLevel)
        region.zoomLevels = max(lowerBound, 0)...max(upperBound, 0)
        return region
    }
}

/// Validation failures thrown by `ImmersiveMapOfflineController.download(_:)`
/// before any network work starts.
public enum ImmersiveMapOfflineError: Error, Equatable, Sendable {
    /// The region covers no tiles (inverted latitudes or an empty zoom range
    /// after clamping).
    case emptyRegion
    /// The region covers more tiles than
    /// `ImmersiveMapOfflineController.maximumTileCountPerDownload` allows.
    case regionTooLarge(tileCount: Int, maximumTileCount: Int)
}

/// A stored or downloading region together with its on-disk progress.
public struct ImmersiveMapOfflineRegionStatus: Equatable, Sendable, Identifiable {
    public enum Phase: Equatable, Sendable {
        case downloading
        /// Every expected tile is on disk.
        case complete
        /// Some tiles are missing: the download was cancelled, interrupted,
        /// or some tiles failed. Downloading the region again fetches only
        /// what is missing.
        case incomplete
    }

    public let region: ImmersiveMapOfflineRegion
    public let phase: Phase
    /// Tiles the download expects after clamping to the provider's maximum
    /// zoom level.
    public let expectedTileCount: Int
    /// Tiles already on disk, including tiles the source reported as empty.
    public let storedTileCount: Int
    /// Tiles the last download run gave up on after retries.
    public let failedTileCount: Int
    /// Bytes of tile data on disk for this region. Tiles shared with an
    /// overlapping region are counted in both.
    public let byteCount: Int64
    /// The last download run stopped because tile requests were not
    /// authorized (401/403/missing token). Downloading again with the same
    /// credentials will stop the same way; surface it instead of a retry
    /// button.
    public let isBlockedByAuthorization: Bool

    public var id: String { region.id }

    public var fractionCompleted: Double {
        guard expectedTileCount > 0 else {
            return 0
        }
        return min(1, Double(storedTileCount) / Double(expectedTileCount))
    }
}
