# Map styling and colors

```swift
let night = ImmersiveMapTilesDefaultMapStyleConfiguration.immersiveMapTilesDefault
    .layers { layers in
        layers.land = SIMD4<Float>(0.08, 0.09, 0.11, 1)
        layers.water = SIMD4<Float>(0.06, 0.14, 0.28, 1)
        layers.wood = SIMD4<Float>(0.07, 0.14, 0.10, 1)
        layers.roads.motorway = SIMD4<Float>(0.55, 0.47, 0.22, 1)
    }
    .features { features in
        features.buildingFillColor = SIMD4<Float>(0.18, 0.19, 0.23, 1)
    }
    .labels { labels in
        labels.city.fillColor = SIMD3<Float>(0.93, 0.94, 0.97)
        labels.city.strokeColor = SIMD3<Float>(0.02, 0.03, 0.06)
    }

ImmersiveMapView()
    .mapStyle(ImmersiveMapTilesMapStyle(configuration: night))
```
