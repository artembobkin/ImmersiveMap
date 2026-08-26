// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import Foundation

/// Builds real Mapbox Vector Tile bytes in memory, so a test can push a tile
/// through the actual parser instead of a hand-made intermediate structure.
///
/// The bytes are produced by the same generated protobuf type the parser reads
/// back (`MvtTileMessage`), which makes the fixture a genuine encode/decode
/// round trip rather than an assertion about a struct. Writing the geometry
/// commands out by hand is the point: they are the part of the MVT format the
/// parser actually has to interpret.
///
/// Nothing is committed as a binary blob. A `.mvt` checked into the repository
/// would be opaque (nobody can read what it claims) and would silently rot
/// against parser changes; a builder states its geometry in code.
enum VectorTileFixture {
    /// MVT geometry commands. The low three bits are the command, the upper
    /// bits the repeat count.
    private enum GeometryCommand: UInt32 {
        case moveTo = 1
        case lineTo = 2
        case closePath = 7

        func encoded(count: UInt32) -> UInt32 {
            (rawValue & 0x7) | (count << 3)
        }
    }

    /// MVT stores coordinate deltas zigzag encoded, so small negative steps
    /// stay small unsigned varints.
    private static func zigZag(_ value: Int32) -> UInt32 {
        UInt32(bitPattern: (value << 1) ^ (value >> 31))
    }

    /// A tile holding one polygon that covers the whole tile, tagged into
    /// `layerName`.
    ///
    /// Filling the tile is deliberate: the test then does not have to reason
    /// about where inside the tile the camera is looking, only about whether
    /// the tile reached the frame at all.
    static func fullCoverageTile(layerName: String,
                                 properties: [String: String] = [:],
                                 extent: UInt32 = 4096) -> Data {
        var feature = MvtFeatureMessage()
        feature.id = 1
        feature.type = .polygon
        feature.geometry = squareRingGeometry(side: Int32(extent))

        var layer = MvtLayerMessage()
        layer.version = 2
        layer.name = layerName
        layer.extent = extent
        for (index, key) in properties.keys.sorted().enumerated() {
            let value = MvtValue.string(properties[key] ?? "")
            layer.keys.append(key)
            layer.values.append(value)
            feature.tags.append(contentsOf: [UInt32(index), UInt32(index)])
        }
        layer.features = [feature]

        return MvtTileMessage(layers: [layer]).serializedData()
    }

    /// One feature of a hand-built layer: a polygon ring or a line, with its
    /// properties. Coordinates are MVT tile units (y down).
    struct Feature {
        enum Geometry {
            case polygon(ring: [(Int32, Int32)])
            case line(points: [(Int32, Int32)])
        }
        let id: UInt64
        let geometry: Geometry
        let properties: [String: String]
    }

    /// A tile holding one layer of arbitrary polygon and line features, for
    /// cases where the parser's behavior depends on how features relate to
    /// one another (a junction area among the roads that enter it).
    static func layerTile(layerName: String,
                          features: [Feature],
                          extent: UInt32 = 4096) -> Data {
        var layer = MvtLayerMessage()
        layer.version = 2
        layer.name = layerName
        layer.extent = extent
        var keyIndex: [String: UInt32] = [:]
        var valueIndex: [String: UInt32] = [:]
        for feature in features {
            var encoded = MvtFeatureMessage()
            encoded.id = feature.id
            switch feature.geometry {
            case .polygon(let ring):
                encoded.type = .polygon
                encoded.geometry = ringGeometry(ring, closed: true)
            case .line(let points):
                encoded.type = .linestring
                encoded.geometry = ringGeometry(points, closed: false)
            }
            for key in feature.properties.keys.sorted() {
                let value = feature.properties[key] ?? ""
                if keyIndex[key] == nil {
                    keyIndex[key] = UInt32(layer.keys.count)
                    layer.keys.append(key)
                }
                if valueIndex[value] == nil {
                    valueIndex[value] = UInt32(layer.values.count)
                    if let integer = Int64(value) {
                        layer.values.append(.int(integer))
                    } else {
                        layer.values.append(.string(value))
                    }
                }
                encoded.tags.append(contentsOf: [keyIndex[key]!, valueIndex[value]!])
            }
            layer.features.append(encoded)
        }
        return MvtTileMessage(layers: [layer]).serializedData()
    }

