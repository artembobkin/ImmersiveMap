# Contributing to ImmersiveMap

Thanks for your interest in contributing.

ImmersiveMap is an early-stage Swift + Metal map rendering engine, currently maintained as a single-maintainer project. Contributions are welcome - especially around documentation, examples, tests, bug reports, and small focused improvements.

## Good first contributions

- Documentation fixes
- Example improvements
- Bug reports with reproduction steps
- Tests for existing behavior
- Small, focused bug fixes

## Development setup

1. Clone the repository.
2. Build and test the package with Swift Package Manager:
   ```bash
   swift build
   swift test
   ```
3. To run the map in a host app, open `ImmersiveMap.xcworkspace` and select one of the example schemes. They live in `Examples/`, one app per integration scenario, and reference the package locally, so unpublished changes run immediately. `ImmersiveMapIOS` is the iOS one; the rest are native macOS (AppKit). The README's **Example Apps** table lists what each one shows.

Native macOS build from the CLI:

```bash
xcodebuild -workspace ImmersiveMap.xcworkspace -scheme ImmersiveMapCameraTourMac \
  -destination 'platform=macOS' build
```

A new example is a hand-written `.xcodeproj` copied from a sibling: keep the `XCLocalSwiftPackageReference` with `relativePath = ../..`, ship a shared scheme under `xcshareddata/xcschemes/` (otherwise the scheme will not appear in the workspace for anyone else), and add a `FileRef` to the `Examples` group of `ImmersiveMap.xcworkspace/contents.xcworkspacedata`.

New projects are for integration scenarios: things an app wires up, like a provider, a controller or a view of your own. A new field on `ImmersiveMapSettings` is not one of those; it gets a section in `ImmersiveMapSettingsMac` next to the labels, scene, style, presentation and diagnostics panels.

## Project conventions

- Every hand-written `.swift`, `.metal`, `.h` file starts with the license header:
  ```text
  // Copyright (c) 2025-2026 ImmersiveMap contributors.
  // SPDX-License-Identifier: MIT
  ```
  Do not add the header to generated files.
- Dependencies point inward: `UI` → `Render` → domain folders → `Utils`. Domain folders must not depend on `UI`/`Render` and must not contain Metal code.
- Naming: `...State`, `...Controller`, `...Resolver`, `...Runtime`, `...Math`. Avoid `Manager`/`Helper`/`Service`.
- Every new `.metal` file or resource directory must be registered under `resources:` in `Package.swift`.
- Because the repository is public: never commit tokens, credentials, or build artifacts.

## Pull requests

Please include:

- What changed and why.
- Screenshots or a short screen recording for rendering changes (before/after).
- Tests, where applicable.
- Any known limitations.

CI runs three jobs on every pull request:

- **Build & Test (SPM)** - `swift build` and `swift test`.
- **Test with shaders (Xcode, macOS)** - the same suite through `xcodebuild`. SwiftPM does not compile the package's `.metal` sources for the test bundle, so under `swift test` every Metal-backed test skips itself, including all the end-to-end offscreen frames. This job is the only one that actually runs them.
- **Test (Xcode, iOS Simulator)** - the same suite on iOS, which is where the UIKit half of the platform layer runs at all.

Please make sure they pass locally first. `swift test` alone is not enough for a rendering change; run the suite the way the Xcode jobs do:

```bash
mkdir -p .swiftpm/xcode/package.xcworkspace
cat > .swiftpm/xcode/package.xcworkspace/contents.xcworkspacedata <<'XML'
<?xml version="1.0" encoding="UTF-8"?>
<Workspace version = "1.0">
   <FileRef location = "self:"></FileRef>
</Workspace>
XML
IMMERSIVE_MAP_REQUIRE_METAL=1 TEST_RUNNER_IMMERSIVE_MAP_REQUIRE_METAL=1 \
  xcodebuild test -workspace .swiftpm/xcode/package.xcworkspace -scheme ImmersiveMap \
  -destination 'platform=macOS'
```

(Opening `Package.swift` in Xcode writes that workspace for you; it is gitignored, so a fresh clone has to produce it.)

End-to-end rendering tests build on `OffscreenFrameHarness` (`Tests/ImmersiveMapTests/Support/`): it stands up a real `RenderFrameEngine` drawing into a texture on a scripted clock and hands the frame back as pixels. Assert on properties of the picture (a corner is unpainted, N pixels carry a colour, the frame got darker), not on a stored reference image: those differ between GPU families and would have to be regenerated on every shader tweak.

`IMMERSIVE_MAP_REQUIRE_METAL=1` (set above and by both Xcode jobs) turns "this build cannot run Metal code" from a skip into a failure. A GPU suite that skips its way to green reports health it never checked. Reading a rendered frame back on the CPU additionally needs a unified-memory GPU, which the iOS Simulator does not have, so the offscreen tests still skip there even under the requirement and belong to the macOS run.

Claude reviews every pull request pushed to a branch in this repository and posts what it finds as inline comments, so a red "Claude review" check means the findings on the diff need an answer, either a fix or a follow-up push. The check is advisory: it does not gate the merge, and an unfinished review holds nothing up. `Build & Test (SPM)` is the only required check. A draft is reviewed once it is marked ready for review. A pull request from a fork gets no repository secrets, so the review is skipped there and a maintainer reads the branch by hand.

## Reporting bugs and asking questions

Use the GitHub issue templates for bug reports and feature requests - the issue tracker is for actionable work.

For questions about how to do something, or anything open-ended, use [Discussions](https://github.com/artembobkin/ImmersiveMap/discussions) - the [Q&A](https://github.com/artembobkin/ImmersiveMap/discussions/categories/q-a) category is the right place to start.

For security issues, report privately through [Security Advisories](https://github.com/artembobkin/ImmersiveMap/security/advisories/new) rather than opening a public issue. See [SECURITY.md](SECURITY.md).
