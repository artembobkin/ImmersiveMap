# Changelog

All notable changes to ImmersiveMap will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project aims to follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html)
once the public API stabilizes.

## [Unreleased]

### Added

- Building depth cues and shadow polish. Three related changes make building masses read as separate volumes without reintroducing an analytic lighting model. (1) Two subtle tonal terms in the building shader separate faces that flat shading merged into one mass: a hemisphere term keeps roofs at the base color while walls darken slightly (the sun-facing side a touch lighter than the far side, so the edge between two walls is always visible), and a vertical gradient darkens walls toward the ground — the classic ambient-occlusion cue that grounds buildings. Both multiply the base color, fade out with the shadow factor (a shadowed face keeps the pure shadow color instead of stacking darkening on darkening), and leave the shading contract — flat color plus shadows — unchanged. (2) Geometrically self-shadowed walls now darken to only 35% of the shadow strength instead of the full cast-shadow darkness: a wall turned away from the sun is lit by the sky, not occluded like a ground spot under a roof. (3) Shadow edges no longer crawl along facades during fast camera movement: the cascade windows are anchored at the camera's look-at point, so panning drives buildings through them, and the previously hard sharp-to-coarse texel switch at a window boundary swept across walls as a visible seam — cascade transitions now cross-fade over an eight-texel band.

- Attribution badge customization. `ImmersiveMapSettings.AttributionSettings` gained size presets (`.small` / `.regular` / `.large` — fonts, paddings, corner radius and the maximum badge width scale coherently), six safe-area-aware positions (four corners plus `.bottomCenter` / `.topCenter`; leading/trailing now follow the layout direction, so RTL apps get the mirrored corner), and an optional `textColor` (RGBA `SIMD4<Float>`, the copyright line renders at 76% of the given alpha). The partial modifier `.attributionSettings(isVisible:size:position:textColor:isProvidedExternally:)` restyles the badge without replacing the whole settings value, and everything applies live without recreating the renderer. A map that starts with a hidden or empty badge logs a one-time-per-process console warning (`os.Logger`, subsystem `ImmersiveMap`, category `Attribution`) reminding that map data licenses require visible attribution near the map; an app that shows the credit itself declares that with the new `.attributionProvidedExternally()` modifier, which silences the warning and changes nothing else.

- Map view reuse (on by default). When a SwiftUI screen with an `ImmersiveMapView` goes away, its platform view — renderer, GPU tile cache, atlas pages, Metal layer, gesture wiring — is parked for a short time (30 s by default) instead of being destroyed, and the next `ImmersiveMapView` adopts it warm, so switching between map screens skips the first-frame rebuild entirely. New settings are reconciled on adoption through the regular settings-apply planner, so adopting with a different configuration is safe (a changed tile provider still recreates the renderer, now cheaply on top of the shared resources). An adopted view keeps its previous camera unless the new view provides an explicit camera position or an attached camera controller. The parked view is released on time-to-live expiry and on memory warnings. Note that SwiftUI creates the incoming screen's view before dismantling the outgoing one, so the first transition between two map screens still builds fresh; every later transition adopts. Opt out with `.viewReuse(false)` or tune via `ImmersiveMapSettings.ViewReuseSettings`. Together with disk-first tile loading and the shared render resources below, this completes the "warm caches, cold view" work: returning to a map screen is now instant.

- Process-wide shared render resources. Immutable GPU state is now created once per process and reused by every map view and every settings-driven renderer recreation: the Metal shader library, all ~26 render and compute pipeline states, depth-stencil states, the MSDF text atlases with their glyph tables (previously two PNG decodes + GPU uploads and two JSON metric decodes per view), the POI sprite atlas (SF Symbol rasterization), the avatar marker SDF, and the procedural sphere and polar-cap geometry. Creating a second `ImmersiveMapView` — or changing settings that rebuild the renderer — no longer pays any of that cost; per view remain only the command queue, dynamic buffers, tile/label caches and the small config-baked pieces (starfield colors and star buffer, polar-cap palette, avatar style values). This is the second half of the "warm caches, cold view" fix started by disk-first tile loading below.

