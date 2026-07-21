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
3. To run the map in a host app, open `ImmersiveMap.xcworkspace` and select the `ImmersiveMapIOS` (iOS) or `ImmersiveMapMac` (native macOS, AppKit) scheme. Both host apps reference the package locally, so unpublished changes run immediately.

Native macOS build from the CLI:

```bash
xcodebuild -workspace ImmersiveMap.xcworkspace -scheme ImmersiveMapMac \
  -destination 'platform=macOS' build
```

## Project conventions

- Every hand-written `.swift`, `.metal`, `.h`, `.proto` file starts with the license header:
  ```text
  // Copyright (c) 2025-2026 ImmersiveMap contributors.
  // SPDX-License-Identifier: MIT
  ```
  Do not add the header to generated files.
- Dependencies point inward: `UI` → `Render` → domain folders → `Utils`. Domain folders must not depend on `UI`/`Render` and must not contain Metal code.
- Most top-level folders contain a `README.md` with boundary rules - read it before adding files there.
- Naming: `...State`, `...Controller`, `...Resolver`, `...Runtime`, `...Math`. Avoid `Manager`/`Helper`/`Service`.
- Every new `.metal` file or resource directory must be registered under `resources:` in `Package.swift`.
- Because the repository is public: never commit tokens, credentials, or build artifacts.

## Pull requests

Please include:

- What changed and why.
- Screenshots or a short screen recording for rendering changes (before/after).
- Tests, where applicable.
- Any known limitations.

CI runs `swift build` and `swift test` on every pull request. Please make sure both pass locally first.

## Reporting bugs and asking questions

Use the GitHub issue templates for bug reports and feature requests - the issue tracker is for actionable work.

For questions about how to do something, or anything open-ended, use [Discussions](https://github.com/artembobkin/ImmersiveMap/discussions) - the [Q&A](https://github.com/artembobkin/ImmersiveMap/discussions/categories/q-a) category is the right place to start.

For security issues, report privately through [Security Advisories](https://github.com/artembobkin/ImmersiveMap/security/advisories/new) rather than opening a public issue. See [SECURITY.md](SECURITY.md).
