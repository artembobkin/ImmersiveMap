# Map styling and colors

Two different things decide what the map looks like, and it is worth knowing which one you want.

- **The map style** owns the palette of the data: water, forest, roads by class, buildings, label colors. It belongs to the tile provider, because a palette is written against a particular MVT schema. Attached with `.mapStyle(_:)`.
- **`StyleSettings`** owns the handful of engine-level colors and switches that are not per-feature: the backdrop behind tiles, the globe background, the building extrusion mode. Attached with `.styleSettings(_:)`.

## The built-in palette

The default map is a light, warm, low-contrast palette in the manner of the system maps people already know: a warm off-white ground, soft pastel greens for parks and forests, a clear light blue for water, and asphalt-grey streets in the manner of a driving map: one grey road surface across the whole automobile network, each road with a slightly deeper edge, in a hierarchy that reads as width alone (wide motorways down to narrow service alleys). A road is a stroke whose width is its class's alone, a motorway the widest and a service alley the narrowest, with a casing and bare asphalt; the real carriageway width from the lane count, the measured surfaces and the lane paint are the opt-in [streetscape](streetscape.md). Buildings are a warm light grey a step under the ground, so a roof separates from the street around it and the renderer's wall shading separates the walls from the roof. The overview biomes of the globe are the same colors, class by class, so nothing shifts hue while zooming.

Three engine defaults are matched to it so a still-loading map, the horizon haze and the placeholder globe wear the ground the tiles will paint over them: `SceneSettings.mapClearColor` and `StyleSettings.baseColors.tileBackground` are the palette's land, and `baseColors.water` is its water (which is what the polar cap continues the ocean with). A custom palette that moves the land or the water color should move those three with it, otherwise loading flashes a lighter patch and the pole changes color at the cap.

Shadows are not in the palette but complete the picture: they are soft and cool by default (see [buildings and shadows](buildings-and-shadows.md) for `ShadowSettings.strength` and `tint`), so a shadowed street still reads as daylight.

## Restyling the built-in map

The default provider's style is `ImmersiveMapTilesMapStyle`, configured by `ImmersiveMapTilesDefaultMapStyleConfiguration`. It is a value with builder methods, so a recolor is a chain:

```swift
let night = ImmersiveMapTilesDefaultMapStyleConfiguration.immersiveMapTilesDefault
    .layers { layers in
        layers.land = SIMD4<Float>(0.08, 0.09, 0.11, 1)
        layers.water = SIMD4<Float>(0.06, 0.14, 0.28, 1)
        layers.wood = SIMD4<Float>(0.07, 0.14, 0.10, 1)
        layers.roads.motorway = SIMD4<Float>(0.55, 0.47, 0.22, 1)
    }
    .features { features in
        features.buildingFillColor = SIMD4<Float>(0.18, 0.19, 0.23, 1)
    }
    .labels { labels in
        labels.city.fillColor = SIMD3<Float>(0.93, 0.94, 0.97)
        labels.city.strokeColor = SIMD3<Float>(0.02, 0.03, 0.06)
    }

ImmersiveMapView()
    .mapStyle(ImmersiveMapTilesMapStyle(configuration: night))
```

| Builder | What it groups |
|---|---|
| `labels(_:)` | Per-kind text appearance: fill, stroke, stroke width, size, weight for city, town, country, POI, water, road. |
| `labelVisibility(_:)` | Which labels the style draws at all: `poiRequiresIcon` (a POI whose category has no icon is left out, on by default), `poiIconlessMinimumZoom` (the zoom those text-only POIs arrive at when it is off), `poiMinimumZoom`. |
| `layers(_:)` | Area and line colors: land, water, wood, grass, farmland, ice, sand, wetland, and the road palette by class through `layers.roads`. |
| `features(_:)` | Feature-level colors that are not a layer palette, notably `buildingFillColor`. |
| `globalLandcover(_:)` | The low-zoom biome palette used before detailed land cover arrives. |

