// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation

/// A Point: one point of the layer.
struct GeoJSONPointReader: GeoJSONGeometryReader {
    let type = "Point"

    func read(coordinates: Any,
              style: ImmersiveMapGeoJSON.SimpleStyle,
              path: String,
              into context: inout GeoJSONReadContext) throws {
        let pointStyle = ImmersiveMapGeoJSON.pointStyle(style, base: context.base.point)
        context.shapes.points.append(ImmersiveMapPoint(coordinate: try ImmersiveMapGeoJSON.position(coordinates, path: path),
                                                       style: pointStyle))
    }
}

/// A MultiPoint: a point of the layer for each position.
struct GeoJSONMultiPointReader: GeoJSONGeometryReader {
    let type = "MultiPoint"

    func read(coordinates: Any,
              style: ImmersiveMapGeoJSON.SimpleStyle,
              path: String,
              into context: inout GeoJSONReadContext) throws {
        let pointStyle = ImmersiveMapGeoJSON.pointStyle(style, base: context.base.point)
        for coordinate in try ImmersiveMapGeoJSON.positions(coordinates, path: path) {
            context.shapes.points.append(ImmersiveMapPoint(coordinate: coordinate, style: pointStyle))
        }
    }
}

/// A LineString: one line of the layer.
struct GeoJSONLineStringReader: GeoJSONGeometryReader {
    let type = "LineString"

    func read(coordinates: Any,
              style: ImmersiveMapGeoJSON.SimpleStyle,
              path: String,
              into context: inout GeoJSONReadContext) throws {
        let polylineStyle = ImmersiveMapGeoJSON.polylineStyle(style, base: context.base.polyline)
        context.shapes.polylines.append(ImmersiveMapPolyline(coordinates: try ImmersiveMapGeoJSON.positions(coordinates, path: path),
                                                             style: polylineStyle))
    }
}

/// A MultiLineString: a line of the layer for each of its lines.
struct GeoJSONMultiLineStringReader: GeoJSONGeometryReader {
    let type = "MultiLineString"

    func read(coordinates: Any,
              style: ImmersiveMapGeoJSON.SimpleStyle,
              path: String,
              into context: inout GeoJSONReadContext) throws {
        let polylineStyle = ImmersiveMapGeoJSON.polylineStyle(style, base: context.base.polyline)
        for (index, line) in try ImmersiveMapGeoJSON.array(coordinates, path: path).enumerated() {
            context.shapes.polylines.append(ImmersiveMapPolyline(coordinates: try ImmersiveMapGeoJSON.positions(line, path: "\(path)[\(index)]"),
                                                                 style: polylineStyle))
        }
    }
}

/// A Polygon: one zone of the layer, its first ring the outline and the
/// rest its holes.
struct GeoJSONPolygonReader: GeoJSONGeometryReader {
    let type = "Polygon"

    func read(coordinates: Any,
              style: ImmersiveMapGeoJSON.SimpleStyle,
              path: String,
              into context: inout GeoJSONReadContext) throws {
        let polygonStyle = ImmersiveMapGeoJSON.polygonStyle(style, base: context.base.polygon)
        context.shapes.polygons.append(try ImmersiveMapGeoJSON.polygon(coordinates, style: polygonStyle, path: path))
    }
}

/// A MultiPolygon: a zone of the layer for each of its polygons.
struct GeoJSONMultiPolygonReader: GeoJSONGeometryReader {
    let type = "MultiPolygon"

    func read(coordinates: Any,
              style: ImmersiveMapGeoJSON.SimpleStyle,
              path: String,
              into context: inout GeoJSONReadContext) throws {
        let polygonStyle = ImmersiveMapGeoJSON.polygonStyle(style, base: context.base.polygon)
        for (index, rings) in try ImmersiveMapGeoJSON.array(coordinates, path: path).enumerated() {
            context.shapes.polygons.append(try ImmersiveMapGeoJSON.polygon(rings, style: polygonStyle, path: "\(path)[\(index)]"))
        }
    }
}
