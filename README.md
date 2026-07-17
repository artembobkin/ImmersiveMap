# ImmersiveMap

[![CI](https://github.com/artembobkin/ImmersiveMap/actions/workflows/ci.yml/badge.svg)](https://github.com/artembobkin/ImmersiveMap/actions/workflows/ci.yml) [![Swift Versions](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2Fartembobkin%2FImmersiveMap%2Fbadge%3Ftype%3Dswift-versions)](https://swiftpackageindex.com/artembobkin/ImmersiveMap) [![Platforms](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2Fartembobkin%2FImmersiveMap%2Fbadge%3Ftype%3Dplatforms)](https://swiftpackageindex.com/artembobkin/ImmersiveMap) [![Release](https://img.shields.io/github/v/tag/artembobkin/ImmersiveMap?label=release&sort=semver&style=flat-square)](https://github.com/artembobkin/ImmersiveMap/tags) [![License](https://img.shields.io/github/license/artembobkin/ImmersiveMap?style=flat-square)](LICENSE)

![ImmersiveMap demo](Documentation/Assets/immersive-map-demo.gif)

Native Swift + Metal map rendering engine for SwiftUI apps.

> **Status: early alpha.** The public API is not stable yet. Not production-ready. Not a drop-in replacement for Mapbox, MapLibre, or MapKit.

ImmersiveMap is an experimental **native Swift + Metal map rendering engine for SwiftUI** apps on Apple platforms.

It is built for developers who want direct control over map rendering, their own vector tile data, globe rendering, and a native engine they can extend to fit their app.

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
| Avatars / live markers | Alpha |
| Disk / memory tile cache | Alpha |
| Offline maps | Planned |
| 3D Tiles | Planned |
| Stable public API | Not yet |
| Production readiness | Not yet |

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

## Markers

Markers (avatars) are owned by an `ImmersiveMapAvatarsController`. The controller is thread-safe - call its methods from any thread and the map redraws itself (rendering is on-demand, so idle markers cost nothing). Attach it with `.avatars(_:)`:

```swift
struct MapScreen: View {
    @State private var avatars = ImmersiveMapAvatarsController()

    var body: some View {
        ImmersiveMapView()
            .avatars(avatars)
            .avatarSettings(size: .px128)          // optional marker size
            .onMarkerTap { event in                // tap handling (native SwiftUI)
                print("tapped marker \(event.marker.id) at \(event.screenPoint)")
            }
            .task {
                avatars.add(AvatarMarker(
                    id: 1,
                    latitude: 55.7558,
                    longitude: 37.6173,
                    image: AvatarMarkerImageFactory.number(1)
                ))
            }
    }
}
```

Every marker has a `UInt64` `id`, unique within the controller; all operations address it by `id`.

### Add, remove, move

```swift
avatars.add(marker)                 // add one (or add([m1, m2]) for several)
avatars.upsert([m1, m2])            // add or replace by id
avatars.set([m1, m2])               // replace the entire marker set

avatars.remove(id: 1)               // remove one (or remove(ids: [1, 2]))
avatars.clear()                     // remove all

avatars.move(id: 1, latitude: 55.76, longitude: 37.62)
```

`move` is animated automatically: the marker glides to the new coordinate (duration scales with distance). For live tracks, just push new coordinates and the engine smooths the motion.

### Images

A marker always has an image. Set it several ways:

```swift
// Ready-made image (CGImage, or UIImage on iOS / NSImage on macOS)
AvatarMarker(id: 1, coordinate: coord, image: cgImage)

// Remote image loaded in the background, with an optional placeholder
AvatarMarker(id: 1, latitude: 55.75, longitude: 37.61,
             imageURL: url, placeholder: placeholderCGImage)

// Generated placeholder: a square with a number
AvatarMarker(id: 1, coordinate: coord, image: AvatarMarkerImageFactory.number(1))
```

Change the image (and optionally border color / selection) later:

```swift
avatars.update(id: 1, image: newImage)
avatars.update(id: 1, borderColor: SIMD4<Float>(0.2, 0.6, 1.0, 1.0), isSelected: true)
```

Reuse a single `CGImage` instance across markers that share a picture - the GPU atlas caches images by object identity, so thousands of markers with the same image occupy one atlas slot.

### Merging markers

Collapse several markers into one clustered marker:

```swift
avatars.merge(ids: [1, 2, 3], mergedID: 100, imageCycleInterval: 2.0)
```

- Members are hidden; a single marker (`100`) is drawn in their place.
- Its coordinate is the **live average** of the members - moving a member glides the merged marker.
- Its image **cycles** through the members' avatars every `imageCycleInterval` seconds (`0` disables cycling).
- A round **count badge** shows how many avatars are merged.

```swift
avatars.mergedMemberIDs(mergedID: 100)     // [1, 2, 3]
avatars.unmerge(mergedID: 100)             // restore members onto the map
```

Members stay addressable (`move`/`update`) while hidden. `remove(id: 100)` deletes the group with its members; removing a member shrinks the count and dissolves an emptied group.

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

ImmersiveMap is currently maintained as a single-maintainer experimental project. Issues and feedback are welcome. Pull requests are accepted for documentation, examples, bug fixes, and tests. See [CONTRIBUTING.md](CONTRIBUTING.md).

## License

ImmersiveMap is available under the MIT license. See [LICENSE](LICENSE).

## Commercial Support

I am available for consulting and custom ImmersiveMap integrations.

To get in touch, open an [issue](https://github.com/artembobkin/ImmersiveMap/issues).

## Screenshots

![ImmersiveMap globe Europe view](Documentation/Assets/immersive-map-globe-europe.png)

![ImmersiveMap globe overview](Documentation/Assets/immersive-map-globe-overview.png)
