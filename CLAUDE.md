# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

ImmersiveMap is a Swift + Metal vector-tile map engine for SwiftUI: globe/flat presentation, labels, starfield, avatar markers. It is the **public** Swift Package `artembobkin/ImmersiveMap` (library product `ImmersiveMap`), Swift 6 tools with language mode v6 (strict concurrency), platforms iOS 18 (UIKit) and native macOS 15 (AppKit) - no Mac Catalyst. Dependencies: SwiftEarcut (polygon triangulation) and swift-protobuf (MVT decoding).

Because the repo is public: never commit tokens (Mapbox, bearer), credentials, `LocalSecrets.plist`-style files, or build artifacts (`.build/`, `DerivedData/`, `Traces/`).

## Commands

```sh
swift build                                        # build the package (native macOS)
swift test                                         # run all tests (XCTest, ~77 files)
swift test --filter <TestClassName>                # run one test class
swift test --filter <TestClassName>/<testMethod>   # run one test method
```

`swift test` runs natively on macOS but cannot compile `.metal` shaders (tests that need a compiled Metal library skip themselves). To run the suite with compiled shaders or on iOS, use xcodebuild against the SwiftPM-generated workspace:

```sh
xcodebuild test -workspace .swiftpm/xcode/package.xcworkspace -scheme ImmersiveMap \
  -destination 'platform=macOS'                          # full suite, native macOS
xcodebuild test -workspace .swiftpm/xcode/package.xcworkspace -scheme ImmersiveMap \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro'   # full suite, iOS (runs UIKit-gated tests)
```

To run the map in an app, open `ImmersiveMap.xcworkspace`, which has schemes `ImmersiveMapIOS` (iOS host app) and `ImmersiveMapMac` (native macOS host app, AppKit). Both host apps reference the package locally, so unpublished package changes run immediately. Native macOS build from the CLI:

```sh
xcodebuild -workspace ImmersiveMap.xcworkspace -scheme ImmersiveMapMac \
  -destination 'platform=macOS' build
```

Host apps read optional launch environment variables: `IMMERSIVE_MAP_TILE_BASE_URL`, `IMMERSIVE_MAP_AUTH_TOKEN`, `IMMERSIVE_MAP_MAPBOX_ACCESS_TOKEN`, `IMMERSIVE_MAP_MAPBOX_TILESET_ID`. If the Mapbox token is present, the host apps use the Mapbox Vector Tiles API.

Offline tooling (not part of the SwiftPM build):

- `Tools/TextAtlas/generate_text_atlas.sh`: regenerates the committed MSDF text atlases in `ImmersiveMap/Text/Resources/` (requires `msdf-atlas-gen` and local Noto Sans fonts; fonts are never committed).

## Architecture

Package source root is `ImmersiveMap/` (~330 Swift files, 17 `.metal` shaders). Most top-level folders contain a `README.md` with hard "Responsibilities / Must Not Contain" boundary rules; read it before adding files to a folder.

### Layering

Dependencies point inward: `UI` → `Render` → domain folders (`Camera`, `Tile`, `Labels`, `Text`, `Presentation`, `Globe`, `EarthScene`, `Avatars`, `Starfield`, `Geo`) → `Utils`. Domain folders must not depend on `UI`/`Render` and must not contain Metal code; `Render` must not contain networking or platform UI. Provider-specific MVT schema logic is confined to `VectorTileAdaptation/` and the concrete provider folders under `Provider/` (`Provider/Mapbox`, `Provider/ImmersiveMapTiles`); `Render`, `Labels`, and `Tile` consume only provider-neutral, already-normalized data.

### Public API and wiring

`ImmersiveMapView` (SwiftUI, `UI/ImmersiveMapView.swift`) accumulates builder-style modifiers (`.camera`, `.tileProvider`, `.mapStyle`, `.labelSettings`, …) into an `ImmersiveMapSettings` value (`Configuration/`) and wraps the platform host view: `ImmersiveMapUIView` (UIKit) on iOS, `ImmersiveMapNSView` (AppKit, flipped, `CAMetalLayer` backing layer) on macOS - internally unified by the `ImmersiveMapHostView` typealias (`UI/PlatformViewSupport.swift`). The public SwiftUI API is identical on both platforms. Wiring chain: `ImmersiveMapView` → host view → `ImmersiveMapHostRuntime` (shared settings/renderer lifecycle owner) → `ImmersiveMapRuntimeGraph` (composition root, `@MainActor`) → controllers/runtimes + `ImmersiveMapRendererBuilder` → `RenderFrameEngine`. Platform-specific UI (gestures, attribution badge, debug HUD, control zones) lives in per-platform files guarded by `#if canImport(UIKit)` / `#if os(macOS)`; never use `targetEnvironment(macCatalyst)`.

Public controllers: `ImmersiveMapCameraController`, `ImmersiveMapAvatarsController`, `ImmersiveMapSelectionController`. Provider protocols live in `Provider/Core/` (`ImmersiveMapTileProvider`, `ImmersiveMapMapStyle`, `ImmersiveMapVectorTileStyle`); concrete implementations live in sibling folders under `Provider/`: `ImmersiveMapTilesProvider`/`ImmersiveMapTilesMapStyle` and `MapboxTileProvider`/`MapboxMapStyle`. Providers/styles expose a `configurationFingerprint` (FNV-1a) that drives disk-cache identity, so changing provider config must change the fingerprint.

