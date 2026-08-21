# Render loop, view reuse and debug HUD

Three unrelated things that share one property: they cost nothing to leave alone, and knowing they exist saves an afternoon when something is slow or something will not redraw.

## Rendering is on demand

The map does not run a display link at 60 Hz waiting for something to happen. The link is normally **paused**, and it resumes for two reasons:

- an **activity** is registered (a gesture in progress, a camera flight, label fades, avatar or model animations) and runs until it ends;
- a one-shot invalidation asks for a single frame (a tile arrived, a marker set changed, a setting changed).

An idle map with idle markers, idle avatars and idle routes costs nothing. Every controller in the public API requests frames for you, so ordinary use needs no thought here. It matters when you reach past the API: state that should redraw but never asks for a frame simply will not appear until something else invalidates.

```swift
public struct RenderLoopSettings: Equatable, Sendable {
    public var forceContinuousRendering: Bool  // false
    public var interactionFramesPerSecond: Int // 60
    public var labelFadeFramesPerSecond: Int   // 30
}
```

| Field | Meaning |
|---|---|
| `forceContinuousRendering` | Runs the display link unconditionally. A profiling and debugging lever: it makes frame times comparable by removing the pauses. Shipping with it on burns battery for nothing. |
| `interactionFramesPerSecond` | Cap while a gesture or animation is driving the camera. |
| `labelFadeFramesPerSecond` | Cap while only label fades are running. Lower than the interaction rate on purpose: a fade does not need 60 Hz. |

```swift
ImmersiveMapView()
    .renderLoopSettings(ImmersiveMapSettings.RenderLoopSettings(
        forceContinuousRendering: false,
        interactionFramesPerSecond: 120,
        labelFadeFramesPerSecond: 30))
```

The display link is a `CAMetalDisplayLink` built from the host view's `CAMetalLayer` on both platforms: it delivers each frame's drawable together with the tick and follows the display that actually presents the layer.

## View reuse

```swift
ImmersiveMapView()
    .viewReuse(false)      // always build a fresh renderer

public struct ViewReuseSettings: Equatable, Sendable {
    public var isEnabled: Bool             // true
    public var parkedTimeToLive: TimeInterval  // 30 s
}
```

When the screen holding a map goes away, the platform view is not destroyed: the renderer, its GPU tile cache and its atlas pages are **parked** for `parkedTimeToLive`, and the next `ImmersiveMapView` adopts it warm. Pushing a detail screen and coming back therefore skips the first-frame rebuild entirely.

An adopted view keeps its previous camera unless the new view supplies an explicit camera position or an attached [camera controller](camera.md). That is usually what you want (returning to a map where you left it) and occasionally not (a fresh map that must open at a fixed place), which is what the explicit position is for.

Turn reuse off when you genuinely need a clean renderer, for instance when measuring cold-start cost.

## Anti-aliasing

```swift
ImmersiveMapView()
    .postProcessingSettings(ImmersiveMapSettings.PostProcessingSettings(fxaaEnabled: true))
```

The world pass is already MSAA. FXAA is an additional full-screen post-processing pass, off by default: it smooths the edges MSAA does not catch (notably inside shaded fragments) at the cost of some sharpness in labels. Judge it on a device rather than on a screenshot.

## Judge speed in Release

Xcode builds a package dependency with the configuration of the app that depends on it, so a Debug build of your app runs an unoptimized engine. That is a different program: the tile parser (MVT decode, clipping, triangulation, building extrusion) runs several times slower without optimization, and in a dense city, where a single tile at the source's maximum zoom carries thousands of buildings, the difference is the one between buildings that arrive with the tiles and buildings that appear tens of seconds after them. Every example and post scheme in this repository runs in Release for that reason. Before concluding that tiles or buildings load slowly, run the app in Release, or profile it there: every frame stage and tile stage is an `os_signpost` interval (subsystem `ImmersiveMap`, categories `Render` and `Tiles`), so Instruments shows where the time actually goes.

## Debug HUD

```swift
ImmersiveMapView()
    .debugPanel()      // shorthand for enableDebugPanel: true
```

```swift
public struct DebugSettings: Equatable, Sendable {
    public var enableDebugPanel: Bool   // false
    public var coordinateScale: Float
    public var diagnosticsScale: Float
    public var leftPadding: Float
    public var topPadding: Float
    public var sectionSpacing: Float
    public var textColor: SIMD3<Float>
}
```

The HUD is host-view chrome drawn above the map: camera coordinates and renderer diagnostics. The remaining fields are layout (text scale, padding, spacing between sections) and color, so the panel can be moved out from under an app's own overlay.

It is a development aid. It does not appear in a [tour video export](tour-video-export.md), same as the attribution badge, and it should not ship enabled.

### Overlays on the map

The HUD's **Controls** tab carries switches that draw over the map itself rather than in the panel: coordinate axes, tile borders with their `tile = x/y/z` watermark, wireframe, and the tile grid. They are development-build overlays, drawn only when the package is compiled in Debug, and they are not part of the public API: a release build ignores them even with the panel on.

**Tile grid** divides the tile under the camera centre, and only that one tile, into a grid of the chosen density (2, 4, 6 or 8 a side) and stamps each cell with four lines:

```
39615/20486/16      the tile the cell belongs to, x/y/z
      C4            the cell code
  x1365-2047        the cell's tile-local x bounds
  y2048-2730        the cell's tile-local y bounds
```

The bounds are the tile's own local units, 0 to 4096, with **x growing east and y growing north from the south edge of the tile**, which is the space the parser leaves geometry in (it flips the incoming MVT y, so the raw `.mvt` value for a stamped `y` is `4096 - y`). The cell code says the same thing: the letter is the column counted from the west, the number is the row counted from the south starting at one. Each cell is self-sufficient on purpose, so a screenshot cropped to one cell still names both the tile and the slice of its geometry to go and read.

While a slot is filled with a substitute (a coarser tile standing in for one that has not arrived), the pixels under the stamp were not built from the tile the first line names, so a fifth `src 19807/10243/15` line appears with the tile they did come from. The bounds stay in the drawn tile's space; the source tile's own rectangle for that slot is what `TileLocalClipMath.clipBounds(source:placeIn:)` computes.

Each stamp sits on a translucent dark plate, laid in the tile plane so it tilts and curves with the map. The plate hugs the text it carries rather than filling the cell: it is there to stop a road name or a POI label underneath from reading through the stamp, not to black out the tile.

Cells too small on screen to hold the stamp keep their lines and drop their text, so a grid can look bare until you zoom in.

## Where the frame time goes

For the shape of the pipeline (the five passes, the subsystems, the tile path) see [architecture](architecture.md). The two levers most likely to matter to an app are the [memory tile cache size](tile-cache.md), which decides how often GPU-ready tiles are rebuilt, and the [shadow map resolution and coverage](buildings-and-shadows.md), which is the most expensive optional pass.

## Limitations

- No published frame-time or memory budget: app size is measured (see the README), performance numbers are not.
- `forceContinuousRendering` is for measurement, not for fixing a missing redraw. If something does not appear, the cause is a missing frame request, not the pacing.
- The debug HUD is not localized and not designed for screenshots.

Running examples: [`Examples/macOS/ImmersiveMapMac`](../../Examples/macOS/ImmersiveMapMac) opens the plain map with the HUD already on, which is the shortest way to read the camera and renderer numbers while flying around; the **Diagnostics** section of [`Examples/macOS/ImmersiveMapSettingsMac`](../../Examples/macOS/ImmersiveMapSettingsMac) drives the HUD, FXAA, the frame loop and the tile caches from one panel, with a badge that names what each change makes the engine do.
