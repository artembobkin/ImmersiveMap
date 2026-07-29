# Changelog

All notable changes to ImmersiveMap will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project aims to follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html)
once the public API stabilizes.

## [Unreleased]

### Added

- Declarative SwiftUI markers: `.markers(items, coordinate:anchor:content:)` on `ImmersiveMapView` anchors arbitrary SwiftUI views to geographic coordinates. Markers are repositioned every rendered frame (flat, globe, and through the morph, riding the unfurl wave), fade behind the globe horizon, and stay fully interactive: buttons and gestures inside marker content work while the map keeps gestures elsewhere. See `Documentation/docs/markers.md`.

### Changed

- `CameraFlightAltitudeStyle.overviewFirst` now flies a true van Wijk & Nuij overview arc: the camera climbs out (up to a full-globe view for intercontinental flights, proportionally lower for short hops), covers the distance at the apex, then dives to the target. Pan speed is coupled to altitude, so the camera crawls near the ground instead of streaking across street-level tiles. Previously the style merely delayed a direct zoom interpolation, so long flights panned the whole route at the start zoom.
- Renamed the avatar tap API: the `onMarkerTap` modifier is now `onAvatarTap`, and `ImmersiveMapMarkerTapEvent` is now `ImmersiveMapAvatarTapEvent` (same fields). No compatibility shims. The term "marker" is freed up for the upcoming SwiftUI marker overlay API. The avatars guide moved from `Documentation/docs/markers.md` to `Documentation/docs/avatars.md`.

## [0.3.0] - 2026-07-24

### Removed

- OpenStreetMap / Shortbread provider (`OpenStreetMapTileProvider` / `OpenStreetMapMapStyle`). The package now ships two providers: the built-in ImmersiveMap tiles and Mapbox. Custom MVT sources remain supported via `VectorTileProvider`.
- City night lights feature.

### Added

- `buildingExtrusionMode` modifier on `ImmersiveMapView` (and `StyleSettings.buildingExtrusionMode`): flat-mode extruded buildings can now render fully opaque with `.solid`, in addition to the default `.translucent` blending. `.solidAtHighZoom(startZoom:endZoom:)` blends translucent buildings into solid ones across a zoom range (default 17...18) as the camera zooms in. Switching the mode (or `buildingExtrusionAlpha`) applies live, without recreating the renderer.
- Reworked globe ↔ flat transition: the globe unrolls as a wave travelling from the view center outward, the morph geometry completes before the surface swap, and horizon culling relaxes continuously through the morph.
- Flat-mode horizon: the far coverage ring is filled with pinned backdrop-zoom tiles up to the horizon, with haze anchored to the vanishing line. The flat view distance now matches the globe side of the transition.
- Latitude-aware camera and tile LOD, and a mip-mapped tile atlas for steeply tilted views.
- POI visibility is derived from rank budgets instead of zoom ramps; iconless POI labels are gated by camera zoom; road labels are gated by clipped visible area and content density.
- `preparedDiskCompressionEnabled` in `.tileSettings(...)`: LZFSE compression of the prepared tile disk cache is now optional. Disabling it trades disk footprint for noticeably less CPU (and battery) while exploring uncached areas.
- Debug HUD: label collision boxes overlay and a total tiles counter.

### Changed

- The package now builds in Swift 6 language mode with strict concurrency.
- Tile loading is split into independent network and parsing stages: a network slot frees right after the download, and parsing runs in separate tasks bounded by the device's core count. Slow networks no longer starve parsing, and long parses no longer block new downloads.
- Default in-memory tile cache budget lowered from 512 to 256 MiB; evicted tiles reload cheaply from the prepared disk cache. The previous budget is still available via `.tileSettings(memoryCacheSizeInBytes:)`.

### Performance

- Globe atlas pages (hundreds of MiB of textures) are released after the map stays in flat presentation for a few seconds, instead of being retained until a memory warning.
- Empty tile geometry layers no longer allocate placeholder GPU buffers (a tile without bridges or tunnels used to allocate buffers for every road phase).
- MSDF text atlases load into private GPU storage via a staging blit, dropping their shadow CPU copies.
- Label rendering skips redundant Metal bindings (font atlas, styles, shifts), and label compute work is batched into two encoders per frame instead of a pair of encoders per road tile record, with frame constants bound once per pass.
- The flat far ring is handed fully to the z3 backdrop with a steeper distance LOD, and building extrusion resolution reuses precomputed footprint bounds and areas.

### Fixed

- Flickering light seams on extruded buildings: thin background-colored lines along facade junctions that shimmered with camera movement. Buildings are now always drawn opaque with plain depth testing - solid mode directly in the world pass, translucent mode into an offscreen building image that is composited over the map with `buildingExtrusionAlpha` - replacing the single-sample "winner ID" discard that clashed with MSAA. Translucency is now uniform across the whole building silhouette, buildings correctly occlude each other, and building geometry is rendered once per frame instead of twice (per-feature building color alpha is no longer factored in).
- Fog is applied to the morph surface at its morphed positions instead of the sphere's, removing fog popping during the globe ↔ flat transition.
- The flat horizon no longer jumps between zoom bands: the far plane is pushed out and horizon haze saturates before the coverage edge.
- Line-only boundary styles no longer fill their polygon features.
- Debug tile overlay watermarks stay flat and bounded at high tilt.

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

[0.3.0]: https://github.com/artembobkin/ImmersiveMap/compare/0.2.0...0.3.0
[0.2.0]: https://github.com/artembobkin/ImmersiveMap/compare/0.1.1...0.2.0
[0.1.1]: https://github.com/artembobkin/ImmersiveMap/releases/tag/0.1.1
