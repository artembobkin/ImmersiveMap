# Posts

Standalone macOS apps that stage ImmersiveMap scenes and render them into video files for social media posts. Each project is one scene: a scripted camera storyboard, an on-screen preview, and a Render Video button that exports the same storyboard offline through `ImmersiveMapTourVideoRecorder`.

Projects:

- `NewYorkFlyover`: a slow cinematic pass over Manhattan's skyscrapers.
- `BerlinNightDescent`: a straight fall from a globe view onto the colonnade of Berlin's Altes Museum, in the dark palette of the `ImmersiveMapSettingsMac` example.
- `GlobeUnfurl`: the sphere unrolling into a plane and rolling back up, with a widened transition span and a hold on the half-unrolled state.

Every project references the package locally (`XCLocalSwiftPackageReference` with `relativePath = ../..`), so unpublished package changes run immediately. A new post project is a copy of a sibling with the names changed, keeping the shared scheme under `xcshareddata/xcschemes/`, plus a `FileRef` inside the `Posts` group of `ImmersiveMap.xcworkspace/contents.xcworkspacedata`.

Build from the CLI:

```sh
xcodebuild -workspace ImmersiveMap.xcworkspace -scheme NewYorkFlyover \
  -destination 'platform=macOS' build
```

Headless rendering (CI or batch use): launching a post app with `IMMERSIVE_POST_AUTORENDER_PATH=<output.mov>` in the environment renders the storyboard to that path and terminates with a process exit code, no clicks needed. `IMMERSIVE_POST_AUTORENDER_DRAFT=1` switches to a fast 640x360 draft, `IMMERSIVE_POST_AUTORENDER_SHOTS=N` limits the render to the first N shots:

```sh
IMMERSIVE_POST_AUTORENDER_PATH=/tmp/draft.mov IMMERSIVE_POST_AUTORENDER_DRAFT=1 \
  ./NewYorkFlyover.app/Contents/MacOS/NewYorkFlyover
```

Exported footage carries no attribution badge (it is host-view chrome): add the map attribution to the post before publishing.
