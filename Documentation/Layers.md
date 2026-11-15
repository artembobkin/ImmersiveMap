# Your own data

Layers draw your app's data on the map: zones as polygons, routes as lines, and places as points. They lie on the ground, over the roads and under the names and the buildings, on the globe and on the flat map alike.

It takes two steps. Register the data once, under a name. Then set the layers, which say what to draw of it and how:

```swift
@State private var layers = ImmersiveMapLayersController()

var body: some View {
    ImmersiveMapView()
        .layers(layers)
        .onAppear {
            layers.register("districts", geoJSONFile: districtsURL)
            layers.register("stops", identity: "v1", points: stops.map { ImmersiveMapPoint(coordinate: $0) })

            layers.set([
                ImmersiveMapLayer(source: "districts",
                                  polygonStyle: ImmersiveMapPolygonStyle(fillColor: SIMD4(0.9, 0.3, 0.2, 0.3))),
                ImmersiveMapLayer(source: "stops", zoomRange: 12...30)
            ])
        }
}
```

The layers draw in the order the controller holds them, so a later one covers an earlier one.

## Sources

A source is data with a name. It is not drawn until a layer names it.

- `register(_:geoJSONFile:)`: a GeoJSON document in a file.
- `register(_:geoJSON:identity:)`: a GeoJSON document in memory.
- `register(_:identity:polygons:polylines:points:)`: shapes you build in code.
- `unregister(_:)` removes a source, and `sourceNames` lists them.

A registered source costs nothing. Its data is read in the background when a layer first draws it, so you can register every file your app has and draw the few the user picks.

### Identity

The map never looks into your data to tell whether it changed. A file is known by its path, size and date. Data in memory is known by the `identity` you give it: a version, a date, an ETag.

```swift
layers.register("parks", geoJSON: data, identity: response.etag)
```

The same identity means the same data. Registering it again does nothing, and a layer prepared from it earlier is reused. When the data changes, give it another identity, or the map goes on drawing the old data.

A file may be read again later, so it has to stay where it is.

## Fast starts

A layer is prepared for the GPU once and saved in the app's Caches directory. On the next launch it is loaded from there, straight into the GPU, and its source is not read at all. A changed file, another identity or a changed style is prepared anew.

The saved layers take up to 256 MB of disk, and the ones used least recently are deleted first. Set your own limit, or zero to save nothing:

```swift
ImmersiveMapLayersController(cacheLimitBytes: 64 * 1024 * 1024)
```

Shapes that change often, such as a live route, get a new saved layer with each identity. Keep such a source small, or lower the limit.

## GeoJSON

A source reads a FeatureCollection, a Feature or a bare geometry. Polygons become zones, LineStrings lines and Points points.

A feature's own [simplestyle](https://github.com/mapbox/simplestyle-spec) properties (`fill`, `fill-opacity`, `stroke`, `stroke-opacity`, `stroke-width`, `marker-color`, `marker-size`, and `marker-radius` in points) style it, over the styles of the layer that draws it.

A file that cannot be read, or a document that is not GeoJSON, is reported:

```swift
layers.onSourceFailed = { name, error in
    print(name, error)
}
```

## Shapes

- `ImmersiveMapPolygon(exterior:holes:)`: a zone, its outline and any holes as rings of `GeoCoordinate`.
- `ImmersiveMapPolyline(coordinates:)`: a line through the coordinates.
- `ImmersiveMapPoint(coordinate:)`: a dot.

Each shape has an `id`, which names it in a tap and in a selection. Pass your own, or leave it out and the shape goes by its place in the source. A GeoJSON feature's shapes take the feature's `id` when it is a whole number, and the feature's place in the document otherwise.

## Layers and styles

A layer draws one source. Its `id` is the source's name unless you give one, which you need when two layers draw the same source:

