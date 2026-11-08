# Relief

The relief raises the ground into mountains and valleys, from real terrain heights. The roads, the buildings and the labels rise with it, the slopes are shaded by the light, and the camera flies over the ridges.

It is off by default. Turn it on:

```swift
ImmersiveMapView()
    .groundRelief(isEnabled: true)
```

## When it shows

The relief rises out of the flat map at zoom 10 and sinks back into it at zoom 13.7. At street zooms the terrain data, 30 m cells over most of the world, would show hills where there are none, so the map lies flat there. Both changes are short animations, 0.3 seconds by default.

```swift
.groundRelief(isEnabled: true, appearZoom: 9, collapseZoom: 15, transitionSeconds: 0.5)
```

Where the terrain has finer data, such as lidar in some countries, the relief stands up to `collapseZoom`. Elsewhere it sinks earlier, at the first zoom the source has no tile for. `collapsesWhereTerrainIsMissing: false` keeps it up to `collapseZoom` everywhere.

## Height

`exaggeration` multiplies every height: 1 is true scale, 2 doubles it. Raise it to make a gentle country readable.

```swift
.groundRelief(isEnabled: true, exaggeration: 1.5)
```

## The terrain source

By default the heights come from [Mapterhorn](https://mapterhorn.com), open terrain for the whole world, credited on the map while the relief stands. Use your own terrain tiles with `.terrain(_:)`:

```swift
ImmersiveMapView()
    .terrain(ImmersiveMapTerrainSource(tileURLTemplate: "https://terrain.example.com/{z}/{x}/{y}.png",
                                       encoding: .mapbox,
                                       credit: "© Example Terrain"))
    .groundRelief(isEnabled: true)
```

The tiles are square PNG or WebP images whose pixels hold heights: `.terrarium` (Mapterhorn, AWS Terrain Tiles) or `.mapbox` (Mapbox Terrain-RGB, MapTiler). A file URL template reads them from disk.

## Shading

The style shades the slopes and darkens the valleys where the terrain hides the sky. With the built-in style, tune both in its theme:

```swift
.mapStyle(.default.apply { theme in
    theme.hillshade.intensity = 0.5
    theme.terrainOcclusion.strength = 0.3
})
```

With shadows on, the mountains also cast shadows (`castsShadows`, on by default).

## The camera

The camera keeps its height over the ground and stops at a ridge between it and the point it looks at. `cameraClearanceMetres` keeps it that many metres over such a ridge:

```swift
.groundRelief(isEnabled: true, cameraClearanceMetres: 50)
```

## Mountains or plain

The map can tell you whether the camera is over mountains or a plain, to adapt your UI or the air:

```swift
ImmersiveMapView()
    .groundRelief(isEnabled: true)
    .onTerrainSurroundingsChange { surroundings in
        // surroundings?.kind is .mountains or .plain, nil off the relief
    }
```

`.terrainSurroundings(sampleRadiusMetres:plainBelowMetres:mountainsAboveMetres:smoothingHalfLife:)` sets how wide an area is read and which span of heights counts as mountains. The map itself uses this to blend into the mountain air of `.mountainGroundFog(...)`.
