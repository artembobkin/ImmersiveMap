# Custom Tile Sources

The tile source is one URL template: where bytes come from and nothing else. How those bytes are parsed and drawn is configured separately, through the map style. This page covers both halves.

## The source: one URL template

```swift
ImmersiveMapView()
    .tileURLTemplate("https://tiles.com/{x}/{y}/{z}?apiKey=xxx")
```

The `{x}`, `{y}` and `{z}` placeholders may appear in any order and the query string is preserved as written, so a key can live in the template. Credentials that travel as HTTP headers go in the second parameter, added to every tile request (offline region downloads included):

```swift
ImmersiveMapView()
    .tileURLTemplate("https://tiles.com/{x}/{y}/{z}",
                     headers: ["Authorization": "Bearer xxx"])
```

Prefer the header where the service allows it: a key in the URL becomes part of the CDN cache key, so every customer gets a private copy of tiles that are byte-identical for everyone.

The template and the request header *names* are part of the tile cache identity, header *values* are not: pointing the map at a different endpoint re-keys the disk caches on its own, while rotating a credential keeps them warm. A header whose value selects different tile content (rare) needs a style `configurationFingerprint` bump to invalidate them.

Without the modifier the map renders the hosted `ImmersiveMapTilesService` source. A source that does not ship the default z0-16 states its depth next to the template with `.tileMaximumZoomLevel(_:)` (the direct field is `tiles.coverage.maximumZoomLevel`): a source that stops at z14 needs `.tileMaximumZoomLevel(14)`, or the renderer keeps asking for tiles the endpoint cannot answer. Past the deepest level the camera keeps zooming and the deepest tiles are scaled up; offline region downloads clamp to the same level. For full control (a base URL with TileJSON discovery instead of a fixed template), the same fields live on `ImmersiveMapSettings.TileSettings.NetworkSettings`, see [tile cache](tile-cache.md).

## The style: how the bytes are drawn

The default `ImmersiveMapTilesMapStyle` draws OpenMapTiles-schema MVT, so an endpoint in that schema (a self-hosted OpenFreeMap/OpenMapTiles planet build) needs only the template. Any other schema pairs the template with a hand-written style:

```swift
ImmersiveMapView()
    .tileURLTemplate("https://tiles.com/{x}/{y}/{z}")
    .mapStyle(VectorTileMapStyle(style: MyVectorTileStyle()))
```

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

`ImmersiveMapFeatureStyleContext` carries the layer name, the tile coordinate and the feature's MVT properties (`string`, `double`, `integer`, `bool`), which is everything needed to classify a feature. The cases of `ImmersiveMapFeatureStyle` are `.hidden`, `.polygon`, `.line`, `.pointLockedLine`, `.extrudedPolygon`, `.pointLabel` and `.roadLabel`. An optional `baseColors` overrides the engine-level backdrop colors, see [map styling](styling.md).

## Point-locked lines

Two line modes exist, and the difference is what the width means. `.line(color:width:)` is a surface on the ground: its width lives in tile units, so it grows and shrinks with the world, which is right for roads seen up close. `.pointLockedLine(color:widthPoints:dashLengthPoints:dashGapPoints:)` is a drawn stroke: its width (and optional dash pattern) is stated in on-screen points and held there at every zoom, the stroke is opaque from the first frame it is visible, and it ends in butt caps. This is the mode the built-in style draws country borders and the overview road skeleton with, and it is the right choice for any symbolic line whose weight is a design decision rather than a width on the ground: borders, grid lines, a network over a country view.

```swift
case "boundary":
    .pointLockedLine(color: SIMD4<Float>(0.42, 0.36, 0.46, 1),
                     widthPoints: 1.2, dashLengthPoints: 6, dashGapPoints: 3)
```

Areal geometry a source ships under a point-locked line style is not filled; only the outlines draw (a boundary layer sometimes carries polygons). `Examples/macOS/ImmersiveMapCustomTilesMac` uses the mode for its boundary layer.

## Label profile

`VectorTileMapStyle` also carries the label profile, which tells the engine which MVT properties carry label text, rank and kind, since every schema names them differently:

```swift
VectorTileMapStyle(
    style: MyVectorTileStyle(),
    labelProfile: ImmersiveMapVectorTileLabelProfile(
        textKeys: ["name:en", "name"],
        rankKeys: ["rank"],
        kindKeys: ["class"],
        pointLabelLayers: ["place"]))
```

`.generic` is the default and reads `name:en` with the usual rank keys. The profile is part of the style's fingerprint, so changing it invalidates prepared tiles correctly.

## Map style fingerprints

Styles conform to `ImmersiveMapMapStyle` (see `Provider/Core/ImmersiveMapMapStyle.swift`) and expose a `configurationFingerprint`. **This is important:** the fingerprint drives disk-cache identity, because prepared tiles are cached on disk with the style baked in. Any change to style configuration that changes the produced tiles must change the fingerprint, otherwise stale tiles are served from disk, see [tile cache](tile-cache.md). `VectorTileMapStyle` derives its fingerprint from the vector tile style's `cacheFingerprint` and the label profile; pass `configurationFingerprint:` to override.

## Schema logic stays at the edge

MVT layers differ between sources (OpenMapTiles is one schema; other tile services name their layers and fields differently). Schema normalization is confined to `VectorTileAdaptation/` and `Provider/ImmersiveMapTiles/`. The rest of the engine (`Render`, `Labels`, `Tile`) consumes only neutral, normalized data - keep schema quirks inside the adaptation layer.

## Attribution

The default badge credits the hosted source ("© OpenStreetMap © OpenMapTiles"). An app pointing the map at its own data owns the credit, because the engine cannot know what the endpoint serves. Declare it:

```swift
ImmersiveMapView()
    .tileURLTemplate("https://tiles.com/{z}/{x}/{y}.mvt")
    .attributionSettings(ImmersiveMapSettings.AttributionSettings(
        attributionOverride: .openStreetMap))
```

`.openStreetMap` is the credit for plain OpenStreetMap data and nothing else. A planet built in the OpenMapTiles schema (which includes the source this engine ships with) owes a second credit, so it needs the spelled-out form below rather than the preset.

Or spell it out for a mixed or custom dataset:

```swift
attributionOverride: ImmersiveMapAttribution(
    title: "© OpenStreetMap contributors",
    copyright: "My Company basemap",
    linkURL: URL(string: "https://www.openstreetmap.org/copyright")
)
```

`title` is the badge's first line; an empty `copyright` renders a one-line badge, a non-empty one adds a second, smaller line. An explicit `ImmersiveMapAttribution.none` empties the badge.

The badge can also be restyled with `attributionSettings(size:position:margin:textColor:)` (the margin is the distance from the corner; 0, the default, pins the badge tightly into it) or hidden with `attributionSettings(isVisible: false)`, but hiding required attribution without crediting the source elsewhere in the app breaks the data licence. A map that starts with a hidden or empty badge logs a one-time console warning; an app that shows the credit itself declares that with `.attributionProvidedExternally()`.

Running example: [`Examples/macOS/ImmersiveMapCustomTilesMac`](../../Examples/macOS/ImmersiveMapCustomTilesMac) wires a template, request headers, a hand-written style with a label profile, and an attribution end to end, entirely through the public API.