Colors are straight (non-premultiplied) RGBA. `SIMD4<Float>` components run `0...1`.

## Style fingerprints and the cache

Every style exposes a `configurationFingerprint`, and the built-in configuration computes its own as an FNV-1a hash over every palette component. This is not cosmetic bookkeeping: prepared tiles are cached on disk with the style baked in, so a palette that changes without changing the fingerprint would keep drawing from stale prepared tiles.

The built-in configuration handles this for you. A **hand-written** `ImmersiveMapVectorTileStyle` must do it itself:

```swift
struct MyStyle: ImmersiveMapVectorTileStyle {
    let cacheFingerprint: UInt32 = 7      // bump whenever the rules below change
    func makeStyle(for feature: ImmersiveMapFeatureStyleContext) -> ImmersiveMapFeatureStyle { … }
}
```

See [custom tile providers](custom-tile-provider.md) for the full protocol.

## Engine-level style settings

```swift
public struct StyleSettings: Equatable, Sendable {
    public var preparedTileStyleRevision: UInt32
    public var flatSeparateRoadRenderingMinimumZoom: Int
    public var buildingExtrusionAlpha: Float
    public var buildingExtrusionMode: BuildingExtrusionMode
    public var fallbackFeatureColor: SIMD4<Float>
    public var baseColors: BaseColors
}

public struct BaseColors: Equatable, Sendable {
    public var tileBackground: SIMD4<Float>   // the built-in palette's land
    public var globeBackground: SIMD4<Double> // deep blue
    public var water: SIMD4<Float>
    public var landCover: SIMD4<Float>
}
```

| Field | Default | Meaning |
|---|---|---|
| `baseColors.tileBackground` | warm off-white, the palette's land | What is under a tile before any feature draws. This is the color of a still-loading map. |
| `baseColors.globeBackground` | deep blue | The globe sphere itself where no tile has arrived. |
| `baseColors.water` / `landCover` | the palette's water / green | The low-zoom fallbacks used before detailed geometry exists; the water is also what the polar cap continues the ocean with. |
| `fallbackFeatureColor` | opaque red | Drawn for a feature the style did not classify. Deliberately loud: a red road is a bug you want to see. |
| `preparedTileStyleRevision` | 86 | Manual cache-invalidation lever for the prepared tile cache. Bump it to force a re-prepare. |
| `flatSeparateRoadRenderingMinimumZoom` | 8 | The zoom from which roads get their own passes (casing, fill, detail) instead of being drawn with other lines. |
| `buildingExtrusionAlpha` / `buildingExtrusionMode` | 0.6 / `.solid` | See [buildings and shadows](buildings-and-shadows.md). |

```swift
ImmersiveMapView()
    .styleSettings(styleSettings)

private var styleSettings: ImmersiveMapSettings.StyleSettings {
    var style = ImmersiveMapSettings.default.style
    style.baseColors.tileBackground = SIMD4<Float>(0.09, 0.10, 0.12, 1)
    style.baseColors.globeBackground = SIMD4<Double>(0.02, 0.03, 0.05, 1)
    return style
}
```

Anti-aliasing is not a style setting: FXAA lives in [post-processing](performance-and-debug.md).

## Limitations

- There is no runtime stylesheet format (no Mapbox Style JSON). A style is Swift code, which is why it can be a plain function of the feature but cannot be downloaded and swapped at runtime.
- A style is written against one provider's schema. Swapping the provider without swapping the style leaves features unclassified and painted `fallbackFeatureColor`.
- Changing a palette re-prepares tiles, so it is not a per-frame knob.

Running examples: [`Examples/macOS/ImmersiveMapCustomTilesMac`](../../Examples/macOS/ImmersiveMapCustomTilesMac) implements a full `ImmersiveMapVectorTileStyle` by hand; the **Style** section of [`Examples/macOS/ImmersiveMapSettingsMac`](../../Examples/macOS/ImmersiveMapSettingsMac) swaps day, night and blueprint palettes for the built-in provider and restyles the attribution badge next to them.
