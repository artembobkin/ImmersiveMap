# 3D scene models

```swift
struct MapScreen: View {
    @State private var sceneModels = ImmersiveMapSceneModelsController()

    var body: some View {
        ImmersiveMapView()
            .sceneModels(sceneModels)
            .onAppear {
                guard let source = ImmersiveMapSceneModel.Source(resource: "biplane",
                                                                 withExtension: "usdz") else { return }
                sceneModels.add(ImmersiveMapSceneModel(
                    id: 1,
                    source: source,
                    coordinate: GeoCoordinate(latitude: 48.8584, longitude: 2.2945),
                    headingDegrees: 45,
                    fitDiameterMeters: 120))
            }
    }
}
```
