# Tour video export

Export a camera tour as a video file with `ImmersiveMapTourVideoRecorder`. The recorder takes the same shot list you would give [`ImmersiveMapCameraTourController`](camera.md), renders it offline into a second, headless render engine, and writes a QuickTime (`.mov`) file: HEVC at 1920×1080, 60 fps by default. Every frame waits for its tiles before it is captured, the timestep is exact, and the on-screen map stays fully interactive while the export runs.

```swift
struct MapScreen: View {
    @State private var camera = ImmersiveMapCameraController()
    @State private var recorder = ImmersiveMapTourVideoRecorder()

    var body: some View {
        ImmersiveMapView()
            .camera(camera, position: overview)
            .tourVideoRecorder(recorder)
    }

    func exportTour(to url: URL) async throws {
        recorder.onProgress = { progress in
            print("export: \(Int(progress.fractionCompleted * 100))%")
        }
        try await recorder.export(shots: makeShots(),   // [ImmersiveMapCameraTourShot]
                                  establish: overview,
                                  to: url)
    }
}
```

Attach the recorder with `.tourVideoRecorder(_:)` before exporting, because that is how it picks up the map's current configuration (tile provider, map style, label settings, avatars). Calling `export` on an unattached recorder throws `ImmersiveMapVideoExportError.notAttached`.

## Configuration

Pass an `ImmersiveMapVideoExportConfiguration` to customize the output:

```swift
var configuration = ImmersiveMapVideoExportConfiguration()
configuration.width = 3840
configuration.height = 2160
configuration.framesPerSecond = 30
configuration.codec = .h264
try await recorder.export(shots: shots, configuration: configuration, to: url)
```

| Field | Default | Meaning |
|---|---|---|
| `width` × `height` | 1920 × 1080 | Output size in pixels. Even values, 64...8192. |
| `framesPerSecond` | 60 | Output frame rate, 1...120. |
| `codec` | `.hevc` | `.hevc` (what Apple devices record natively) or `.h264` (maximum compatibility). The container is always QuickTime `.mov`. |
| `averageBitRate` | derived | Target bits per second. The default follows the frame geometry: ~12 Mbit/s for HEVC and ~25 Mbit/s for H.264 at 1080p60. |
| `tileReadinessTimeout` | 10 s | How long one frame may wait for outstanding tiles before it is captured with whatever has loaded. Also caps the pre-roll. |
| `sceneDate` | export start | Wall date for the earth scene (sun position), fixed across the whole export for determinism. |
| `includesAvatars` | `true` | Whether avatar markers are rendered into the video. The export uses a detached copy of the avatar state taken at export start, so live avatar updates during the export are not captured. |
| `includesMarkers` | `true` | Whether SwiftUI markers (`.markers(...)`) are composited into the video. Views are rasterized once at export start and follow the same per-frame projection (anchor, globe-horizon fade) as on screen. |
| `markerScale` | 2.0 | Rasterization scale of SwiftUI markers in pixels per point (0.5...8). The default sizes markers as on a Retina display whose drawable matches the export resolution; raise it for 4K exports. |

Progress arrives on the main thread via `onProgress` as `ImmersiveMapVideoExportProgress` (phase, frames completed, fraction). `cancel()` aborts the export: `export` throws `.cancelled` and the partial file is deleted.

## How it works

The export never records the screen. It builds a second, headless `RenderFrameEngine` from a snapshot of the view's settings and replays the tour deterministically:

- Tour time advances in exact `1/fps` steps. Camera flights are pure functions of that timeline: the same easing, routes (including `.automatic` great-circle resolution), overview arcs, and exact-target snaps as the live tour controller.
- Before the first frame the exporter renders a discarded pre-roll until tiles, label fades, and the label visibility cycle settle, so frame 0 is fully composed.
- Each captured frame renders, and if tiles for the new viewport are still loading, waits for them (up to `tileReadinessTimeout`) and re-renders with scene time held, so no tile pop-in is captured mid-fade.
- Frames render straight into `CVPixelBuffer`-backed Metal textures (zero copy) and are encoded by `AVAssetWriter` with BT.709 color tagging.
- Avatar markers render in Metal like on screen, from a detached copy of the avatar state (snapshots are consumed destructively, so the live and export engines cannot share one controller). SwiftUI markers cannot render in Metal (the live map hosts them as platform views above the map), so the export rasterizes each marker view once and composites the images onto finished frames at the exact projected positions, with the same anchor and horizon-fade alpha as the live overlay.

Because rendering is offline, the export can run faster or slower than real time depending on hardware and network, and a settings change or gesture on the live map does not affect it. The export starts from `establish` when given, otherwise from the map's current camera position. `loop` and `stopOnUserInteraction` semantics of the live tour do not apply: an export is one finite pass.

## Limitations

- The attribution badge and the debug HUD are host-view chrome and do not appear in the exported video. **If you publish exported footage, add the required data attribution yourself** (see `Documentation/docs/map-data.md`).
- Avatars and SwiftUI markers are captured as of export start (`includesAvatars` / `includesMarkers`): later live mutations (moved avatars, changed marker sets, stateful marker view updates) are not reflected in a running export. Interactive marker states (e.g. a pressed button) are not captured either; markers are rasterized in their idle appearance.
- Remote avatar images have no readiness signal; images already shown on the live map are typically warm in the shared cache. Merged-avatar image cycling is frozen during the export for determinism.
- The export engine is a full second engine: expect additional GPU and cache memory for the duration of the export. Disk tile caches are shared with the live map, so a tour the map has already played exports without re-downloading.
- Label and symbol sizes are defined in pixels by the map style, so their apparent size scales with the chosen output resolution: a 4K export shows relatively smaller labels than a 1080p export. Pick the resolution accordingly (and raise `markerScale` for 4K).
- [Routes](routes.md) and [3D scene models](scene-models.md) are not rendered into the export.

Running example: [`Examples/macOS/ImmersiveMapCameraTourMac`](../../Examples/macOS/ImmersiveMapCameraTourMac) exports one lap of its cinematic to a file chosen in a save panel, with progress and cancellation, while the on-screen map stays interactive.
