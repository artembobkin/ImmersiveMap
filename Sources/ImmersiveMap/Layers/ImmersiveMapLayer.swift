// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

import Foundation
import simd

/// A layer of the app's own data drawn over the map: how one registered
/// source is drawn. The data is registered with the map's controller under
/// a name (`ImmersiveMapLayersController.register`), and a layer names the
/// source it draws and gives the styles, the zooms and the visibility:
///
///     layers.register("zones", geoJSONFile: zonesURL)
///     layers.register("stations", identity: "v1", points: coordinates.map { ImmersiveMapPoint(coordinate: $0) })
///     layers.set([
///         ImmersiveMapLayer(source: "zones",
///                           polygonStyle: ImmersiveMapPolygonStyle(fillColor: [0.9, 0.3, 0.2, 0.3])),
///         ImmersiveMapLayer(source: "stations", zoomRange: 12 ... 30)
///     ])
///
/// A layer lies on the ground, over the map's fills and roads and under its
/// names and buildings, on the globe, on the flat map and through the morph
/// between them. Every shape draws in the layer's style for its kind unless
/// it carries its own. Several layers can draw one source, each its own
/// way. A layer is a small value: making the same layers again on every
/// view update redraws nothing.
public struct ImmersiveMapLayer: Identifiable, Equatable, Sendable {
    /// The layer's identity among the map's layers.
    public let id: String
    /// The name of the registered source the layer draws.
    public var source: String
    /// How the shapes of each kind draw when they carry no style of their own.
    public var polygonStyle: ImmersiveMapPolygonStyle
    public var polylineStyle: ImmersiveMapPolylineStyle
    public var pointStyle: ImmersiveMapPointStyle
    /// Whether the layer draws. A hidden layer keeps what the map prepared
    /// of it while memory allows, so showing it again is immediate.
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

    /// A layer that draws `source`. Its `id` is the source's name unless
    /// one is given, which several layers of one source need.
    public init(id: String? = nil,
                source: String,
                polygonStyle: ImmersiveMapPolygonStyle = ImmersiveMapPolygonStyle(),
                polylineStyle: ImmersiveMapPolylineStyle = ImmersiveMapPolylineStyle(),
                pointStyle: ImmersiveMapPointStyle = ImmersiveMapPointStyle(),
                isVisible: Bool = true,
                zoomRange: ClosedRange<Double> = 0 ... 30,
                hidesBehindTerrain: Bool = false) {
        self.id = id ?? source
        self.source = source
        self.hidesBehindTerrain = hidesBehindTerrain
        self.polygonStyle = polygonStyle
        self.polylineStyle = polylineStyle
        self.pointStyle = pointStyle
        self.isVisible = isVisible
        self.zoomRange = zoomRange
    }

    /// Whether the layer draws at the camera's `zoom`.
    func draws(atZoom zoom: Double) -> Bool {
        isVisible && zoomRange.contains(zoom)
    }

    /// The style a shape of the layer's source draws in: its own, or what
    /// its GeoJSON feature states laid over the layer's, or the layer's.
    func style(of polygon: ImmersiveMapPolygon) -> ImmersiveMapPolygonStyle {
        polygon.style
            ?? polygon.simpleStyle.flatMap { ImmersiveMapGeoJSON.polygonStyle($0, base: polygonStyle) }
            ?? polygonStyle
    }

    func style(of polyline: ImmersiveMapPolyline) -> ImmersiveMapPolylineStyle {
        polyline.style
            ?? polyline.simpleStyle.flatMap { ImmersiveMapGeoJSON.polylineStyle($0, base: polylineStyle) }
            ?? polylineStyle
    }

    func style(of point: ImmersiveMapPoint) -> ImmersiveMapPointStyle {
        point.style
            ?? point.simpleStyle.flatMap { ImmersiveMapGeoJSON.pointStyle($0, base: pointStyle) }
            ?? pointStyle
    }

