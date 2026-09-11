# ``ImmersiveMap``

A native Swift and Metal vector-tile map engine for SwiftUI, with a continuous globe and flat presentation.

## Overview

ImmersiveMap renders vector tiles directly with Metal on iOS 18 and macOS 15 (native AppKit, not Mac Catalyst). Nothing here wraps a platform map SDK: tile decoding, tessellation, the render graph, the labels and the shaders are the package. Drop ``ImmersiveMapView`` into a SwiftUI hierarchy and it renders against the public tile service at [immersivemap.dev](https://immersivemap.dev), with no key and no account. Every feature is a builder-style modifier on the view, and all of them write into the ``ImmersiveMapSettings`` value the renderer is configured from.

```swift
import SwiftUI
import ImmersiveMap

struct MapScreen: View {
    var body: some View {
        ImmersiveMapView()
            .enableCameraUIControls()
            .ignoresSafeArea()
    }
}
```

The [README](https://github.com/artembobkin/ImmersiveMap#readme) is the place to read about the engine: the feature list, one guide and one example app per feature, and the changelog. This reference lists the public symbols as they are in the source. ImmersiveMap is pre-1.0 and the public API is still moving, so read the release notes before updating.
