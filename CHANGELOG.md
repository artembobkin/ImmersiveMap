# Changelog

All notable changes to ImmersiveMap will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project aims to follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html)
once the public API stabilizes.

## [Unreleased]

## [0.2.0] - 2026-07-14

### Added

- `onMarkerTap` modifier on `ImmersiveMapView`: a native SwiftUI way to receive avatar marker taps. The `ImmersiveMapMarkerTapEvent` carries the tapped marker snapshot and screen point, and fires on every tap independent of the selection controller.
- Cursor-anchored zoom: scroll wheel, trackpad pinch, and touch pinch keep the world point under the cursor / gesture centroid fixed while zooming. Anchoring strength is configurable via `CameraSettings.zoomAnchorFactor`.
- Double-tap (iOS) / double-click (macOS) zoom that flies one zoom level toward the tapped point.
- Merged avatar markers: `ImmersiveMapAvatarsController.merge(ids:mergedID:imageCycleInterval:)` collapses markers into one marker at the live spherical average of its members, cycling the avatar image between members on a configurable timer. A round count badge shows how many avatars are merged; `unmerge(mergedID:)` restores the members.
- `AvatarCountBadge` on `AvatarMarker` for showing a count bubble on any marker.

### Changed

- ImmersiveMap Tiles are now served over the `tiles.immersivemap.dev` Cloudflare CDN. The tile loader discovers a versioned, immutable tile URL template from the service's TileJSON, so tiles are fetched over a long-lived edge-cached path (falling back to the base path until/if discovery resolves).

## [0.1.1] - 2026-07-11

Initial public alpha.

### Added

- SwiftUI `ImmersiveMapView` with builder-style modifiers (`.camera`, `.tileProvider`, `.mapStyle`, `.labelSettings`, …).
- Native Metal rendering pipeline (on-demand frame loop, multi-pass render graph).
- Built-in ImmersiveMap tile provider that renders out of the box, no token required.
- Mapbox vector tile provider (`MapboxTileProvider` / `MapboxMapStyle`).
- OpenStreetMap / Shortbread provider (`OpenStreetMapTileProvider` / `OpenStreetMapMapStyle`).
- Custom tile providers via `ImmersiveMapTileProvider` / `VectorTileProvider`.
- Globe and flat presentation with continuous morphing between sphere and plane.
- Labels, starfield, and avatar / live markers.
- Disk (raw + prepared) and in-memory tile caches.

### Known Limitations

- The public API is unstable and may change.
- Documentation is incomplete.
- Not production-ready yet.
- Not a drop-in replacement for Mapbox, MapLibre, or MapKit.

[Unreleased]: https://github.com/artembobkin/ImmersiveMap/compare/0.2.0...HEAD
[0.2.0]: https://github.com/artembobkin/ImmersiveMap/compare/0.1.1...0.2.0
[0.1.1]: https://github.com/artembobkin/ImmersiveMap/releases/tag/0.1.1
