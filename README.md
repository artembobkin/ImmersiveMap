# ImmersiveMap

[![CI](https://github.com/artembobkin/ImmersiveMap/actions/workflows/ci.yml/badge.svg)](https://github.com/artembobkin/ImmersiveMap/actions/workflows/ci.yml) [![Swift Versions](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2Fartembobkin%2FImmersiveMap%2Fbadge%3Ftype%3Dswift-versions)](https://swiftpackageindex.com/artembobkin/ImmersiveMap) [![Platforms](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2Fartembobkin%2FImmersiveMap%2Fbadge%3Ftype%3Dplatforms)](https://swiftpackageindex.com/artembobkin/ImmersiveMap) [![Release](https://img.shields.io/github/v/tag/artembobkin/ImmersiveMap?label=release&sort=semver&style=flat-square)](https://github.com/artembobkin/ImmersiveMap/tags) [![License](https://img.shields.io/github/license/artembobkin/ImmersiveMap?style=flat-square)](LICENSE)

ImmersiveMap is a **pure Swift + Metal map** rendering engine for **SwiftUI apps** on Apple platforms.

<!-- gallery:start -->
<!-- Written by Tools/ReadmeFrames from frames.json: edit the frames, not these rows. -->
<p align="center">
  <img src="Assets/readme-globe-europe.png" width="100%" alt="The globe over Europe: biomes, the road network and the atmosphere">
</p>
<p align="center">
  <img src="Assets/readme-matterhorn.png" width="49%" alt="The Matterhorn's summit on the terrain relief, with the hillshade and the mountain shadows">
  <img src="Assets/readme-zermatt-valley.png" width="49%" alt="The valley of Zermatt from above, the relief under the land cover and the mountain air">
</p>
<p align="center">
  <img src="Assets/readme-manhattan.png" width="49%" alt="Lower Manhattan with extruded buildings, shadows and street names">
  <img src="Assets/readme-rome.png" width="49%" alt="The Roman Forum from a tilted camera, with the points of interest">
</p>
<p align="center">
  <img src="Assets/readme-moscow-city.png" width="49%" alt="The towers of Moscow City over the Third Ring Road">
  <img src="Assets/readme-kremlin.png" width="49%" alt="The Kremlin wall and the Saviour Tower from the model archive">
</p>
<p align="center">
  <img src="Assets/readme-bolshoi.png" width="49%" alt="The Bolshoi Theatre at street level, a 3D model standing in for the building">
  <img src="Assets/readme-paris-region.png" width="49%" alt="Paris and its suburbs on the relief, with the route shields">
</p>
<p align="center">
  <img src="Assets/readme-san-francisco.png" width="49%" alt="San Francisco's hills on the relief, toward the bay">
  <img src="Assets/readme-san-francisco-downtown.png" width="49%" alt="Downtown San Francisco from above, with the points of interest">
</p>
<p align="center">
  <img src="Assets/readme-berlin-night.png" width="49%" alt="Berlin Mitte in the dark palette">
  <img src="Assets/readme-avatars-shibuya.png" width="49%" alt="Avatar markers with badges over Shibuya">
</p>
<p align="center">
  <img src="Assets/readme-scene-models-paris.png" width="49%" alt="A 3D scene model by the Eiffel Tower">
  <img src="Assets/readme-avatars-globe.png" width="49%" alt="Avatar markers on the globe">
</p>
<!-- gallery:end -->

## Features

Built-in Protomaps vector tiles, native iOS (UIKit host), native macOS, SwiftUI integration, map styling and colors, SwiftUI markers, avatars, 3D scene models, landmark models that replace the map's buildings, tour video export.

## Map Data

The map draws the Protomaps basemap, an OpenStreetMap planet in a single PMTiles archive that the engine reads with HTTP range requests, with no tile server in between. The archive hosted for this project is the default, and `.tileArchive(_:headers:)` points the map at any [Protomaps planet build](https://maps.protomaps.com/builds/) or a region cut from one.

The 3D building models are a second PMTiles archive of the same kind, built for this project and hosted on Cloudflare's S3-compatible storage.

The globe's overview (the biomes, the lakes and the road network of the low zooms) is baked from RESOLVE and Natural Earth data into the package resources, in this repository, so it ships with the engine and loads from no server.

## Quick Start

```swift
import SwiftUI
import ImmersiveMap

struct ContentView: View {
    var body: some View {
        ImmersiveMapView()
            .ignoresSafeArea()
    }
}
```

## Installation

Add ImmersiveMap as a Swift Package dependency:

```text
https://github.com/artembobkin/ImmersiveMap.git
```

## Requirements

- Swift 6.0+
- Xcode 16+
- iOS 18+
- macOS 15+
- Metal-capable device or simulator

## Attribution

The default map is built from open data, and three of its sources ask to be credited:

1. **OpenStreetMap**: the built-in vector tiles are OpenStreetMap data under ODbL, so "© OpenStreetMap" is required.
2. **RESOLVE Ecoregions 2017**: the biomes the engine paints under the land of the globe are under CC BY 4.0, so "Biomes © RESOLVE" is required while they are on screen.
3. **Mapterhorn**: the terrain the ground relief rises by is Mapterhorn's open elevation data, so "© Mapterhorn" is required while the relief is on screen.

The attribution badge shows each credit at the zooms its data is on screen, and a source switched off takes its credit with it.

Otherwise the license is MIT and nothing here changes that. The badge ends with "Powered by ImmersiveMap" by default, a courtesy the license does not ask for, and it can be switched off. It would just be cool if you mention ImmersiveMap somewhere:

```text
Maps powered by ImmersiveMap (immersivemap.dev)
```

## Contributing

ImmersiveMap is currently maintained as a single-maintainer project. Issues and feedback are welcome. Pull requests are accepted. For bug reports, feature requests, questions and ideas, open an [issue](https://github.com/artembobkin/ImmersiveMap/issues).

## License

ImmersiveMap is available under the MIT license. See [LICENSE](LICENSE). The internal earcut triangulator is a port of ISC-licensed Mapbox code, and its notice heads [EarcutCore.swift](Sources/Earcut/EarcutCore.swift).

## Commercial Support

I am available for consulting and custom ImmersiveMap integrations. To get in touch, open an [issue](https://github.com/artembobkin/ImmersiveMap/issues/new).
