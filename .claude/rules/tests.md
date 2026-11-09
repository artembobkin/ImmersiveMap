---
paths:
  - "Tests/**"
  - "Tools/DeviceTests/**"
---

# Tests

- The test suite never fetches a tile from the network: such a test also asserts that the machine has a network and that a CDN answered in time with the planet build it was written against. A test that needs tiles takes its settings from `FixtureTiles` (`Tests/ImmersiveMapTests/Support/`): `settings()` serves generated fixture tiles over loopback so the bytes travel the whole loader path, and `tilelessSettings()` gives a map no tile can reach, for a case comparing two frames. `FixtureTileServiceTests` fails the run when a runtime is handed `ImmersiveMapSettings.default` instead.
- Every build of the package compiles the shaders (`MetalLibraryPlugin`), `swift test` included, so a Metal-backed test runs under `swift test` as under xcodebuild, and skips itself only where there is no Metal device or no compiled library (`MetalTestEnvironment`). The iOS half runs through xcodebuild (see the commands in `CLAUDE.md`).
- Never write a picture test: one that renders a frame (through `OffscreenFrameHarness` or otherwise) and asserts on its pixels, colours or coverage. They are brittle, they fail on a driver or a one-pixel shift, and nobody maintains them as a gate. The existing ones are opt-in behind `IMMERSIVE_MAP_RUN_PICTURE_TESTS=1`, skipped by default and never run in CI, so do not add that variable to a workflow. A rendering change is checked by the person at the screen in the app, and a test covers the math, the planning and the state behind it instead: pipeline creation, uniforms, placement, resolver and store logic.
- Never write a test that waits a fixed time and then asserts that something happened (a sleep, then "the tile is ready", "the view expired", events ordered by sleeping between them). Whether the work is done by then depends on how fast the machine is, and the CI's iOS simulator is the slowest of them, so such a test fails there now and then and trains everyone to ignore a red run. A test drives the work to a point it can wait on (`ControlledTileLoadPipeline.waitUntil...`, a completion, an injected clock) or is not written. A sleep followed by an assertion that nothing happened is allowed: a slow machine cannot make it fail.
- Never write a test of a view's layout or its controls (a UIKit or AppKit view built in the test and inspected through hooks). The debug panel's were removed for being brittle, and a view is checked in the app like a picture. Test the planner or the model behind the view instead.
