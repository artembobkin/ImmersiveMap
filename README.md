# ImmersiveMap

[![CI](https://github.com/artembobkin/ImmersiveMap/actions/workflows/ci.yml/badge.svg)](https://github.com/artembobkin/ImmersiveMap/actions/workflows/ci.yml) [![Swift Versions](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2Fartembobkin%2FImmersiveMap%2Fbadge%3Ftype%3Dswift-versions)](https://swiftpackageindex.com/artembobkin/ImmersiveMap) [![Platforms](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2Fartembobkin%2FImmersiveMap%2Fbadge%3Ftype%3Dplatforms)](https://swiftpackageindex.com/artembobkin/ImmersiveMap) [![Release](https://img.shields.io/github/v/tag/artembobkin/ImmersiveMap?label=release&sort=semver&style=flat-square)](https://github.com/artembobkin/ImmersiveMap/tags) [![License](https://img.shields.io/github/license/artembobkin/ImmersiveMap?style=flat-square)](LICENSE)

ImmersiveMap is a **pure Swift + Metal map** rendering engine for **SwiftUI apps** on Apple platforms.

<!-- gallery:start -->
<!-- Written by Tools/ReadmeFrames from frames.json: edit the frames, not these rows. -->
<p align="center">
  <img src="Assets/readme-globe-europe.avif" width="100%" alt="The globe over Europe: biomes, the road network and the atmosphere">
</p>
<p align="center">
  <img src="Assets/readme-matterhorn.avif" width="49%" alt="The Matterhorn's summit on the terrain relief, with the hillshade and the mountain shadows">
  <img src="Assets/readme-zermatt-valley.avif" width="49%" alt="The valley of Zermatt from above, the relief under the land cover and the mountain air">
</p>
<p align="center">
  <img src="Assets/readme-manhattan.avif" width="49%" alt="Lower Manhattan with extruded buildings, shadows and street names">
  <img src="Assets/readme-rome.avif" width="49%" alt="The Roman Forum from a tilted camera, with the points of interest">
</p>
<p align="center">
  <img src="Assets/readme-moscow-city.avif" width="49%" alt="The towers of Moscow City over the Third Ring Road">
  <img src="Assets/readme-kremlin.avif" width="49%" alt="The Kremlin wall and the Saviour Tower from the model archive">
</p>
<p align="center">
  <img src="Assets/readme-bolshoi.avif" width="49%" alt="The Bolshoi Theatre at street level, a 3D model standing in for the building">
  <img src="Assets/readme-paris-region.avif" width="49%" alt="Paris and its suburbs on the relief, with the route shields">
</p>
<p align="center">
  <img src="Assets/readme-san-francisco.avif" width="49%" alt="San Francisco's hills on the relief, toward the bay">
  <img src="Assets/readme-san-francisco-downtown.avif" width="49%" alt="Downtown San Francisco from above, with the points of interest">
</p>
<p align="center">
  <img src="Assets/readme-berlin-night.avif" width="49%" alt="Berlin Mitte in the dark palette">
  <img src="Assets/readme-avatars-shibuya.avif" width="49%" alt="Avatar markers with badges over Shibuya">
</p>
<p align="center">
  <img src="Assets/readme-scene-models-paris.avif" width="49%" alt="A 3D scene model by the Eiffel Tower">
  <img src="Assets/readme-avatars-globe.avif" width="49%" alt="Avatar markers on the globe">
</p>
<!-- gallery:end -->

## Features

Built-in Protomaps vector tiles, native iOS (UIKit host), native macOS, SwiftUI integration, map styling and colors, SwiftUI markers, avatars, 3D scene models, 3D building models from a model archive, tour video export.

The guides are in [Documentation](Documentation): [the tile source](Documentation/TileSource.md), [the camera](Documentation/Camera.md), [the style](Documentation/Style.md), [custom styles](Documentation/CustomStyle.md), [the relief](Documentation/Relief.md) and [attribution](Documentation/Attribution.md).

## Map Data

The map draws OpenStreetMap data from a single [PMTiles](https://docs.protomaps.com/pmtiles/) file, read straight from storage with no tile server. The 3D building models come from a second archive, and the globe's biomes ship inside the package. To use your own tiles, see [Setting up the tile source](Documentation/TileSource.md).

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

The package compiles its Metal shaders with a build plugin, so Xcode asks you to trust it on the first build. On the command line, pass `-skipPackagePluginValidation` to `xcodebuild`.

## Requirements

- Swift 6.1+
- Xcode 16.3+
- iOS 18+
- macOS 15+
- Metal-capable device or simulator

## Attribution

The default map is built from open data, and three of its sources ask to be credited:

1. **OpenStreetMap**: the built-in vector tiles are OpenStreetMap data under ODbL, so "© OpenStreetMap" is required.
2. **RESOLVE Ecoregions 2017**: the biomes the engine paints under the land of the globe are under CC BY 4.0, so "Biomes © RESOLVE" is required while they are on screen.
3. **Mapterhorn**: the terrain the ground relief rises by is Mapterhorn's open elevation data, so "© Mapterhorn" is required while the relief is on screen.

The attribution badge shows each credit at the zooms its data is on screen, and a source switched off takes its credit with it.

Otherwise the license is MIT and nothing here changes that. The badge opens with "Powered by ImmersiveMap" by default, a courtesy the license does not ask for, and it can be switched off. It would just be cool if you mention ImmersiveMap somewhere:

```text
Maps powered by ImmersiveMap (immersivemap.dev)
```

## Contributing

ImmersiveMap is currently maintained as a single-maintainer project. Pull requests are accepted.

## License

ImmersiveMap is available under the MIT license. See [LICENSE](LICENSE). The internal earcut triangulator is a port of ISC-licensed Mapbox code, and its notice heads [EarcutCore.swift](Sources/Earcut/EarcutCore.swift).

## Support

Feel free to open an [issue](https://github.com/artembobkin/ImmersiveMap/issues/new) with a question, a bug or an idea. I am happy to help.
