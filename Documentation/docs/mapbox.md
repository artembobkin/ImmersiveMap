# Mapbox vector tiles

ImmersiveMap renders Mapbox Vector Tiles through a first-party provider. Attach `MapboxTileProvider` with your public access token and the matching `MapboxMapStyle`, and the rest of the API is unchanged: the same camera, markers, avatars, labels and globe.

```swift
ImmersiveMapView()
    .tileProvider(MapboxTileProvider(accessToken: "pk.your-public-token"))
    .mapStyle(MapboxMapStyle())
```

The provider and the style go together. The provider knows how the Mapbox Streets schema names its layers and fields; the style is a palette written against those names. Attaching one without the other leaves features unclassified.

## Provider

```swift
public struct MapboxTileProvider: ImmersiveMapTileProvider {
    public static let defaultTilesetID = "mapbox.mapbox-streets-v8,mapbox.mapbox-terrain-v2"
    public static let defaultMaximumTileZoomLevel = 20

    public init(accessToken: String?, tilesetID: String = MapboxTileProvider.defaultTilesetID)
}
```

The default tileset composites Mapbox Streets with Mapbox Terrain, which is what feeds the contour and hillshade layers of the style. A different `tilesetID` (including your own Mapbox Studio tileset) works, as long as the style has something to say about its layers.

The token travels as a query parameter, the way the Mapbox Vector Tiles API expects. Use a **public** token (`pk.`); a secret token has no business in a client app.

## Attribution

`MapboxTileProvider` declares its attribution, and the badge shows it automatically:

> © Mapbox © OpenStreetMap - Improve this map

This is not optional decoration. Mapbox requires its own copyright and the OpenStreetMap copyright next to the map, and OpenStreetMap data is ODbL. Hiding the badge without crediting the sources elsewhere in the app breaks both. See [ATTRIBUTION.md](../../ATTRIBUTION.md) for what has to appear, where, and how to draw the credit yourself with `.attributionProvidedExternally()`.

## Styling

`MapboxMapStyle` is configured by `MapboxDefaultMapStyleConfiguration`, a value with builder methods:

```swift
let night = MapboxDefaultMapStyleConfiguration.mapboxDefault
    .layers { layers in
        layers.water = SIMD4<Float>(0.04, 0.09, 0.20, 1)
        layers.forest = SIMD4<Float>(0.06, 0.13, 0.10, 1)
        layers.roads.motorway = SIMD4<Float>(0.55, 0.47, 0.22, 1)
    }
    .features { features in
        features.buildingFillColor = SIMD4<Float>(0.18, 0.19, 0.23, 1)
    }
    .labels { labels in
        labels.city.fillColor = SIMD3<Float>(0.92, 0.94, 1.0)
        labels.city.strokeColor = SIMD3<Float>(0.02, 0.03, 0.06)
    }

ImmersiveMapView()
    .tileProvider(MapboxTileProvider(accessToken: token))
    .mapStyle(MapboxMapStyle(configuration: night))
```

`labels` covers per-kind text appearance (city, small settlement, district, capital, national capital, POI, landmark, road, water, continent, house number), `layers` covers area and line palettes including `layers.roads` and `layers.railway`, and `features` covers `buildingFillColor`. The configuration hashes every component into its `cacheFingerprint`, so a recolor invalidates prepared tiles correctly, see [map styling](styling.md) and [tile cache](tile-cache.md).

## Keeping the token out of the repository

A token is a credential. Do not put one in a source file that gets committed. The workable options, in order of preference:

1. A launch environment variable, which is what `Examples/macOS/ImmersiveMapMapboxMac` does. The scheme declares `IMMERSIVE_MAP_MAPBOX_ACCESS_TOKEN` with an empty value; each developer fills theirs in locally, and nothing lands in git.
2. A gitignored `.xcconfig` or plist read at launch.
3. Fetching it from your own backend at runtime, which is also what lets you rotate it.

Mapbox tokens are scoped and rotatable from the account dashboard. Scope a client token to tile reads only.

## Mapbox or the built-in source?

| | [Built-in tiles](map-data.md) | Mapbox |
|---|---|---|
| Account | None required | Mapbox account and token |
| Schema | OpenMapTiles | Mapbox Streets v8 |
| Maximum zoom | 14 | 20 |
| Terrain layers | No | Yes, with the default tileset |
| Billing | Free shared pool, or a key for your own throughput | Mapbox pricing per tile request |

Any third source works too, through `VectorTileProvider`, see [custom tile providers](custom-tile-provider.md).

## Limitations

- The style reads the Mapbox Streets schema. A custom Studio tileset with renamed layers needs a style of its own.
- Terrain layers are only present if the tileset includes them; the default composite does.
- Mapbox usage is billed by Mapbox and governed by their terms; nothing in this engine changes that.

Running example: [`Examples/macOS/ImmersiveMapMapboxMac`](../../Examples/macOS/ImmersiveMapMapboxMac) reads the token from the environment, falls back to an in-app field, and shows a restyled night palette.
