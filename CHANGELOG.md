# Changelog

All notable changes to ImmersiveMap will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project aims to follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html)
once the public API stabilizes.

## [Unreleased]

### Added

- `ImmersiveMapTourVideoRecorder`: exports a camera tour to a QuickTime video file. Attach it with `.tourVideoRecorder(_:)` on `ImmersiveMapView` and call `export(shots:establish:configuration:to:)` with the same `ImmersiveMapCameraTourShot` list a live tour uses. The tour is rendered offline into a second, headless render engine at an exact fixed timestep: every frame waits for its tiles (with a configurable timeout), a pre-roll settles label and avatar fades before the first frame, and the on-screen map stays interactive throughout. Avatar markers render from a detached copy of the avatar state taken at export start (renderer snapshots are consumed destructively, so two engines cannot share one controller), and SwiftUI markers are rasterized once and composited onto each frame at their projected positions with the live overlay's anchor and horizon-fade semantics; both can be excluded via `includesAvatars` / `includesMarkers`, and `markerScale` controls marker rasterization density. Output defaults to HEVC 1920×1080 at 60 fps in `.mov` with BT.709 tagging; codec (`.hevc`/`.h264`), resolution, frame rate, and bit rate are configurable via `ImmersiveMapVideoExportConfiguration`. Progress is reported through `onProgress`, `cancel()` deletes the partial file. The attribution badge is host-view chrome and is not part of the exported frames. See `Documentation/docs/tour-video-export.md`.

### Fixed

- Attribution now credits the data source instead of the engine. The badge previously showed "Immersive map, © 2025-2026 ImmersiveMap contributors" over OpenStreetMap data, which satisfies neither ODbL nor the OpenMapTiles and Mapbox terms. Attribution is now a property of the tile provider (`ImmersiveMapTileProvider.attribution`): the built-in tiles credit OpenStreetMap, OpenFreeMap and OpenMapTiles, `MapboxTileProvider` credits Mapbox and OpenStreetMap, and a provider that declares no attribution renders no badge at all instead of borrowing someone else's name.

### Changed

- `ImmersiveMapSettings.AttributionSettings` no longer carries `title`, `copyright` and `linkURL`. It keeps `isVisible` plus an optional `attributionOverride`, and the resolved text comes from the active tile provider unless the app overrides it. `VectorTileProvider` gained an `attribution` parameter (`.none` by default, with `.openStreetMap` provided for plain OSM sources). Switching tile providers now updates the badge live.
- README documents where the default tiles come from (an OpenMapTiles-schema planet assembled from OpenFreeMap data, i.e. OpenStreetMap data under ODbL), how to point the engine at your own MVT source, and how attribution is resolved. Status wording that described the package as unfinished was dropped in favour of a feature list.

## [0.4.1] - 2026-07-30

### Changed

- The macOS example app (`ImmersiveMapMac`) now ships the full demo scene: a looping cinematic tour (globe, tilted pass through the globe-to-flat morph, Tokyo streets, Dubai, back to orbit) built on `ImmersiveMapCameraTourController`, SwiftUI city-card markers, avatar markers with badges, and an enlarged GPU-ready tile cache via `.tileSettings(memoryCacheSizeInBytes:)`. Start the tour with the Cinematic Tour button or R, stop with R, Esc, or any map gesture.

### Fixed

- Avatar markers now project through the same shared projector as tiles and SwiftUI markers (`GeoScreenProjectionMath`): the unfurl-wave morph and the soft per-point horizon. Previously avatars used a plain sphere-to-plane lerp with a stale horizon threshold, so mid-morph at high tilt a far-away avatar (Moscow with the camera over Dubai) drifted across the screen, floated above the horizon and popped in and out while zooming. The duplicated projection math in `AvatarSelectionProjector` is gone.
- Markers far behind the globe horizon no longer flash across the viewport at the tail of the globe-to-flat morph. The unfurl wave carries such a point from the far side of the sphere to its flat position far off-screen, and for a few frames the trajectory crossed the visible area over empty ocean (tiles never render that far coverage mid-flight). During the morph a marker now stays hidden unless its sphere position is within the spherical horizon plus a margin for what the unfurl legitimately brings into view.

## [0.4.0] - 2026-07-30

### Added

- `ImmersiveMapCameraTourController`: runs the camera through a sequence of `ImmersiveMapCameraTourShot`s (position, flight options, hold time), chaining flights back to back. Supports an optional establishing jump, looping, a finish callback, and stops automatically when the user starts a gesture (without occupying the public `onUserInteractionBegan` callback). Useful for cinematic fly-throughs, demo reels, and onboarding tours.
- Declarative SwiftUI markers: `.markers(items, coordinate:anchor:content:)` on `ImmersiveMapView` anchors arbitrary SwiftUI views to geographic coordinates. Markers are repositioned every rendered frame (flat, globe, and through the morph, riding the unfurl wave), fade behind the globe horizon, and stay fully interactive: buttons and gestures inside marker content work while the map keeps gestures elsewhere. See `Documentation/docs/markers.md`.

### Fixed

- Toggling `enableCameraUIControls` no longer tears down and recreates the whole platform map view: the SwiftUI body keeps one stable view identity, so the renderer, tile caches and controller attachments survive UI chrome toggles.
- A dismantled host view no longer detaches camera, avatars and selection controllers from a newer host view that reuses them (SwiftUI creates the replacement representable before dismantling the old one). Detach is now ownership-checked, which unbreaks camera commands, including `ImmersiveMapCameraTourController` tours, across view recreation.
- Renderer recreation now completes an active camera flight with `success == false` instead of silently swallowing its completion, so chained `fly` calls cannot hang on a never-resumed continuation.
- SwiftUI markers on the far side of the globe no longer leak through the horizon mid-morph. The horizon threshold now relaxes per point with the unfurl-wave local phase instead of the global transition: a still-spherical point keeps the strict spherical test. Tiles hide this leak behind the depth test, the view overlay has none.
- The globe polar caps no longer flicker or break into gray triangle fans. The cap smears a single edge-texel row of the boundary tiles, but sampled it with automatic mip selection: near the pole the uv derivatives explode (meridians converge, the longitude wrap adds a derivative discontinuity), so the sampler dove into deep atlas mips where texels average unrelated tiles, and every atlas repack reshuffled the colors. The cap now samples the base mip explicitly and feathers toward the pole color, so narrow coastal features at the boundary row (like Ross Sea water) no longer smear radial needles across the cap.

### Changed

- `CameraFlightAltitudeStyle.overviewFirst` now flies a true van Wijk & Nuij overview arc: the camera climbs out (up to a full-globe view for intercontinental flights, proportionally lower for short hops), covers the distance at the apex, then dives to the target. Pan speed is coupled to altitude, so the camera crawls near the ground instead of streaking across street-level tiles. Previously the style merely delayed a direct zoom interpolation, so long flights panned the whole route at the start zoom.
- Renamed the avatar tap API: the `onMarkerTap` modifier is now `onAvatarTap`, and `ImmersiveMapMarkerTapEvent` is now `ImmersiveMapAvatarTapEvent` (same fields). No compatibility shims. The term "marker" now belongs to the SwiftUI marker overlay API introduced in this release. The avatars guide moved from `Documentation/docs/markers.md` to `Documentation/docs/avatars.md`.

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
