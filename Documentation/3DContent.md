# 3D content

The map can show two kinds of 3D models: detailed buildings from a model archive, which replace the map's own boxes, and your own models placed anywhere.

## Building models

The map raises every building from its footprint. A model archive replaces some of them with detailed models, such as the Kremlin or a skyscraper. The models are off by default. Turn them on with the hosted archive:

```swift
ImmersiveMapView()
    .modelArchive(ImmersiveMapTilesService.modelArchiveURL)
```

The archive is a PMTiles file read like the [tile source](TileSource.md): over HTTP range requests, or from disk for a file URL, with `headers` for credentials. The models of the area in view load as the camera moves and are kept on disk. A building stays drawn until its model has loaded, so the map never shows a gap. `.modelArchive(nil)` turns them off again.

How they load and draw:

```swift
.modelArchiveSettings(memoryBudgetInBytes: 300_000_000,
                      depthBias: [14: 0.05, 15.5: 0.01],
                      minimumZoom: 14)
```

- `memoryBudgetInBytes` and `diskCacheSizeInBytes`: how much of the models stays in memory and on disk.
- `depthBias`: draws a model slightly nearer than it stands, so it covers the plain building it replaces.
- `minimumZoom`: the camera zoom the models appear at.

## Your own models

Place USDZ or OBJ models at coordinates with an `ImmersiveMapSceneModelsController`:

```swift
@State private var models = ImmersiveMapSceneModelsController()

var body: some View {
    ImmersiveMapView()
        .sceneModels(models)
        .onAppear {
            models.set([
                ImmersiveMapSceneModel(id: 1,
                                       source: .init(resource: "balloon", withExtension: "usdz")!,
                                       coordinate: GeoCoordinate(latitude: 48.8584, longitude: 2.2945),
                                       altitudeMeters: 120,
                                       headingDegrees: 90,
                                       fitDiameterMeters: 40),
            ])
        }
}
```

- **The file** must be local: a bundle resource or a file you downloaded. Models that share a file share one loaded mesh.
- **Size.** One unit of the file is one metre. `scale` multiplies it, and `fitDiameterMeters` resizes the model so its largest side spans that many metres.
- **Placement.** `altitudeMeters` above the ground, `headingDegrees` clockwise from north, and `pitchDegrees` and `rollDegrees`.
- **Changes.** `move(id:to:)`, `setOrientation(id:...)`, `setScale(id:_:)` and `setAltitude(id:meters:)` animate over `duration`, 0.3 seconds by default.

### Flying along a path

```swift
models.animate(id: 1,
               along: ImmersiveMapGeoPath(from: start, to: end, peakAltitudeMeters: 300),
               duration: 20) { finished in
    // false when it was interrupted
}
```

The model turns to its direction of travel. To have the camera fly with it, start `camera.follow(path:duration:)` (see [Camera](Camera.md)) with the same path, duration and curve.

Taps on models arrive in `.onSceneModelTap` (see [Markers and taps](MarkersAndTaps.md)).
