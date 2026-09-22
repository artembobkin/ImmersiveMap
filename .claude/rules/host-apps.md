---
paths:
  - "Examples/**"
  - "Develop/**"
  - "ImmersiveMap.xcworkspace/**"
---

# Example and development apps

To run the map in an app, open `ImmersiveMap.xcworkspace`. `Examples/` holds one host app per integration scenario, each its own scheme, split by platform: `Examples/ImmersiveMapIOS` (the only iOS one, a minimal host rather than a feature demo) and, under `Examples/macOS/`, `ImmersiveMapMac` (the plain map: built-in provider, camera UI controls, debug HUD, no panel over it), `ImmersiveMapCameraTourMac`, `ImmersiveMapMarkersMac`, `ImmersiveMapAvatarsMac`, `ImmersiveMapSceneModelsMac`, `ImmersiveMapRoutesMac`, `ImmersiveMapOfflineMac`, `ImmersiveMapSettingsMac`, `ImmersiveMapCustomTilesMac`. Everything that is a field on `ImmersiveMapSettings` (labels, scene, style, presentation, tiles, debug) belongs in `ImmersiveMapSettingsMac`, which has a sidebar section per branch: add a section there instead of a new project. All reference the package locally, so unpublished package changes run immediately. Native macOS build from the CLI:

```sh
xcodebuild -workspace ImmersiveMap.xcworkspace -scheme ImmersiveMapCameraTourMac \
  -destination 'platform=macOS' build
```

The hosted tile service at `immersivemap.dev` is public: no key, no account, and the documentation must not say otherwise. Every example app writes the tile source as the one-line template `.tileURLTemplate("https://immersivemap.dev/tiles/{z}/{x}/{y}.mvt")`, with no headers and no key-reading helper. A private endpoint of your own takes its headers through `.tileURLTemplate(_:headers:)` from a value kept outside the repository, and secrets must never be committed, whether in a scheme, in code, or anywhere else. `ImmersiveMapCustomTilesMac` additionally lets the URL field point anywhere and pairs it with its own style.

The showcase scenes, standalone macOS apps that each stage one scene and render it into a video file for a social media post (`NewYorkFlyover`, `BerlinNightDescent`, `GlobeUnfurl`, `CrowdBloom`), are their own repository, `artembobkin/ImmersiveMapShowcase`, checked out next to this one as `../ImmersiveMapShowcase` and linking this package by the local path `../../ImmersiveMap`. Its README documents the headless render hooks and lists the scenes, and its own CLAUDE.md carries the scene conventions (video export always, hand-written projects, Release schemes). A new scene made for a post is written there.

`Develop/` holds scratch apps for work in progress: the map pointed at a tile source that is still being cut, at a setting being tried out, at whatever is on the bench. They are committed on purpose, so that a clone opens the same workspace and so that what the engine is being worked against is visible instead of living in an uncommitted diff. `ImmersiveMapDevMac` is the one project so far: the plain map with camera controls and the debug HUD, reading the test tile endpoint with the disk caches cleared on every launch, repointable through `IMMERSIVEMAP_DEV_TILE_TEMPLATE` in the scheme environment. Nothing in `Documentation/` links there and no test covers it. An app here is expected to change under you; when an experiment turns into a feature, the app that shows it off is written in `Examples/`, and `ImmersiveMapMac` in particular stays the untouched demonstration of the shipping tile service, so a test source belongs here rather than in that file. `Develop/README.md` states the rules.

The example projects are hand-written `.xcodeproj` files, not generated: a new one is a copy of a sibling with the names changed, keeping a shared scheme under `xcshareddata/xcschemes/` and the `XCLocalSwiftPackageReference` pointed at the package root, which is `relativePath = ../../..` for a Mac app in `Examples/macOS/` and `relativePath = ../..` for an iOS one directly in `Examples/`. It also needs a `FileRef` in `ImmersiveMap.xcworkspace/contents.xcworkspacedata`, inside the `macOS` group of `Examples` for a Mac app and directly under `Examples` for an iOS one.

Every example scheme runs the app in `Release`, not `Debug`: these projects exist to be watched, and a debug build of the engine drops frames on exactly the scenes they are built to show. `ONLY_ACTIVE_ARCH = YES` is set in the `Release` configuration too, so a run builds the native slice instead of a universal binary. A new project copied from a sibling inherits both; keep them. Debugging one of these apps means switching its scheme's Run action back to `Debug` by hand. A `Develop/` scheme is the exception and runs `Debug`: those apps exist to be stepped through, not watched.
