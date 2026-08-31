# Extruded buildings and shadows

On the flat map, buildings rise out of their footprints and cast directional shadows onto the ground, onto each other and onto [3D scene models](scene-models.md). Both are flat-presentation only: on the globe there is nothing to extrude into and no ground plane to receive a shadow, so both fade out through the [globe-to-flat morph](globe.md).

```swift
ImmersiveMapView()
    .buildingExtrusionMode(.solidAtHighZoom(startZoom: 16.5, endZoom: 17))
    .shadows()
    .sceneLight(direction: SIMD3<Float>(-0.4, -0.6, 1.0))
```

## Extrusion modes

```swift
public enum BuildingExtrusionMode: Equatable, Sendable {
    case translucent
    case solid
    case solidAtHighZoom(startZoom: Double, endZoom: Double)

    public static let solidAtHighZoom = BuildingExtrusionMode.solidAtHighZoom(startZoom: 17.0, endZoom: 18.0)
}
```

| Mode | What happens |
|---|---|
| `.translucent` | Buildings render into an offscreen image which is then composited over the map with `StyleSettings.buildingExtrusionAlpha` (0.6 by default). Streets stay visible through the massing. The price is that a roof also shows the ground under it, which its own building shadows, so with shadows on every roof reads darker than its color. |
| `.solid` | The default. Buildings draw straight into the world pass, fully opaque: roofs keep their color, walls take the shading, and the shadows fall on the ground around them. `buildingExtrusionAlpha` and the style's color alpha are ignored. |
| `.solidAtHighZoom(startZoom:endZoom:)` | Translucent below `startZoom`, opaque above `endZoom`, with the blend alpha interpolated in between. The compromise most apps want: massing at district zoom, real buildings at street zoom. |

The mode is not just an appearance choice. **The composited translucent image carries no depth**, which is why translucent buildings never occlude a scene model and never tint one. Under `.solid` (or `.solidAtHighZoom` past its end zoom), occlusion between buildings and models is depth-correct. If a model is meant to stand behind a building rather than in front of it, that is the setting to change.

Building color comes from the map style (`features.buildingFillColor`), see [map styling](styling.md).

## The light

```swift
public struct SceneLightSettings: Equatable, Sendable {
    public var direction: SIMD3<Float>   // default (-0.4, -0.6, 1.0)
}
```

`direction` points **towards** the light in the flat basis: +X east, +Y north, +Z up. It is normalized before use, so only the direction matters. There is no analytic surface shading in flat mode: faces darken only through the shadow map, so this vector is the single thing that decides where shadows fall and how long they are. A low elevation (a small +Z relative to the horizontal components) throws long shadows.

What the walls do get is a tonal cue, not lighting: a roof keeps the style's building color, a wall square to the light sits a step under it, a wall turned away steps down further (and the shadow map then shades it as self-shadowed), and every wall darkens toward the ground over its first thirty meters, the ambient occlusion of a street canyon. Roof, lit wall, side wall and shaded wall are therefore four distinct tones of one color, which is what makes a block read as a lit solid.

This is not the [Earth scene sun](earth-scene.md), which lights the globe. The two are independent, and an app that wants them to agree has to set both.

## Shadows

```swift
public struct ShadowSettings: Equatable, Sendable {
    public var isEnabled: Bool                 // true
    public var strength: Float                 // 0.22
    public var mapResolution: Int              // 1024
    public var coverageCameraDistances: Float  // 16.0
    public var tint: SIMD3<Float>              // (0.88, 0.92, 1.0)
}
```

| Field | Meaning |
|---|---|
| `strength` | How much a shadowed fragment darkens, `0...1`. |
| `tint` | The cast of the shadowed light: an RGB multiplier applied on top of `strength` where a surface is fully in shadow, and in proportion where it is partly shadowed. White keeps the neutral darkening; the default cool tint gives shadows the bluish cast of light arriving only from the sky, so a shadowed street reads as daylight rather than as a grey stain. The ground, the buildings and the scene models all take the same tint. |
| `mapResolution` | Side of the square shadow map in pixels, clamped to `256...4096` at render time. The main sharpness-versus-cost lever. |
| `coverageCameraDistances` | Far-cascade coverage radius, measured in multiples of the camera distance. Beyond it shadows fade out. |

The defaults are deliberately soft: at a strength of 0.22 with the cool tint a fully shadowed white surface comes out around `(0.69, 0.72, 0.78)`, a light blue-grey. Heavier shadows are one line away (`strength: 0.5, tint: SIMD3<Float>(repeating: 1)` is the neutral darkening earlier versions shipped).

Shadows use three cascades, one per slice of a `depth16Unorm` texture array, fitted per frame from the camera as discs around the point the camera looks at. The near cascade covers one camera distance and stays crisp, the middle one three, and the far cascade is stretched over `coverageCameraDistances`, so its texel density scales inversely with the radius you ask for. Raising coverage buys reach and pays in softness at the far end.

The ground reads its shadow from a screen-sized mask that a small pass computes once per frame right after the shadow map (the shadow factor of the ground plane under every pixel), so the many blended layers the ground is drawn in share one cascade lookup per pixel; buildings and scene models sample the cascades per fragment, since their surfaces are not the plane. Solid buildings draw before the ground and the ground depth-tests against them, so nothing under a building is shaded.

Coverage is expressed in camera **distance**, not in a screen or world rectangle, precisely because distance is independent of pitch and bearing: tilting or rotating the camera never changes how far shadows reach or how sharp they are.

`.shadows(isEnabled:)` is the shorthand; `.shadowSettings(_:)` takes the whole value.

## Limitations

- **Flat only.** Neither extrusion nor shadows draw on the globe. The shadow pass is skipped entirely there.
- **Translucent buildings carry no depth**, so they neither occlude nor are occluded by scene models. Use `.solid` or `.solidAtHighZoom` where that matters.
- Building heights come from the tile data. Where a source carries none, the style's fallback height is used, so a city with sparse height data extrudes unevenly.
- Shadow casters are buildings and scene models. Terrain, roads and other tile geometry receive shadows but do not cast them.

Running example: the **Buildings and shadows** section of [`Examples/macOS/ImmersiveMapSettingsMac`](../../Examples/macOS/ImmersiveMapSettingsMac) switches the three extrusion modes at street level and drives the sun angle, strength, map resolution and coverage live.
