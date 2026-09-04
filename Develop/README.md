# Develop

Scratch apps for work in progress: the map pointed at a tile source that is
still being built, at a setting being tried out, at whatever is on the bench
this week. They are committed so that the workspace a clone opens is the same
workspace, and so that what the engine is being worked against is visible rather
than living in someone's uncommitted diff.

Projects:

- `ImmersiveMapDevMac`: the plain map with the camera controls and the debug HUD,
  reading the test tile endpoint instead of the hosted one, with the disk caches
  cleared on every launch, with the streetscape switch in the file. `IMMERSIVEMAP_DEV_TILE_TEMPLATE`
  and `IMMERSIVEMAP_DEV_STREETSCAPE_TEMPLATE` in the scheme environment repoint
  the map tiles and the streetscape archive at another source without editing
  the file.

## Not an example, not a post

`Examples/` documents the public API for a reader, and each project there stays
put: one page of the manual per app. `Posts/` stages a scene to be recorded.
Both are written to be found in the state a stranger expects.

A project here is the opposite. It is expected to change under you, to be
pointed at a URL that will stop existing, to carry the settings of the current
experiment. Nothing in `Documentation/` links to it, no test covers it, and
breaking one costs nothing but the next commit. When an experiment turns into a
feature, the app that shows it off is written in `Examples/` and this one goes
back to whatever comes next.

Two consequences follow from that:

- The schemes run **Debug**, unlike every example and post scheme, which run
  Release so the scene they exist to show does not drop frames. These exist to
  be stepped through with breakpoints in the tile pipeline. Switch a scheme's
  Run action to Release by hand when the question is about frame timing.
- A tile URL under development is a URL under development. It can answer 204
  outside the box it was cut for, serve a stale build, or go away entirely, and
  an empty map is the data saying so, not the engine failing.

## Conventions

Same hand-written `.xcodeproj` layout as the examples: a shared scheme under
`xcshareddata/xcschemes/`, an `XCLocalSwiftPackageReference` with
`relativePath = ../..` pointing at the package root, and a `FileRef` inside the
`Develop` group of `ImmersiveMap.xcworkspace/contents.xcworkspacedata`. A new
project is a copy of a sibling with the names changed.

The API key follows the rule the rest of the repository follows: read from
`IMMERSIVEMAP_API_KEY` in the environment, otherwise from the gitignored
`LocalSecrets.plist` at the repository root. The shared schemes carry the
variable with an empty value as a placeholder. A key is never committed, here
least of all.

Build from the CLI:

```sh
xcodebuild -workspace ImmersiveMap.xcworkspace -scheme ImmersiveMapDevMac \
  -destination 'platform=macOS' build
```