- Disk-first tile loading. A tile with a prepared entry on disk now renders immediately from that entry while the network request runs in the background as pure revalidation: a matching ETag confirms the content already on screen (no re-parse, no re-upload), a changed ETag re-parses the fresh bytes and swaps the tile in place, and a failed download simply leaves the served content up instead of arming retry backoff. Previously the loader always waited for the network stage before consulting the prepared cache — with `Cache-Control: must-revalidate` tiles, that put a network round-trip in front of every tile even when the disk held a byte-identical parsed copy, which is exactly the "warm caches, cold view" delay on app launch and on every newly created map view. The mechanics are guarded against the failure modes optimistic rendering invites: a served tile stays **requestable** in the render store until some load confirms or replaces it, so a revalidation lost to `cancelAll` (memory warning) or a parse failure of fresh bytes retries on later frames under the normal backoff instead of pinning stale content for the session; the network slot is released when the download completes, not when the (serialized) disk decode does, so cold tiles never queue behind warm ones; prepared-entry decoding moved off the shared serial cache queue so concurrent loads decode in parallel; and a parse failure no longer deletes the disk entry that is currently displayed. Entries saved from responses without an ETag cannot be revalidated and are re-parsed as before.

- A lower zoom bound: `ImmersiveMapSettings.CameraSettings.minimumZoom` and the `.zoomRange(minimum:maximum:)` modifier. The camera previously clamped only from above, with the bottom pinned to zoom 0. Both bounds are now enforced in one place, so gestures, zoom commands and camera flights all obey them — including the overview arc of a long `fly(to:)`, which used to climb to a globe view regardless. A minimum above the globe-to-flat transition keeps the map flat for good; an omitted bound is left as configured, and an inverted range collapses to `maximumZoom` rather than trapping the camera.

- Directional shadows on the flat map: extruded buildings and 3D scene models cast real-time shadows onto the ground, onto neighboring buildings and onto each other, via three cascaded shadow maps rendered into one 3:1 depth atlas in a single depth-only pass. All cascades are fitted to **pose-invariant discs** around the camera's look-at point with radii in multiples of the camera distance (1 / 3 / coverage), so tilting or rotating the camera changes nothing about shadow sharpness or coverage. Cascades are sampled with Castaño's 3x3 tent PCF (four hardware-bilinear compares with computed weights): a crisp ~2-texel edge that is orientation-independent — no staircase on shadow boundaries diagonal to the shadow grid (the far edge cast by a roof almost always is), about a meter of transition at street zooms in the near cascade; the middle cascade (3 camera distances) keeps meter-scale texels where most visible shadows land at a tilted camera, and the far cascade (16 by default) shares the filter at its coarser texel inside the fade zone. Every comparison uses the receiver-plane depth predicted from screen-space derivatives (Isidoro receiver-plane bias), so flat roofs and the ground need almost no constant bias — no acne striping, and the small per-frame bias (derived from the actual texel footprint) keeps shadows attached to building bases. The texel grid is stabilized against camera motion: window sizes quantize in √2 steps (capping density overshoot at 1.41× while integer-zoom re-normalization still lands on exact ×2) and window centers snap to whole texels in pan-anchored coordinates (computed in Double — at high zoom the pan offset is world-sized and Float ULP exceeds a texel), so shadow edges do not crawl during movement and stay glued to the map across integer-zoom re-normalization. Shadows are on by default and tunable through `.shadowSettings(_:)` / `.shadows(isEnabled:)` (`ImmersiveMapSettings.ShadowSettings`: strength, per-cascade map resolution, far coverage in camera distances); the shared light direction that drives both shading and shadows moved into settings as `.sceneLight(direction:)` (default unchanged: light from the south-west, shadows fall north-east). All shadow settings apply live without recreating the renderer. Known v1 limits: the ground shadow under a translucent building is not attenuated by the composite alpha; buildings clipped at tile boundaries have no boundary walls, so edge-on light can leak slightly (softened by two-sided caster rasterization); the texel grid re-anchors once when crossing the antimeridian and when a quantized window size doubles (rare, zoom-dependent); sharpness steps down once at the near-cascade border (~2 camera distances out); the coarse horizon backdrop receives no shadows by design and hides the coverage edge in the horizon fog.

- API keys: the `.apiKey(_:)` view modifier (backed by `ImmersiveMapSettings.apiKey(_:)`) authorizes tile requests against the hosted service. The key travels as an `Authorization: Bearer` header rather than a query parameter, so byte-identical tiles share one CDN cache entry across customers. It applies to whichever provider is configured and may be written before or after `tileProvider`; `ImmersiveMapTilesProvider(apiKey:)` now sends its key the same way (previously `?key=`).

