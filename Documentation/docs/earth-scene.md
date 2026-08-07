# Sun, day/night terminator and starfield

The Earth scene is what makes the globe read as a planet rather than a textured ball: a visible sun, a terminator sweeping the sphere so half of it is in night, and a starfield behind it. It is on by default and follows the real clock, so a map opened at midnight in Tokyo opens with Japan in the dark.

`.earthScene(isEnabled:)` is the shorthand for turning the whole package on and off. Everything else lives on `ImmersiveMapSettings.SceneSettings` and is attached with `.sceneSettings(_:)`.

```swift
struct MapScreen: View {
    var body: some View {
        ImmersiveMapView()
            .sceneSettings(sceneSettings)
    }

    private var sceneSettings: ImmersiveMapSettings.SceneSettings {
        var scene = ImmersiveMapSettings.default.scene
        scene.earth.timeMode = .fixed(midsummerNoonUTC)   // deterministic lighting
        scene.earth.nightSideBrightness = 0.10            // darker nights
        scene.starfield.starCount = 6000
        return scene
    }
}
```

## Time

```swift
public enum EarthSceneTimeMode: Equatable, Sendable {
    case realtime
    case fixed(Date)
}
```

The sun direction is derived from a wall date. `.realtime` tracks the clock; `.fixed` pins it, which is what you want for a deterministic screenshot, a scripted demo, or a [video export](tour-video-export.md) whose lighting must not drift across a long render. Animating the date is how you sweep the terminator around the planet.

## Terminator and night

| Field | Default | Meaning |
|---|---|---|
| `earth.isEnabled` | `true` | The whole package: sun, terminator shading and night side. |
| `earth.daySideMinimumBrightness` | 0.82 | Floor on daylight brightness, `0...1`. Keeps the lit half from washing out at grazing angles. |
| `earth.nightSideBrightness` | 0.18 | Base brightness of the dark half, `0...1`. Zero is a true black night; the default keeps the map legible there. |
| `earth.terminatorFadeWidth` | 0.12 | Width of the day-to-night fade, as a normalized dot product. Small is a hard edge, large is a wide dusk band. |

## Sun

```swift
public struct SunSettings: Equatable, Sendable {
    public var isEnabled: Bool           // true
    public var diskAngularSize: Float    // 0.075
    public var diskIntensity: Float      // 1.0
    public var glowIntensity: Float      // 0.75
    public var edgeGlareIntensity: Float // 0.0
    public var limbHaloIntensity: Float  // 0.35
    public var limbHaloWidth: Float      // 0.10
}
```

| Field | What it draws |
|---|---|
| `diskAngularSize` / `diskIntensity` | The sun's own disk in space, and how bright it is. |
| `glowIntensity` | The halo immediately around the disk. |
| `edgeGlareIntensity` | Glare at the viewport edge when the sun is offscreen. Zero by default: an offscreen light source that keeps announcing itself reads as a lens artifact rather than a planet. |
| `limbHaloIntensity` / `limbHaloWidth` | The lit rim of the globe seen against space, the atmosphere read. |

## Starfield and space

```swift
public struct StarfieldSettings: Equatable, Sendable {
    public var starCount: Int        // 3400
    public var sizeMin: Float        // 0.9
    public var sizeMax: Float        // 5.2
    public var brightnessMin: Float  // 0.16
    public var brightnessMax: Float  // 1.05
    public var near: Float, far: Float, radiusScale: Float
}

public struct SpaceSettings: Equatable, Sendable {
    public var clearColor: SIMD4<Double>   // near-black blue
    public var isTransparent: Bool         // false
}
```

The starfield is a point cloud on a sphere well outside the globe, drawn in the world pass before everything else. `starCount: 0` removes it and leaves `space.clearColor` as the backdrop. `radiusScale` sets how far out the sphere sits, which is what keeps stars from parallaxing as the camera orbits.

## Transparent space

```swift
ImmersiveMapView()
    .transparentSpace()
```

`isTransparent` leaves everything outside the globe unpainted: the frame is cleared to a fully transparent pixel and the entire starfield layer (space background, stars and the visible sun) is skipped, so whatever the app puts behind the map, a color, a gradient, an image, continues around the planet. `clearColor` is ignored in that mode, and the globe surface itself stays opaque.

This is the mode for a globe that is one element on a screen with its own background rather than a scene in orbit. Painting space a flat color could only ever match a flat background exactly; anything else showed as a square around the globe. On the way to the flat presentation the clear color still ramps to the opaque map color through the morph, so the plane arrives fully painted. On macOS the enclosing window must itself be transparent for the desktop to show through.

## The flat-mode light

`SceneLightSettings.direction` is a different thing and worth not confusing with the sun above. It is the static directional light of the **flat** presentation, pointing towards the light in the flat basis (+X east, +Y north, +Z up), and it defines where [buildings and models cast their shadows](buildings-and-shadows.md). The Earth scene sun lights the globe; this one throws shadows on the plane.

```swift
ImmersiveMapView()
    .sceneLight(direction: SIMD3<Float>(-0.4, -0.6, 1.0))
```

## Limitations

- The sun, the terminator and the starfield are globe-side: they fade out through the [globe-to-flat morph](globe.md) and draw nothing on the fully flat map.
- `transparentSpace()` and the sun are mutually exclusive by construction: the visible sun draws in the starfield layer, which transparent space skips entirely.
- The terminator is a lighting model, not a data layer: it shades the rendered sphere and has no bearing on labels, markers or tile content.
- `.realtime` re-resolves the date per frame, so a long-running screen drifts with the clock by design. Pin it with `.fixed` when that matters.

Running example: the **Earth scene** section of [`Examples/macOS/ImmersiveMapSettingsMac`](../../Examples/macOS/ImmersiveMapSettingsMac) drives the terminator with an hour slider, exposes the sun fields live, and puts a gradient behind the map so transparent space has something to show through to.
