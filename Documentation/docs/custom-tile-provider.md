# Custom Tile Providers

ImmersiveMap is built around pluggable tile providers. A provider describes *where* tiles come from and *how* their vector data maps to labels; a map style describes *how* the data is drawn.

The provider protocols live in `ImmersiveMap/Provider/`.

## The quick path: `VectorTileProvider`

If you have an MVT (Mapbox Vector Tile) endpoint, you often don't need a new type. `VectorTileProvider` wraps any tile source:

```swift
let provider = VectorTileProvider(
    id: "my-tiles",
    tileSource: ImmersiveMapTileSource(tileBaseURL: myTileURL),
    labelProfile: .generic,
    maximumTileZoomLevel: 14,
    attribution: .openStreetMap
)

ImmersiveMapView()
    .tileProvider(provider)
    .mapStyle(VectorTileMapStyle(style: MyVectorTileStyle()))
```

## Tile source

```swift
public struct ImmersiveMapTileSource: Equatable, Sendable {
    public var tileBaseURL: URL
    public var tileJSONURL: URL?
    public var accessToken: String?
    public var authorization: AuthorizationMode   // .bearerHeader | .accessTokenQuery(parameterName:)

    public init(tileBaseURL:tileJSONURL:accessToken:authorization:)
    public static func url(_ tileBaseURL: URL) -> ImmersiveMapTileSource
    public func token(_ accessToken: String?) -> ImmersiveMapTileSource
    public func accessToken(_ accessToken: String?, parameterName: String = "access_token") -> ImmersiveMapTileSource
}
```

The loader appends `/{z}/{x}/{y}.mvt` to `tileBaseURL`. When `tileJSONURL` is set it first discovers a versioned, immutable tile URL template from that endpoint and falls back to the base path until (or unless) it resolves, which is what makes tiles CDN-cacheable rather than always revalidated.

`token(_:)` sends the credential in an `Authorization: Bearer` header, `accessToken(_:parameterName:)` puts it in a query parameter. Prefer the header where the service allows it: a key in the URL becomes part of the CDN cache key, so every customer gets a private copy of tiles that are byte-identical for everyone.

## Vector tile styles

A style is one function over a feature:

```swift
struct MyVectorTileStyle: ImmersiveMapVectorTileStyle {
    let cacheFingerprint: UInt32 = 1   // bump whenever the rules below change

    func makeStyle(for feature: ImmersiveMapFeatureStyleContext) -> ImmersiveMapFeatureStyle {
        switch feature.layerName {
        case "water":     .polygon(color: SIMD4<Float>(0.10, 0.20, 0.36, 1))
        case "building":  .extrudedPolygon(color: SIMD4<Float>(0.22, 0.24, 0.29, 1), fallbackHeight: 8)
        case "transportation": .line(color: SIMD4<Float>(0.28, 0.29, 0.31, 1), width: 1.2)
        default:          .hidden
        }
    }
}
```

`ImmersiveMapFeatureStyleContext` carries the layer name, the tile coordinate and the feature's MVT properties (`string`, `double`, `integer`, `bool`), which is everything needed to classify a feature. The cases of `ImmersiveMapFeatureStyle` are `.hidden`, `.polygon`, `.line`, `.extrudedPolygon`, `.pointLabel` and `.roadLabel`. An optional `baseColors` overrides the engine-level backdrop colors, see [map styling](styling.md).

Wrap it in `VectorTileMapStyle(style:)` to attach it.

## Label profile

`ImmersiveMapVectorTileLabelProfile` tells the provider which MVT properties carry label text, rank and kind, since every schema names them differently:

```swift
labelProfile: ImmersiveMapVectorTileLabelProfile(
    textKeys: ["name:en", "name"],
    rankKeys: ["rank"],
    kindKeys: ["class"],
    pointLabelLayers: ["place"])
```

`.generic` is the default and reads `name:en` with the usual rank keys. The profile is part of the provider's fingerprint, so changing it invalidates prepared tiles correctly.

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

The built-in `ImmersiveMapTilesProvider` is a concrete example worth reading.

## Map styles

Providers pair with an `ImmersiveMapMapStyle` (see `Provider/Core/ImmersiveMapMapStyle.swift`). Styles expose a `configurationFingerprint` and a `vectorTileStyle`. As with providers, changing style configuration must change the fingerprint so caches stay correct: prepared tiles are cached on disk with the style baked in, see [tile cache](tile-cache.md).

## Provider-specific schema logic

MVT layers differ between providers (OpenMapTiles is one schema; other tile services name their layers and fields differently). Provider-specific schema normalization is confined to `VectorTileAdaptation/` and the concrete provider folder `Provider/ImmersiveMapTiles/`. The rest of the engine (`Render`, `Labels`, `Tile`) consumes only provider-neutral, normalized data - keep provider quirks inside the adaptation layer.

## Attribution

The attribution badge takes its text from the active tile provider, so a provider is the right place to declare who owns the data it fetches. The engine never substitutes its own name: a provider that declares nothing renders no badge.

Most open data carries a licence obligation. OpenStreetMap under ODbL requires visible credit, and so do OpenMapTiles and every commercial provider. Declare it:

```swift
let provider = VectorTileProvider(
    id: "my-tiles",
    tileSource: ImmersiveMapTileSource(tileBaseURL: myTileURL),
    attribution: .openStreetMap
)
```

`.openStreetMap` is the credit for plain OpenStreetMap data and nothing else. A planet built in the OpenMapTiles schema (which includes the source this engine ships with) owes a second credit, so it needs the spelled-out form below rather than the preset.

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

Running example: [`Examples/macOS/ImmersiveMapCustomTilesMac`](../../Examples/macOS/ImmersiveMapCustomTilesMac) wires a provider, a tile source, a hand-written style and an attribution end to end, entirely through the public API.
