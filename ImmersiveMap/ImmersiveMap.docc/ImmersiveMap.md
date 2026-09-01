# ``ImmersiveMap``

A native Swift and Metal vector-tile map engine for SwiftUI, with a continuous globe and flat presentation.

## Overview

ImmersiveMap renders vector tiles directly with Metal and integrates with SwiftUI on iOS 18 and macOS 15 (native AppKit, not Mac Catalyst). Nothing here wraps a platform map SDK: tile decoding, tessellation, the render graph, the labels and the shaders are the package, which is what makes the map stylable and extendable down to the geometry.

Drop ``ImmersiveMapView`` into a SwiftUI hierarchy and it renders with the built-in tile provider, no token and no account:

```swift
import SwiftUI
import ImmersiveMap

struct MapScreen: View {
    @State private var camera = ImmersiveMapCameraController()

    private let barcelona = ImmersiveMapCameraPosition(latitudeDegrees: 41.3874,
                                                       longitudeDegrees: 2.1686,
                                                       zoom: 15,
                                                       bearing: 0,
                                                       pitch: 0.9)   // radians

    var body: some View {
        ImmersiveMapView()
            .camera(camera, position: barcelona)
            .enableCameraUIControls()
            .ignoresSafeArea()
    }
}
```

Everything else is a builder-style modifier on the view (`.tileURLTemplate(_:headers:)`, `.mapStyle(_:)`, `.labelSettings(_:)`, `.sceneSettings(_:)`, `.shadows()`, `.debugPanel()`, and the rest). Each one writes into the ``ImmersiveMapSettings`` value the renderer is configured from, so the same map can also be driven from one stored settings value.

### Presentation

Zoom drives a continuous transition between a globe and a flat map: the sphere unrolls as a wave travelling outward from the view center, and the shaders morph between sphere and plane rather than switching modes. Around the globe there is a starfield, or nothing at all with `.transparentSpace()`, which leaves everything outside the globe unpainted so the app's own background shows through.

### On the map

Labels rasterize from MSDF text atlases with GPU collision, rank-budgeted point-of-interest visibility, and per-language name selection. On the flat map, buildings extrude (solid or translucently composited) and cast real-time directional shadows from three cascades onto the ground, onto each other, and onto 3D models. Colors, road classes, landcover and label styles come from the map style, which an app tunes through its configuration or replaces outright.

### Your own content

- SwiftUI markers bound to coordinates with `.markers(_:coordinate:anchor:content:)`, repositioned every frame through the same projection the shaders use, without invalidating SwiftUI at display rate.
- Avatars and live markers with images, count, speed and battery badges, and merged clusters: ``ImmersiveMapAvatarsController``.
- Routes drawn as ribbons along great-circle paths, truncated at an exact arc-length fraction: ``ImmersiveMapRoutesController``.
- USDZ and OBJ models anchored to coordinates and animated along a path: ``ImmersiveMapSceneModelsController``.
- Taps on avatars and models (`.onAvatarTap`, `.onSceneModelTap`) plus a shared selection model: ``ImmersiveMapSelectionController``.

### Camera

``ImmersiveMapCameraController`` jumps, flies (with cinematic van Wijk and Nuij overview arcs for long flights), travels along an ``ImmersiveMapGeoPath``, and reports every camera change back to the app. ``ImmersiveMapCameraTourController`` chains flights and holds into a scripted tour. Gestures are cursor-anchored, with pan inertia, double-tap zoom, optional on-screen controls, and configurable zoom, pitch and bearing limits that follow the presentation.

### Map data

The built-in tile source renders out of the box; any other MVT endpoint plugs in with one URL template, `.tileURLTemplate("https://tiles.com/{x}/{y}/{z}?apiKey=xxx", headers: [:])`, with parsing and styling configured separately through ``VectorTileMapStyle``. Tiles are cached on disk twice (raw bytes and GPU-ready prepared geometry) and stay in memory only while a frame draws them, and ``ImmersiveMapOfflineController`` downloads whole regions that keep rendering with no network at all.

### Export

``ImmersiveMapTourVideoRecorder`` takes the same shot list as a scripted tour and writes it to a QuickTime file (HEVC, 1920x1080 at 60 fps by default), rendered offline in a second headless engine while the on-screen map stays interactive. ``ImmersiveMapStillRecorder`` renders one frame the same way, with no map on screen at all, and hands it back as a `CGImage`.

### Frame loop

Rendering is on-demand: the display link stays paused until something needs a frame (interaction, label fades, camera or avatar animation, an arriving tile). Frame rates follow ProMotion when the display allows it and back off under thermal pressure or Low Power Mode, dismantled map views are parked and reused by the next screen, and `os_signpost` intervals make every frame stage and tile stage visible in Instruments.

> Important: ImmersiveMap is pre-1.0. The public API is still moving: a deprecation is short-lived and the symbol is removed in a following release, so read the release notes before updating.

