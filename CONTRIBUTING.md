# Contributing to ImmersiveMap

Thanks for your interest in contributing. ImmersiveMap is maintained as a single-maintainer project. Documentation, examples, tests, bug reports and small focused fixes are the most welcome contributions.

## Development setup

Clone the repository and build the package:

```bash
swift build
swift test
```

To run the map in a host app, open `ImmersiveMap.xcworkspace` and pick one of the schemes in `Examples/`. They reference the package locally, so unpublished changes run immediately.

`swift test` cannot compile the package's `.metal` sources, so every Metal-backed test skips itself there. A rendering change has to be run through Xcode:

```bash
xcodebuild test -workspace .swiftpm/xcode/package.xcworkspace -scheme ImmersiveMap \
  -destination 'platform=macOS'
```

## Conventions

- Every hand-written `.swift`, `.metal`, `.h` file starts with the license header:
  ```text
  // Copyright (c) 2025-2026 ImmersiveMap contributors.
  // SPDX-License-Identifier: MIT
  ```
- Dependencies point inward: `UI` → `Render` → domain folders → `Utils`.
- Every new `.metal` file or resource directory is registered under `resources:` in `Package.swift`.
- The repository is public: never commit tokens, credentials, or build artifacts.

## Pull requests

Say what changed and why, add tests where applicable, and attach a before/after screenshot or clip for a rendering change. CI runs the suite three ways: SPM, Xcode on macOS (the only job that runs the Metal tests), and Xcode on the iOS Simulator. Please check they pass locally first.

## Bugs and questions

Bug reports and feature requests go to [Issues](https://github.com/artembobkin/ImmersiveMap/issues), open-ended questions to [Discussions](https://github.com/artembobkin/ImmersiveMap/discussions). Report security issues privately through [Security Advisories](https://github.com/artembobkin/ImmersiveMap/security/advisories/new); see [SECURITY.md](SECURITY.md).
