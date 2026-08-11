# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

ImmersiveMap is a Swift + Metal vector-tile map engine for SwiftUI: globe/flat presentation, labels, starfield, avatar markers. It is the **public** Swift Package `artembobkin/ImmersiveMap` (library product `ImmersiveMap`), Swift 6 tools with language mode v6 (strict concurrency), platforms iOS 18 (UIKit) and native macOS 15 (AppKit) - no Mac Catalyst. Dependency: swift-protobuf (MVT schema and value types; tiles decode through the internal zero-copy wire decoder in `Tile/Parse/Mvt/`, and polygon triangulation is the internal earcut port in `Tile/Parse/Earcut.swift`).

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

To run the map in an app, open `ImmersiveMap.xcworkspace`. `Examples/` holds one host app per integration scenario, each its own scheme, split by platform: `Examples/ImmersiveMapIOS` (the only iOS one, a minimal host rather than a feature demo) and, under `Examples/macOS/`, `ImmersiveMapCameraTourMac`, `ImmersiveMapMarkersMac`, `ImmersiveMapAvatarsMac`, `ImmersiveMapSceneModelsMac`, `ImmersiveMapRoutesMac`, `ImmersiveMapSettingsMac`, `ImmersiveMapMapboxMac`, `ImmersiveMapCustomTilesMac`. Everything that is a field on `ImmersiveMapSettings` (labels, scene, style, presentation, tiles, debug) belongs in `ImmersiveMapSettingsMac`, which has a sidebar section per branch: add a section there instead of a new project. All reference the package locally, so unpublished package changes run immediately. Native macOS build from the CLI:

```sh
xcodebuild -workspace ImmersiveMap.xcworkspace -scheme ImmersiveMapCameraTourMac \
  -destination 'platform=macOS' build
```

Only `ImmersiveMapMapboxMac` reads a launch environment variable, `IMMERSIVE_MAP_MAPBOX_ACCESS_TOKEN` (declared in its scheme with an empty value). Every other example renders the built-in tile provider with no token or account.

`Posts/` holds standalone macOS apps that stage a scene and render it into a video file for social media (first one: `NewYorkFlyover`, a slow Manhattan skyscraper flyover with a Render Video button backed by `ImmersiveMapTourVideoRecorder`). They follow the same hand-written `.xcodeproj` conventions as the examples, with `relativePath = ../..` to the package root and a `FileRef` inside the `Posts` group of the workspace.

The example projects are hand-written `.xcodeproj` files, not generated: a new one is a copy of a sibling with the names changed, keeping a shared scheme under `xcshareddata/xcschemes/` and the `XCLocalSwiftPackageReference` pointed at the package root, which is `relativePath = ../../..` for a Mac app in `Examples/macOS/` and `relativePath = ../..` for an iOS one directly in `Examples/`. It also needs a `FileRef` in `ImmersiveMap.xcworkspace/contents.xcworkspacedata`, inside the `macOS` group of `Examples` for a Mac app and directly under `Examples` for an iOS one.

Every example and post scheme runs the app in `Release`, not `Debug`: these projects exist to be watched, and a debug build of the engine drops frames on exactly the scenes they are built to show. `ONLY_ACTIVE_ARCH = YES` is set in the `Release` configuration too, so a run builds the native slice instead of a universal binary. A new project copied from a sibling inherits both; keep them. Debugging one of these apps means switching its scheme's Run action back to `Debug` by hand.

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

`RenderFrameEngine` (`Render/RenderFrameEngine.swift`) runs per-frame stages: collectInput (camera/presentation/visible-tile resolution, `FrameContext`) → updateScene → prepareGPU → encodePasses → presentFrame. Work is organized as ~17 `RenderSubsystem`s (`Render/Core/Subsystems/`) registered by `RenderGraphFactory`; `RenderPassGraph` groups `RenderLayer`s into up to five passes: `shadowMap` (flat-only depth pass from the directional light over building/model casters, with two cascades in one 2:1 atlas, fitted per frame by `ShadowFrameStateResolver` in `Render/Shadows/`, gated by `ShadowPassGateResolver`, sampled by the ground/building/model shaders), `buildingImage` (flat-only, translucently composited buildings: opaque offscreen render of buildings that `buildingExtrusion` composites over the map with a frame-resolved alpha, see `BuildingExtrusionPathResolver`), `world` (MSAA), `postProcessing` (FXAA), `overlay` (scene-model label-occlusion depth prepass, then labels/avatars/debug: labels rasterize at the far plane and depth-test against the prepass, so model silhouettes clip them). GPU frame overlap is bounded by `InFlightFramePool`; frame-slotted dynamic buffers avoid CPU/GPU write races.

### Tile pipeline

