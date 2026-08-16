# Disk and memory tile cache

A tile is expensive twice: once to download, once to parse and tessellate into GPU buffers. ImmersiveMap caches at both points, so panning back to where you were costs nothing and a second launch over the same area skips the network entirely.

Three layers, outermost first:

| Layer | Holds | Lives in |
|---|---|---|
| Raw HTTP cache | The `.mvt` bytes as fetched, conditionally revalidated against the server's ETag and `Cache-Control` | `URLCache` on disk |
| Prepared tile cache | Parsed and tessellated geometry, optionally LZFSE-compressed | A dedicated disk cache |
| Memory cache | `MetalTile`s: GPU buffers ready to draw | RAM, LRU |

Nothing has to be configured. The knobs live on `ImmersiveMapSettings.TileSettings` and are reached either through the whole value or through the two convenience overloads:

```swift
ImmersiveMapView()
    .tileSettings(memoryCacheSizeInBytes: 1_073_741_824)   // 1 GiB of GPU-ready tiles
```

```swift
ImmersiveMapView()
    .tileSettings(clearDiskCachesOnLaunch: true,
                  preparedTileCacheEnabled: false,
                  memoryCacheSizeInBytes: 128 * 1024 * 1024)
```

## Cache settings

```swift
public struct CacheSettings: Equatable, Sendable {
    public var clearDiskCachesOnLaunch: Bool          // false
    public var urlCacheEnabled: Bool                  // true
    public var preparedTileCacheEnabled: Bool         // true
    public var preparedDiskCompressionEnabled: Bool   // true
    public var preparedDiskTimeToLive: TimeInterval   // 7 days
    public var preparedDiskCacheSizeInBytes: Int      // 256 MiB
    public var memoryCacheSizeInBytes: Int            // 256 MiB
}
```

| Field | Why you would change it |
|---|---|
| `memoryCacheSizeInBytes` | The one worth tuning. A looped camera tour or a map that revisits the same few cities pays for evicted tiles with re-uploads; raising this keeps them resident. |
| `preparedDiskCacheSizeInBytes` | A root-wide byte quota shared by every prepared-tile namespace. The most recently initialized map makes its quota the active policy. |
| `preparedDiskTimeToLive` | How long a prepared tile stays valid. Shorter for fast-moving data, longer for a basemap that rarely changes. |
| `preparedDiskCompressionEnabled` | Off writes larger files and burns less CPU (and battery) while exploring new areas. Both variants stay readable either way, so flipping it does not invalidate anything. |
| `preparedTileCacheEnabled` | Off re-parses from raw bytes every load. Useful when iterating on a style, where prepared tiles would be stale by construction. |
| `urlCacheEnabled` | Off drops the `URLCache` entirely, so every tile is downloaded in full with no HTTP conditional revalidation. Response ETags are still read, and still key the prepared cache below. |
| `clearDiskCachesOnLaunch` | A development lever, not a product one. |

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

Loading runs off the main thread with bounded concurrency: `maxConcurrentFetches` in flight, the rest in a dedup FIFO capped at `pendingRequestQueueCapacity`, with retry and backoff. Requests for a tile already in flight join the existing one rather than starting a second.

Most apps never touch `NetworkSettings` directly: `.tileURLTemplate(_:headers:)` supplies the URL and the credentials. Setting the fields by hand is for cases the template cannot express.

`CoverageSettings.maximumZoomLevel` caps the zoom level actually requested from the source. Past it the engine keeps rendering the deepest tiles it has, scaled up, which is why a source that stops at z14 still draws at z18.

## Where the caches live

Both disk caches sit in the app's caches directory, so the system may evict them under storage pressure and they are not backed up. A [tour video export](tour-video-export.md) shares them with the live map, which is why exporting a tour the map has already played does not re-download anything.

## Limitations

- `preparedDiskCacheSizeInBytes` is root-wide, not per map instance: the last map to initialize sets the policy for all of them.
- Cache identity is the app's responsibility for custom styles. A `configurationFingerprint` that does not change when the output does produces stale tiles that look like rendering bugs.
- The caches fill from what the camera has actually looked at, and the system may evict them. To pre-download an area and keep it, use [offline regions](offline-tiles.md), which are a separate pinned store, not a cache policy.

Running examples: [`Examples/macOS/ImmersiveMapCameraTourMac`](../../Examples/macOS/ImmersiveMapCameraTourMac) raises the memory cache to 1 GiB so a looped tour does not re-upload tiles between laps; the **Diagnostics** section of [`Examples/macOS/ImmersiveMapSettingsMac`](../../Examples/macOS/ImmersiveMapSettingsMac) turns the raw and prepared caches off one at a time, so the cost of the stage below each one is visible on screen.
