# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

ImmersiveMap is a Swift + Metal vector-tile map engine for SwiftUI: globe/flat presentation, labels, starfield, extruded buildings with directional shadows, SwiftUI markers, avatar markers, routes, 3D scene models, offline regions, and video/still export. It is the **public** Swift Package `artembobkin/ImmersiveMap` (library product `ImmersiveMap`), Swift 6 tools with language mode v6 (strict concurrency), platforms iOS 18 (UIKit) and native macOS 15 (AppKit)

Because the repo is public: never commit tile-provider API keys, bearer tokens, credentials, `LocalSecrets.plist`-style files, or build artifacts (`.build/`, `DerivedData/`, `Traces/`).

## Commands

`swift test` runs natively on macOS but cannot compile `.metal` shaders (tests that need a compiled Metal library skip themselves). To run the suite with compiled shaders or on iOS, use xcodebuild against the SwiftPM-generated workspace:

```sh
xcodebuild test -workspace .swiftpm/xcode/package.xcworkspace -scheme ImmersiveMap \
  -destination 'platform=macOS'                          # full suite, native macOS
xcodebuild test -workspace .swiftpm/xcode/package.xcworkspace -scheme ImmersiveMap \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro'   # full suite, iOS (runs UIKit-gated tests)
```

To run the map in an app, open `ImmersiveMap.xcworkspace`. Work in progress is shown in `Develop/ImmersiveMapDevMac`, and `Examples/macOS/ImmersiveMapMac` stays the untouched demonstration of the shipping tile service. A user-visible rendering feature that ships without a scenario in `Tools/VisualReview/` does not get looked at before a release.

## Architecture

A folder's boundary rules, what it owns and what it must not contain, are in the comment on its main type (`RenderFrameEngine` for `Render`, `ImmersiveMapView` for `UI`). Read it before adding a file to a folder.

### Targets

The package follows the standard SwiftPM layout (`Sources/<Target>`, `Tests/<Target>Tests`), so `Package.swift` states no paths. Besides `ImmersiveMap` (the engine, the only product) there are five targets at `package` access, visible to every target of the package and to no app that links the product:

- `Mvt` (`Sources/Mvt`): the Mapbox Vector Tile decoder. The zero-copy wire decoder `MvtTileDecoder`, the decoded model, `MvtGeometryDecoder` and `MvtAttributeDecoder` (the per-feature geometry and tag loops live there so they specialize next to the varint reader, never across the module boundary), `MvtValue` and `MvtGeometryType`, and the tile-space geometry `Point`/`Polygon` with the multi aliases, which `Sources/ImmersiveMap/Tile/Parse/TileSpaceGeometry.swift` re-declares as engine typealiases so they shadow QuickDraw's names the way the old in-module declarations did. The target knows nothing of the tile schema's meaning: no layer name, no style.
- `MvtTestSupport` (`Sources/MvtTestSupport`): the test-side encoder, the synthetic fixture tiles and a deterministic generator. A regular target because test targets cannot share sources, and `MvtTests` and `ImmersiveMapTests` both depend on it.
- `PMTiles` (`Sources/PMTiles`): the PMTiles v3 reader, a tool like `Earcut` with no engine dependency. The format as pure functions over `Data` (`PMTilesHeader`, `PMTilesDirectory` with `PMTilesEntry` and the lookup, `PMTilesTileID` for the Hilbert tile id, `PMTilesGzip` over the system zlib, `PMTilesFormatError`) and the HTTP range client `PMTilesArchiveClient` that reads an archive with them, keeping its leaf directories in `PMTilesDirectoryCache`. It hands back decompressed tile bytes, and the engine's `TileDownloader` maps its outcomes onto the tile loader's.
- `PMTilesTestSupport` (`Sources/PMTilesTestSupport`): `PMTilesArchiveWriter`, a writer independent of the reader that builds fixture archives for `PMTilesTests` and `ImmersiveMapTests`.
- `Earcut` (`Sources/Earcut`): the internal earcut port for polygon triangulation, one enum `Earcut` with `tessellate` and `deviation`, no dependencies. `ParsePolygon` reaches it with `import Earcut`, and `EarcutTests` imports the module without `@testable`.

