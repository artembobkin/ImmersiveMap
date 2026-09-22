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
and stroke colour, halo, size and weight per label class),
`labelVisibility` and `roadMetrics`. Every value feeds the style's cache
fingerprint, so a changed value rebakes the prepared tiles by itself.

### Road widths and zooms

`roadMetrics` is how wide the roads draw and from where, one value per road
class (`motorway`, `trunk`, `primary`, `secondary`, `tertiary`, `minor`,
`service`, `path`, and `other` for every class the style does not name):

```swift
let style = ImmersiveMapTilesMapStyle.default.apply { theme in
    theme.roadMetrics.symbolWidthPoints.minor = 3
    theme.roadMetrics.worldLockZoom = 15
    theme.roadMetrics.minimumTileZoom.service = 13
}
```

- `symbolWidthPoints`: the width of a class on screen, in points, from
  `symbolZoom` (default 14) up to the world lock zoom, the same on screen at
  every zoom between the two.
- `overviewWidthPoints`, `overviewZoom` (default 6) and `overviewOpacity`
  (default 0.6): the hairline a class is over a country view, and how much of
  its colour it carries there. Between `overviewZoom` and `symbolZoom` the
  width grows from the overview stroke to the symbol by the same ratio per
  zoom level, and the opacity to one, both continuous in camera zoom, so a
  road never steps in width, neither with the camera nor when the engine
  swaps the tile level that serves it.
- `worldLockZoom` (default 15): the camera zoom from which a road's width is
  fixed on the ground instead. The road keeps the ground width its symbol had
  at this zoom, so it doubles on screen with every zoom level past it, like
  the blocks around it, and never thins into a hairline at street level. The
  handover is continuous. Zero keeps every road a symbol at every zoom.
- `drawsCasing` (default off): whether a street map's road stroke wears an
  outline a point wide on each side at street zoom.
- `minimumTileZoom`: the tile zoom a class first draws at. A value under the
  zoom the tile source first ships the class at changes nothing.

Roads that overlap (two streets at a junction, the pieces of one street, the
margins of two tiles) draw as one sheet, every pixel blended once, so a
translucent road colour stays even across junctions instead of doubling
where the ribbons cross.

What no tile paints follows the theme too: the ground where no tile has
arrived yet is the land colour, the northern polar cap the water and the
southern one the ice (`ImmersiveMapBaseColors`, which a style of your own
states itself).

A source in another schema, or a look the theme cannot express, is a style of
its own: an `ImmersiveMapVectorTileStyle` answering `makeStyle(for:)` per
feature, paired with a schema reading in `VectorTileMapStyle(style:schema:)`.
The custom tiles example shows one.
