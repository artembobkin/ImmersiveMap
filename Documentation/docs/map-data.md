# Where the Map Data Comes From

A map engine draws tiles, it does not produce them. Here is exactly what you are rendering when you write `ImmersiveMapView()` and nothing else.

**Out of the box.** The default provider fetches vector tiles from `immersivemap.dev`, the tile service run for this project. It serves a planet build in the [OpenMapTiles](https://openmaptiles.org) schema, assembled from [OpenFreeMap](https://openfreemap.org) data, which is [OpenStreetMap](https://www.openstreetmap.org/copyright) data under ODbL. No token, no account, no sign-up, and the demo apps in this repository render against it directly.

**A key of your own.** The default provider works anonymously on a shared public pool. A free key from [immersivemap.dev/account](https://immersivemap.dev/account) moves you onto your own throughput; attach it as a request header, `.tileURLTemplate("https://immersivemap.dev/tiles/{z}/{x}/{y}.mvt", headers: ["Authorization": "Bearer im_…"])`. The header form is deliberate: a key in the URL becomes part of the CDN cache key, so every customer would get a private copy of tiles that are byte-identical for everyone. The demo apps in this repository read the key from the `IMMERSIVEMAP_API_KEY` environment variable; their schemes carry it with an empty value as a placeholder, so paste your own key there (Edit Scheme → Run → Arguments) and keep it out of commits.

**Your own endpoint, one line.** An OpenMapTiles-schema endpoint of your own (a self-hosted planet build, a different tile service) plugs in with a single URL template, drawn by the built-in style:

```swift
ImmersiveMapView()
    .tileURLTemplate("https://tiles.com/{x}/{y}/{z}?apiKey=xxx")
```

`{x}`, `{y}` and `{z}` may appear in any order and the query string is preserved, so a key can live in the template. Credentials that travel as headers go in the second parameter: `.tileURLTemplate("https://tiles.com/{x}/{y}/{z}", headers: ["X-API-Key": "xxx"])`.

**Your own tiles.** Any MVT source works the same way: your own tile server, your own planet build, or any service that speaks MVT. A source in another schema pairs the template with your own style, `.mapStyle(VectorTileMapStyle(style:labelProfile:))`. See the [custom tile source guide](custom-tile-provider.md).

## Attribution is not optional

Map data carries licence obligations, and the most common one, ODbL for OpenStreetMap data, requires visible credit in your app.

For the default source the engine handles this for you: the badge shows the one-line credit "© OpenStreetMap © OpenMapTiles" linking to the full license story, which is what the built-in tiles require. You do not have to write anything.

If you point the map at your own data with `.tileURLTemplate`, the credit is yours to get right, because the engine cannot know what your endpoint serves. Declare it:

```swift
ImmersiveMapView()
    .tileURLTemplate("https://tiles.com/{z}/{x}/{y}.mvt")
    .attributionSettings(ImmersiveMapSettings.AttributionSettings(
        attributionOverride: .openStreetMap))   // or your own ImmersiveMapAttribution
```

The badge is adjustable without touching the credit itself:

```swift
ImmersiveMapView()
    .attributionSettings(size: .large,             // .small / .regular / .large
                         margin: 12,               // distance from the corner; 0 (default) pins it tight
                         position: .topLeading,    // four corners plus .bottomCenter / .topCenter
                         textColor: SIMD4<Float>(1, 1, 1, 1))
```

You can also hide it with `.attributionSettings(isVisible: false)`, but only if your app credits the data source somewhere else. Hiding required attribution outright breaks the data licence, and that is on the app, not on the engine. A map that starts with a hidden (or empty) badge logs a one-time console warning as a reminder. Once your app does show the credit on its own, declare it:

```swift
ImmersiveMapView()
    .attributionSettings(isVisible: false)
    .attributionProvidedExternally()   // silences the hidden-attribution warning
```

The licence obligations in full (what each provider requires, where the credit has to appear, what stays your app's responsibility) and the whole badge API are covered in [ATTRIBUTION.md](../../ATTRIBUTION.md).