    /// A polyline or ring as MVT commands: one moveTo, the rest lineTo, and a
    /// closePath for a ring.
    private static func ringGeometry(_ points: [(Int32, Int32)], closed: Bool) -> [UInt32] {
        guard let first = points.first else { return [] }
        var commands: [UInt32] = [GeometryCommand.moveTo.encoded(count: 1), zigZag(first.0), zigZag(first.1)]
        if points.count > 1 {
            commands.append(GeometryCommand.lineTo.encoded(count: UInt32(points.count - 1)))
            var cursor = first
            for point in points.dropFirst() {
                commands.append(zigZag(point.0 - cursor.0))
                commands.append(zigZag(point.1 - cursor.1))
                cursor = point
            }
        }
        if closed {
            commands.append(GeometryCommand.closePath.encoded(count: 1))
        }
        return commands
    }

    /// One closed square ring from (0,0) to (side,side), as MVT commands.
    ///
    /// The ring is emitted counter-clockwise in tile coordinates; the parser
    /// normalizes winding itself (`ensureWinding`), so the direction here only
    /// has to be consistent, not to match the renderer's front face.
    private static func squareRingGeometry(side: Int32) -> [UInt32] {
        [
            GeometryCommand.moveTo.encoded(count: 1),
            zigZag(0), zigZag(0),
            GeometryCommand.lineTo.encoded(count: 3),
            zigZag(side), zigZag(0),
            zigZag(0), zigZag(side),
            zigZag(-side), zigZag(0),
            GeometryCommand.closePath.encoded(count: 1)
        ]
    }
}

/// The Web Mercator tile scheme (the XYZ convention every raster and vector
/// tile service uses), spelled out here so a test can name the tiles a camera
/// position implies.
enum WebMercatorTileScheme {
    /// The tile containing `latitude`/`longitude` at zoom `z`.
    static func tile(latitude: Double, longitude: Double, z: Int) -> Tile {
        let scale = Double(1 << z)
        let x = (longitude + 180.0) / 360.0 * scale
        let latitudeRadians = latitude * .pi / 180.0
        let y = (1.0 - log(tan(latitudeRadians) + 1.0 / cos(latitudeRadians)) / .pi) / 2.0 * scale
        let maximumIndex = (1 << z) - 1
        return Tile(x: min(max(Int(x.rounded(.down)), 0), maximumIndex),
                    y: min(max(Int(y.rounded(.down)), 0), maximumIndex),
                    z: z)
    }

    /// Every tile within `radius` tiles of the one containing the coordinate,
    /// at each zoom from 0 through `maximumZoom`.
    ///
    /// A test feeding tiles into the store by hand does not know which zoom the
    /// coverage policy will settle on or how far the viewport reaches, so it
    /// supplies the neighbourhood at every level instead of predicting one.
    /// Each tile is a single quad, so the whole pyramid is cheap.
    static func neighbourhoodPyramid(latitude: Double,
                                     longitude: Double,
                                     maximumZoom: Int,
                                     radius: Int = 1) -> [Tile] {
        (0...maximumZoom).flatMap { z -> [Tile] in
            let center = tile(latitude: latitude, longitude: longitude, z: z)
            let maximumIndex = (1 << z) - 1
            return (-radius...radius).flatMap { dx in
                (-radius...radius).compactMap { dy -> Tile? in
                    let x = center.x + dx
                    let y = center.y + dy
                    guard x >= 0, y >= 0, x <= maximumIndex, y <= maximumIndex else {
                        return nil
                    }
                    return Tile(x: x, y: y, z: z)
                }
            }
        }
    }
}
