# Globe rendering and the globe-to-flat morph

ImmersiveMap does not switch between a globe mode and a flat mode. It renders one continuous surface that is a sphere at low zoom, a plane at high zoom, and a partially unrolled sheet in between. The transition is a value in `0...1` computed every frame from the camera, and the shaders morph the geometry with it, so there is no frame where the map jumps.

Nothing has to be configured for this: a bare `ImmersiveMapView()` already does it. The tuning lives on `ImmersiveMapSettings.PresentationSettings`, attached with `.presentationSettings(_:)`.

```swift
ImmersiveMapView()
    .presentationSettings(ImmersiveMapSettings.PresentationSettings(
        automaticTransitionStartZoom: 6.0,
        automaticTransitionSpan: 1.0,
        globeRadiusScale: 0.14))
```

## The transition window

| Field | Default | Meaning |
|---|---|---|
| `automaticTransitionStartZoom` | 6.0 | The zoom where the sphere starts unrolling. Below it the map is fully a globe. |
| `automaticTransitionSpan` | 1.0 | How many zoom levels the unroll takes, before the latitude correction below. |
| `globeRadiusScale` | 0.14 | The rendered radius of the globe relative to the world scale. Bigger fills more of the screen at the same zoom. |

The window is widened by latitude. A Mercator plane stretches by `1/cos(latitude)`, so unrolling at high latitude covers more ground per zoom level than at the equator; the resolver adds `log2(1 / cos(latitude))` to the span to compensate. At Tokyo's 35.7° that is about 0.3 zoom levels, so the default window there runs from z6.0 to roughly z7.3. The point of the correction is that the speed at which the sphere becomes a plane does not depend on where you are.

Both a `GlobeRenderState` and a `FlatRenderState` are produced on every frame regardless of the transition value; what changes is how the shaders blend them and which layers the frame graph runs.

## What is globe-only and what is flat-only

| Feature | Where it draws |
|---|---|
| Starfield and the globe cap | Globe, fading out through the morph |
| [Sun and day/night terminator](earth-scene.md) | Globe (the terminator shades the sphere) |
| [Routes](routes.md) | Globe and the whole morph, fading out over its last tenth |
| [Extruded buildings](buildings-and-shadows.md) | Flat |
| [Shadows](buildings-and-shadows.md) | Flat |
| [SwiftUI markers](markers.md), [avatars](avatars.md), [3D scene models](scene-models.md), labels | Everywhere, including mid-morph |

Marker and model anchors ride the unfurl wave, so they stay glued to their tile through the whole transition rather than sliding to a new projection at the end of it. Past the globe horizon a marker fades out over a narrow band and stops receiving input.

## Pinning the presentation

There is no public "force globe" or "force flat" switch. The supported way to pin the map is to keep the camera on one side of the window with [`zoomRange`](camera.md):

```swift
ImmersiveMapView()
    .zoomRange(minimum: 8)     // always flat: never zooms out into the window
```

```swift
ImmersiveMapView()
    .zoomRange(maximum: 5)     // always a globe
```

Because gestures, camera commands and flights are all clamped to the same range, this holds against the user as well as against the app.

## Camera limits on the globe

A zoomed-out globe limits how far the camera may rotate and tilt, so a small drag does not spin the planet into a disorienting angle. The thresholds are `CameraSettings.globeBearingUnlockZoom` and `globePitchUnlockZoom` (zoom 6 by default for bearing). Commands are clamped rather than refused: a flight or a [path follow](camera-path-follow.md) that asks for more turn than the zoom allows simply turns as far as it can.

## Limitations

- The transition is driven by zoom, not chosen by the app. To hold a presentation, clamp the zoom.
- A tilted pass through the window is the most demanding thing the renderer does; a slow flight across it (three to five seconds) reads far better than a fast one.
- `globeRadiusScale` changes framing, not projection: it does not make the globe more or less accurate, only bigger or smaller on screen.

Running example: [`Examples/ImmersiveMapCameraTourMac`](../../Examples/ImmersiveMapCameraTourMac) crosses the whole window twice under near-maximum tilt, in both directions.
