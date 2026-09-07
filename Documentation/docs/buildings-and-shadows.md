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

## Roof shapes

Where the tiles describe a roof (`roof:shape`: gabled, hipped, skillion, pyramidal, domes and more), the engine can raise the shaped roof surface, with the walls rising to meet it. This is off by default (every building takes a flat lid at its full height); switch it on with:

```swift
ImmersiveMapView()
    .buildingRoofShapes()
```

The roofs are baked into the prepared tiles at parse time, so the toggle applies by re-parsing them, the same way any style change does; expect a brief reload rather than an instant switch. The setting is `StyleSettings.buildingRoofShapesEnabled`.

## The light

```swift
public struct SceneLightSettings: Equatable, Sendable {
    public var direction: SIMD3<Float>   // default (-0.4, -0.6, 1.0)
}
```

`direction` points **towards** the light in the flat basis: +X east, +Y north, +Z up. It is normalized before use, so only the direction matters. There is no analytic surface shading in flat mode: faces darken only through the shadow map, so this vector is the single thing that decides where shadows fall and how long they are. A low elevation (a small +Z relative to the horizontal components) throws long shadows.

What the walls do get is a tonal cue, not lighting: a roof keeps the style's building color, a wall square to the light sits a step under it, a wall turned away steps down further (and the shadow map then shades it as self-shadowed), and every wall darkens toward the ground over its first thirty meters, the ambient occlusion of a street canyon. Roof, lit wall, side wall and shaded wall are therefore four distinct tones of one color, which is what makes a block read as a lit solid.

The globe has no analytic sun of its own: this light exists only for the flat presentation's shadows.

## Shadows

```swift
public struct ShadowSettings: Equatable, Sendable {
    public var isEnabled: Bool                 // true
    public var strength: Float                 // 0.22
    public var mapResolution: Int              // 2048
    public var coverageCameraDistances: Float  // 3.0
    public var maxCasterHeightMeters: Float    // 10
    public var normalOffsetTexels: Float       // 2.5
    public var softness: Float                 // 1.5
    public var tint: SIMD3<Float>              // (0.88, 0.92, 1.0)
}
```

| Field | Meaning |
|---|---|
| `strength` | How much a shadowed fragment darkens, `0...1`. |
| `tint` | The cast of the shadowed light: an RGB multiplier applied on top of `strength` where a surface is fully in shadow, and in proportion where it is partly shadowed. White keeps the neutral darkening; the default cool tint gives shadows the bluish cast of light arriving only from the sky, so a shadowed street reads as daylight rather than as a grey stain. The ground, the buildings and the scene models all take the same tint. |
| `mapResolution` | Side of the square shadow map in pixels, clamped to `256...4096` at render time. The main sharpness-versus-cost lever. |
| `maxCasterHeightMeters` | Tallest building the window is fitted for, clamped to `10...500`. The window has to reach beyond its own disc by about 0.72 of this (how far a caster that tall throws its shadow into the disc), and that margin is spent whether or not such a building is in sight. At a street camera a 1000 m assumption was three quarters of the window, which is why coverage appeared to do nothing to a shadow's sharpness. Set it to the tallest building actually around: too low and anything above it stops casting. The default is the floor of the range, chosen for the sharpness of a street view, where the margin is pure cost; what it costs is that a tall building at the edge of the visible ground loses the part of its shadow thrown from above 10 m, so scenes staged around towers want it raised to the height of the buildings in frame. |
| `normalOffsetTexels` | How far a receiver's shadow lookup steps off its own surface along the normal, in shadow map texels, clamped to `0...8`. The only defence against shadow acne, and a two-sided trade: too little and grazing walls stripe, too much and a wall stops being shadowed by anything closer to it than the offset, which is what makes narrow alleys lose their shadows as the camera pulls back. Stated in texels rather than meters because the acne to cover is proportional to how coarse the map is, so the same value holds at every zoom and coverage. |
| `softness` | How soft the edge of a shadow is: the factor the sampling kernel's four taps are pushed out by, clamped to `1...2.5`. `1` is the plain 3x3 tent and every step up widens the ramp in proportion; the default sits a step above it, where an edge stops reading as a hard cut without the contact under a building going soft. It is free (the same four hardware compares at any softness) and it cannot move a shadow, because the kernel stays symmetric about the point being shaded, which puts the half-lit contour on the true edge whatever the width. What it is not is a way to sharpen a stepped edge: the steps in a shadow's outline are one texel of the map, and a wider kernel rounds their corners rather than removing them. Raising it far also softens the contact where a building meets the ground, which is what makes it read as standing on it. |
| `coverageCameraDistances` | How far shadows reach, in multiples of the camera distance, measured from the camera. Beyond it they fade out. It is an upper bound rather than a size: the window is fitted to the visible ground, so asking for more reach than the camera can see costs nothing. One map is stretched over the radius, so raising this coarsens every shadow in the frame in proportion, and `mapResolution` is what buys the density back. The window also has to reach beyond its own disc far enough for a tall building to throw a shadow into it, so the caster-height limit (`maxCasterHeightMeters`) is also capped by the radius rather than adding a fixed margin that would swamp a small window. Clamped to `0.25...48`. Shadows fade out over the outer quarter of the radius, so the window's edge is never visible as a circle. Values well under 1 are a debugging aid: they wind the window down onto the point the camera looks at, which is how the texel grid is looked at up close. |

