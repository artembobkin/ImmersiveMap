// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation
import simd

/// Why a GeoJSON document could not be read into a layer.
public enum ImmersiveMapGeoJSONError: Error, Equatable, Sendable {
    /// The bytes are not JSON.
    case invalidJSON
    /// An object has no `type`, or one GeoJSON does not define.
    case unknownType(String)
    /// A geometry's `coordinates` are not shaped as its type requires,
    /// at the path given (the members from the document's root).
    case invalidCoordinates(String)
}

/// GeoJSON (RFC 7946) read into the shapes of a layer
/// (`ImmersiveMapLayer.init(id:geoJSON:)`). Positions are longitude,
/// latitude, an altitude after them is ignored. A feature's simplestyle
/// properties (`fill`, `fill-opacity`, `stroke`, `stroke-opacity`,
/// `stroke-width`, `marker-color`, `marker-size`, `marker-radius`) give the
/// shapes of its geometry a style of their own, laid over the layer's when
/// the document is read: a property the feature does not state keeps the
/// layer's value of that moment. A feature with a null geometry is skipped.
enum ImmersiveMapGeoJSON {
    struct Shapes {
        var polygons: [ImmersiveMapPolygon] = []
        var polylines: [ImmersiveMapPolyline] = []
        var points: [ImmersiveMapPoint] = []
    }

    /// The overrides a feature's simplestyle properties state, each nil
    /// where the feature states nothing.
    struct SimpleStyle {
        var fill: SIMD3<Float>?
        var fillOpacity: Float?
        var stroke: SIMD3<Float>?
        var strokeOpacity: Float?
        var strokeWidth: Float?
        var markerColor: SIMD3<Float>?
        var markerRadius: Float?

        var isEmpty: Bool {
            fill == nil && fillOpacity == nil && stroke == nil && strokeOpacity == nil
                && strokeWidth == nil && markerColor == nil && markerRadius == nil
        }
    }

    /// The layer's styles a feature's simplestyle properties are laid
    /// over: a property the feature leaves out keeps the base's value.
    struct BaseStyles {
        var polygon = ImmersiveMapPolygonStyle()
        var polyline = ImmersiveMapPolylineStyle()
        var point = ImmersiveMapPointStyle()
    }

