# ImmersiveMap

![ImmersiveMap hero](Documentation/Assets/immersive-map-hero.png)

Native Swift + Metal map rendering engine for SwiftUI apps.

> **Status: early alpha.** The public API is not stable yet. Not production-ready. Not a drop-in replacement for Mapbox, MapLibre, or MapKit.

ImmersiveMap is an experimental native Swift + Metal map rendering engine for SwiftUI apps on Apple platforms. It is built for developers who need direct control over map rendering, custom vector tile providers, terrain/globe rendering, and native SwiftUI integration - without a WebView or a JavaScript bridge.

## Why ImmersiveMap?

Use ImmersiveMap when you need:

- Native SwiftUI integration
- Direct control over the rendering pipeline
- Metal-based rendering instead of a WebView
- Custom vector tile providers
- Custom map styles
- Terrain and globe rendering
- Apple-first map experiences for iOS and Mac Catalyst

ImmersiveMap is not a full GIS workbench. It is a rendering engine / SDK for Apple apps.

## Features

| Feature | Status |
|---|---|
| SwiftUI integration | Experimental |
| Native Metal renderer | Experimental |
| Mapbox vector tiles | Experimental |
| OpenStreetMap / Shortbread provider | Experimental |
| Terrain rendering | Experimental |
| Globe rendering | Experimental |
| Labels | Experimental |
| Avatars / live markers | Experimental |
| Disk / memory tile cache | Experimental |
| Offline maps | Planned |
| 3D Tiles | Planned |
| Stable public API | Not yet |
| Production readiness | Not yet |

## Requirements

- Swift 6.0+
- Xcode 16+
- iOS 18+
- Mac Catalyst 18+
- macOS 12+
- Metal-capable device or simulator

## Installation

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
    private let tileProvider = MapboxTileProvider(accessToken: "your-mapbox-public-token")
    private let mapStyle = MapboxMapStyle()

    var body: some View {
        ImmersiveMapView()
            .camera(
                camera,
                position: ImmersiveMapCameraPosition(
                    latitudeDegrees: 55.7558,
                    longitudeDegrees: 37.6173,
                    zoom: 0
                )
            )
            .tileProvider(tileProvider)
            .mapStyle(mapStyle)
            .ignoresSafeArea()
    }
}
```

## Example Apps

The repository includes two host apps that reference the package locally:

- `ImmersiveMapIOS` - iOS demo app
- `ImmersiveMapMac` - Mac Catalyst demo app

To run:

1. Clone the repository.
2. Open `ImmersiveMap.xcworkspace`.
3. Select the `ImmersiveMapIOS` or `ImmersiveMapMac` scheme.
4. Add your Mapbox public token if you use the Mapbox provider (see the launch environment variables below).
5. Build and run.

The host apps read optional launch environment variables: `IMMERSIVE_MAP_TILE_BASE_URL`, `IMMERSIVE_MAP_AUTH_TOKEN`, `IMMERSIVE_MAP_MAPBOX_ACCESS_TOKEN`, `IMMERSIVE_MAP_MAPBOX_TILESET_ID`. If the Mapbox token is present, the host apps use the Mapbox Vector Tiles API; otherwise they fall back to the OpenStreetMap / Shortbread provider.

## Tile Providers

ImmersiveMap is designed around pluggable tile providers.

### Mapbox

```swift
ImmersiveMapView()
    .tileProvider(MapboxTileProvider(accessToken: "your-mapbox-public-token"))
    .mapStyle(MapboxMapStyle())
```

### OpenStreetMap / Shortbread

```swift
ImmersiveMapView()
    .tileProvider(OpenStreetMapTileProvider())
    .mapStyle(OpenStreetMapMapStyle())
```

### Custom Providers

Custom providers conform to `ImmersiveMapTileProvider` (see `ImmersiveMap/Provider/`). For a quick start, `VectorTileProvider` lets you point at any MVT tile source without writing a new type. See [Documentation/docs/custom-tile-provider.md](Documentation/docs/custom-tile-provider.md).

## Architecture

High-level rendering flow:

```text
SwiftUI App
   ↓
ImmersiveMapView
   ↓
Camera / Tile / Style / Scene controllers
   ↓
Tile providers + cache
   ↓
Metal render pipeline
   ↓
Screen
```

More detail in [Documentation/docs/architecture.md](Documentation/docs/architecture.md).

## Screenshots

![ImmersiveMap terrain view](Documentation/Assets/immersive-map-terrain.png)

![ImmersiveMap globe Europe view](Documentation/Assets/immersive-map-globe-europe.png)

![ImmersiveMap globe overview](Documentation/Assets/immersive-map-globe-overview.png)

## Known Limitations

- Early alpha; the public API may change.
- Not production-ready yet.
- Not a drop-in replacement for Mapbox, MapLibre, or MapKit.
- Currently focused on Apple platforms.
- Requires Metal.
- Tile provider terms and attribution are the responsibility of the app developer.
- Performance characteristics are still being measured.

## Roadmap

See [Documentation/docs/roadmap.md](Documentation/docs/roadmap.md).

## Testing

Run tests with Swift Package Manager:

```bash
swift test
```

Or run the `ImmersiveMapTests` target from Xcode.

## Attribution and Tile Provider Terms

ImmersiveMap is MIT-licensed, but map tiles, styles, and geospatial datasets may have their own licenses and attribution requirements. When using Mapbox, OpenStreetMap, or other providers, make sure your app follows their terms and attribution rules.

## Contributing

ImmersiveMap is currently maintained as a single-maintainer experimental project. Issues and feedback are welcome. Pull requests are accepted for documentation, examples, bug fixes, and tests. See [CONTRIBUTING.md](CONTRIBUTING.md).

## License

ImmersiveMap is available under the MIT license. See [LICENSE](LICENSE).

## Commercial Support

I am available for consulting and custom ImmersiveMap integrations.

Contact: [@BobkinArtem](https://x.com/BobkinArtem)
