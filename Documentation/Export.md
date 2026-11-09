# Export

The map can render a picture or a video of itself, offscreen and at any size. The map on screen stays interactive meanwhile.

## A picture

```swift
let recorder = ImmersiveMapStillRecorder()
let image = try await recorder.capture(
    settings: .default,
    camera: ImmersiveMapCameraPosition(latitudeDegrees: 55.75, longitudeDegrees: 37.61, zoom: 14),
    configuration: ImmersiveMapStillConfiguration(width: 1280, height: 720))
```

You get a `CGImage`. No map has to be on screen, so this suits thumbnails and share images.

- **Settings.** Pass the same `ImmersiveMapSettings` as your map, with your tile source and style, to get the same look.
- **Content.** Avatars and 3D models are passed as values, with `avatars:` and `sceneModels:`. SwiftUI markers can't be drawn into a picture.
- **Waiting.** The capture waits for the tiles it needs, up to `settleTimeout` (10 seconds by default), so the picture is complete.
- **Repeatability.** Set `sceneDate` to get the same sun and the same picture on every run.

## A video

Record a camera tour, the same shots as a tour on screen (see [Camera](Camera.md)), into a QuickTime file:

```swift
@State private var recorder = ImmersiveMapTourVideoRecorder()

ImmersiveMapView()
    .tourVideoRecorder(recorder)

// Later:
try await recorder.export(
    shots: [
        ImmersiveMapCameraTourShot(position: start),
        ImmersiveMapCameraTourShot(position: end, options: CameraFlightOptions(duration: 6)),
    ],
    configuration: ImmersiveMapVideoExportConfiguration(width: 1920, height: 1080, framesPerSecond: 60),
    to: outputURL)
```

The recorder takes the map's current look when the export starts. It renders frame by frame, waiting for each frame's tiles, so the video never shows a missing tile, whatever the network does.

- **Format.** HEVC by default, or `codec: .h264` for wider compatibility.
- **Content.** Avatars and SwiftUI markers are drawn in. `includesAvatars: false` and `includesMarkers: false` leave them out.
- **Progress.** `recorder.onProgress` reports the phase and `fractionCompleted`, and `recorder.cancel()` stops the export and deletes the partial file.

## Credit

Neither a picture nor a video contains the attribution badge. Add the data's credit wherever you publish them (see [Attribution](Attribution.md)).
