# ``ImmersiveMap``

A native Swift and Metal vector-tile map engine for SwiftUI, with a continuous globe and flat presentation.

## Overview

ImmersiveMap renders vector tiles directly with Metal and integrates with SwiftUI on iOS and macOS - no WebView and no JavaScript bridge. It provides a continuous globe/flat presentation that morphs between a sphere and a plane, labels, a starfield, avatar / live markers, and pluggable tile providers with disk and memory caching.

Drop ``ImmersiveMapView`` into a SwiftUI hierarchy to render a map out of the box with the built-in tile provider. Attach a provider such as ``MapboxTileProvider`` or ``OpenStreetMapTileProvider`` to render other vector tiles, and drive the map with ``ImmersiveMapCameraController``.

> Important: ImmersiveMap is early alpha. The public API is not stable yet, and the package is not production-ready.

## Topics

### Essentials

- ``ImmersiveMapView``
- ``ImmersiveMapSettings``

### Controllers

- ``ImmersiveMapCameraController``
- ``ImmersiveMapAvatarsController``
- ``ImmersiveMapSelectionController``

### Tile Providers and Styles

- ``ImmersiveMapTileProvider``
- ``ImmersiveMapMapStyle``
- ``ImmersiveMapVectorTileStyle``
- ``MapboxTileProvider``
- ``MapboxMapStyle``
- ``OpenStreetMapTileProvider``
- ``OpenStreetMapMapStyle``
