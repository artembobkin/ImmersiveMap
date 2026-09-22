---
paths:
  - "Tests/**"
  - "Tools/DeviceTests/**"
---

# Tests

- The test suite never fetches a tile from the network: such a test also asserts that the machine has a network and that a CDN answered in time with the planet build it was written against. A test that needs tiles takes its settings from `FixtureTiles` (`Tests/ImmersiveMapTests/Support/`): `settings()` serves generated fixture tiles over loopback so the bytes travel the whole loader path, and `tilelessSettings()` gives a map no tile can reach, for a case comparing two frames. `FixtureTileServiceTests` fails the run when a runtime is handed `ImmersiveMapSettings.default` instead.
- `swift test` cannot compile `.metal` shaders, so a test that needs a compiled Metal library skips itself there and runs only through xcodebuild (see the commands in `CLAUDE.md`).