```swift
layers.set([
    ImmersiveMapLayer(id: "districts-far", source: "districts", zoomRange: 0...10),
    ImmersiveMapLayer(id: "districts-near", source: "districts",
                      polygonStyle: ImmersiveMapPolygonStyle(strokeWidthPoints: 4),
                      zoomRange: 10...30)
])
```

Each layer has one style per kind of shape, and a shape can carry its own, which wins.

- `ImmersiveMapPolygonStyle(fillColor:strokeColor:strokeWidthPoints:)`: the fill and the outline.
- `ImmersiveMapPolylineStyle(color:widthPoints:)`: a line with round joins and ends.
- `ImmersiveMapPointStyle(color:radiusPoints:strokeColor:strokeWidthPoints:)`: a disc with a ring around it.

Colours are RGBA from 0 to 1. Widths and radii are in screen points, so they stay the same size at every zoom. A zero alpha or a zero width leaves that part out.

Lines and outlines are always solid. A fill and a point can be translucent, but for a line the alpha only says whether it draws: zero leaves it out, and anything else draws it opaque. A GeoJSON feature's `stroke-opacity` is treated the same way.

A line's edge is not softened, which lets the map draw even hundreds of thousands of segments cheaply. For smooth edges, turn on `.msaa()`.

## Showing and hiding

```swift
ImmersiveMapLayer(source: "zones",
                  isVisible: showZones,
                  zoomRange: 10...18,
                  hidesBehindTerrain: true)
```

- `isVisible`: `layers.setVisible(id: "zones", false)` hides a layer the controller holds. A hidden layer keeps what was prepared of it while memory allows, so showing it again is immediate.
- `zoomRange`: the camera zooms the layer draws at.
- `hidesBehindTerrain`: lets a mountain in front of the layer cover it. Off by default, so a layer shows over the relief everywhere.

## Updates

Change the layers through the controller:

- `set(_:)` replaces every layer, and a layer left out is let go.
- `upsert(_:)` puts a layer in the place of the one with its id, or adds it after the last one.
- `remove(id:)`, `remove(ids:)` and `clear()` take layers away.
- `layers` and `layer(id:)` read what the controller holds.

A layer is a small value, so setting the same layers again costs nothing. The map prepares a changed layer in the background and goes on drawing the old one until the new one is ready. To change the data, register the new data under the same name, with another identity.

The controller is thread-safe.

## Memory

The map reads a source's data to prepare a layer, and lets it go once the layer is prepared. A map that listens to taps on its layers, with `.onLayerTap` or a selection controller, keeps the data of the layers it draws, since a tap is tested against it.

The data held at one time is bounded by one limit, 64 MB by default: 16 bytes for a coordinate and a small fixed cost for a shape.

```swift
ImmersiveMapLayersController(inputLimitBytes: 128 * 1024 * 1024)
```

If the sources needed at once do not fit, the one drawn last in the layers' order is refused, and `onSourceFailed` reports `.limitExceeded`. It is read again when another source is no longer needed.

When the system warns of low memory, the map lets go of everything it prepared for the layers that are not drawn. It comes back when they are shown.

## Taps and selection

```swift
ImmersiveMapView()
    .layers(layers)
    .onLayerTap { event in
        print(event.layer.id, event.shapeID, event.coordinate)
    }
```

A tap lands on the shape the map shows under it: of the layer drawn last first, and within a layer its points, then its lines, then its zones. A zone is hit in its fill, or on its outline when it has no fill. A thin line and a small point grow to a touch target. A pin or a model over a shape takes the tap first.

With an `ImmersiveMapSelectionController` (see [Annotations, pins and taps](AnnotationsAndPins.md)), a tap also selects the shape:

```swift
selection.onSelectionChanged = { event in
    if let layerID = event.selection.kind.layerID {
        highlight(layerID, shape: event.selection.objectID)
    }
}

selection.select(ImmersiveMapSelection(kind: .layer("districts"), objectID: 42))
```

A selected shape looks the same as before. To highlight it, draw it yourself: register the shape as a source of its own and add a layer over it.
