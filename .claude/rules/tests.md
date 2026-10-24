---
paths:
  - "Tests/**"
  - "Tools/DeviceTests/**"
---

# Tests

- The test suite never fetches a tile from the network: such a test also asserts that the machine has a network and that a CDN answered in time with the planet build it was written against. A test that needs tiles takes its settings from `FixtureTiles` (`Tests/ImmersiveMapTests/Support/`): `settings()` serves generated fixture tiles over loopback so the bytes travel the whole loader path, and `tilelessSettings()` gives a map no tile can reach, for a case comparing two frames. `FixtureTileServiceTests` fails the run when a runtime is handed `ImmersiveMapSettings.default` instead.
- `swift test` cannot compile `.metal` shaders, so a test that needs a compiled Metal library skips itself there and runs only through xcodebuild (see the commands in `CLAUDE.md`).
- Never write a picture test: one that renders a frame (through `OffscreenFrameHarness` or otherwise) and asserts on its pixels, colours or coverage. They are brittle, they fail on a driver or a one-pixel shift, and nobody maintains them as a gate. The existing ones are opt-in behind `IMMERSIVE_MAP_RUN_PICTURE_TESTS=1`, skipped by default and never run in CI, so do not add that variable to a workflow. A rendering change is checked by the person at the screen in the app, and a test covers the math, the planning and the state behind it instead: pipeline creation, uniforms, placement, resolver and store logic.
