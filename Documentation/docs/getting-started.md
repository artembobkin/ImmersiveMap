# Getting Started

ImmersiveMap is a native Swift + Metal map rendering engine for SwiftUI. This guide covers installing the package and rendering your first map.

## Install

Add the package dependency:

```text
https://github.com/artembobkin/ImmersiveMap.git
```

In Xcode: **File → Add Package Dependencies…**, paste the URL, and add the `ImmersiveMap` library to your app target.

## Requirements

- Swift 6.0+, Xcode 16+
- iOS 18+, Mac Catalyst 18+, or macOS 12+
- A Metal-capable device or simulator

## Your first map

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

`ImmersiveMapView` is a SwiftUI view that accumulates builder-style modifiers (`.camera`, `.tileProvider`, `.mapStyle`, `.labelSettings`, …) into an immutable settings value.

## No Mapbox token?

Use the OpenStreetMap / Shortbread provider, which needs no token:

```swift
ImmersiveMapView()
    .tileProvider(OpenStreetMapTileProvider())
    .mapStyle(OpenStreetMapMapStyle())
```

## Controlling the camera

`ImmersiveMapCameraController` is a public controller you own as `@State`. Pass it to `.camera(_:position:)` to drive the initial position and to programmatically move the camera.

## Next steps

- [Architecture](architecture.md) — how the engine is put together.
- [Custom tile providers](custom-tile-provider.md) — point at any MVT source.
- [Roadmap](roadmap.md) — what's planned.