- 3D scene models: `ImmersiveMapSceneModelsController` plus the `.sceneModels(_:)` modifier anchor USDZ/OBJ models at geographic coordinates. Models render inside the world pass with depth, MSAA, and the building light — in flat mode, on the globe, and through the morph between them: the anchor rides the same unfurl wave as the surface, the tangent frame tilts from the sphere normal to flat up, and the meter scale blends from true globe scale to the Web-Mercator `1/cos(latitude)` convention, so a model stays glued to the map at any zoom. Descriptors carry altitude in meters, heading/pitch/roll, a meter `scale` multiplier, and `fitDiameterMeters` to size arbitrary assets; `move` animates along a great circle with distance-derived duration, `setOrientation`/`setScale`/`setAltitude` ease with shortest-arc quaternion interpolation. Assets load asynchronously via Model I/O (`MDLAsset` → `MTKMesh`, no new package dependencies), deduplicate by source URL, retry with cooldown, and live in a memory-pressure-aware LRU cache; rendering stays on-demand throughout. Models are excluded from tour video export and not tappable in this version. See `Documentation/docs/scene-models.md`.

- `ImmersiveMapTourVideoRecorder`: exports a camera tour to a QuickTime video file. Attach it with `.tourVideoRecorder(_:)` on `ImmersiveMapView` and call `export(shots:establish:configuration:to:)` with the same `ImmersiveMapCameraTourShot` list a live tour uses. The tour is rendered offline into a second, headless render engine at an exact fixed timestep: every frame waits for its tiles (with a configurable timeout), a pre-roll settles label and avatar fades before the first frame, and the on-screen map stays interactive throughout. Avatar markers render from a detached copy of the avatar state taken at export start (renderer snapshots are consumed destructively, so two engines cannot share one controller), and SwiftUI markers are rasterized once and composited onto each frame at their projected positions with the live overlay's anchor and horizon-fade semantics; both can be excluded via `includesAvatars` / `includesMarkers`, and `markerScale` controls marker rasterization density. Output defaults to HEVC 1920×1080 at 60 fps in `.mov` with BT.709 tagging; codec (`.hevc`/`.h264`), resolution, frame rate, and bit rate are configurable via `ImmersiveMapVideoExportConfiguration`. Progress is reported through `onProgress`, `cancel()` deletes the partial file. The attribution badge is host-view chrome and is not part of the exported frames. See `Documentation/docs/tour-video-export.md`.

### Fixed

- Attribution now credits the data source instead of the engine. The badge previously showed "Immersive map, © 2025-2026 ImmersiveMap contributors" over OpenStreetMap data, which satisfies neither ODbL nor the OpenMapTiles and Mapbox terms. Attribution is now a property of the tile provider (`ImmersiveMapTileProvider.attribution`): the built-in tiles credit OpenStreetMap, OpenFreeMap and OpenMapTiles, `MapboxTileProvider` credits Mapbox and OpenStreetMap, and a provider that declares no attribution renders no badge at all instead of borrowing someone else's name.

### Changed

- The default attribution text is now the single line "© OpenStreetMap © OpenMapTiles" (previously two lines: "© OpenStreetMap contributors" + "OpenFreeMap © OpenMapTiles"); the link still leads to the full license story at openstreetmap.org/copyright, and OpenFreeMap asks for no credit of its own. The `.openStreetMap` preset is one-line as well ("© OpenStreetMap contributors"). An `ImmersiveMapAttribution` with an empty `copyright` renders a one-line badge — no empty second row, no spacing.

- The camera control zones in the bottom corners — drag on the leading side to tilt, on the trailing side to zoom — are now **off by default** and opt in through `.cameraControlZones(pitch:zoom:)`. They were always on, invisible, and captured drags that would otherwise pan the map, so the first encounter reads as a panning bug rather than a feature. Pointer scroll zoom (trackpad, mouse wheel) moved out of the zoom zone into its own `ScrollZoomGesture` and keeps working either way.

- Building and scene-model shading dropped its analytic lighting model (previously Phong, briefly a soft lambert): faces keep their flat base color and darken **only** where the shadow map says the static sun is occluded. Walls turned away from the sun are shadowed by a geometric self-shadow test (a face with N·L ≤ 0 is in shadow by definition — the map is neither needed nor trusted there, which also kills acne striping on walls nearly parallel to the sun rays), everything else darkens per the shadow map — one consistent shadow system, and neighboring buildings now visibly cast onto walls. `.sceneLight(direction:)` still defines the sun; it now drives shadow casting alone.
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
