# Style

The style decides how the map looks: the colours of the land, the water and the roads, the names and their fonts. The built-in style draws the hosted tiles, and you change it by its theme.

## Changing colours

Start from the built-in look and change what you need:

```swift
ImmersiveMapView()
    .mapStyle(.default.apply { theme in
        theme.layers.water = SIMD4(0.55, 0.75, 0.95, 1)
        theme.layers.park = SIMD4(0.70, 0.86, 0.62, 1)
        theme.labels.city.sizePoints = 18
    })
```

Colours are RGBA from 0 to 1. The theme has three main parts:

- `layers`: the ground and the lines. `land`, `water`, `wood`, `grass`, `park`, `sand`, `ice`, `residential`, `industrial`, the `roads`, and more.
- `labels`: one appearance per kind of name, such as `city`, `town`, `district`, `country`, `poi`, `water` and `road`. Each one has its fill and halo colours, size, weight and letter spacing.
- `hillshade` and `terrainOcclusion`: the shading of the relief (see [Relief](Relief.md)).

`theme.labelOpacity` fades the names in and out by zoom:

```swift
theme.labelOpacity.pois = [14: 0.6, 16: 1]
```

A change to the colours or the labels parses the tiles again, so set the style once rather than on every frame. The opacity and the relief shading are applied while drawing, and cost nothing to change.

## Night

```swift
ImmersiveMapView()
    .night()
```

It sets the night palette and a night sky, and `.night(false)` brings back the day. For a night of your own, set the two apart: `.mapStyle(.night.apply { theme in … })` and `.fogSettings(.night)`.

## The globe's colours

The zoomed-out globe can wear its own palette, for example a sunlit planet around a dark map:

```swift
.mapStyle(.default.apply { theme in
    theme = theme.globeLayers { layers in
        layers.water = SIMD4(0.2, 0.4, 0.8, 1)
    }
})
```

## Language of the names

Names show in English by default. Choose another language:

```swift
ImmersiveMapView()
    .labelSettings(language: .russian)
```

The language is any code the tiles carry names in: `.english`, `.russian`, `.french`, `.german`, `.spanish`, and more, or `ImmersiveMapSettings.LabelLanguage("ja")`. Where a place has no name in that language, the map shows its English name, then its local one. `fallbackPolicy: .localFirst` shows the local name first.

`.labels(isEnabled: false)` hides every name.

## Tiles in another schema

The built-in style reads the Protomaps basemap schema. For tiles in another schema, pair a style of your own with a schema of your own:

```swift
.mapStyle(VectorTileMapStyle(style: myStyle, schema: mySchema))
```

The protocols `ImmersiveMapVectorTileStyle` and `ImmersiveMapTileSchema` describe what each one provides.
