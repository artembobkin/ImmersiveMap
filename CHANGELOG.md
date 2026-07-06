# Changelog

All notable changes to ImmersiveMap will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project aims to follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html)
once the public API stabilizes.

## [Unreleased]

## [0.1.0-alpha.1]

Initial public alpha.

### Added

- SwiftUI `ImmersiveMapView` with builder-style modifiers (`.camera`, `.tileProvider`, `.mapStyle`, `.labelSettings`, …).
- Native Metal rendering pipeline (on-demand frame loop, multi-pass render graph).
- Mapbox vector tile provider (`MapboxTileProvider` / `MapboxMapStyle`).
- OpenStreetMap / Shortbread provider (`OpenStreetMapTileProvider` / `OpenStreetMapMapStyle`).
- Custom tile providers via `ImmersiveMapTileProvider` / `VectorTileProvider`.
- Globe and flat presentation with continuous morphing between sphere and plane.
- Terrain rendering.
- Labels, starfield, and avatar / live markers.
- Disk (raw + prepared) and in-memory tile caches.

### Known Limitations

- The public API is unstable and may change.
- Documentation is incomplete.
- Not production-ready yet.
- Not a drop-in replacement for Mapbox, MapLibre, or MapKit.

[Unreleased]: https://github.com/artembobkin/ImmersiveMap/compare/0.1.0-alpha.1...HEAD
[0.1.0-alpha.1]: https://github.com/artembobkin/ImmersiveMap/releases/tag/0.1.0-alpha.1