### Frame loop and render pipeline

Rendering is **on-demand**: `ImmersiveMapRenderDriver` (`UI/`) drives a `CADisplayLink` that is normally paused; `RenderLoopPacing` resumes it for activities (interaction, label fades, camera/avatar animations) and one-shot `requestFrame(reason:)` invalidations. Any state change that should redraw must request a frame or register an activity, otherwise the screen won't update. The display link is created via a platform `DisplayLinkFactory`: `CADisplayLink(target:selector:)` on iOS, `NSView.displayLink(target:selector:)` on macOS (tracks the window's display).

`RenderFrameEngine` (`Render/RenderFrameEngine.swift`) runs per-frame stages: collectInput (camera/presentation/visible-tile resolution, `FrameContext`) → updateScene → prepareGPU → encodePasses → presentFrame. Work is organized as ~17 `RenderSubsystem`s (`Render/Core/Subsystems/`) registered by `RenderGraphFactory`; `RenderPassGraph` groups `RenderLayer`s into up to five passes: `shadowMap` (flat-only depth pass from the directional light over building/model casters, with two cascades in one 2:1 atlas, fitted per frame by `ShadowFrameStateResolver` in `Render/Shadows/`, gated by `ShadowPassGateResolver`, sampled by the ground/building/model shaders), `buildingImage` (flat-only, translucently composited buildings: opaque offscreen render of buildings that `buildingExtrusion` composites over the map with a frame-resolved alpha, see `BuildingExtrusionPathResolver`), `world` (MSAA), `postProcessing` (FXAA), `overlay` (labels/avatars/debug). GPU frame overlap is bounded by `InFlightFramePool`; frame-slotted dynamic buffers avoid CPU/GPU write races.

### Tile pipeline

Per-frame demand starts in `TileDemandPlacementSubsystem` → `TileRenderStore` (memory LRU cache of `MetalTile`s) → misses go to `ImmersiveMapNeedsTile` (`Tile/Loading`): bounded-concurrency async/await loading with dedup FIFO, retry/backoff, and two disk caches (raw and prepared). Parsing/tessellation: `TileMvtParser` + clippers/decoders + SwiftEarcut → `PreparedTileCPU` → `MetalTileFactory` → GPU `TileBuffers`. Completion invalidates a frame with `.tileAvailable`.

### Globe vs flat presentation

`Presentation/PresentationStateResolver` computes a continuous `transition` in [0,1] from zoom (or a forced override in `MapPresentationStateController`); both `GlobeRenderState` and `FlatRenderState` are always produced, and shaders morph between sphere and plane rather than hard-switching. `renderSurfaceMode` (`.spherical`/`.flat`) selects the world layers (globe adds starfield + globe cap; flat adds the building image/extrusion work) and camera constraints.

### Threading model

No Swift actors. The frame engine and all `UI` runtimes are main-thread (`ImmersiveMapRuntimeGraph` is `@MainActor`). Tile loading runs in `Task`s off the main thread with mutable state serialized by plain `DispatchQueue`s (e.g. `ImmersiveMapNeedsTile.stateQueue`).

## Conventions and Rules

- Every hand-written `.swift`, `.metal`, `.h`, `.proto` file starts with:
  ```text
  // Copyright (c) 2025-2026 ImmersiveMap contributors.
  // SPDX-License-Identifier: MIT
  ```
  Do **not** add the header to generated files (`ImmersiveMap/Generated/Proto/vector_tile.pb.swift`).
- `ImmersiveMap/Generated/Proto/vector_tile.pb.swift` is generated by swift-protobuf from `ImmersiveMap/Proto/vector_tile.proto`; never hand-edit it, regenerate from the schema.
- Shaders and resources load via `Bundle.module`. Every new `.metal` file or resource directory must be registered under `resources:` in `Package.swift`, and every new in-source `README.md` must be added to `exclude:`, otherwise the build breaks or the resource silently doesn't ship.
- Do not edit `README.md` unless explicitly asked.
- Do not preserve backward compatibility unless explicitly asked: remove deprecated APIs, shims, and legacy call sites when replacing an API.
- Do not add a `Co-Authored-By` trailer (or any AI co-author attribution) to commit messages.
- Do not merge. Prepare the branch, commit, push and open the pull request, then stop and report the PR link. Merging into `main` is done by the maintainer by hand, always. This holds even if a merge was mentioned as an option earlier in the conversation.
- Never use an em dash (U+2014, the long dash) in any text: documentation, comments, commit messages, changelog entries, UI strings. Rewrite with a comma, a colon, parentheses, or a second sentence instead.
- Naming: `...State` (value-like state), `...Controller` (command/interaction coordination), `...Resolver` (deterministic input→output conversion), `...Runtime` (long-lived wiring), `...Math` (stateless calculations). Avoid `Manager`/`Helper`/`Service`.
- Many source files carry Russian-language doc comments; match the surrounding file's style.
- Keep rendering changes scoped. If a file seems to fit several layers, split it by responsibility rather than placing it in a broad folder.
