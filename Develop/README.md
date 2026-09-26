# Develop

Scratch apps for work in progress: the map pointed at a tile source that is
still being built, at a setting being tried out, at whatever is on the bench
this week. They are committed so that the workspace a clone opens is the same
workspace, and so that what the engine is being worked against is visible rather
than living in someone's uncommitted diff.

Projects:

- `ImmersiveMapDevMac`: the plain map with the camera controls and the debug HUD,
  reading the hosted Protomaps archive, with the disk caches cleared on every
  launch. `IMMERSIVEMAP_DEV_TILE_ARCHIVE` in the scheme environment points the
  map at another PMTiles archive URL without editing the file, which is what
  to reach for when comparing two builds of a tileset.

## Not an example, not a post

`Examples/` documents the public API for a reader, and each project there stays
put: one page of the manual per app. A showcase scene (its own repository,
`../ImmersiveMapShowcase`) stages a scene to be recorded. Both are written to be
found in the state a stranger expects.

A project here is the opposite. It is expected to change under you, to be
pointed at a URL that will stop existing, to carry the settings of the current
experiment. The README does not link to it, no test covers it, and breaking
one costs nothing but the next commit. When an experiment turns into a
feature, the app that shows it off is written in `Examples/` and this one goes
back to whatever comes next.

Two consequences follow from that:

- The schemes run **Debug**, unlike every example and post scheme, which run
  Release so the scene they exist to show does not drop frames. These exist to
  be stepped through with breakpoints in the tile pipeline. Switch a scheme's
  Run action to Release by hand when the question is about frame timing.
- An archive under development is an archive under development. It can cover
  only the box it was cut for, hold a stale build, or go away entirely, and an
  empty map is the data saying so, not the engine failing.

## Conventions

Same hand-written `.xcodeproj` layout as the examples: a shared scheme under
`xcshareddata/xcschemes/`, an `XCLocalSwiftPackageReference` with
`relativePath = ../..` pointing at the package root, and a `FileRef` inside the
`Develop` group of `ImmersiveMap.xcworkspace/contents.xcworkspacedata`. A new
project is a copy of a sibling with the names changed.

The hosted archive is public and needs no key, and nothing secret is ever
committed, here least of all. An app that has to reach a private archive of
your own passes its headers through `.tileArchive(_:headers:)` from a value
that lives outside the repository.

Build from the CLI:

```sh
xcodebuild -workspace ImmersiveMap.xcworkspace -scheme ImmersiveMapDevMac \
  -destination 'platform=macOS' build
```
