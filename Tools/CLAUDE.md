# Tools

A physical iPhone needs a different route. SwiftPM test targets are tool-hosted, and `xcodebuild` rejects them on a device destination ("Tool-hosted testing is unavailable on device destinations"), so the suite runs there through `Tools/DeviceTests/`, a host app plus a test bundle that takes its sources straight from `Tests/ImmersiveMapTests` through a synchronized folder reference (no second file list to keep in step):

```sh
xcrun xctrace list devices                                   # find the device id
xcodebuild test -project Tools/DeviceTests/ImmersiveMapDeviceTests.xcodeproj \
  -scheme ImmersiveMapDeviceTests -destination 'id=<device-id>'
```

Reach for it when the question is about hardware: the simulator is a software renderer, so timing, memory and driver behaviour are only real on a device. The tests that read `.metal` source off the checkout to assert on shader logic cannot pass on a device, where there is no checkout; filter them out with `-only-testing:` rather than treating them as failures.

Offline tooling (not part of the SwiftPM build):

- `Tools/TextAtlas/generate_text_atlas.sh`: regenerates the committed MTSDF text atlases in `Sources/ImmersiveMap/Text/Resources/` (`atlas` and `atlas_thin`: RGB carries the MSDF the label fill samples, alpha the plain SDF the halo/stroke coverage is derived from). Requires `msdf-atlas-gen` and local Noto Sans fonts; fonts are never committed. The PNG and its JSON are regenerated together, so a half-updated pair means the shader samples a channel that is not there.
- `Tools/Overview/bake_overview.sh`: bakes the committed overview archive `Sources/ImmersiveMap/Tile/Overview/Resources/overview.pmtiles` (the biomes of RESOLVE Ecoregions 2017 fitted to the Natural Earth coast at zooms 0 to 7, the zoom 0 lakes and the Natural Earth road network at zooms 2 to 5) from the published sources, with the Python steps next to it. Requires mapshaper, tippecanoe and shapely, downloads about 250 MB. The archive is a contract with the built-in style, so a new one bumps `PreparedTileDiskCaching.preparedFormatVersion`.
- `Tools/DeviceTests/`: the `ImmersiveMapDeviceTests` project, which is only how the XCTest suite reaches a physical iPhone (see Commands above). Two targets: a host app that exists solely to be loaded into, and the test bundle. Never part of CI.
