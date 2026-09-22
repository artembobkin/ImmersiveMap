// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation

/// Converts an offline region's geographic rectangle into concrete tile
/// coordinates per zoom level, using the same Web Mercator conventions as the
/// renderer (`ImmersiveMapProjection`): normalized x from longitude, y growing
/// southward with tile row 0 at the north edge.
enum OfflineRegionTileMath {
    /// Hard ceiling on zoom arithmetic. Real tile sources stop far below it
    /// (the deepest provider in the package serves z20), and past z30 the
    /// per-zoom tile counts approach `Int.max`, so a nonsense zoom range in a
    /// public `ImmersiveMapOfflineRegion` must clamp here rather than trap in
    /// count arithmetic.
    static let maximumSupportedZoomLevel = 30

    struct ZoomCoverage: Equatable, Sendable {
        let zoom: Int
        /// One range normally; two when the region crosses the antimeridian.
        let xRanges: [ClosedRange<Int>]
        let yRange: ClosedRange<Int>

        var tileCount: Int {
            let columns = xRanges.reduce(0) { $0 + $1.count }
            return columns * yRange.count
        }
    }

    static func coverage(of region: ImmersiveMapOfflineRegion) -> [ZoomCoverage] {
        // A non-finite coordinate would reach `Int(floor(...))` and trap;
        // public input degrades to an empty region instead of crashing.
        guard region.southWest.latitude.isFinite,
              region.southWest.longitude.isFinite,
              region.northEast.latitude.isFinite,
              region.northEast.longitude.isFinite,
              region.southWest.latitude <= region.northEast.latitude else {
            return []
        }
        let maximumLatitude = ImmersiveMapProjection.maxMercatorLatitude * 180.0 / .pi
        let northLatitude = min(max(region.northEast.latitude, -maximumLatitude), maximumLatitude)
        let southLatitude = min(max(region.southWest.latitude, -maximumLatitude), maximumLatitude)
        let topY = normalizedY(latitudeDegrees: northLatitude)
        let bottomY = normalizedY(latitudeDegrees: southLatitude)

        let coversFullWorld = region.northEast.longitude - region.southWest.longitude >= 360
        let westLongitude = normalizedWestLongitude(region.southWest.longitude)
        let eastLongitude = normalizedEastLongitude(region.northEast.longitude)
        let crossesAntimeridian = coversFullWorld == false && eastLongitude < westLongitude

        let lowestZoom = min(max(region.zoomLevels.lowerBound, 0), Self.maximumSupportedZoomLevel)
        let highestZoom = min(region.zoomLevels.upperBound, Self.maximumSupportedZoomLevel)
        guard lowestZoom <= highestZoom else {
            return []
        }

        return (lowestZoom...highestZoom).map { zoom in
            let tilesPerAxis = 1 << zoom
            let yRange = tileIndex(topY, tilesPerAxis: tilesPerAxis)...tileIndex(bottomY, tilesPerAxis: tilesPerAxis)

            let xRanges: [ClosedRange<Int>]
            if coversFullWorld {
                xRanges = [0...(tilesPerAxis - 1)]
            } else {
                let westIndex = tileIndex(normalizedX(longitudeDegrees: westLongitude),
                                          tilesPerAxis: tilesPerAxis)
                let eastIndex = tileIndex(normalizedX(longitudeDegrees: eastLongitude),
                                          tilesPerAxis: tilesPerAxis)
                if crossesAntimeridian {
                    // At coarse zooms the two sides of the antimeridian meet in
                    // the same tiles; a merged full row avoids counting them twice.
                    if eastIndex + 1 >= westIndex {
                        xRanges = [0...(tilesPerAxis - 1)]
                    } else {
                        xRanges = [westIndex...(tilesPerAxis - 1), 0...eastIndex]
                    }
                } else {
                    xRanges = [westIndex...max(eastIndex, westIndex)]
                }
            }
            return ZoomCoverage(zoom: zoom, xRanges: xRanges, yRange: yRange)
        }
    }

    static func tileCount(in region: ImmersiveMapOfflineRegion) -> Int {
        coverage(of: region).reduce(0) { $0 + $1.tileCount }
    }

    /// All tiles of the region, coarse zoom levels first so a download becomes
    /// usable from the top down, rows north to south within a zoom.
    static func tiles(in region: ImmersiveMapOfflineRegion) -> [Tile] {
        var tiles: [Tile] = []
        for zoomCoverage in coverage(of: region) {
            for y in zoomCoverage.yRange {
                for xRange in zoomCoverage.xRanges {
                    for x in xRange {
                        tiles.append(Tile(x: x, y: y, z: zoomCoverage.zoom))
                    }
                }
            }
        }
        return tiles
    }

    static func tileSet(in region: ImmersiveMapOfflineRegion) -> Set<Tile> {
        Set(tiles(in: region))
    }

    /// Normalized Web Mercator x in `0...1` for a longitude already normalized
    /// into `[-180, 180]`. Unlike `ImmersiveMapProjection.worldMercator`, the
    /// east edge maps to 1 rather than wrapping to 0, so a range ending at
    /// longitude 180 covers the last tile column instead of the first.
    private static func normalizedX(longitudeDegrees: Double) -> Double {
        (longitudeDegrees + 180.0) / 360.0
    }

    private static func normalizedY(latitudeDegrees: Double) -> Double {
        let latitudeRadians = latitudeDegrees * .pi / 180.0
        let mercatorY = ImmersiveMapProjection.yMercatorNormalized(latitude: latitudeRadians)
        return ImmersiveMapProjection.clampNormalizedWorldY((1.0 - mercatorY) * 0.5)
    }

    private static func tileIndex(_ normalized: Double, tilesPerAxis: Int) -> Int {
        min(max(Int(floor(normalized * Double(tilesPerAxis))), 0), tilesPerAxis - 1)
    }

    /// Wraps into `[-180, 180)`: the west edge of a range.
    private static func normalizedWestLongitude(_ degrees: Double) -> Double {
        var value = (degrees + 180.0).truncatingRemainder(dividingBy: 360.0)
        if value < 0 {
            value += 360.0
        }
        return value - 180.0
    }

    /// Wraps into `(-180, 180]`: the east edge of a range, so longitude 180
    /// stays 180 instead of becoming -180 and inverting the range.
    private static func normalizedEastLongitude(_ degrees: Double) -> Double {
        let wrapped = normalizedWestLongitude(degrees)
        return wrapped == -180.0 ? 180.0 : wrapped
    }
}
