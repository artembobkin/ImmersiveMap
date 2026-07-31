# Where the Map Data Comes From

A map engine draws tiles, it does not produce them. Here is exactly what you are rendering when you write `ImmersiveMapView()` and nothing else.

**Out of the box.** The default provider fetches vector tiles from `tiles.immersivemap.dev`, the tile service run for this project. It serves a planet build in the [OpenMapTiles](https://openmaptiles.org) schema, assembled from [OpenFreeMap](https://openfreemap.org) data, which is [OpenStreetMap](https://www.openstreetmap.org/copyright) data under ODbL. No token, no account, no sign-up, and the demo apps in this repository render against it directly.

**Your own tiles.** Any MVT source works through `VectorTileProvider`: your own tile server, your own planet build, or any service that speaks MVT. See the [custom tile provider guide](custom-tile-provider.md).

**Mapbox.** `MapboxTileProvider` renders Mapbox vector tiles with your own access token, paired with `MapboxMapStyle`.

## Attribution is not optional

Map data carries licence obligations, and the most common one, ODbL for OpenStreetMap data, requires visible credit in your app.

The engine handles this for you: **the attribution badge takes its text from the active tile provider**, so the built-in tiles credit OpenStreetMap, OpenFreeMap and OpenMapTiles. Each provider carries the credit its own data requires, and only while that provider is active. You do not have to write anything.

If you build a custom `VectorTileProvider`, declare its attribution, because the engine will not invent one for you:

```swift
VectorTileProvider(
    id: "my-tiles",
    tileSource: .immersiveMapTiles(tileBaseURL: myTileURL, apiKey: nil),
    attribution: .openStreetMap    // or your own ImmersiveMapAttribution
)
```

You can restyle or relocate the badge, and hide it with `attributionSettings(.init(isVisible: false))`, but only if your app credits the data source somewhere else. Hiding required attribution outright breaks the data licence, and that is on the app, not on the engine.
