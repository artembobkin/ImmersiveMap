# Changelog

All notable changes to ImmersiveMap will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project aims to follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html)
once the public API stabilizes.

## [Unreleased]

### Added

- `buildingExtrusionMode` modifier on `ImmersiveMapView` (and `StyleSettings.buildingExtrusionMode`): flat-mode extruded buildings can now render fully opaque with `.solid`, in addition to the default `.translucent` blending. Switching the mode (or `buildingExtrusionAlpha`) applies live, without recreating the renderer.

### Fixed

- Flickering light seams on extruded buildings: thin background-colored lines along facade junctions that shimmered with camera movement. Buildings are now always drawn opaque with plain depth testing - solid mode directly in the world pass, translucent mode into an offscreen building image that is composited over the map with `buildingExtrusionAlpha` - replacing the single-sample "winner ID" discard that clashed with MSAA. Translucency is now uniform across the whole building silhouette, buildings correctly occlude each other, and building geometry is rendered once per frame instead of twice (per-feature building color alpha is no longer factored in).

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
