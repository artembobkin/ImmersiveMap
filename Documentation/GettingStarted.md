# Getting started

## Adding the package

In Xcode, choose File > Add Package Dependencies and enter:

```text
https://github.com/artembobkin/ImmersiveMap.git
```

Add the `ImmersiveMap` library to your app's target. The map runs on iOS 18 and macOS 15 with Xcode 16.3 or later. The package compiles its Metal shaders with a build plugin, so Xcode asks you to trust the plugin on the first build. On the command line, pass `-skipPackagePluginValidation` to `xcodebuild`.

**On macOS, allow the network.** A new Mac app in Xcode is sandboxed, and the sandbox blocks the tile downloads. The map then shows the stars, the atmosphere and the badge around a black globe, with no error. Turn on Outgoing Connections (Client) under Signing & Capabilities → App Sandbox. A map that reads its tiles from a file in the bundle needs no network (see [Setting up the tile source](TileSource.md)).

## The first map

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

This is the whole planet from the hosted tiles, with the built-in style, the globe at low zooms, buildings, trees and the attribution badge. Nothing needs a key or an account.

## Modifiers

Everything about the map is set by modifiers on the view:

```swift
ImmersiveMapView()
    .cameraPosition(ImmersiveMapCameraPosition(latitudeDegrees: 48.858, longitudeDegrees: 2.294, zoom: 15))
    .night()
    .shadows(strength: 0.6)
    .trees(isEnabled: false)
```

A modifier sets only the values you pass. Everything you leave out keeps its default, or the value an earlier modifier gave it, so `.shadows(strength: 0.6)` changes the strength and nothing else.

## Settings in one place

Every modifier that configures the map also exists on `ImmersiveMapSettings`, the value that holds the map's whole configuration. Only the camera position, the markers and the controllers stay on the view. Build the value once when several maps share it, or when it comes from your app's own settings:

```swift
let settings = ImmersiveMapSettings.default
    .night()
    .shadows(strength: 0.6)

ImmersiveMapView(settings: settings)
    .cameraPosition(start)
```

The modifiers on the view apply over the value you pass. The same value configures a picture or a video (see [Export](Export.md)).

## Changing the settings

Pass new values whenever your state changes, and the map follows. Most changes apply on the next frame: the camera, the light and the shadows, the fog, the layers, the attribution.

A few change how the tiles are prepared, so the map is built again and reloads what it shows, from the disk cache where it can: the tile source, the style (`.night()` included), the labels, the caches, the avatar settings, the model archive, and `.msaa()`. Change them when the user asks for it, not on every frame.

## Next

- [Setting up the tile source](TileSource.md) and [Attribution](Attribution.md): the data the map draws and its credit.
- [Camera](Camera.md): where the map looks, and how the user moves it.
- [Style](Style.md), [Custom styles](CustomStyle.md), [Relief](Relief.md) and [The scene](Scene.md): how the map looks.
- [Your own data](Layers.md), [Markers and taps](MarkersAndTaps.md) and [3D content](3DContent.md): what you put on the map.
- [Export](Export.md): pictures and videos of the map.
