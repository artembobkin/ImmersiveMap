// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

import Foundation

/// A tile of the XYZ scheme the web's maps share: Web Mercator, `zoom`
/// halving the tile's side at each step, `x` counted east from the
/// antimeridian and `y` south from the north edge of the map. It names a
/// square of the ground, not a tile of the map's own archive, so a tile of
/// any zoom can be named, whatever zooms the archive holds.
public struct ImmersiveMapTileID: Hashable, Codable, Sendable, CustomStringConvertible {
    /// The deepest zoom a tile is named at.
    public static let maximumZoom = 24

    public let zoom: Int
    public let x: Int
    public let y: Int

    /// A tile by its numbers. The zoom is clamped to
    /// `0...maximumZoom`, the x wraps round the antimeridian (a column past
    /// the last is the first again) and the y is clamped to the map.
    public init(zoom: Int, x: Int, y: Int) {
        let zoom = min(max(zoom, 0), Self.maximumZoom)
        let count = 1 << zoom
        let wrapped = x % count
        self.zoom = zoom
        self.x = wrapped < 0 ? wrapped + count : wrapped
        self.y = min(max(y, 0), count - 1)
    }

    /// The tile of `zoom` that holds the coordinate. A latitude past the
    /// map's edge (about 85.05 degrees) gives the tile of the edge.
    public init(containing coordinate: GeoCoordinate, zoom: Int) {
        let world = ImmersiveMapProjection.worldMercator(latitude: coordinate.latitude * .pi / 180,
                                                         longitude: coordinate.longitude * .pi / 180)
        self.init(Tile.containing(normalizedWorld: world, zoom: min(max(zoom, 0), Self.maximumZoom)))
    }

    /// The tile's box in degrees.
    public var bounds: ImmersiveMapGeoBounds {
        let count = Double(1 << zoom)
        let west = Double(x) / count * 360 - 180
        let east = Double(x + 1) / count * 360 - 180
        let north = ImmersiveMapProjection.latitude(fromNormalizedWorldY: Double(y) / count) * 180 / .pi
        let south = ImmersiveMapProjection.latitude(fromNormalizedWorldY: Double(y + 1) / count) * 180 / .pi
        return ImmersiveMapGeoBounds(southWest: GeoCoordinate(latitude: south, longitude: west),
                                     northEast: GeoCoordinate(latitude: north, longitude: east))
    }

    /// The middle of the tile's square on the map, which is north of the
    /// middle of its latitudes.
    public var center: GeoCoordinate {
        let count = Double(1 << zoom)
        let latitude = ImmersiveMapProjection.latitude(fromNormalizedWorldY: (Double(y) + 0.5) / count) * 180 / .pi
        return GeoCoordinate(latitude: latitude, longitude: (Double(x) + 0.5) / count * 360 - 180)
    }

    /// The tile one zoom up that holds this one, nil at zoom 0.
    public var parent: ImmersiveMapTileID? {
        zoom > 0 ? ImmersiveMapTileID(zoom: zoom - 1, x: x >> 1, y: y >> 1) : nil
    }

    /// The four tiles one zoom down, west to east and north to south, none
    /// at `maximumZoom`.
    public var children: [ImmersiveMapTileID] {
        guard zoom < Self.maximumZoom else { return [] }
        return [(0, 0), (1, 0), (0, 1), (1, 1)].map {
            ImmersiveMapTileID(zoom: zoom + 1, x: x * 2 + $0.0, y: y * 2 + $0.1)
        }
    }

    /// The tile as `zoom/x/y`.
    public var description: String { "\(zoom)/\(x)/\(y)" }
}

extension ImmersiveMapTileID {
    init(_ tile: Tile) {
        self.init(zoom: tile.z, x: tile.x, y: tile.y)
    }

    /// The engine's own name for the tile.
    var tile: Tile { Tile(x: x, y: y, z: zoom) }
}
