# Where the Map Data Comes From

The engine renders the [Protomaps basemap](https://docs.protomaps.com/basemaps/layers) by default: a planet of vector tiles built from [OpenStreetMap](https://www.openstreetmap.org/copyright) data, under ODbL, with Natural Earth at the lowest zooms. The planet is one [PMTiles](https://docs.protomaps.com/pmtiles/) archive, hosted for this project at `https://tiles.immersivemap.dev/20260922.pmtiles`.

Nothing is required to start: `ImmersiveMapView()` reads the hosted archive anonymously, with no token, no account and no sign-up. The demo apps in this repository do exactly that.

## How the archive is read

There is no tile server. A PMTiles archive is a single file with a directory of its tiles, and the engine reads it the way a browser reads a video: with HTTP range requests.

- The first request fetches the archive's header and root directory, 16 KB at the start of the file, once per session.
- Each tile is then one range request for its bytes. A tile in a leaf directory costs one more request for that directory the first time, and the directory stays in memory.
- The tiles are decompressed and decoded on device. The prepared result is cached on disk, so a tile is fetched and parsed once.

The archive covers zooms 0 to 15. Past zoom 15 the map keeps drawing the zoom 15 tiles, more detailed on screen as the camera closes in.

The file name carries the build date. A new planet is a new URL, so the prepared-tile cache and the offline regions start fresh with it instead of mixing two builds.

## Your own archive

Any PMTiles v3 archive of vector tiles (MVT, gzip-compressed or uncompressed) works, served from any host that answers range requests: object storage such as S3 or Cloudflare R2, a CDN, or a plain web server. Point the map at it with the archive URL and, if the host needs them, request headers:

```swift
ImmersiveMapView()
    .tileArchive(URL(string: "https://tiles.example.com/planet.pmtiles")!,
                 headers: ["Authorization": "Bearer <token>"])
```

The [pmtiles CLI](https://docs.protomaps.com/pmtiles/cli) cuts a region or a zoom range out of the planet (`pmtiles extract`), which is how to ship a smaller archive for one city or one country. Protomaps publishes daily planet builds at [maps.protomaps.com/builds](https://maps.protomaps.com/builds/).

The built-in style reads the Protomaps basemap schema: its layers (`earth`, `landcover`, `landuse`, `water`, `roads`, `buildings`, `boundaries`, `places`, `pois`) and their `kind` values. An archive in another schema needs a style of its own, see [Map styling and colors](styling.md).

## Attribution

The tiles are OpenStreetMap data, so the map shows "© OpenStreetMap" in its attribution badge. Keep it visible, or credit OpenStreetMap elsewhere in the app, as the ODbL asks.
