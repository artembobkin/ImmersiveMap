# Custom style

When changing the built-in theme is not enough (see [Style](Style.md)), write a style of your own. A style answers one question for every feature of every tile: how does it draw?

## Two halves

A map style is two pieces:

- **The schema** says what a feature is: a road in a tunnel, a building 30 m tall, a place with names in several languages. It reads the tile's tags, which every tile provider spells its own way.
- **The style** says how it looks: colours, widths, labels. It reads the schema's answer, never the tags again.

For tiles in the Protomaps basemap schema, keep the built-in schema and write only the style.

## A style

```swift
struct MonoStyle: ImmersiveMapVectorTileStyle {
    let cacheFingerprint: UInt32 = 1
    let styleID = "mono"

    func makeStyle(for feature: ImmersiveMapFeatureStyleContext) -> FeatureStyle {
        switch feature.layerName {
        case "earth":
            return .polygon(key: 1, color: SIMD4(0.95, 0.95, 0.95, 1))
        case "water":
            return .polygon(key: 2, color: SIMD4(0.75, 0.80, 0.85, 1))
        case "roads":
            return .line(key: 10, color: SIMD4(1, 1, 1, 1), width: 6)
        case "buildings":
            return .extrudedPolygon(key: 20, color: SIMD4(0.85, 0.85, 0.85, 1), fallbackHeight: 10)
        case "places":
            return .pointLabel(key: 30, LabelTextStyle(fillColor: SIMD3(0.2, 0.2, 0.2),
                                                       strokeColor: SIMD3(1, 1, 1),
                                                       haloEm: 0.15,
                                                       sizePoints: 14,
                                                       weight: .bold))
        default:
            return .hidden
        }
    }
}

ImmersiveMapView()
    .mapStyle(VectorTileMapStyle(style: MonoStyle()))
```

- **What a feature is.** The context gives the tile's `layerName`, the feature's `properties` (`feature.properties.string("kind")`), its `geometry`, the tile's zoom, and the schema's `facts`: `.road`, `.building`, `.labelled` or `.none`.
- **The drawing modes.**
  - `.polygon`: a fill.
  - `.line`: a line whose width is in tile units, 4096 to a tile, so it grows as you zoom in.
  - `.pointLockedLine`: a line whose width is in screen points, for borders and networks.
  - `.extrudedPolygon`: a building raised to the schema's heights.
  - `.pointLabel` and `.roadLabel`: names.
  - `.hidden`: nothing.
- **The key.** It orders the ground: a tile draws its fills and lines in ascending key. Features with the same key share one style entry, so give one key to each look, not to each feature.
- **The label text** is not the style's. The map shows the schema's name in the map's language (`.labelSettings(language:)`), and the style says only how it looks.
- **`cacheFingerprint`** must change whenever the style's output changes. The map keeps parsed tiles on disk by it, and with an unchanged fingerprint it would keep showing tiles drawn by the old style.

The style can also set what no tile paints (`baseColors`), the relief shading (`hillshade`, `terrainOcclusion`), the trees (`treePalette`) and the label opacity by zoom (`labelOpacity`). Each one defaults to the built-in theme's.

## A schema

For tiles from another provider, also write the schema: one function that turns a feature into facts.

```swift
struct MySchema: ImmersiveMapTileSchema {
    let cacheFingerprint: UInt32 = 1

    func read(_ feature: ImmersiveMapFeature) -> ImmersiveMapFeatureFacts {
        switch feature.layerName {
        case "building":
            return .building(ImmersiveMapBuildingExtrusion(
                heightMetres: feature.properties.double("render_height").map(Float.init)))
        case "place":
            return .labelled(ImmersiveMapLabelFacts(name: feature.properties.string("name")))
        default:
            return .none
        }
    }
}

ImmersiveMapView()
    .tileArchive(myArchiveURL)
    .mapStyle(VectorTileMapStyle(style: MyStyle(), schema: MySchema()))
```

Roads are `.road(ImmersiveMapRoadFacts(...))`, with their structure (a bridge or a tunnel) and their layer, so the map can stack them. Like the style's, the schema's `cacheFingerprint` must change whenever its reading changes.
