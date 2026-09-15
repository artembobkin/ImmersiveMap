# Map styling and colors

The built-in style draws the hosted tiles, and its look is a plain value,
`ImmersiveMapTilesTheme`: the colour of every ground layer and road class, the
building fill, the label appearances and which labels show. Start from the
default and change what you want, on the view:

```swift
ImmersiveMapView()
    .mapStyle(.default.apply { theme in
        theme.layers.water = [0.06, 0.14, 0.28, 1]
        theme.layers.roads.motorway = [0.55, 0.47, 0.22, 1]
        theme.features.buildingFillColor = [0.18, 0.19, 0.23, 1]
        theme.labels.city.fillColor = [0.93, 0.94, 0.97]
    })
```

Colours are RGBA in 0...1 (label colours RGB), written as array literals or
as `SIMD4<Float>`. A theme can also be a value of its own, passed to
`ImmersiveMapTilesMapStyle(theme:)`:

```swift
let night = ImmersiveMapTilesTheme.default.apply { theme in
    theme.layers.land = [0.08, 0.09, 0.11, 1]
    theme.layers.wood = [0.07, 0.14, 0.10, 1]
}

ImmersiveMapView()
    .mapStyle(ImmersiveMapTilesMapStyle(theme: night))
```

The groups are `layers` (land, water, wood, grass, farmland, ice, sand,
wetland, park, residential, industrial, boundary, aeroway, and `roads` with
one colour per road class plus the casing), `features` (the building fill,
and whether buildings rise at all and raise their shaped roofs:
`buildingExtrusion`, on by default, and `buildingRoofShapes`, off by
default), `labels` (fill
and stroke colour, halo, size and weight per label class) and
`labelVisibility`. Every value feeds the style's cache fingerprint, so a
changed colour rebakes the prepared tiles by itself.

What no tile paints follows the theme too: the ground where no tile has
arrived yet is the land colour, the northern polar cap the water and the
southern one the ice (`ImmersiveMapBaseColors`, which a style of your own
states itself).

A source in another schema, or a look the theme cannot express, is a style of
its own: an `ImmersiveMapVectorTileStyle` answering `makeStyle(for:)` per
feature, paired with a schema reading in `VectorTileMapStyle(style:schema:)`.
The custom tiles example shows one.