### Decisions

The code shows how things are wired. These are the decisions behind it, which the code cannot show.

- Dependencies point inward: `UI` → `Render` and the feature folders → `Utils`. A feature folder owns everything of its feature, its model, its math and its drawing (pipelines, shaders, drawers, its `RenderSubsystem`), so there is one place to read for a feature. `Render` knows a feature only through `RenderSubsystem` and `RenderGraphFactory`, a feature never reaches into another feature's GPU internals, feature folders never depend on `UI`, and `Render` holds no networking or platform UI.
- Schema-specific tile logic is confined to `VectorTileAdaptation/`, `Schema/Default` and `Style/Default`. `Render`, `Labels` and `Tile` consume only schema-neutral, already normalized data.
- Rendering is on-demand. The display link is normally paused and resumes for activities (interaction, fades, animations) and one-shot frame requests, so any state change that should redraw must request a frame or register an activity, or the screen does not update.
- Globe and flat are one continuous transition, not a switch. Both render states are always produced and the shaders morph between sphere and plane by a value in [0, 1], so a new layer follows the morph rather than branching on the mode.
- No Swift actors. The frame engine and the `UI` runtimes are main-thread, and tile loading runs in `Task`s off the main thread with its mutable state serialized by plain `DispatchQueue`s. An isolation error is solved within that scheme, not by introducing an actor.
- The public API and the map style: `.claude/rules/public-api.md`, loaded when working under `UI/`, `Configuration/`, `Style/` or `Schema/`.

## Conventions and Rules

- Every hand-written `.swift`, `.metal`, `.h` file starts with:
  ```text
  // Copyright (c) 2025-2026 ImmersiveMap contributors.
  // SPDX-License-Identifier: MIT
  ```
- Shaders and resources load via `Bundle.module`. Every new `.metal` file or resource directory must be registered under `resources:` in `Package.swift`, otherwise the resource silently doesn't ship.
- Never commit, run tests or push on your own. A change is left in the working tree, built if a build is needed to check it, and reported. The person at the screen looks first and says when to commit, which tests to run, and when to push, each one its own explicit word.
- There is no separate documentation to keep up: the guides and the DocC catalog were removed on purpose, and the doc comments in the code are the reference. Do not add them back. `Assets/` holds the README's images.
- Never edit `README.md`, `CHANGELOG.md` or any other `.md` file except this one and the rules under `.claude/`. When a change makes a statement in one of them wrong, leave the file as it is and say which file and which statement in the report.
- Never launch an app or take screenshots. Building it to check that it compiles is where it stops. Rendering is judged by the person: say which app to run (`Develop/ImmersiveMapDevMac` for work in progress), what the frame should look like, and ask for a screenshot.
- The public API is not frozen. Refactoring it is allowed, breaking changes included: a public symbol may be renamed, removed, reshaped or given a different signature when the design calls for it, and no deprecation shim or parallel old API is required. Anything `internal` can be reshaped freely as before.
- Never use a semicolon to join two clauses in prose (documentation, comments, commit messages, UI strings, replies): write two sentences instead. Semicolons in code are fine.
- Never use an em dash (U+2014, the long dash) in any text: documentation, comments, commit messages, changelog entries, UI strings. Rewrite with a comma, a colon, parentheses, or a second sentence instead.
- English everywhere: doc comments, inline comments, assertion messages, `fatalError` and log text, commit messages, documentation. Any other language belongs in the repository only as data, meaning localized map strings (`"ru"`, `"de"`, `"ja"` and the rest of the name entries, style keywords matched against tile properties) and test fixtures that exist to exercise non-ASCII text.
