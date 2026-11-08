# Setting up the tile source

The map draws from one file: a [PMTiles](https://docs.protomaps.com/pmtiles/) v3 archive of vector tiles (MVT, gzip-compressed or not). The engine reads it with HTTP range requests, so any static host serves it, and no tile server is needed.

## The default

A bare `ImmersiveMapView()` draws the hosted archive, `ImmersiveMapTilesService.tileArchiveURL`: the whole planet from OpenStreetMap, credited "© OpenStreetMap" on the map.

## Your own archive

```swift
ImmersiveMapView()
    .tileArchive(URL(string: "https://tiles.example.com/planet.pmtiles")!)
```

- **Keys.** A query string is sent as written, so a key can live in the URL. Credentials sent as headers go in `headers`, which are added to every request:
  ```swift
  .tileArchive(url, headers: ["Authorization": "Bearer …"])
  ```
- **Offline.** A file URL reads the archive from disk, so an app can ship its map in the bundle:
  ```swift
  .tileArchive(Bundle.main.url(forResource: "city", withExtension: "pmtiles")!)
  ```
- **Depth.** The map reads how deep the archive goes from its header, and never asks for a deeper tile. Past that zoom, the deepest tiles are stretched. To read less, cap it with `.tileMaximumZoomLevel(14)`.
- **Updates.** You can upload a new archive under the same URL. The map notices by the ETag the host sends, and parses the changed tiles again. A host that sends no ETag needs a new URL for each upload.

## Caching

The map keeps every tile it has parsed on disk, up to 2 GB by default, so a place seen before comes back without the network. Set the size in the unit that reads best:

```swift
ImmersiveMapView()
    .preparedTileDiskCacheSize(.gigabytes(4))
```

The size is an `ImmersiveMapByteCount`: `.gigabytes(_:)`, `.megabytes(_:)`, `.kilobytes(_:)` or `.bytes(_:)`. Fractions work, as in `.megabytes(1.5)`. A gigabyte here is 1024 megabytes. The cache is shared by every map in the app, and the most recently created map sets its size.
