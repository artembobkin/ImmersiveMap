// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation
import simd

/// A layer of the app's own data drawn over the map: zones as polygons,
/// paths as lines, and points, as many as the data has. A layer lies on
/// the ground, over the map's fills and roads and under its names and
/// buildings, on the globe, on the flat map and through the morph between
/// them. Set on the view with `ImmersiveMapView.layers(_:)`:
///
///     let zones = try ImmersiveMapLayer(id: "zones", geoJSON: data,
///                                       polygonStyle: ImmersiveMapPolygonStyle(fillColor: [0.9, 0.3, 0.2, 0.3]))
///     let stations = ImmersiveMapLayer(id: "stations",
///                                      points: coordinates.map { ImmersiveMapPoint(coordinate: $0) })
///     ImmersiveMapView()
///         .layers([zones, stations])
///
/// Every shape draws in the layer's style for its kind unless it carries
/// its own. The data is read once, when the layer is made: two layers made
/// from the same data compare equal, so a view that rebuilds its layers on
/// every update redraws nothing. A changed layer is prepared for the GPU
/// off the main thread and replaces the old one when it is ready.
public struct ImmersiveMapLayer: Identifiable, Equatable, Sendable {
    /// The layer's identity among the map's layers.
    public let id: String
    /// How the shapes of each kind draw when they carry no style of their own.
    public var polygonStyle: ImmersiveMapPolygonStyle
    public var polylineStyle: ImmersiveMapPolylineStyle
    public var pointStyle: ImmersiveMapPointStyle
    /// Whether the layer draws. A hidden layer keeps its data on the GPU,
    /// so showing it again is immediate.
    public var isVisible: Bool
    /// The camera zooms the layer draws at.
    public var zoomRange: ClosedRange<Double>
    /// Whether the ground relief nearer the camera hides the layer: a
    /// mountain in front of a zone covers it. Off by default, the layer
    /// shows over the ground everywhere, over the mountains as on the
    /// plain, since it lies on the plane and not on the slopes. Either way
    /// the buildings, the models and the trees standing in front of it
    /// cover it. Applies live.
    public var hidesBehindTerrain: Bool

    let content: ImmersiveMapLayerContent

    /// The layer's zones.
    public var polygons: [ImmersiveMapPolygon] { content.polygons }
    /// The layer's lines.
    public var polylines: [ImmersiveMapPolyline] { content.polylines }
    /// The layer's points.
    public var points: [ImmersiveMapPoint] { content.points }

    public init(id: String,
                polygons: [ImmersiveMapPolygon] = [],
                polylines: [ImmersiveMapPolyline] = [],
                points: [ImmersiveMapPoint] = [],
                polygonStyle: ImmersiveMapPolygonStyle = ImmersiveMapPolygonStyle(),
                polylineStyle: ImmersiveMapPolylineStyle = ImmersiveMapPolylineStyle(),
                pointStyle: ImmersiveMapPointStyle = ImmersiveMapPointStyle(),
                isVisible: Bool = true,
                zoomRange: ClosedRange<Double> = 0 ... 30,
                hidesBehindTerrain: Bool = false) {
        self.id = id
        self.hidesBehindTerrain = hidesBehindTerrain
        self.polygonStyle = polygonStyle
        self.polylineStyle = polylineStyle
        self.pointStyle = pointStyle
        self.isVisible = isVisible
        self.zoomRange = zoomRange
        self.content = ImmersiveMapLayerContent(polygons: polygons, polylines: polylines, points: points)
    }

