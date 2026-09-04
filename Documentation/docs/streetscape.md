# The Streetscape

The streetscape is the measured street: the carriageway surfaces reconstructed from the road graph (one polygon per carriageway, one per junction, flush with each other) and the paint on them, lane separators, centre dividers, the letters of a bus lane, the sawtooth of a bus stop, the comb of a parking lot. It is optional and off by default.

```swift
ImmersiveMapView()
    .streetscape(isEnabled: true)
```

## What the default map draws

Without the streetscape, roads draw the way a street map draws them: a stroke per class, its width the class's alone (a motorway the widest, a service alley a sliver, growing with the camera at street zoom), with a casing and nothing painted on it. The tiles' lane count is not read: a road's real carriageway width is a streetscape fact, drawn only to carry the measured surfaces and paint. No lane lines, no centre dividers, no parking-bay combs; a parking lot is a plain asphalt surface with a kerb. The one figure on the road that stays is the zebra crossing, which the map tiles carry on the crossing footway itself and which belongs to a street map rather than to the measured streetscape.

## Where it comes from

The hosted service keeps the streetscape out of the map tiles and serves it as a second archive, `https://immersivemap.dev/tiles/streetscape/{z}/{x}/{y}.mvt`, covering z15 and z16 and only where the road graph was reconstructed. With the streetscape on, every tile at those zooms is two requests, the map tile and the streetscape tile, merged into one before parsing; below z15 a tile is one request, as always. The streetscape requests carry the same headers as the map tile requests, so a key attached with `.tileURLTemplate(_:headers:)` covers both. The archive is handed out to the keys that ask for it: when the service refuses the streetscape request (HTTP 401 or 403), the tile is not drawn at all and one throttled warning names the cause, rather than the map quietly looking as if the streetscape were off. A tile the archive has nothing for (HTTP 404) is drawn from the map tile alone.

A custom tile source that ships a streetscape archive of its own says where it lives:

```swift
ImmersiveMapView()
    .tileURLTemplate("https://tiles.com/map/{z}/{x}/{y}.mvt")
    .streetscapeTileURLTemplate("https://tiles.com/streetscape/{z}/{x}/{y}.mvt")
    .streetscape(isEnabled: true)
```

The archive's tiles carry one layer, `streetscape`, in the same schema as the roads of the map tiles: carriageway and junction polygons (`subclass=carriageway_area`, `subclass=junction_area` with `origin=graph`) and paint lines (`marking=dividing`, `lane_separator`, `edge`, `bus_lane`, `bus_stop_zigzag`, with `style`, `paint`, `brunnel` and `layer`). The engine folds that layer into the road layer of the map tile, so the surfaces clip the ribbons of the roads that enter them and the paint stops at a junction's edge. Setting the template does not turn the streetscape on, and a custom source with the streetscape on but no template requests nothing and logs one warning.

The direct fields are `ImmersiveMapSettings.TileSettings.StreetscapeSettings`: `isEnabled`, `tileURLTemplate`, and `minimumTileZoom` (15) for an archive cut to a different depth.

## Caches and offline regions

Whether the streetscape is on is part of the prepared tile cache identity: a tile prepared with it carries a second source's features, a tile prepared without it carries no road paint, and neither answers the other map. Turning it on or off therefore re-prepares every tile, from the raw tile cache where the bytes are still there. Downloaded [offline regions](offline-tiles.md) hold map tiles only, namespaced by the map tile source alone, so toggling the streetscape orphans no region; a tile answered from a region draws without its streetscape.
