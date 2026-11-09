# Your own data

Layers draw your app's data on the map: zones as polygons, routes as lines, and places as points. They lie on the ground, over the roads and under the names and the buildings, on the globe and on the flat map alike.

```swift
ImmersiveMapView()
    .layers([
        ImmersiveMapLayer(id: "route",
                          polylines: [ImmersiveMapPolyline(coordinates: route)],
                          polylineStyle: ImmersiveMapPolylineStyle(color: SIMD4(0.9, 0.2, 0.2, 1), widthPoints: 4)),
        ImmersiveMapLayer(id: "stops",
                          points: stops.map { ImmersiveMapPoint(coordinate: $0) })
    ])
```

The layers draw in the order given, so a later one covers an earlier one. A later `.layers(...)` call replaces the layers of an earlier one.

## Shapes

- `ImmersiveMapPolygon(exterior:holes:)`: a zone, its outline and any holes as rings of `GeoCoordinate`.
- `ImmersiveMapPolyline(coordinates:)`: a line through the coordinates.
- `ImmersiveMapPoint(coordinate:)`: a dot.

## Styles

Each layer has one style per kind of shape, and a shape can carry its own, which wins.

- `ImmersiveMapPolygonStyle(fillColor:strokeColor:strokeWidthPoints:)`: the fill and the outline.
- `ImmersiveMapPolylineStyle(color:widthPoints:)`: a line with round joins and ends.
- `ImmersiveMapPointStyle(color:radiusPoints:strokeColor:strokeWidthPoints:)`: a disc with a ring around it.

Colours are RGBA from 0 to 1. Widths and radii are in screen points, so they stay the same size at every zoom. A zero alpha or a zero width leaves that part out.

```swift
ImmersiveMapPolygon(exterior: park,
                    style: ImmersiveMapPolygonStyle(fillColor: SIMD4(0.2, 0.7, 0.3, 0.3),
                                                    strokeColor: SIMD4(0.2, 0.7, 0.3, 1),
                                                    strokeWidthPoints: 2))
```

## GeoJSON

A layer can be made from a GeoJSON document: a FeatureCollection, a Feature or a bare geometry.

```swift
let districts = try ImmersiveMapLayer(id: "districts", geoJSON: data)
```

Polygons become zones, LineStrings lines and Points points. A feature's own [simplestyle](https://github.com/mapbox/simplestyle-spec) properties (`fill`, `fill-opacity`, `stroke`, `stroke-opacity`, `stroke-width`, `marker-color`, `marker-size`) style it, over the layer's styles. A document that is not GeoJSON throws `ImmersiveMapGeoJSONError`.

## Showing and hiding

```swift
ImmersiveMapLayer(id: "zones", polygons: zones,
                  isVisible: showZones,
                  zoomRange: 10...18,
                  hidesBehindTerrain: true)
```

- `isVisible`: a hidden layer keeps its data ready, so showing it again is immediate.
- `zoomRange`: the camera zooms the layer draws at.
- `hidesBehindTerrain`: lets a mountain in front of the layer cover it. Off by default, so a layer shows over the relief everywhere.

## Updates

Change the data and pass the layers again: the map prepares a changed layer in the background and swaps it in when it is ready. Two layers built from the same data are equal, so a view that rebuilds its layers on every update costs nothing until the data really changes.