The defaults are deliberately soft: at a strength of 0.22 with the cool tint a fully shadowed white surface comes out around `(0.69, 0.72, 0.78)`, a light blue-grey. Heavier shadows are one line away (`strength: 0.5, tint: SIMD3<Float>(repeating: 1)` is the neutral darkening earlier versions shipped).

Shadows use one `depth16Unorm` map, fitted per frame to the ground the camera can actually see: the view frustum's corner and edge rays intersected with the ground plane, clamped to `coverageCameraDistances` from the camera. Fitting a disc around the look-at point instead would have to reach as far as the farthest visible ground and would then cover as much ground behind the camera, which at a tilted camera was half the window's side spent on nothing. The cost of following the view is that turning the camera refits the window, so the texel grid depends on where you look. Receivers outside it are lit, and the fade band is the outer quarter of the radius, measured radially from the window's own centre, so the boundary is never visible as a line and no camera pose moves it. Sampling is a 3x3 tent kernel (four hardware bilinear depth compares with computed weights), the same one for every receiver: the ground through its mask, buildings, and scene models. A single compare is exact along the shadow map's own axes and staircases on every other angle, which shows up as clean edges on the buildings that happen to stand along the sun and jagged ones on the rest; the tent's ramp is the same width in every orientation, and `softness` scales that width by pushing the four taps out about the sample point (symmetrically, so the ramp lengthens and its centre does not move). Acne is prevented by moving the sample point off the surface along its normal rather than by a receiver-plane gradient, and walls too oblique for that are declared self-shadowed by their own `N·L` instead of being sampled at all.

Reach and sharpness therefore trade directly: the same map covers whatever radius you ask for. The defaults, 2048 pixels over three camera distances, put a shadow texel under a meter of ground at street zooms.

The ground reads its shadow from a screen-sized mask that a small pass computes once per frame right after the shadow map (the shadow factor of the ground plane under every pixel), so the many blended layers the ground is drawn in share one lookup per pixel; buildings and scene models sample the map per fragment, since their surfaces are not the plane. Solid buildings draw before the ground and the ground depth-tests against them, so nothing under a building is shaded.

Coverage is expressed in camera **distance**, not in a screen or world rectangle, precisely because distance is independent of pitch and bearing: tilting or rotating the camera never changes how far shadows reach or how sharp they are.

`.shadows(isEnabled:)` is the shorthand; `.shadowSettings(_:)` takes the whole value.

## Limitations

- **Flat only.** Neither extrusion nor shadows draw on the globe. The shadow pass is skipped entirely there.
- **Translucent buildings carry no depth**, so they neither occlude nor are occluded by scene models. Use `.solid` or `.solidAtHighZoom` where that matters.
- Building heights come from the tile data. Where a source carries none, the style's fallback height is used, so a city with sparse height data extrudes unevenly.
- Shadow casters are buildings and scene models. Terrain, roads and other tile geometry receive shadows but do not cast them.

Running example: the **Buildings and shadows** section of [`Examples/macOS/ImmersiveMapSettingsMac`](../../Examples/macOS/ImmersiveMapSettingsMac) switches the three extrusion modes at street level and drives the sun angle, strength, map resolution and coverage live.
