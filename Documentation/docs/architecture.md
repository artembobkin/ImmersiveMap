# Architecture

ImmersiveMap is a Swift 6 package (`ImmersiveMap/`, ~330 Swift files and 17 Metal shaders) that renders vector tiles with Metal and integrates with SwiftUI. This document is a high-level map of the engine.

## Layering

Dependencies point inward:

```text
UI → Render → domain folders → Utils
```

- **UI** - SwiftUI surface, platform hosts (UIKit on iOS, AppKit on macOS), `CAMetalLayer`, render driver.
- **Render** - Metal render pipeline, subsystems, shaders.
- **Domain folders** - `Camera`, `Tile`, `Labels`, `Text`, `Presentation`, `Globe`, `EarthScene`, `Avatars`, `Starfield`, `Geo`.
- **Utils** - shared stateless helpers.

Domain folders must not depend on `UI`/`Render` and must not contain Metal code. `Render` must not contain networking or platform UI. Provider-specific MVT schema logic is confined to `VectorTileAdaptation/` and the concrete provider folders under `Provider/` (`Provider/Mapbox`, `Provider/ImmersiveMapTiles`); `Render`, `Labels`, and `Tile` consume only provider-neutral, normalized data.

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

Public controllers: `ImmersiveMapCameraController`, `ImmersiveMapAvatarsController`, `ImmersiveMapSelectionController`. Provider protocols live in `Provider/`; concrete implementations are `ImmersiveMapTilesProvider`/`ImmersiveMapTilesMapStyle` and `MapboxTileProvider`/`MapboxMapStyle`.

## Frame loop and render pipeline

Rendering is **on-demand**. `ImmersiveMapRenderDriver` drives a `CADisplayLink` that is normally paused; `RenderLoopPacing` resumes it for activities (interaction, label fades, camera/avatar animations) and one-shot `requestFrame(reason:)` invalidations. Any state change that should redraw must request a frame or register an activity.

`RenderFrameEngine` runs per-frame stages:

```text
collectInput → updateScene → prepareGPU → encodePasses → presentFrame
```

Work is organized as ~17 `RenderSubsystem`s registered by `RenderGraphFactory`. `RenderPassGraph` groups render layers into up to four passes: `buildingWinner` (flat-only building ID prepass), `world` (MSAA), `postProcessing` (FXAA), and `overlay` (labels/avatars/debug). GPU frame overlap is bounded by `InFlightFramePool`.

## Tile pipeline

```text
TileDemandPlacementSubsystem
   ↓
TileRenderStore (in-memory LRU of MetalTiles)
   ↓  miss
ImmersiveMapNeedsTile (bounded-concurrency async loading, dedup, retry/backoff, disk caches)
   ↓
TileMvtParser + clippers/decoders + SwiftEarcut → PreparedTileCPU
   ↓
MetalTileFactory → GPU TileBuffers
```

Completion invalidates a frame with `.tileAvailable`. There are two disk caches: raw payloads and prepared tiles.

## Globe vs flat presentation

`PresentationStateResolver` computes a continuous `transition` in `[0, 1]` from zoom (or a forced override). Both `GlobeRenderState` and `FlatRenderState` are always produced, and shaders morph between sphere and plane rather than hard-switching. `renderSurfaceMode` (`.spherical` / `.flat`) selects the world layers and camera constraints.

## Threading model

No Swift actors. The frame engine and all `UI` runtimes are main-thread (`ImmersiveMapRuntimeGraph` is `@MainActor`). Tile loading runs in `Task`s off the main thread, with mutable state serialized by plain `DispatchQueue`s.
