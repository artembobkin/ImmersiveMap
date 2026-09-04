# The atmosphere and the horizon

Around the globe's limb ImmersiveMap paints an atmosphere: a halo of scattered light in space just outside the planet's edge and a matching glow on the surface toward it. It is the globe's alone. As the sphere unrolls into the plane, the halo fades into the colour of the flat map's fog band, and the flat presentation itself has no atmosphere: its horizon wears only that band, where the far ground blends into the map's clear colour at the horizon line.

Nothing has to be configured: a bare `ImmersiveMapView()` draws the atmosphere on the globe and the fog band on the plane. The atmosphere is optional; the fog band is not.

```swift
ImmersiveMapView()
    .atmosphere(isEnabled: false)          // a bare planet against space

ImmersiveMapView()
    .atmosphereSettings(ImmersiveMapSettings.AtmosphereSettings(
        color: SIMD3<Float>(0.40, 0.66, 1.0),
        intensity: 1.0,
        thickness: 1.0,
        sunInfluence: 0.6))
```

## The globe's atmosphere

`ImmersiveMapSettings.AtmosphereSettings` lives on `SceneSettings.atmosphere` and applies live.

| Field | Default | Meaning |
|---|---|---|
| `isEnabled` | `true` | Whether the halo and the surface glow draw at all. |
| `color` | sky blue `(0.40, 0.66, 1.0)` | The colour of the scattered light. The very edge whitens toward the limb on its own. |
| `intensity` | 1.0 | Brightness multiplier of the halo and the glow, `0...2`. 0 keeps the layer on and the sphere bare. |
| `thickness` | 1.0 | Width multiplier, relative to the globe radius: 2 is twice as wide, 0.5 a thin bright ring. |
| `sunInfluence` | 0.6 | How much the scene light (`SceneLightSettings.direction`, the same sun the buildings cast shadows from) shapes the halo: at 1 it is full where the limb faces the light and dims to a residual glow opposite it, at 0 it is even all the way around. |

The halo is resolved per pixel from the view ray and the sphere, not from a circle drawn on screen, so it hugs the true silhouette under perspective on a tilted or off-centre globe. Its widths are a fixed fraction of the planet's radius seen from the camera: a thin ring from far away, wider as the camera comes down toward the surface.

### The limb feather

Whether the atmosphere is on or off, the limb keeps a thin glow a couple of pixels wide across the edge, half over the surface and half over space. The globe's surface is the tile mesh projected onto the sphere, and its silhouette is a polygon of chords rasterized at one sample per pixel; the feather is what hides that staircase. It is sized in pixels, so it looks the same at every zoom, and it takes the atmosphere's colour when the atmosphere is on and the fog colour when it is off.

### Transparent space

With `.transparentSpace()` nothing may be painted around the globe, so the halo and the outer half of the feather are dropped with the stars; the surface glow and the inner half stay.

## The flat map's fog band

On the flat map the ground blends into the map's clear colour (`SceneSettings.mapClearColor`, the built-in style's land) by angle below the horizon: saturated at the line, thinning over the next few degrees, and exactly zero further down, so the map under the camera is byte-clean of fog. The band covers everything painted near the horizon, buildings and models included; labels stay crisp over it. Because the sky above the line is the clear colour too, the far range meets it with no seam.

The fog band is always on. Its colour follows the clear colour, so a style with its own land colour carries the fog with it.

## Through the morph

The handover runs on the globe-to-flat transition (see [globe rendering](globe.md)):

| Transition | Around the edge |
|---|---|
| up to 0.5 | The atmosphere, unchanged, following the limb of the unrolling sphere. |
| 0.5 to 0.9 | The halo fades out into space, the surface glow narrows into the fog band's widths, and every colour blends to the fog colour. |
| 0.9 and beyond | The plane's fog band, on the globe's rendering path and on the flat one alike, so the surface switch at 1 happens between identical frames. |

Running examples: the **Sky** section of [`Examples/macOS/ImmersiveMapSettingsMac`](../../Examples/macOS/ImmersiveMapSettingsMac) exposes every field of the atmosphere next to the stars and transparent space; [`Examples/macOS/ImmersiveMapCameraTourMac`](../../Examples/macOS/ImmersiveMapCameraTourMac) flies through the handover twice.