    static func decode(_ data: Data, base: BaseStyles = BaseStyles()) throws -> Shapes {
        guard let root = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
            throw ImmersiveMapGeoJSONError.invalidJSON
        }
        var reader = Reader(base: base)
        try reader.read(object: root, style: SimpleStyle(), path: "")
        return reader.shapes
    }

    private struct Reader {
        let base: BaseStyles
        var shapes = Shapes()

        mutating func read(object: Any, style: SimpleStyle, path: String) throws {
            guard let dictionary = object as? [String: Any], let type = dictionary["type"] as? String else {
                throw ImmersiveMapGeoJSONError.unknownType(path.isEmpty ? "root" : path)
            }
            switch type {
            case "FeatureCollection":
                guard let features = dictionary["features"] as? [Any] else {
                    throw ImmersiveMapGeoJSONError.invalidCoordinates("\(path)features")
                }
                for (index, feature) in features.enumerated() {
                    try read(object: feature, style: style, path: "\(path)features[\(index)].")
                }
            case "Feature":
                let properties = dictionary["properties"] as? [String: Any] ?? [:]
                let featureStyle = ImmersiveMapGeoJSON.simpleStyle(of: properties)
                guard let geometry = dictionary["geometry"], (geometry is NSNull) == false else { return }
                try read(object: geometry, style: featureStyle, path: "\(path)geometry.")
            case "GeometryCollection":
                guard let geometries = dictionary["geometries"] as? [Any] else {
                    throw ImmersiveMapGeoJSONError.invalidCoordinates("\(path)geometries")
                }
                for (index, geometry) in geometries.enumerated() {
                    try read(object: geometry, style: style, path: "\(path)geometries[\(index)].")
                }
            case "Point", "MultiPoint", "LineString", "MultiLineString", "Polygon", "MultiPolygon":
                let coordinatesPath = "\(path)coordinates"
                guard let coordinates = dictionary["coordinates"] else {
                    throw ImmersiveMapGeoJSONError.invalidCoordinates(coordinatesPath)
                }
                try readGeometry(type: type, coordinates: coordinates, style: style, path: coordinatesPath)
            default:
                throw ImmersiveMapGeoJSONError.unknownType(type)
            }
        }

        mutating func readGeometry(type: String, coordinates: Any, style: SimpleStyle, path: String) throws {
            switch type {
            case "Point":
                let pointStyle = ImmersiveMapGeoJSON.pointStyle(style, base: base.point)
                shapes.points.append(ImmersiveMapPoint(coordinate: try ImmersiveMapGeoJSON.position(coordinates, path: path),
                                                       style: pointStyle))
            case "MultiPoint":
                let pointStyle = ImmersiveMapGeoJSON.pointStyle(style, base: base.point)
                for coordinate in try ImmersiveMapGeoJSON.positions(coordinates, path: path) {
                    shapes.points.append(ImmersiveMapPoint(coordinate: coordinate, style: pointStyle))
                }
            case "LineString":
                shapes.polylines.append(ImmersiveMapPolyline(coordinates: try ImmersiveMapGeoJSON.positions(coordinates, path: path),
                                                             style: ImmersiveMapGeoJSON.polylineStyle(style, base: base.polyline)))
            case "MultiLineString":
                for (index, line) in try ImmersiveMapGeoJSON.array(coordinates, path: path).enumerated() {
                    shapes.polylines.append(ImmersiveMapPolyline(coordinates: try ImmersiveMapGeoJSON.positions(line, path: "\(path)[\(index)]"),
                                                                 style: ImmersiveMapGeoJSON.polylineStyle(style, base: base.polyline)))
                }
            case "Polygon":
                let polygonStyle = ImmersiveMapGeoJSON.polygonStyle(style, base: base.polygon)
                shapes.polygons.append(try ImmersiveMapGeoJSON.polygon(coordinates, style: polygonStyle, path: path))
            case "MultiPolygon":
                let polygonStyle = ImmersiveMapGeoJSON.polygonStyle(style, base: base.polygon)
                for (index, rings) in try ImmersiveMapGeoJSON.array(coordinates, path: path).enumerated() {
                    shapes.polygons.append(try ImmersiveMapGeoJSON.polygon(rings, style: polygonStyle, path: "\(path)[\(index)]"))
                }
            default:
                throw ImmersiveMapGeoJSONError.unknownType(type)
            }
        }
    }

    private static func polygon(_ value: Any, style: ImmersiveMapPolygonStyle?, path: String) throws -> ImmersiveMapPolygon {
        let rings = try array(value, path: path)
        guard let exterior = rings.first else {
            throw ImmersiveMapGeoJSONError.invalidCoordinates(path)
        }
        let holes = try rings.dropFirst().enumerated().map { index, ring in
            try positions(ring, path: "\(path)[\(index + 1)]")
        }
        return ImmersiveMapPolygon(exterior: try positions(exterior, path: "\(path)[0]"),
                                   holes: holes,
                                   style: style)
    }

    private static func array(_ value: Any, path: String) throws -> [Any] {
        guard let array = value as? [Any] else {
            throw ImmersiveMapGeoJSONError.invalidCoordinates(path)
        }
        return array
    }

    private static func positions(_ value: Any, path: String) throws -> [GeoCoordinate] {
        try array(value, path: path).enumerated().map { index, item in
            try position(item, path: "\(path)[\(index)]")
        }
    }

    private static func position(_ value: Any, path: String) throws -> GeoCoordinate {
        guard let numbers = value as? [Any], numbers.count >= 2,
              let longitude = (numbers[0] as? NSNumber)?.doubleValue,
              let latitude = (numbers[1] as? NSNumber)?.doubleValue,
              longitude.isFinite, latitude.isFinite else {
            throw ImmersiveMapGeoJSONError.invalidCoordinates(path)
        }
        return GeoCoordinate(latitude: latitude, longitude: longitude)
    }

    // MARK: - simplestyle

    static func simpleStyle(of properties: [String: Any]) -> SimpleStyle {
        var style = SimpleStyle()
        style.fill = color(properties["fill"])
        style.fillOpacity = number(properties["fill-opacity"]).map { min(max($0, 0), 1) }
        style.stroke = color(properties["stroke"])
        style.strokeOpacity = number(properties["stroke-opacity"]).map { min(max($0, 0), 1) }
        style.strokeWidth = number(properties["stroke-width"]).map { max($0, 0) }
        style.markerColor = color(properties["marker-color"])
        if let radius = number(properties["marker-radius"]) {
            style.markerRadius = max(radius, 0)
        } else if let size = properties["marker-size"] as? String {
            switch size {
            case "small": style.markerRadius = 3
            case "medium": style.markerRadius = 5
            case "large": style.markerRadius = 8
            default: break
            }
        }
        return style
    }

    private static func number(_ value: Any?) -> Float? {
        if let number = value as? NSNumber, number.floatValue.isFinite {
            return number.floatValue
        }
        if let string = value as? String, let parsed = Float(string), parsed.isFinite {
            return parsed
        }
        return nil
    }

    /// A `#rgb` or `#rrggbb` colour, the hash optional.
    static func color(_ value: Any?) -> SIMD3<Float>? {
        guard var text = (value as? String)?.trimmingCharacters(in: .whitespaces) else { return nil }
        if text.hasPrefix("#") {
            text.removeFirst()
        }
        if text.count == 3 {
            text = text.map { "\($0)\($0)" }.joined()
        }
        guard text.count == 6, let value = UInt32(text, radix: 16) else { return nil }
        return SIMD3<Float>(Float((value >> 16) & 0xFF), Float((value >> 8) & 0xFF), Float(value & 0xFF)) / 255
    }

    /// The overrides over the layer's styles, nil when the feature states
    /// none, so the shape takes the layer's style whole.
    private static func polygonStyle(_ style: SimpleStyle, base: ImmersiveMapPolygonStyle) -> ImmersiveMapPolygonStyle? {
        guard style.fill != nil || style.fillOpacity != nil || style.stroke != nil
                || style.strokeOpacity != nil || style.strokeWidth != nil else { return nil }
        return ImmersiveMapPolygonStyle(fillColor: color(style.fill, opacity: style.fillOpacity, base: base.fillColor),
                                        strokeColor: color(style.stroke, opacity: style.strokeOpacity, base: base.strokeColor),
                                        strokeWidthPoints: style.strokeWidth ?? base.strokeWidthPoints)
    }

    private static func polylineStyle(_ style: SimpleStyle, base: ImmersiveMapPolylineStyle) -> ImmersiveMapPolylineStyle? {
        guard style.stroke != nil || style.strokeOpacity != nil || style.strokeWidth != nil else { return nil }
        return ImmersiveMapPolylineStyle(color: color(style.stroke, opacity: style.strokeOpacity, base: base.color),
                                         widthPoints: style.strokeWidth ?? base.widthPoints)
    }

    private static func pointStyle(_ style: SimpleStyle, base: ImmersiveMapPointStyle) -> ImmersiveMapPointStyle? {
        guard style.markerColor != nil || style.markerRadius != nil else { return nil }
        var resolved = base
        resolved.color = color(style.markerColor, opacity: nil, base: base.color)
        resolved.radiusPoints = style.markerRadius ?? base.radiusPoints
        return resolved
    }

    private static func color(_ rgb: SIMD3<Float>?, opacity: Float?, base: SIMD4<Float>) -> SIMD4<Float> {
        SIMD4<Float>(rgb ?? SIMD3<Float>(base.x, base.y, base.z), opacity ?? base.w)
    }
}
