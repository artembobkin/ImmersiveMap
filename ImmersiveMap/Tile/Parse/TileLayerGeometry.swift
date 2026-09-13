// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation
import Mvt

/// The geometry of one layer's features in the parser's tile space: the
/// decoder's coordinates scaled from the layer's own extent to the tile
/// extent (a layer at another extent is legal, and a tile may mix two),
/// decoded on demand per feature so a feature a reader skips costs nothing.
///
/// The `bytes` overloads take one mapping of the payload for a whole pass
/// over a layer instead of one per feature geometry.
struct TileLayerGeometry {
    let layer: MvtDecodedLayer
    let data: Data
    /// 1 when the layer is at the tile extent, which is the common case and
    /// leaves the decoded points untouched.
    private let scale: Double

    init(layer: MvtDecodedLayer, data: Data) {
        self.layer = layer
        self.data = data
        self.scale = layer.extent > 0 ? TileCoordinateSpace.tileExtentDouble / Double(layer.extent) : 1
    }

    func polygons(of feature: MvtDecodedFeature) -> MultiPolygon {
        normalize(MvtGeometryDecoder.decodePolygons(feature.geometry, in: data))
    }

    func polygons(of feature: MvtDecodedFeature, in bytes: UnsafeRawBufferPointer) -> MultiPolygon {
        normalize(MvtGeometryDecoder.decodePolygons(feature.geometry, in: bytes))
    }

    func lines(of feature: MvtDecodedFeature) -> MultiLineString {
        normalize(MvtGeometryDecoder.decodeLines(feature.geometry, in: data))
    }

    func lines(of feature: MvtDecodedFeature, in bytes: UnsafeRawBufferPointer) -> MultiLineString {
        normalize(MvtGeometryDecoder.decodeLines(feature.geometry, in: bytes))
    }

    func points(of feature: MvtDecodedFeature) -> MultiPoint {
        normalize(MvtGeometryDecoder.decodePoints(feature.geometry, in: data))
    }

    private func normalize(_ polygons: MultiPolygon) -> MultiPolygon {
        guard scale != 1 else {
            return polygons
        }
        return polygons.map { polygon in
            Polygon(exteriorRing: normalize(polygon.exteriorRing),
                    interiorRings: polygon.interiorRings.map(normalize))
        }
    }

    private func normalize(_ lines: MultiLineString) -> MultiLineString {
        guard scale != 1 else {
            return lines
        }
        return lines.map(normalize)
    }

    private func normalize(_ points: [Point]) -> [Point] {
        guard scale != 1 else {
            return points
        }
        return points.map { point in
            Point(x: Int32((Double(point.x) * scale).rounded()),
                  y: Int32((Double(point.y) * scale).rounded()))
        }
    }
}