    /// What the GPU form of the layer depends on: its source's data as of
    /// `sourceRevision` and the styles baked into it. A change of
    /// visibility, zoom range or how the terrain hides it is not one.
    func meshKey(sourceRevision: UInt64) -> LayerMeshKey {
        LayerMeshKey(source: source,
                     sourceRevision: sourceRevision,
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
    /// Names the zone in a selection and in a tap event, within its
    /// source. Left nil, the zone goes by its place among the source's
    /// shapes (`ImmersiveMapLayersController.register`).
    public var id: UInt64?
    public var exterior: [GeoCoordinate]
    public var holes: [[GeoCoordinate]]
    /// The zone's own style, nil for the layer's.
    public var style: ImmersiveMapPolygonStyle?
    /// What a GeoJSON feature states of its style, laid over the style of
    /// the layer that draws it.
    var simpleStyle: ImmersiveMapGeoJSON.SimpleStyle?

    public init(id: UInt64? = nil,
                exterior: [GeoCoordinate],
                holes: [[GeoCoordinate]] = [],
                style: ImmersiveMapPolygonStyle? = nil) {
        self.id = id
        self.exterior = exterior
        self.holes = holes
        self.style = style
    }
}

/// A line through its coordinates: a path, a track, a border.
public struct ImmersiveMapPolyline: Hashable, Sendable {
    /// Names the line in a selection and in a tap event, within its
    /// source. Left nil, the line goes by its place among the source's
    /// shapes.
    public var id: UInt64?
    public var coordinates: [GeoCoordinate]
    /// The line's own style, nil for the layer's.
    public var style: ImmersiveMapPolylineStyle?
    /// What a GeoJSON feature states of its style, laid over the style of
    /// the layer that draws it.
    var simpleStyle: ImmersiveMapGeoJSON.SimpleStyle?

    public init(id: UInt64? = nil, coordinates: [GeoCoordinate], style: ImmersiveMapPolylineStyle? = nil) {
        self.id = id
        self.coordinates = coordinates
        self.style = style
    }
}

/// A point: a dot of a size on screen, whatever the zoom.
public struct ImmersiveMapPoint: Hashable, Sendable {
    /// Names the point in a selection and in a tap event, within its
    /// source. Left nil, the point goes by its place among the source's
    /// shapes.
    public var id: UInt64?
    public var coordinate: GeoCoordinate
    /// The point's own style, nil for the layer's.
    public var style: ImmersiveMapPointStyle?
    /// What a GeoJSON feature states of its style, laid over the style of
    /// the layer that draws it.
    var simpleStyle: ImmersiveMapGeoJSON.SimpleStyle?

    public init(id: UInt64? = nil, coordinate: GeoCoordinate, style: ImmersiveMapPointStyle? = nil) {
        self.id = id
        self.coordinate = coordinate
        self.style = style
    }
}

/// How a zone draws: its fill and the line round it. Colours are RGBA in
/// 0...1, the alpha straight; a zero alpha or a zero width leaves the part
/// out. The fill may be translucent. The line round it is always solid:
/// any alpha of `strokeColor` above zero draws it opaque, as a line is
/// (`ImmersiveMapPolylineStyle`).
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

/// How a line draws. Its joins and its ends are round. A line is always
/// solid: the alpha of `color` only says whether the line draws, zero
/// leaving it out and any other value drawing it opaque. A line is drawn
/// in parts that overlap, so a translucent one would darken itself at
/// every vertex, and a solid one costs the GPU nothing where its parts
/// overlap. Its edge is not softened: turn on `.msaa()` for smooth edges.
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

/// What a layer's GPU form is made of (`LayerMeshStore`).
struct LayerMeshKey: Hashable, Sendable {
    let source: String
    let sourceRevision: UInt64
    let polygonStyle: ImmersiveMapPolygonStyle
    let polylineStyle: ImmersiveMapPolylineStyle
    let pointStyle: ImmersiveMapPointStyle
}
