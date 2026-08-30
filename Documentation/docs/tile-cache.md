# Tile caches

A tile is expensive twice: once to download, once to parse and tessellate into GPU-ready geometry. ImmersiveMap caches at both points on disk, and keeps in memory only what the frame draws: panning back to where you were is a disk read, not a residency bet, and a second launch over the same area skips the network entirely.

Two disk layers, outermost first:

| Layer | Holds | Lives in |
|---|---|---|
| Raw HTTP cache | The `.mvt` bytes as fetched, conditionally revalidated against the server's ETag and `Cache-Control` | `URLCache` on disk |
| Prepared tile cache | Parsed and tessellated GPU-ready geometry, optionally LZFSE-compressed | A dedicated disk cache, 2 GiB by default |

A tile the frame demands is looked up in the prepared cache first, on its own concurrency: a hit is materialized straight into GPU buffers (through a DMA load on Metal 3 devices) and the network is never asked. Only a miss downloads, parses, and saves the result back. Freshness of prepared content comes from `preparedDiskTimeToLive` and from the cache identity below, not from a per-load server round-trip.

## What stays in memory

Exactly the working set: the tiles the current frame demands (the visible tiles, their fallback parents, the horizon backdrop and the shadow-caster strip) plus the world cover at z0-3, which stays resident so the globe and the horizon never blank. Everything else is released the moment the demanded set stops naming it. There is no byte budget and nothing to tune: the footprint follows the frame, not the camera's history. A memory warning cancels in-flight loads and drops the off-screen world cover; the map on screen stays intact.

Returning to a place the camera has left re-materializes its tiles from the prepared cache over a few frames; until they land, the slot draws the coarser parent tile.

Nothing has to be configured. The one knob worth knowing sizes the prepared cache:

```swift
ImmersiveMapView()
    .preparedTileDiskCacheSize(bytes: 4 * 1024 * 1024 * 1024)   // 4 GiB for a looped tour
```

## Cache settings

```swift
public struct CacheSettings: Equatable, Sendable {
    public var clearDiskCachesOnLaunch: Bool          // false
    public var urlCacheEnabled: Bool                  // true
    public var preparedTileCacheEnabled: Bool         // true
    public var preparedDiskCompressionEnabled: Bool   // true
    public var preparedDiskTimeToLive: TimeInterval   // 7 days
    public var preparedDiskCacheSizeInBytes: Int      // 2 GiB
    public var memoryCacheSizeInBytes: Int            // deprecated, ignored
}
```

| Field | Why you would change it |
|---|---|
| `preparedDiskCacheSizeInBytes` | The one worth tuning. Every revisited area returns through this cache, so the quota decides how much of the world stays a disk read away instead of a re-download and re-parse. Root-wide, shared by every prepared-tile namespace; the most recently initialized map makes its quota the active policy. |
| `preparedDiskTimeToLive` | The freshness lever for prepared content: a served tile is not revalidated against the server, it simply expires. Shorter for fast-moving data, longer for a basemap that rarely changes. |
| `preparedDiskCompressionEnabled` | Off writes larger files and burns less CPU (and battery) while exploring new areas. Both variants stay readable either way, so flipping it does not invalidate anything. |
| `preparedTileCacheEnabled` | Off re-parses from raw bytes on every load and downloads on every miss. Useful when iterating on a style, where prepared tiles would be stale by construction. |
| `urlCacheEnabled` | Off drops the `URLCache` entirely, so every download goes to the network in full. Response ETags are still read, and still key the prepared cache below. |
| `clearDiskCachesOnLaunch` | A development lever, not a product one. |
| `memoryCacheSizeInBytes` | Nothing any more: tiles stay in GPU memory only while a frame draws them. The field is deprecated, ignored, and left out of settings equality, so setting it does not even rebuild the renderer. |

## Cache identity

This is the part that bites. Prepared tiles carry the schema interpretation, the style's palette and the label language baked in, so a cache entry is only valid for the exact configuration that produced it. Identity comes from three places:

- The tile source identity: the base URL, the URL template and the request header names, plus `NetworkSettings.cacheIdentity`. It is what keeps two endpoints from reading each other's tiles; pointing the map elsewhere with `.tileURLTemplate` re-keys the caches on its own.
- `ImmersiveMapMapStyle.configurationFingerprint`, so a recolor does not draw from tiles prepared under the old palette, see [map styling](styling.md).
- `LabelLanguage.preparedTileCacheNamespaceKey`, so switching the [label language](labels.md) re-prepares rather than redraws.

`StyleSettings.preparedTileStyleRevision` is the manual override: bump it to invalidate every prepared tile regardless of the above.

## Network and coverage

```swift
public struct NetworkSettings: Equatable, Sendable {
    public var maxConcurrentFetches: Int
    public var pendingRequestQueueCapacity: Int
    public var tileBaseURL: URL
    public var tileJSONURL: URL?
    public var tileURLTemplate: String?               // "https://tiles.com/{x}/{y}/{z}?apiKey=xxx"
    public var tileRequestHeaders: [String: String]   // added to every tile request
    public var cacheIdentity: UInt64
}

public struct CoverageSettings: Equatable, Sendable {
    public var maximumZoomLevel: Int
}
```

Loading runs off the main thread in three stages with independent concurrency: the prepared-cache read, then the download (`maxConcurrentFetches` in flight, the rest in a dedup FIFO capped at `pendingRequestQueueCapacity`, with retry and backoff), then parsing. A disk hit never occupies a network slot, and requests for a tile already in flight join the existing one rather than starting a second.

Most apps never touch `NetworkSettings` directly: `.tileURLTemplate(_:headers:)` supplies the URL and the credentials. Setting the fields by hand is for cases the template cannot express.

`CoverageSettings.maximumZoomLevel` caps the zoom level actually requested from the source. Past it the engine keeps rendering the deepest tiles it has, scaled up, which is why a source that stops at z14 still draws at z18.

## Where the caches live

Both disk caches sit in the app's caches directory, so the system may evict them under storage pressure and they are not backed up. A [tour video export](tour-video-export.md) shares them with the live map, which is why exporting a tour the map has already played does not re-download anything.

## Limitations

- Returning to a place the camera has left shows the coarser parent for the few frames the disk read takes: residency is not kept as a hedge, so the pop-in is the price of the flat memory footprint.
- The prepared disk quota is load-bearing: an undersized quota (or an aggressive `preparedDiskTimeToLive`) turns revisits back into downloads. `preparedDiskCacheSizeInBytes` is root-wide, not per map instance: the last map to initialize sets the policy for all of them.
- `preparedDiskTimeToLive` is the only freshness mechanism for prepared content: a tile served from disk is not revalidated against the server until it expires or the cache identity changes. Raw bytes still revalidate by ETag when they are actually downloaded.
- The caches fill from what the camera has actually looked at, and the system may evict them. To pre-download an area and keep it, use [offline regions](offline-tiles.md), which are a separate pinned store, not a cache policy.

Running examples: [`Examples/macOS/ImmersiveMapCameraTourMac`](../../Examples/macOS/ImmersiveMapCameraTourMac) raises the prepared disk cache to 4 GiB so a looped tour never prunes the previous lap; the **Diagnostics** section of [`Examples/macOS/ImmersiveMapSettingsMac`](../../Examples/macOS/ImmersiveMapSettingsMac) turns the raw and prepared caches off one at a time and sizes the prepared quota, so the cost of the stage below each one is visible on screen.
