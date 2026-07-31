# ImmersiveMap

[![CI](https://github.com/artembobkin/ImmersiveMap/actions/workflows/ci.yml/badge.svg)](https://github.com/artembobkin/ImmersiveMap/actions/workflows/ci.yml) [![Swift Versions](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2Fartembobkin%2FImmersiveMap%2Fbadge%3Ftype%3Dswift-versions)](https://swiftpackageindex.com/artembobkin/ImmersiveMap) [![Platforms](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2Fartembobkin%2FImmersiveMap%2Fbadge%3Ftype%3Dplatforms)](https://swiftpackageindex.com/artembobkin/ImmersiveMap) [![Release](https://img.shields.io/github/v/tag/artembobkin/ImmersiveMap?label=release&sort=semver&style=flat-square)](https://github.com/artembobkin/ImmersiveMap/tags) [![License](https://img.shields.io/github/license/artembobkin/ImmersiveMap?style=flat-square)](LICENSE)

![ImmersiveMap demo](Documentation/Assets/immersive-map-demo.gif)

Native Swift + Metal map rendering engine for SwiftUI apps.

ImmersiveMap is a **native Swift + Metal map rendering engine for SwiftUI** apps on Apple platforms. Pure Swift and Metal: no C, no C++, no Objective-C, and no native SDK wrapped in a Swift API.

It is built for apps where the map *is* the product rather than decoration: live location and social maps, games, travel, logistics, data visualisation. You get direct control over rendering, your own vector tile data, globe rendering, and an engine you can read and extend instead of file a support ticket against.

## Requirements

- Swift 6.0+
- Xcode 16+
- iOS 18+
- macOS 15+ (native AppKit, not Mac Catalyst)
- Metal-capable device or simulator

## Installation

ImmersiveMap is available on the [Swift Package Index](https://swiftpackageindex.com/artembobkin/ImmersiveMap).

Add ImmersiveMap as a Swift Package dependency:

```text
https://github.com/artembobkin/ImmersiveMap.git
```

Or in Xcode:

1. Open your project.
2. Select **File → Add Package Dependencies…**
3. Paste the repository URL.
4. Add the `ImmersiveMap` library to your app target.

## Quick Start

```swift
import SwiftUI
import ImmersiveMap

struct ContentView: View {
    @State private var camera = ImmersiveMapCameraController()

    var body: some View {
        ImmersiveMapView()
            .cameraController(camera)
            .enableCameraUIControls()
            .ignoresSafeArea()
    }
}
```

ImmersiveMap ships with a built-in tile provider, so the snippet above renders a map out of the box - no token or account required (see [Where the map data comes from](#where-the-map-data-comes-from)). The same SwiftUI code runs natively on iOS (UIKit host) and macOS (AppKit host): `ImmersiveMapView` bridges to the platform view internally.

To use Mapbox vector tiles instead, attach a provider and style:

```swift
ImmersiveMapView()
    .tileProvider(MapboxTileProvider(accessToken: "your-mapbox-public-token"))
    .mapStyle(MapboxMapStyle())
    // camera and other modifiers...
```

Any other MVT source works through `VectorTileProvider`, see the [custom tile provider guide](Documentation/docs/custom-tile-provider.md).

## Features

| Feature | Status |
|---|---|
| SwiftUI integration | Available |
| Native iOS (UIKit host) | Available |
| Native macOS (AppKit host, no Catalyst) | Available |
| Native Metal renderer | Available |
| Built-in vector tiles, no token required | Available |
| Mapbox vector tiles | Available |
| Your own MVT tile source | Available |
| Globe rendering and globe-to-flat morph | Available |
| Labels with MSDF text and GPU collision | Available |
| [SwiftUI markers](Documentation/docs/markers.md) | Available |
| [Avatars / live markers](Documentation/docs/avatars.md) | Available |
| Camera flights and scripted tours | Available |
| Disk / memory tile cache | Available |
| Offline maps | Planned |
| 3D Tiles | Planned |

## Example Apps

The repository includes two host apps that reference the package locally:

- `ImmersiveMapIOS` - iOS demo app
- `ImmersiveMapMac` - native macOS demo app (AppKit, not Catalyst)

To run:

1. Clone the repository.
2. Open `ImmersiveMap.xcworkspace`.
3. Select the `ImmersiveMapIOS` or `ImmersiveMapMac` scheme.
4. Build and run.

Both demo apps render the built-in tile provider out of the box, so they run with no token or account. To try the Mapbox provider instead, attach it to the app's `ImmersiveMapView` as shown in [Quick Start](#quick-start).

## Where the map data comes from

A map engine draws tiles, it does not produce them. Here is exactly what you are rendering when you write `ImmersiveMapView()` and nothing else.

**Out of the box.** The default provider fetches vector tiles from `tiles.immersivemap.dev`, the tile service run for this project. It serves a planet build in the [OpenMapTiles](https://openmaptiles.org) schema, assembled from [OpenFreeMap](https://openfreemap.org) data, which is [OpenStreetMap](https://www.openstreetmap.org/copyright) data under ODbL. No token, no account, no sign-up, and the demo apps in this repository render against it directly.

**Your own tiles.** Any MVT source works through `VectorTileProvider`: your own tile server, your own planet build, or any service that speaks MVT. See the [custom tile provider guide](Documentation/docs/custom-tile-provider.md).

**Mapbox.** `MapboxTileProvider` renders Mapbox vector tiles with your own access token, paired with `MapboxMapStyle`.

### Attribution is not optional

Map data carries licence obligations, and the most common one, ODbL for OpenStreetMap data, requires visible credit in your app.

The engine handles this for you: **the attribution badge takes its text from the active tile provider**, so the built-in tiles credit OpenStreetMap, OpenFreeMap and OpenMapTiles. Each provider carries the credit its own data requires, and only while that provider is active. You do not have to write anything.

If you build a custom `VectorTileProvider`, declare its attribution, because the engine will not invent one for you:

```swift
VectorTileProvider(
    id: "my-tiles",
    tileSource: .immersiveMapTiles(tileBaseURL: myTileURL, apiKey: nil),
    attribution: .openStreetMap    // or your own ImmersiveMapAttribution
)
```

You can restyle or relocate the badge, and hide it with `attributionSettings(.init(isVisible: false))`, but only if your app credits the data source somewhere else. Hiding required attribution outright breaks the data licence, and that is on the app, not on the engine.

## Known Limitations

- Not a drop-in replacement for Mapbox, MapLibre, or MapKit. Its own API, so adopting it means writing the map layer against ImmersiveMap.
- Apple platforms only. Requires Metal.
- Offline maps and 3D tiles are not implemented yet.
- Published performance numbers are not available yet, measurement is in progress.
- Maintained by one person. Issues and integration questions are answered quickly, but plan accordingly.

## Contributing

ImmersiveMap is currently maintained as a single-maintainer project. Issues and feedback are welcome. Pull requests are accepted for documentation, examples, bug fixes, and tests. See [CONTRIBUTING.md](CONTRIBUTING.md).

Bug reports and feature requests belong in [Issues](https://github.com/artembobkin/ImmersiveMap/issues). Questions, ideas, and anything open-ended belong in [Discussions](https://github.com/artembobkin/ImmersiveMap/discussions).

## License

ImmersiveMap is available under the MIT license. See [LICENSE](LICENSE).

## Commercial Support

I am available for consulting and custom ImmersiveMap integrations.

To get in touch, start a [discussion](https://github.com/artembobkin/ImmersiveMap/discussions).

## Screenshots

![ImmersiveMap globe Europe view](Documentation/Assets/immersive-map-globe-europe.png)

![ImmersiveMap globe overview](Documentation/Assets/immersive-map-globe-overview.png)
