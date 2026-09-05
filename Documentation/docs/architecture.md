# Architecture

ImmersiveMap is a Swift 6 package (`ImmersiveMap/`, ~430 Swift files and 18 Metal shaders) that renders vector tiles with Metal and integrates with SwiftUI. This document is a high-level map of the engine.

## Layering

Dependencies point inward:

```text
UI → Render → domain folders → Utils
```

- **UI** - SwiftUI surface, platform hosts (UIKit on iOS, AppKit on macOS), `CAMetalLayer`, render driver.
- **Render** - Metal render pipeline, subsystems, shaders.
- **Domain folders** - `Camera`, `Tile`, `Labels`, `Text`, `Presentation`, `Globe`, `Horizon`, `Avatars`, `Starfield`, `Geo`.
- **Utils** - shared stateless helpers.

Domain folders must not depend on `UI`/`Render` and must not contain Metal code. `Render` must not contain networking or platform UI. Provider-specific MVT schema logic is confined to `VectorTileAdaptation/` and the concrete provider folder `Provider/ImmersiveMapTiles`; `Render`, `Labels`, and `Tile` consume only provider-neutral, normalized data.

## Public API and wiring

```text
ImmersiveMapView (SwiftUI, identical API on iOS and macOS)
   ↓  accumulates modifiers into ImmersiveMapSettings
ImmersiveMapUIView (UIKit, iOS) / ImmersiveMapNSView (AppKit, macOS) + CAMetalLayer
   ↓
ImmersiveMapHostRuntime (shared settings/renderer lifecycle)
   ↓
ImmersiveMapRuntimeGraph (composition root, @MainActor)
   ↓  controllers/runtimes + ImmersiveMapRendererBuilder
RenderFrameEngine
```

The package targets iOS 18 (UIKit) and native macOS 15 (AppKit); Mac Catalyst is not supported. Platform-specific UI (gestures, attribution badge, debug HUD, touch control zones) lives in per-platform files; shared runtime logic is platform-neutral and references the host view through the `ImmersiveMapHostView` typealias.

Public controllers: `ImmersiveMapCameraController`, `ImmersiveMapAvatarsController`, `ImmersiveMapSelectionController`. Style protocols live in `Provider/Core/` (`ImmersiveMapMapStyle`, `ImmersiveMapVectorTileStyle`), together with the generic `VectorTileMapStyle`; the built-in style is `ImmersiveMapTilesMapStyle` in `Provider/ImmersiveMapTiles/`, next to the `ImmersiveMapTilesService` constants for the hosted source.

## Frame loop and render pipeline

Rendering is **on-demand**. `ImmersiveMapRenderDriver` drives a `CAMetalDisplayLink` (built from the host view's `CAMetalLayer`, delivering each frame's drawable with the tick) that is normally paused; `RenderLoopPacing` resumes it for activities (interaction, label fades, camera/avatar animations) and one-shot `requestFrame(reason:)` invalidations. Any state change that should redraw must request a frame or register an activity.

`RenderFrameEngine` runs per-frame stages:

```text
collectInput → updateScene → prepareGPU → encodePasses → presentFrame
```

Work is organized as ~17 `RenderSubsystem`s registered by `RenderGraphFactory`. `RenderPassGraph` groups render layers into up to six passes: `shadowMap` (flat-only depth pass from the directional light, sampled by later passes), `groundShadowMask` (flat-only, right after the shadow map: the shadow factor of the ground plane evaluated once per screen pixel into an 8-bit texture, which every ground layer of the world pass reads with one texture read instead of sampling the shadow map per layer), `buildingImage` (flat-only offscreen render of opaque buildings that the world pass composites translucently, only in the translucent extrusion modes), `world` (on the globe the starfield first and then the tile geometry on the sphere, which blends over it, and the polar caps; on the plane the buildings first and then the ground, which depth-tests against them so nothing under a building is shaded; scene models and routes on both; last on both surfaces the `horizon` layer, the air around the surface's edge: the globe's atmosphere and limb feather, the flat map's fog band, two depth-split fullscreen draws), `postProcessing` (FXAA), and `overlay` (a scene-model label-occlusion depth prepass, then labels/avatars/debug: labels rasterize at the far plane and depth-test against the prepass, so model silhouettes clip them). GPU frame overlap is bounded by `InFlightFramePool`.

## Tile pipeline

```text
TileDemandPlacementSubsystem
   ↓
TileRenderStore (working set of MetalTiles: the frame's demanded tiles plus the z0-3 world cover)
   ↓  miss
ImmersiveMapNeedsTile (disk stage first: a prepared tile on disk answers final; misses download with bounded concurrency, dedup, retry/backoff)
   ↓
TileMvtParser + the Mvt target (MvtTileDecoder/MvtGeometryDecoder/MvtAttributeDecoder) + clippers + the Earcut target (internal earcut port) → PreparedTileCPU
   ↓
MetalTileFactory → GPU TileBuffers
```

Completion invalidates a frame with `.tileAvailable`. There are two disk caches: raw payloads and prepared tiles. Tiles stay in GPU memory only while a frame draws them; a revisited place returns through the prepared cache, whose TTL and identity namespace are the freshness contract.

## Globe vs flat presentation

`PresentationStateResolver` computes a continuous `transition` in `[0, 1]` from zoom (or a forced override). Both `GlobeRenderState` and `FlatRenderState` are always produced, and shaders morph between sphere and plane rather than hard-switching. `renderSurfaceMode` (`.spherical` / `.flat`) selects the world layers and camera constraints.

## Threading model

No Swift actors. The frame engine and all `UI` runtimes are main-thread (`ImmersiveMapRuntimeGraph` is `@MainActor`). Tile loading runs in `Task`s off the main thread, with mutable state serialized by plain `DispatchQueue`s.