Feature guides, one example app per feature and the changelog live in the [repository](https://github.com/artembobkin/ImmersiveMap). The default tile service, API keys and usage dashboard live at [immersivemap.dev](https://immersivemap.dev).

## Topics

### Essentials

- ``ImmersiveMapView``
- ``ImmersiveMapSettings``

### Camera

- ``ImmersiveMapCameraController``
- ``ImmersiveMapCameraPosition``
- ``CameraFlightOptions``
- ``CameraFlightAltitudeStyle``
- ``CameraFlightRouteStyle``
- ``ImmersiveMapCameraFollowOptions``
- ``ImmersiveMapCameraSnapshot``
- ``ImmersiveMapCameraAngleLimits``
- ``ImmersiveMapCameraBearingLimits``
- ``ImmersiveMapCameraControlPanel``

### Scripted Tours

- ``ImmersiveMapCameraTourController``
- ``ImmersiveMapCameraTourShot``

### Geography and Paths

- ``GeoCoordinate``
- ``ImmersiveMapGeoPath``
- ``ImmersiveMapPathAnimationCurve``

### Avatars and Live Markers

- ``ImmersiveMapAvatarsController``
- ``AvatarMarker``
- ``AvatarMarkerImageSource``
- ``AvatarCountBadge``
- ``AvatarSpeedBadge``
- ``AvatarBatteryBadge``
- ``AvatarClusterPolicy``
- ``AvatarsSnapshot``
- ``AvatarMarkerImageFactory``
- ``AvatarMarkerImageLoader``
- ``AvatarMarkerImageLoaderError``

### Routes

- ``ImmersiveMapRoutesController``
- ``ImmersiveMapRoute``
- ``ImmersiveMapRouteDash``

### 3D Scene Models

- ``ImmersiveMapSceneModelsController``
- ``ImmersiveMapSceneModel``

### Taps and Selection

- ``ImmersiveMapSelectionController``
- ``ImmersiveMapSelection``
- ``ImmersiveMapSelectionSource``
- ``ImmersiveMapSelectionChangeEvent``
- ``ImmersiveMapSelectionClearEvent``
- ``ImmersiveMapAvatarTapEvent``
- ``ImmersiveMapSceneModelTapEvent``

### Tile Sources

- ``ImmersiveMapTilesService``
- ``ImmersiveMapAttribution``

### Map Styles

- ``ImmersiveMapMapStyle``
- ``ImmersiveMapTilesMapStyle``
- ``ImmersiveMapTilesDefaultMapStyleConfiguration``
- ``VectorTileMapStyle``
- ``AnyImmersiveMapMapStyle``

### Styling Your Own Vector Tiles

- ``ImmersiveMapVectorTileStyle``
- ``BasicVectorTileStyle``
- ``ImmersiveMapFeatureStyle``
- ``ImmersiveMapFeatureProperties``
- ``ImmersiveMapFeatureStyleContext``
- ``ImmersiveMapLabelTextStyle``
- ``LabelFontWeight``
- ``ImmersiveMapVectorTileLabelProfile``

### Offline Regions

- ``ImmersiveMapOfflineController``
- ``ImmersiveMapOfflineRegion``
- ``ImmersiveMapOfflineRegionStatus``
- ``ImmersiveMapOfflineError``

### Video Export

- ``ImmersiveMapTourVideoRecorder``
- ``ImmersiveMapVideoExportConfiguration``
- ``ImmersiveMapVideoExportProgress``
- ``ImmersiveMapVideoExportError``

### Still Capture

- ``ImmersiveMapStillRecorder``
- ``ImmersiveMapStillConfiguration``
- ``ImmersiveMapStillCaptureError``

### Settings

- ``ImmersiveMapSettings/CameraSettings``
- ``ImmersiveMapSettings/PresentationSettings``
- ``ImmersiveMapSettings/TileSettings``
- ``ImmersiveMapSettings/LabelSettings``
- ``ImmersiveMapSettings/LabelLanguage``
- ``ImmersiveMapSettings/LabelFallbackPolicy``
- ``ImmersiveMapSettings/SceneSettings``
- ``ImmersiveMapSettings/SceneLightSettings``
- ``ImmersiveMapSettings/ShadowSettings``
- ``ImmersiveMapSettings/StarfieldSettings``
- ``ImmersiveMapSettings/SpaceSettings``
- ``ImmersiveMapSettings/StyleSettings``
- ``ImmersiveMapSettings/AvatarSettings``
- ``ImmersiveMapSettings/AttributionSettings``
- ``ImmersiveMapSettings/PostProcessingSettings``
- ``ImmersiveMapSettings/RenderLoopSettings``
- ``ImmersiveMapSettings/ViewReuseSettings``
- ``ImmersiveMapSettings/DebugSettings``