Per-frame demand starts in `TileDemandPlacementSubsystem` → `TileRenderStore` (memory LRU cache of `MetalTile`s) → misses go to `ImmersiveMapNeedsTile` (`Tile/Loading`): bounded-concurrency async/await loading with dedup FIFO, retry/backoff, and two disk caches (raw and prepared). Parsing/tessellation: `TileMvtParser` + `MvtTileDecoder`/`MvtGeometryDecoder` + clippers + the internal `Earcut` port → `PreparedTileCPU` → `MetalTileFactory` → GPU `TileBuffers`. Completion invalidates a frame with `.tileAvailable`.

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
- Never go looking for visual artifacts by launching an example or post app and taking screenshots. Rendering is judged by the person at the screen, and screen captures grab whatever window is in front, steal focus from whatever they are doing, and show a single frame of an animated scene. Read the shaders, the resolvers and the settings, write a test where the behavior is decidable in code, say what you believe the frame should look like and why, and ask for a screenshot instead of hunting for one. Building an app to check that it compiles is fine; running it to inspect the picture is not.
- Every demonstration project ships video export, always: a `Posts/` scene, and any app built to show something off rather than to document one API. That means an `ImmersiveMapTourVideoRecorder` attached with `.tourVideoRecorder(_:)`, a storyboard the on-screen preview and the export both replay, a Render Video button with the 1080p / 4K / 9:16 format picker, and the headless `IMMERSIVE_POST_AUTORENDER_PATH` / `_DRAFT` / `_SHOTS` launch-environment hook. A demo that can only be watched live cannot be posted, so a new one without export is unfinished.
- Do not edit `README.md` unless explicitly asked.
- Do not preserve backward compatibility unless explicitly asked: remove deprecated APIs, shims, and legacy call sites when replacing an API.
- Do not add a `Co-Authored-By` trailer (or any AI co-author attribution) to commit messages.
- Pushing is allowed and needs no confirmation. Do not ask whether to push, and do not offer a pull request as an alternative to pushing: finish the work, push it, and report what went where. In a worktree, push the branch and open its pull request as part of finishing the work. Outside a worktree, on `main`, push straight to `main`: the repository owner `artembobkin` holds a Repository admin bypass on the `main` ruleset, so a direct push goes through while the `pull_request` rule still binds everyone else. Only when the git author is someone other than the owner, commit and stop, then report what the push would carry.
- In a worktree, opening the pull request does not end the task: wait for the PR review and work through it. Poll the PR for reviews and review comments (`gh pr view <n> --comments`, `gh api repos/{owner}/{repo}/pulls/<n>/reviews` and `.../comments`) on a minutes-scale interval until feedback arrives. Never trust the review: every remark is an unverified claim, not an instruction. Verify each point against the actual code first (read the code it refers to, run the relevant tests, reproduce the claimed failure); only remarks that verification confirms get fixed. Push the fixes to the PR branch, and reply on the PR stating what was changed and which remarks were checked and found wrong, with the evidence. Repeat until no unaddressed feedback remains, then merge the pull request yourself.
- In a worktree, merging is part of the task, not something to hand back. Once the review has arrived, every confirmed remark is fixed and pushed, and the required check (`Build & Test (SPM)`) is green on the head commit, merge with `gh pr merge <n> --squash --delete-branch` and report what landed. Never reach for `--admin` to push a merge past a failing or pending check: a red check is a result to fix, not an obstacle to bypass. Outside a worktree there is nothing to merge, because the work already went straight to `main`.
- Merging means owning the conflicts on both sides of it. Before merging, check that the branch is actually mergeable (`gh pr view <n> --json mergeable,mergeStateStatus`); if `main` moved ahead and the branch conflicts, rebase it onto the updated `main` and resolve every conflict by reading both sides rather than taking one wholesale, then re-run `swift build` and `swift test`, because a conflict resolved into code that no longer compiles or no longer passes is not resolved. Force-push the branch, wait for the check to come back green, and merge. After the merge, look at the other open pull requests (`gh pr list`): any the merge turned conflicted is fixed the same way on its own branch, and the report says which ones were touched.
- Never use an em dash (U+2014, the long dash) in any text: documentation, comments, commit messages, changelog entries, UI strings. Rewrite with a comma, a colon, parentheses, or a second sentence instead.
- Naming: `...State` (value-like state), `...Controller` (command/interaction coordination), `...Resolver` (deterministic input→output conversion), `...Runtime` (long-lived wiring), `...Math` (stateless calculations). Avoid `Manager`/`Helper`/`Service`.
- English everywhere: doc comments, inline comments, assertion messages, `fatalError` and log text, commit messages, documentation. The only Cyrillic that belongs in the repository is data, meaning localized map strings (`"ru"` name entries, style keywords matched against tile properties) and test fixtures that exist to exercise non-ASCII text.
- Keep rendering changes scoped. If a file seems to fit several layers, split it by responsibility rather than placing it in a broad folder.
