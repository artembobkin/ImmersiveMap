# ImmersiveMap

[![CI](https://github.com/artembobkin/ImmersiveMap/actions/workflows/ci.yml/badge.svg)](https://github.com/artembobkin/ImmersiveMap/actions/workflows/ci.yml) [![Swift Versions](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2Fartembobkin%2FImmersiveMap%2Fbadge%3Ftype%3Dswift-versions)](https://swiftpackageindex.com/artembobkin/ImmersiveMap) [![Platforms](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2Fartembobkin%2FImmersiveMap%2Fbadge%3Ftype%3Dplatforms)](https://swiftpackageindex.com/artembobkin/ImmersiveMap) [![Release](https://img.shields.io/github/v/tag/artembobkin/ImmersiveMap?label=release&sort=semver&style=flat-square)](https://github.com/artembobkin/ImmersiveMap/tags) [![License](https://img.shields.io/github/license/artembobkin/ImmersiveMap?style=flat-square)](LICENSE)

![ImmersiveMap demo](Documentation/Assets/immersive-map-demo.gif)

Native Swift + Metal map rendering engine for SwiftUI apps.

> **Status: early alpha.** The public API is not stable yet. Not production-ready. Not a drop-in replacement for Mapbox, MapLibre, or MapKit.

ImmersiveMap is a **native Swift + Metal map rendering engine for SwiftUI** apps on Apple platforms.

It is built for developers who want direct control over map rendering, their own vector tile data, globe rendering, and a native engine they can extend to fit their app.

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

ImmersiveMap ships with a built-in tile provider, so the snippet above renders a map out of the box - no token or account required. The same SwiftUI code runs natively on iOS (UIKit host) and macOS (AppKit host): `ImmersiveMapView` bridges to the platform view internally.

To use Mapbox vector tiles instead, attach a provider and style:

```swift
ImmersiveMapView()
    .tileProvider(MapboxTileProvider(accessToken: "your-mapbox-public-token"))
    .mapStyle(MapboxMapStyle())
    // camera and other modifiers...
```

## Features

| Feature | Status |
|---|---|
| SwiftUI integration | Alpha |
| Native iOS (UIKit host) | Alpha |
| Native macOS (AppKit host, no Catalyst) | Alpha |
| Native Metal renderer | Alpha |
| Mapbox vector tiles | Alpha |
| Globe rendering | Alpha |
| Labels | Alpha |
| [Avatars / live markers](MARKERS.md) | Alpha |
| Disk / memory tile cache | Alpha |
| Offline maps | Planned |
| 3D Tiles | Planned |
| Stable public API | Not yet |
| Production readiness | Not yet |

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

## Known Limitations

- Early alpha; the public API may change.
- Not production-ready yet.
- Not a drop-in replacement for Mapbox, MapLibre, or MapKit.
- Currently focused on Apple platforms.
- Requires Metal.
- Tile provider terms and attribution are the responsibility of the app developer.
- Performance characteristics are still being measured.

## Attribution and Tile Provider Terms

ImmersiveMap is MIT-licensed, but map tiles, styles, and geospatial datasets may have their own licenses and attribution requirements. When using Mapbox or other providers, make sure your app follows their terms and attribution rules.

## Contributing

ImmersiveMap is currently maintained as a single-maintainer project. Issues and feedback are welcome. Pull requests are accepted for documentation, examples, bug fixes, and tests. See [CONTRIBUTING.md](CONTRIBUTING.md).

## License

ImmersiveMap is available under the MIT license. See [LICENSE](LICENSE).

## Commercial Support

I am available for consulting and custom ImmersiveMap integrations.

To get in touch, open an [issue](https://github.com/artembobkin/ImmersiveMap/issues).

## Screenshots

![ImmersiveMap globe Europe view](Documentation/Assets/immersive-map-globe-europe.png)

![ImmersiveMap globe overview](Documentation/Assets/immersive-map-globe-overview.png)
