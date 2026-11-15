// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

import Foundation

/// A Point: one point of the layer.
struct GeoJSONPointReader: GeoJSONGeometryReader {
    let type = "Point"

    func read(coordinates: Any,
              style: ImmersiveMapGeoJSON.SimpleStyle,
              path: String,
              into context: inout GeoJSONReadContext) throws {
        var point = ImmersiveMapPoint(id: context.featureID, coordinate: try ImmersiveMapGeoJSON.position(coordinates, path: path))
        point.simpleStyle = ImmersiveMapGeoJSON.pointPart(style)
        context.shapes.points.append(point)
    }
}

/// A MultiPoint: a point of the layer for each position.
struct GeoJSONMultiPointReader: GeoJSONGeometryReader {
    let type = "MultiPoint"

    func read(coordinates: Any,
              style: ImmersiveMapGeoJSON.SimpleStyle,
              path: String,
              into context: inout GeoJSONReadContext) throws {
        let pointStyle = ImmersiveMapGeoJSON.pointPart(style)
        for coordinate in try ImmersiveMapGeoJSON.positions(coordinates, path: path) {
            var point = ImmersiveMapPoint(id: context.featureID, coordinate: coordinate)
            point.simpleStyle = pointStyle
            context.shapes.points.append(point)
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
        var polyline = ImmersiveMapPolyline(id: context.featureID, coordinates: try ImmersiveMapGeoJSON.positions(coordinates, path: path))
        polyline.simpleStyle = ImmersiveMapGeoJSON.polylinePart(style)
        context.shapes.polylines.append(polyline)
    }
}

/// A MultiLineString: a line of the layer for each of its lines.
struct GeoJSONMultiLineStringReader: GeoJSONGeometryReader {
    let type = "MultiLineString"

    func read(coordinates: Any,
              style: ImmersiveMapGeoJSON.SimpleStyle,
              path: String,
              into context: inout GeoJSONReadContext) throws {
        let polylineStyle = ImmersiveMapGeoJSON.polylinePart(style)
        for (index, line) in try ImmersiveMapGeoJSON.array(coordinates, path: path).enumerated() {
            var polyline = ImmersiveMapPolyline(id: context.featureID, coordinates: try ImmersiveMapGeoJSON.positions(line, path: "\(path)[\(index)]"))
            polyline.simpleStyle = polylineStyle
            context.shapes.polylines.append(polyline)
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
        let polygonStyle = ImmersiveMapGeoJSON.polygonPart(style)
        context.shapes.polygons.append(try ImmersiveMapGeoJSON.polygon(coordinates, id: context.featureID, style: polygonStyle, path: path))
    }
}

/// A MultiPolygon: a zone of the layer for each of its polygons.
struct GeoJSONMultiPolygonReader: GeoJSONGeometryReader {
    let type = "MultiPolygon"

    func read(coordinates: Any,
              style: ImmersiveMapGeoJSON.SimpleStyle,
              path: String,
              into context: inout GeoJSONReadContext) throws {
        let polygonStyle = ImmersiveMapGeoJSON.polygonPart(style)
        for (index, rings) in try ImmersiveMapGeoJSON.array(coordinates, path: path).enumerated() {
            context.shapes.polygons.append(try ImmersiveMapGeoJSON.polygon(rings, id: context.featureID, style: polygonStyle, path: "\(path)[\(index)]"))
        }
    }
}
