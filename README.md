# ImmersiveMap

[![CI](https://github.com/artembobkin/ImmersiveMap/actions/workflows/ci.yml/badge.svg)](https://github.com/artembobkin/ImmersiveMap/actions/workflows/ci.yml) [![Swift Versions](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2Fartembobkin%2FImmersiveMap%2Fbadge%3Ftype%3Dswift-versions)](https://swiftpackageindex.com/artembobkin/ImmersiveMap) [![Platforms](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2Fartembobkin%2FImmersiveMap%2Fbadge%3Ftype%3Dplatforms)](https://swiftpackageindex.com/artembobkin/ImmersiveMap) [![Release](https://img.shields.io/github/v/tag/artembobkin/ImmersiveMap?label=release&sort=semver&style=flat-square)](https://github.com/artembobkin/ImmersiveMap/tags) [![License](https://img.shields.io/github/license/artembobkin/ImmersiveMap?style=flat-square)](LICENSE)

ImmersiveMap is a **pure Swift + Metal map** rendering engine for **SwiftUI apps** on Apple platforms.

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

## Installation

Add ImmersiveMap as a Swift Package dependency:

```text
https://github.com/artembobkin/ImmersiveMap.git
```

## Requirements

- Swift 6.0+
- Xcode 16+
- iOS 18+
- macOS 15+ (native AppKit, not Mac Catalyst)
- Metal-capable device or simulator

## Features

- SwiftUI integration
- Native iOS (UIKit host)
- Native macOS (AppKit host, no Catalyst)
- Native Metal renderer
- [Built-in vector tiles, no token required](Documentation/docs/map-data.md)
- [Your own MVT tile source](Documentation/docs/custom-tile-provider.md)
- [Customizable attribution badge](ATTRIBUTION.md)
- [Globe rendering and globe-to-flat morph](Documentation/docs/globe.md)
- [The globe's atmosphere and the flat horizon's fog band](Documentation/docs/atmosphere.md)
- [Labels with MSDF text and GPU collision](Documentation/docs/labels.md)
- [Map styling and colors](Documentation/docs/styling.md)
- [The streetscape: measured carriageways and road paint, opt-in](Documentation/docs/streetscape.md)
- [Extruded buildings and shadows](Documentation/docs/buildings-and-shadows.md)
- [SwiftUI markers](Documentation/docs/markers.md)
- [Avatars / live markers](Documentation/docs/avatars.md)
- [Tap selection of avatars and models](Documentation/docs/selection.md)
- [Routes on the globe](Documentation/docs/routes.md)
- [3D scene models](Documentation/docs/scene-models.md)
- [Camera flights and scripted tours](Documentation/docs/camera.md)
- [Camera travelling along a path](Documentation/docs/camera-path-follow.md)
- [Tour video export](Documentation/docs/tour-video-export.md)
- [Tile caches: two disk layers, a working set in memory](Documentation/docs/tile-cache.md)
- [Offline regions: download once, render without a network](Documentation/docs/offline-tiles.md)
- [Render loop, view reuse and debug HUD](Documentation/docs/performance-and-debug.md)

## App size

Measured from a Release archive of the iOS demo app (`Examples/ImmersiveMapIOS`, arm64, unsigned). That demo is about twenty lines of SwiftUI, so these numbers are effectively what the engine itself adds to an app.

| Part | Size |
|---|---|
| **App bundle, total** | **6.5 MB** |
| Binary (engine, no dependencies) | 3.4 MB |
| Resources | 2.9 MB |
| ├ MSDF font atlases, two weights | 2.3 MB |
| ├ Compiled Metal library | 392 KB |
| └ Glyph metrics | 192 KB |

Most of the resource weight is the bundled Noto Sans MSDF atlases that draw every label on the map. If your app only needs a subset of scripts, regenerate smaller atlases with `Tools/TextAtlas/generate_text_atlas.sh`.

The App Store download size is lower than the archive size, since the store compresses and thins the bundle.

## Example Apps

The `Examples` folder holds small host apps that show the engine's features in practice: camera tours and video export, markers, avatars, routes, 3D scene models, live settings, offline regions, and a custom tile source. Clone the repository, open `ImmersiveMap.xcworkspace`, pick an example scheme, and run: they reference the package locally, and every one but the custom tile source renders the built-in tile provider with no token or account.

## Where the map data comes from

[**immersivemap.dev**](https://immersivemap.dev) is the home of this project. It runs the vector tile service the engine renders by default, and hosts the account dashboard where you create API keys and watch your tile usage.

Nothing there is required to get started: the default provider renders out of the box with no token and no account, on a shared public pool. A free key from [immersivemap.dev/account](https://immersivemap.dev/account) moves you off that shared pool onto your own throughput, with usage visible in the dashboard.

## Attribution

The map shows a small attribution badge ("© OpenStreetMap" with the built-in tiles) because map data licenses require visible credit. The badge is restylable (size, position, text color) and can be replaced with your own credit elsewhere in the app. The details, including what exactly has to be credited, where it has to appear, and what stays your app's responsibility, are in [ATTRIBUTION.md](ATTRIBUTION.md).

Crediting ImmersiveMap itself is **not** required: the license is MIT and nothing here changes that. But if the engine is useful in your app, a line like this on an about or credits screen is genuinely appreciated:

```text
Maps powered by ImmersiveMap (immersivemap.dev)
```

And if you ship something built with ImmersiveMap, [say hello in Discussions](https://github.com/artembobkin/ImmersiveMap/discussions). Knowing where the engine ends up is what keeps it moving.

## Known Limitations

- Apple platforms only. Requires Metal.
- App size is measured (see [App size](#app-size)), frame time and memory numbers are not published yet.
- Maintained by one person. Issues and integration questions are answered quickly, but plan accordingly.

## Contributing

ImmersiveMap is currently maintained as a single-maintainer project. Issues and feedback are welcome. Pull requests are accepted for documentation, examples, bug fixes, and tests. See [CONTRIBUTING.md](CONTRIBUTING.md).

Bug reports and feature requests belong in [Issues](https://github.com/artembobkin/ImmersiveMap/issues). Questions, ideas, and anything open-ended belong in [Discussions](https://github.com/artembobkin/ImmersiveMap/discussions).

## License

ImmersiveMap is available under the MIT license. See [LICENSE](LICENSE). The internal earcut triangulator is a port of ISC-licensed Mapbox code; its notice, ready to copy into an app's acknowledgements screen, is in [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md).

## Commercial Support

I am available for consulting and custom ImmersiveMap integrations.

To get in touch, start a [discussion](https://github.com/artembobkin/ImmersiveMap/discussions), or write to me in the chat at [immersivemap.dev/account](https://immersivemap.dev/account/).

## Screenshots

![ImmersiveMap globe Europe view](Documentation/Assets/immersive-map-globe-europe.png)

![ImmersiveMap globe overview](Documentation/Assets/immersive-map-globe-overview.png)