    /// A layer of a GeoJSON document (RFC 7946): a FeatureCollection, a
    /// Feature, a GeometryCollection or a bare geometry. Polygons and
    /// MultiPolygons are zones, LineStrings and MultiLineStrings lines,
    /// Points and MultiPoints points. A feature's simplestyle properties
    /// (`fill`, `fill-opacity`, `stroke`, `stroke-opacity`, `stroke-width`,
    /// `marker-color`, `marker-size`, `marker-radius`) give it a style of
    /// its own, laid over the styles given here: a later change of the
    /// layer's style reaches the features that state none. Throws `ImmersiveMapGeoJSONError` for a document that is not
    /// GeoJSON.
    public init(id: String,
                geoJSON: Data,
                polygonStyle: ImmersiveMapPolygonStyle = ImmersiveMapPolygonStyle(),
                polylineStyle: ImmersiveMapPolylineStyle = ImmersiveMapPolylineStyle(),
                pointStyle: ImmersiveMapPointStyle = ImmersiveMapPointStyle(),
                isVisible: Bool = true,
                zoomRange: ClosedRange<Double> = 0 ... 30,
                hidesBehindTerrain: Bool = false) throws {
        let shapes = try ImmersiveMapGeoJSON.decode(geoJSON, base: ImmersiveMapGeoJSON.BaseStyles(polygon: polygonStyle,
                                                                                                 polyline: polylineStyle,
                                                                                                 point: pointStyle))
        self.init(id: id,
                  polygons: shapes.polygons,
                  polylines: shapes.polylines,
                  points: shapes.points,
                  polygonStyle: polygonStyle,
                  polylineStyle: polylineStyle,
                  pointStyle: pointStyle,
                  isVisible: isVisible,
                  zoomRange: zoomRange,
                  hidesBehindTerrain: hidesBehindTerrain)
    }

    public static func == (lhs: ImmersiveMapLayer, rhs: ImmersiveMapLayer) -> Bool {
        lhs.id == rhs.id
            && lhs.polygonStyle == rhs.polygonStyle
            && lhs.polylineStyle == rhs.polylineStyle
            && lhs.pointStyle == rhs.pointStyle
            && lhs.isVisible == rhs.isVisible
            && lhs.zoomRange == rhs.zoomRange
            && lhs.hidesBehindTerrain == rhs.hidesBehindTerrain
            && lhs.content.fingerprint == rhs.content.fingerprint
    }

    /// What the GPU form of the layer depends on: its data and the styles
    /// baked into it. A change of visibility, zoom range or how the
    /// terrain hides it is not one.
    var meshKey: LayerMeshKey {
        LayerMeshKey(contentFingerprint: content.fingerprint,
                     polygonStyle: polygonStyle,
                     polylineStyle: polylineStyle,
                     pointStyle: pointStyle)
    }
}

/// A zone: an exterior ring and the holes cut out of it. The rings need
/// not be closed (a ring whose last coordinate repeats its first is taken
/// as it is) and may run either way round. A zone across the 180th
/// meridian is drawn whole when its longitudes run on past ±180 instead of
/// jumping back.
public struct ImmersiveMapPolygon: Hashable, Sendable {
    public var exterior: [GeoCoordinate]
    public var holes: [[GeoCoordinate]]
    /// The zone's own style, nil for the layer's.
    public var style: ImmersiveMapPolygonStyle?

    public init(exterior: [GeoCoordinate], holes: [[GeoCoordinate]] = [], style: ImmersiveMapPolygonStyle? = nil) {
        self.exterior = exterior
        self.holes = holes
        self.style = style
    }
}

/// A line through its coordinates: a path, a track, a border.
public struct ImmersiveMapPolyline: Hashable, Sendable {
    public var coordinates: [GeoCoordinate]
    /// The line's own style, nil for the layer's.
    public var style: ImmersiveMapPolylineStyle?

    public init(coordinates: [GeoCoordinate], style: ImmersiveMapPolylineStyle? = nil) {
        self.coordinates = coordinates
        self.style = style
    }
}

/// A point: a dot of a size on screen, whatever the zoom.
public struct ImmersiveMapPoint: Hashable, Sendable {
    public var coordinate: GeoCoordinate
    /// The point's own style, nil for the layer's.
    public var style: ImmersiveMapPointStyle?

    public init(coordinate: GeoCoordinate, style: ImmersiveMapPointStyle? = nil) {
        self.coordinate = coordinate
        self.style = style
    }
}

/// How a zone draws: its fill and the line round it. Colours are RGBA in
/// 0...1, the alpha straight; a zero alpha or a zero width leaves the part
/// out.
public struct ImmersiveMapPolygonStyle: Hashable, Sendable {
    public var fillColor: SIMD4<Float>
    public var strokeColor: SIMD4<Float>
    /// The outline's width on screen, in points.
    public var strokeWidthPoints: Float

