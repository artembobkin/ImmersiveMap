# Tour video export

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
