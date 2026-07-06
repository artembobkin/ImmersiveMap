# Custom Tile Providers

ImmersiveMap is built around pluggable tile providers. A provider describes *where* tiles come from and *how* their vector data maps to labels; a map style describes *how* the data is drawn.

The provider protocols live in `ImmersiveMap/Provider/`.

## The quick path: `VectorTileProvider`

If you have an MVT (Mapbox Vector Tile) endpoint, you often don't need a new type. `VectorTileProvider` wraps any tile source:

```swift
let provider = VectorTileProvider(
    id: "my-tiles",
    tileSource: /* ImmersiveMapTileSource pointing at your MVT URL template */,
    labelProfile: .generic,
    maximumTileZoomLevel: 14
)

ImmersiveMapView()
    .tileProvider(provider)
    .mapStyle(/* your ImmersiveMapMapStyle */)
```

## Conforming to `ImmersiveMapTileProvider`

For full control, conform to the protocol:

```swift
public protocol ImmersiveMapTileProvider {
    var id: String { get }
    var cacheNamespace: String { get }
    var configurationFingerprint: UInt64 { get }
    var tileSource: ImmersiveMapTileSource { get }
    var maximumTileZoomLevel: Int? { get }
}
```

- `id` — stable identifier for the provider.
- `cacheNamespace` — namespace used for on-disk cache identity.
- `configurationFingerprint` — an FNV-1a fingerprint of the provider configuration. **This is important:** the fingerprint drives disk-cache identity, so any change to provider config that changes the produced tiles must change the fingerprint. Otherwise stale tiles are served from disk.
- `tileSource` — describes the tile URLs / scheme.
- `maximumTileZoomLevel` — optional cap on requested zoom.

The built-in `MapboxTileProvider` and `OpenStreetMapTileProvider` are concrete examples worth reading.

## Map styles

Providers pair with an `ImmersiveMapMapStyle` (see `Provider/ImmersiveMapMapStyle.swift`). Styles expose a `configurationFingerprint` and a `vectorTileStyle`. As with providers, changing style configuration must change the fingerprint so caches stay correct.

## Provider-specific schema logic

MVT layers differ between providers (Mapbox streets vs OpenStreetMap / Shortbread). Provider-specific schema normalization is confined to `VectorTileAdaptation/`, `mapbox/`, and `openstreetmap/`. The rest of the engine (`Render`, `Labels`, `Tile`) consumes only provider-neutral, normalized data — keep provider quirks inside the adaptation layer.

## Attribution

Tile provider terms and attribution are the responsibility of the app developer. Make sure your app satisfies the license and attribution requirements of whatever tile source you point at.