    public init(fillColor: SIMD4<Float> = SIMD4<Float>(0.18, 0.47, 0.96, 0.25),
                strokeColor: SIMD4<Float> = SIMD4<Float>(0.18, 0.47, 0.96, 1),
                strokeWidthPoints: Float = 2) {
        self.fillColor = fillColor
        self.strokeColor = strokeColor
        self.strokeWidthPoints = max(strokeWidthPoints, 0)
    }
}

/// How a line draws. Its joins and its ends are round.
public struct ImmersiveMapPolylineStyle: Hashable, Sendable {
    public var color: SIMD4<Float>
    /// The width on screen, in points.
    public var widthPoints: Float

    public init(color: SIMD4<Float> = SIMD4<Float>(0.18, 0.47, 0.96, 1), widthPoints: Float = 3) {
        self.color = color
        self.widthPoints = max(widthPoints, 0)
    }
}

/// How a point draws: a disc with a ring round it.
public struct ImmersiveMapPointStyle: Hashable, Sendable {
    public var color: SIMD4<Float>
    /// The disc's radius on screen, in points, the ring outside it.
    public var radiusPoints: Float
    public var strokeColor: SIMD4<Float>
    public var strokeWidthPoints: Float

    public init(color: SIMD4<Float> = SIMD4<Float>(0.18, 0.47, 0.96, 1),
                radiusPoints: Float = 4,
                strokeColor: SIMD4<Float> = SIMD4<Float>(1, 1, 1, 1),
                strokeWidthPoints: Float = 1) {
        self.color = color
        self.radiusPoints = max(radiusPoints, 0)
        self.strokeColor = strokeColor
        self.strokeWidthPoints = max(strokeWidthPoints, 0)
    }
}

/// A layer's data, read once: shared by every copy of the layer, and
/// compared by a fingerprint of every coordinate and style it holds, so a
/// layer rebuilt from the same data on every view update is the same layer.
final class ImmersiveMapLayerContent: Sendable {
    let polygons: [ImmersiveMapPolygon]
    let polylines: [ImmersiveMapPolyline]
    let points: [ImmersiveMapPoint]
    let fingerprint: UInt64

    init(polygons: [ImmersiveMapPolygon], polylines: [ImmersiveMapPolyline], points: [ImmersiveMapPoint]) {
        self.polygons = polygons
        self.polylines = polylines
        self.points = points
        var hasher = StableFNV1aHasher()
        func add(_ coordinate: GeoCoordinate) {
            hasher.combine(coordinate.latitude.bitPattern)
            hasher.combine(coordinate.longitude.bitPattern)
        }
        func add(_ color: SIMD4<Float>) {
            for index in 0 ..< 4 {
                hasher.combine(UInt64(color[index].bitPattern))
            }
        }
        func add(_ value: Float) {
            hasher.combine(UInt64(value.bitPattern))
        }
        hasher.combine(UInt64(polygons.count))
        for polygon in polygons {
            hasher.combine(UInt64(polygon.exterior.count))
            polygon.exterior.forEach(add)
            hasher.combine(UInt64(polygon.holes.count))
            for hole in polygon.holes {
                hasher.combine(UInt64(hole.count))
                hole.forEach(add)
            }
            if let style = polygon.style {
                add(style.fillColor)
                add(style.strokeColor)
                add(style.strokeWidthPoints)
            } else {
                hasher.combine(0)
            }
        }
        hasher.combine(UInt64(polylines.count))
        for polyline in polylines {
            hasher.combine(UInt64(polyline.coordinates.count))
            polyline.coordinates.forEach(add)
            if let style = polyline.style {
                add(style.color)
                add(style.widthPoints)
            } else {
                hasher.combine(0)
            }
        }
        hasher.combine(UInt64(points.count))
        for point in points {
            add(point.coordinate)
            if let style = point.style {
                add(style.color)
                add(style.radiusPoints)
                add(style.strokeColor)
                add(style.strokeWidthPoints)
            } else {
                hasher.combine(0)
            }
        }
        fingerprint = hasher.finalize()
    }
}

/// What a layer's GPU form is made of (`LayerMeshStore`).
struct LayerMeshKey: Hashable, Sendable {
    let contentFingerprint: UInt64
    let polygonStyle: ImmersiveMapPolygonStyle
    let polylineStyle: ImmersiveMapPolylineStyle
    let pointStyle: ImmersiveMapPointStyle
}
