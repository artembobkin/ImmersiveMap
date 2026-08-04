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
    var attribution: ImmersiveMapAttribution { get }
}
```

- `id` - stable identifier for the provider.
- `cacheNamespace` - namespace used for on-disk cache identity.
- `configurationFingerprint` - an FNV-1a fingerprint of the provider configuration. **This is important:** the fingerprint drives disk-cache identity, so any change to provider config that changes the produced tiles must change the fingerprint. Otherwise stale tiles are served from disk.
- `tileSource` - describes the tile URLs / scheme.
- `maximumTileZoomLevel` - optional cap on requested zoom.
- `attribution` - what the attribution badge shows while this provider is active. Defaults to `.none`, which renders no badge at all.

The built-in `ImmersiveMapTilesProvider` and `MapboxTileProvider` are concrete examples worth reading.

## Map styles

Providers pair with an `ImmersiveMapMapStyle` (see `Provider/ImmersiveMapMapStyle.swift`). Styles expose a `configurationFingerprint` and a `vectorTileStyle`. As with providers, changing style configuration must change the fingerprint so caches stay correct.

## Provider-specific schema logic

MVT layers differ between providers (Mapbox Streets vs OpenMapTiles). Provider-specific schema normalization is confined to `VectorTileAdaptation/` and the concrete provider folders under `Provider/`. The rest of the engine (`Render`, `Labels`, `Tile`) consumes only provider-neutral, normalized data - keep provider quirks inside the adaptation layer.

## Attribution

The attribution badge takes its text from the active tile provider, so a provider is the right place to declare who owns the data it fetches. The engine never substitutes its own name: a provider that declares nothing renders no badge.

Most open data carries a licence obligation. OpenStreetMap under ODbL requires visible credit, and so do OpenMapTiles and every commercial provider. Declare it:

```swift
let provider = VectorTileProvider(
    id: "my-tiles",
    tileSource: .immersiveMapTiles(tileBaseURL: myTileURL, apiKey: nil),
    attribution: .openStreetMap
)
```

Or spell it out for a mixed or custom dataset:

```swift
attribution: ImmersiveMapAttribution(
    title: "© OpenStreetMap contributors",
    copyright: "My Company basemap",
    linkURL: URL(string: "https://www.openstreetmap.org/copyright")
)
```

`title` is the badge's first line; an empty `copyright` renders a one-line badge, a non-empty one adds a second, smaller line.

An app can override the badge text with `attributionSettings(.init(attributionOverride:))` or hide it with `attributionSettings(isVisible: false)`, but hiding required attribution without crediting the source elsewhere in the app breaks the data licence. A map that starts with a hidden or empty badge logs a one-time console warning; an app that shows the credit itself declares that with `.attributionProvidedExternally()`.
