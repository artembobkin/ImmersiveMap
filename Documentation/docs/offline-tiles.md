# Offline regions

Download a geographic region once and the map renders it with no network connection. Two pieces, deliberately decoupled:

- `ImmersiveMapOfflineController` downloads and manages regions. It is standalone: create it with a tile provider anywhere in the app (a settings screen, a background task), no map view involved.
- The map serves downloaded tiles automatically. Both sides derive the same on-disk store location from the tile provider's source identity, so a map configured with the same provider finds the regions without any wiring.

```swift
let offline = ImmersiveMapOfflineController(tileProvider: ImmersiveMapTilesProvider())

try offline.download(ImmersiveMapOfflineRegion(
    id: "london",
    southWest: GeoCoordinate(latitude: 51.42, longitude: -0.25),
    northEast: GeoCoordinate(latitude: 51.60, longitude: 0.05),
    zoomLevels: 0...14))
```

A region is a rectangle plus a zoom span: every tile overlapping the rectangle at every zoom in the range, edges included. Start the range at 0: the low levels cost a handful of tiles per zoom and keep the map usable while zooming out over the downloaded area. The cost of a region is dominated by its top zoom level. Zoom levels above the provider's `maximumTileZoomLevel` are clamped away; the renderer never requests them (it overzooms by stretching the deepest tiles it has). `ImmersiveMapOfflineRegion.tileCount` estimates the size before downloading, and `download(_:)` throws `ImmersiveMapOfflineError.regionTooLarge` past the controller's `maximumTileCountPerDownload` (50 000 by default) rather than quietly mirroring half the planet.

## Watching progress

`regions` and the `onRegionsChanged` callback live on the main actor and carry `ImmersiveMapOfflineRegionStatus` values: phase (`downloading`, `complete`, `incomplete`), tile counts, bytes on disk, and a `fractionCompleted` ready for a `ProgressView`.

```swift
offline.onRegionsChanged = {
    regionStatuses = offline.regions
}
```

`cancelDownload(regionID:)` stops between tiles and keeps what landed. Downloading the same id again fetches only what is missing, which is also how a cancelled, interrupted, or partially failed region resumes. Tiles the source reports as empty (ocean at high zoom) are recorded as known empty and count toward completion. Authorization failures abort the run instead of failing tile by tile.

## Serving

`ImmersiveMapSettings.TileSettings.OfflineSettings.Mode` decides how the map uses the store, via `.offlineTileMode(_:)`:

```swift
ImmersiveMapView()
    .offlineTileMode(.offlineOnly)
```

- `.automatic` (the default): tiles come from the network; any failed request (offline, server error, missing authorization) is answered from the downloaded regions instead. Nothing to configure, and with no connection the fallback is immediate.
- `.offlineOnly`: the network is never touched, including the TileJSON discovery request. Only downloaded regions and the local caches render; tiles outside every region stay empty. This is the deterministic mode for airplane-mode UX and for verifying what a download actually covers.
- `.disabled`: downloaded regions are ignored.

Serving goes through the regular pipeline, so offline tiles get the same parsing, styling, and prepared-tile caching as network tiles.

## Storage and lifecycle

Regions live under Application Support (unlike the [tile caches](tile-cache.md), which live in Caches and are the system's to evict): an explicit download stays until the app removes it. `removeRegion(regionID:)` deletes a region but keeps tiles shared with an overlapping region; `removeAllRegions()` clears everything for that tile source. The store is namespaced by the provider's source identity, the same identity that keys the prepared-tile cache, so changing the provider configuration (a different URL, a different `configurationFingerprint`) makes existing downloads invisible to it: download and serve with the same provider configuration.

Running example: [`Examples/macOS/ImmersiveMapOfflineMac`](../../Examples/macOS/ImmersiveMapOfflineMac) downloads preset city regions or a box around the current map center, shows live progress with cancel/resume/delete, and has the mode switch: download a city, flip to "Offline only", and pan around it.
